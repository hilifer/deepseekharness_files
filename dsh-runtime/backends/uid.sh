#!/bin/bash
# =====================================================================
# 后端 uid —— 每个员工一个独立 OS 用户，靠文件权限（DAC）做强制点
#
# 用法（由 dsh-sandbox.sh 调度，不直接调用）:
#   backends/uid.sh probe
#   backends/uid.sh run <username> <port> <dsh_home> <workspace>
#
# 这是【最后一档】，只在前两档都拿不到时才选：
#   容器内是 root（能 useradd）、但既没有可用的 docker，也开不出命名空间
#   （无非特权 userns、无 CAP_SYS_ADMIN）。默认 docker 容器就是这个形状。
#
# 它给到什么：
#   ✔ 员工之间读不到彼此的工作区、DSH_HOME（不同 UID + 0770 目录）
#   ✔ 员工读不到 Authelia 用户库、TLS 私钥、FileBrowser 库、管理后台代码
#   ✔ 实例改不了 node/dsh 本体与共享插件（只读位）
#   ✔ 连不到同僚的实例端口与本机内部服务端口（netfilter 按 uid 匹配封锁）
#
# 【为什么必须有那条防火墙规则】DAC 只管文件。员工 A 的 shell 一句
#   curl 127.0.0.1:<B 的端口>
# 就能驱动 B 的 dsh，而那个进程以 B 的 uid 跑、读的是 B 的工作区——
# 一个字节的文件权限都没违反，B 的数据照样出来了。前两档靠 netns、
# landlock 档靠 TCP 端口白名单封这条路；本档只剩 netfilter 的 owner 匹配
# 这一个强制点，所以它是【probe 的硬前提】，拿不到就不选本档。
#
# 它【给不到】什么——这些必须如实写出来，不能让人误以为等价于前两档：
#   ✘ 无独立 pid ns：`ps` 能看到全机进程，能看到别人的命令行参数
#   ✘ /tmp 共享：只能靠粘滞位，不能防同名占坑
#   ✘ 一旦出现任何 setuid 提权点或【连得通】的 docker socket，整层就作废
#     （probe 会真去连一次，连得通就拒绝选用本后端；只有死 socket 文件不算）
#
# 因此：能用 container 或 bwrap 时永远不要用它。dsh-sandbox.sh 的选择顺序
# 已经保证了这一点。
# =====================================================================
set -euo pipefail

BACKEND_TAG=uid
# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 员工 OS 用户名前缀。useradd 上限 32 字符，username 已被 core.py 限到 33 字符
# 以内，这里再截一次保证不越界。
osuser_for() { local n="dsh-$1"; echo "${n:0:31}"; }

# 服务账号的组：工作区的组位留给它，FileBrowser / 管理后台（以该账号运行）
# 才能继续读写员工目录。不这么做，建号后文件服务器那一侧立刻全部 403。
service_gid() { stat -c %g "$DSH_ROOT"; }

have_dropper() {
  command -v setpriv >/dev/null 2>&1 || command -v runuser >/dev/null 2>&1
}

# ---------- 同僚端口封锁（本档唯一的网络强制点）----------
# 用 netfilter 的 owner 匹配：按【发起连接的 uid】拦截。这正好贴合本档的
# 隔离模型——每个员工一个 uid，规则也就一人一条链。
#   · nginx / FileBrowser / 管理后台以服务账号跑，不在任何一条规则里，不受影响
#   · 实例自己那个端口放行（RETURN），别的实例端口与内部服务端口一律 REJECT
#   · 入站不受影响：nginx 反代打进来的是 INPUT，规则只挂在 OUTPUT
fw_chain_for() { echo "DSH-ISO-$1"; }

# 本机可用的 iptables 变体。装了不等于能用（容器里常常没有 CAP_NET_ADMIN、
# 或者 xt_owner 模块加载不了），所以每个变体都真去列一次表。
fw_variants() {
  local c
  for c in iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 && "$c" -w 5 -S OUTPUT >/dev/null 2>&1 && echo "$c"
  done
}

# 真往 OUTPUT 里插一条 owner 规则再删掉——只判命令存在会漏掉最常见的两种
# 失败：没有 CAP_NET_ADMIN、内核没有 xt_owner。
fw_available() {
  local ipt; ipt=$(fw_variants | head -1)
  [ -n "$ipt" ] || return 1
  "$ipt" -w 5 -I OUTPUT 1 -p tcp --dport 65534 -m owner --uid-owner 0 -j RETURN 2>/dev/null || return 1
  "$ipt" -w 5 -D OUTPUT -p tcp --dport 65534 -m owner --uid-owner 0 -j RETURN 2>/dev/null
  return 0
}

fw_seal_peer_ports() { # $1=uid $2=本人端口
  local uid=$1 own=$2 chain ipt p
  chain=$(fw_chain_for "$uid")
  for ipt in $(fw_variants); do
    "$ipt" -w 5 -N "$chain" 2>/dev/null || true
    "$ipt" -w 5 -F "$chain" || die "清空链 $chain 失败（$ipt）"
    "$ipt" -w 5 -A "$chain" -p tcp --dport "$own" -j RETURN \
      || die "写入放行本人端口的规则失败（$ipt）"
    "$ipt" -w 5 -A "$chain" -p tcp --dport "$DSH_PORT_RANGE" -j REJECT --reject-with tcp-reset \
      || die "写入封锁实例端口段 $DSH_PORT_RANGE 的规则失败（$ipt）"
    for p in $DSH_INTERNAL_PORTS; do
      "$ipt" -w 5 -A "$chain" -p tcp --dport "$p" -j REJECT --reject-with tcp-reset \
        || die "写入封锁内部服务端口 $p 的规则失败（$ipt）"
    done
    # 挂到 OUTPUT 最前面，幂等
    "$ipt" -w 5 -C OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null \
      || "$ipt" -w 5 -I OUTPUT 1 -m owner --uid-owner "$uid" -j "$chain" \
      || die "把 $chain 挂进 OUTPUT 失败（$ipt）"
  done
}

# 装完再回内核里确认一次。规则不在就【不启动】——本档没有别的手段封这条路，
# 带着漏洞起来等于把「个体不能访问其他空间的数据」这条要求废掉。
fw_assert_sealed() { # $1=uid
  local chain ipt n=0
  chain=$(fw_chain_for "$1")
  for ipt in $(fw_variants); do
    "$ipt" -w 5 -C OUTPUT -m owner --uid-owner "$1" -j "$chain" 2>/dev/null \
      || die "OUTPUT 里找不到 uid=$1 的封锁规则（$ipt），拒绝启动。
       本档靠它挡住「员工 A 直连员工 B 的实例端口驱动其 agent」，
       没有它，DAC 再严也拦不住 B 的数据被读走。"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "一个 iptables 变体都用不了，拒绝启动（本档需要 CAP_NET_ADMIN + xt_owner）"
}

# ---------- probe ----------
backend_probe() {
  if [ "$(id -u)" != "0" ]; then
    echo "NOT_ROOT"; log "本后端需要 root（要 useradd 和 chown）"; return 1
  fi
  if ! command -v useradd >/dev/null 2>&1; then
    echo "NO_USERADD"; log "缺 useradd（apt-get install -y passwd）"; return 1
  fi
  if ! have_dropper; then
    echo "NO_DROPPER"; log "缺 setpriv / runuser（apt-get install -y util-linux）"; return 1
  fi
  if ! fw_available; then
    echo "NO_NETFILTER"
    log "拿不到 netfilter 的 owner 匹配（缺 iptables、缺 CAP_NET_ADMIN、或内核无 xt_owner）。"
    log "  本档没有别的手段封「员工 A 直连员工 B 的实例端口」这条路——那条路不经过"
    log "  文件系统，DAC 一点忙都帮不上：A 驱动 B 的 agent，读出来的就是 B 的工作区。"
    log "  处理: 容器加 --cap-add NET_ADMIN 并安装 iptables；或改用 container / landlock 档。"
    return 1
  fi
  if docker_socket_live; then
    echo "DOCKER_SOCKET_LIVE"
    log "机器上有【连得通】的 docker socket。UID 隔离在它面前完全无效——"
    log "  容器里的 shell 一句 'docker run -v /:/host ...' 就拿到整台宿主。"
    log "  这种环境请用 container 后端（它本来就更强），不要退到 uid。"
    return 1
  fi
  if docker_socket_file_exists; then
    # 死 socket 不构成逃逸路径，但这是颗定时炸弹：哪天有人把 dockerd 起起来，
    # 本档立刻失效。每次启动都会重新判一次，所以起了之后会被 run 那边拦住。
    log "注意: 有 docker socket 文件但连不上守护进程，暂不构成逃逸路径。"
    log "  一旦 dockerd 被启动，本档即刻失效——那时应改用 container 后端。"
  fi
  echo "OK root+useradd+netfilter"
  return 0
}

# ---------- 权限收紧 ----------
# 把「谁都能读」的默认状态改成「只有属主和服务账号能读」。
# 这一步是本后端的全部强制力所在，每次启动都重放一遍（幂等）。
#
# 顺序是有讲究的，颠倒了会互相覆盖：
#   1 先把【所有】员工目录对 others 关死（不能只关自己那份——没起过实例的
#     同事目录会一直是 755，谁都读得到）
#   2 再给必经的层级留 x 位（能穿过，但列不出同级有谁）
#   3 最后处理本人的两块可写空间（属主给本人，组位留给服务账号）
#   4 补回部门目录的 x 位：主管的空间就是整个部门目录，第 3 步会把它关死，
#     不补回来同部门的员工就进不去自己的目录了
harden_tree() { # $1=本人 os 用户 $2=dsh_home $3=workspace
  local osuser=$1 home=$2 ws=$3 gid; gid=$(service_gid)
  local d p lvl

  # 1 高危目录 + 所有员工目录：员工一律不可见
  for d in dsh-auth nginx filebrowser admin scripts dsh-runtime; do
    [ -e "$DSH_ROOT/$d" ] && chmod -R o= "$DSH_ROOT/$d" 2>/dev/null || true
  done
  for d in "$DSH_ROOT"/dsh-files/departments/*/*/; do
    [ -d "$d" ] && chmod -R o= "$d" 2>/dev/null || true
  done
  # 目录只给 x 位挡得住「列出」，挡不住「直接按路径读文件」——
  # dsh-users/registry.json 就是这么漏出去的（它 644，员工知道路径就能 cat）。
  # 所以这些层级里【直接躺着的文件】要单独收掉。
  for lvl in "$DSH_ROOT" "$DSH_ROOT/dsh-users" "$DSH_ROOT/dsh-files" \
             "$DSH_ROOT/dsh-files/departments"; do
    [ -d "$lvl" ] && find "$lvl" -maxdepth 1 -type f -exec chmod o= {} + 2>/dev/null || true
  done

  # 2 程序本体与共享插件：所有实例只读；必经层级只开「可穿过」不开「可列出」
  [ -d "$NODE_ROOT" ] && chmod -R o=rX "$NODE_ROOT" 2>/dev/null || true
  [ -d "$SHARED_PROFILES" ] && chmod -R o=rX "$SHARED_PROFILES" 2>/dev/null || true
  chmod o=x "$DSH_ROOT" 2>/dev/null || true
  for d in "$DSH_ROOT/dsh-files" "$DSH_ROOT/dsh-files/departments" "$DSH_ROOT/dsh-users" \
           "$DSH_ROOT/dsh-runtime"; do
    [ -d "$d" ] && chmod o=x "$d" 2>/dev/null || true
  done

  # 3 本人的两块可写空间：属主是本人，组是服务账号（FileBrowser 走组位），
  #   其他人零权限
  for p in "$home" "$ws"; do
    chown -R "$osuser:$gid" "$p" 2>/dev/null || true
    chmod -R u=rwX,g=rwX,o= "$p" 2>/dev/null || true
  done

  # 4 部门目录补回 x 位（主管的空间可能就是它，第 3 步已把它关死）
  for d in "$DSH_ROOT"/dsh-files/departments/*/; do
    [ -d "$d" ] && chmod o=x "$d" 2>/dev/null || true
  done

  # 额外空间（主管的整个部门目录、共享资料库等）只能走 ACL，不能 chown：
  # 部门目录里躺着各员工自己的目录，chown 过来会把他们的属主抢掉；而 DAC 的
  # 三段位（属主/组/其他）也表达不了「主管看得到全部门、员工只看得到自己」。
  # 这是本档相对命名空间档的又一处先天不足：没有 ACL 支持的文件系统上，
  # 主管的部门级权限【给不了】。
  local i
  for i in "${!MOUNT_PATHS[@]}"; do
    local perm=rX
    [ "${MOUNT_MODES[$i]}" = "rw" ] && perm=rwX
    if setfacl -R -m "u:$osuser:$perm" -m "d:u:$osuser:$perm" \
               "${MOUNT_PATHS[$i]}" 2>/dev/null; then
      log "  额外空间 [${MOUNT_MODES[$i]}] ${MOUNT_PATHS[$i]} 已用 ACL 授权"
    else
      log "  ⚠ 额外空间 ${MOUNT_PATHS[$i]} 授权失败（缺 setfacl，或文件系统不支持 ACL）"
      log "    该目录本次对 $osuser 不可访问。装 acl 包，或改用 container / bwrap 档。"
    fi
  done
}

assert_ancestors_traversable() {
  local p="$DSH_ROOT" bad=""
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    if [ "$(stat -c %a "$p" 2>/dev/null | tail -c 2)" ]; then
      # others 位（八进制最后一位）里没有 1 = 没有 x
      local o; o=$(stat -c %a "$p" 2>/dev/null); o="${o: -1}"
      case "$o" in 1|3|5|7) ;; *) bad="$p" ;; esac
    fi
    p=$(dirname "$p")
  done
  [ -z "$bad" ] || die "目录 $bad 对其他用户没有 x 位，员工用户穿不过去，实例必然起不来。
       处理: chmod o+x $bad （UID 档靠逐级目录权限，祖先目录必须可穿过）"
}

ensure_osuser() { # $1=os 用户名 $2=home
  local osuser=$1 home=$2
  if ! id -u "$osuser" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir "$home" \
            --shell /usr/sbin/nologin "$osuser" \
      || die "创建系统用户失败: $osuser"
    log "已创建系统用户 $osuser"
  fi
}

# ---------- run ----------
backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  [ "$(id -u)" = "0" ] || die "本后端需要 root（调度器本应先 probe 过）"
  if docker_socket_live; then
    die "检测到连得通的 docker socket，UID 隔离在它面前无效，拒绝启动（请改用 container 后端）"
  fi
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE"

  WORKSPACE=$(readlink -f "$WORKSPACE")
  DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

  assert_ancestors_traversable
  local osuser; osuser=$(osuser_for "$USERNAME")
  ensure_osuser "$osuser" "$DSH_HOME_DIR"

  parse_extra_mounts "$WORKSPACE"
  harden_tree "$osuser" "$DSH_HOME_DIR" "$WORKSPACE"

  build_instance_env "$USERNAME" "$DSH_HOME_DIR" "$WORKSPACE" "$ALLOWED_ROOTS"
  build_trusted_host_args

  local envargs=(env -i)
  local kv
  for kv in "${INSTANCE_ENV[@]}"; do envargs+=("$kv"); done

  # 进程的主组必须是【本人自己的组】，不能是服务账号的组。
  # 早先这里用了 service_gid：那等于把服务账号的组权限直接交给员工实例，
  # dsh-auth/ 下 640 root:root 的用户库、TLS 私钥立刻全部可读，本档形同虚设。
  # 服务账号的组只出现在工作区的【属主组】上（chown osuser:service_gid），
  # 供 FileBrowser 继续读写；员工本人走属主位，不需要那个组。
  local uid gid
  uid=$(id -u "$osuser"); gid=$(id -g "$osuser")

  # 网络强制点：封掉同僚实例端口与内部服务端口，只放行本人那个端口
  fw_seal_peer_ports "$uid" "$PORT"
  fw_assert_sealed "$uid"

  apply_rlimits
  cd "$WORKSPACE"
  log "启动 $USERNAME: port=$PORT ws=$WORKSPACE (os 用户 $osuser/$uid, DAC 隔离)"
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid="$uid" --regid="$gid" --clear-groups --inh-caps=-all --no-new-privs -- \
      "${envargs[@]}" "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
  fi
  exec runuser -u "$osuser" -- \
    "${envargs[@]}" "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
}

case "${1:-}" in
  probe) backend_probe ;;
  run)   shift; backend_run "$@" ;;
  *) echo "用法: $0 probe | run <username> <port> <dsh_home> <workspace>" >&2; exit 2 ;;
esac
