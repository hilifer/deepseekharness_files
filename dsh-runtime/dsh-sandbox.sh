#!/bin/bash
# =====================================================================
# dsh-sandbox.sh — 用 bubblewrap 把单个 dsh 实例钳制在自己的工作区内
#
# 用法: dsh-sandbox.sh <username> <port> <dsh_home> <workspace>
#       dsh-sandbox.sh --check          # 仅自检沙箱是否可用，不启动实例
#
# 与 dsh-plugin-clamped-picker 的区别（二者是互补的两层）：
#   插件层：只覆盖目录选择器的 list/createDirectory，是 UX 钳制，
#           dsh 的 bash 工具用绝对路径可以完全绕过。
#   本层  ：挂载命名空间。工作区以外的路径在沙箱里【根本不存在】，
#           bash 用绝对路径也读不到——因为那个 inode 不在这个 mount ns 里。
#
# 沙箱内可见的全部内容：
#   ro  /usr /bin /sbin /lib* /etc            系统运行时
#   ro  $NODE_ROOT                            node + dsh 程序本体
#   ro  $SHARED_PROFILES                      共享插件（只读 => 用户改不了别人的 patch）
#   rw  $DSH_HOME                             本人实例状态
#   rw  $WORKSPACE                            本人工作区
#       /proc /dev /tmp                       内核接口 + 私有 tmpfs
#
# 沙箱内【不存在】的（当前部署下的高危目标）：
#   dsh-auth/          Authelia 用户库、initial-credentials.txt（全员明文初始密码）
#   nginx/certs/       TLS 私钥
#   filebrowser/       database.db（全员权限模型）
#   scripts/ admin/    建号脚本与管理后台代码
#   其他部门/其他员工的目录、其他用户的 DSH_HOME
#
# 失败策略：FAIL-CLOSED。沙箱不可用时【拒绝启动实例】，而不是退回无隔离运行。
#   仅当显式设置 DSH_ALLOW_UNCONFINED=1 时才允许裸跑（仅供排障，会大声告警）。
# =====================================================================
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
NODE_ROOT="${DSH_NODE_ROOT:-$DSH_ROOT/node}"
NODE_BIN="${DSH_NODE_BIN:-$NODE_ROOT/bin/node}"
DSH_BIN="${DSH_BIN:-$NODE_ROOT/bin/dsh}"
SHARED_PROFILES="${DSH_SHARED_PROFILES:-$DSH_ROOT/.local/share/dsh/profiles}"

# dsh 的 --trusted-host，三个入口域全填（见 OPS.md）。
# 公网 IP 是云 NAT，不绑在本机网卡上，只填它的话本机与局域网访问会被
# dsh 的 Host 校验一律拒绝。现场实测已确认 dsh 接受重复的 --trusted-host。
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-218.17.143.249:8099 192.168.1.225:8099 127.0.0.1:8099}"

# 允许透传进沙箱的环境变量名（dsh 的模型 API Key 之类放这里）
DSH_SANDBOX_PASSENV="${DSH_SANDBOX_PASSENV:-}"

# 本人工作区之外还要挂载的空间，由 core.py 计算后传入。
# 每行一条 "mode<TAB>path"，mode 为 ro 或 rw。典型来源：
#   - 主管：整个部门目录（rw），与 FileBrowser 的部门级 scope 对齐
#   - 管理员在后台为某人单独配置的共享目录 / 只读资料库
# core.py 已校验过每条路径解析符号链接后仍在 dsh-files 之内。
DSH_EXTRA_MOUNTS="${DSH_EXTRA_MOUNTS:-}"

# 网络隔离模式（可选，默认关闭）。
#   0 = 与宿主共享网络命名空间。文件系统仍完全隔离，但沙箱能连宿主 127.0.0.1
#       上的服务；FileBrowser 与管理后台已用密钥头挡住，但【员工 A 可以直连
#       员工 B 的 dsh 端口】驱动其 agent —— 这是已知残留风险。
#   1 = 每实例独立网络命名空间：pasta 提供出网，入站改走 unix socket，
#       宿主回环上不再留下任何 dsh 端口，实例间互连即被封死。
#       需要 pasta（passt 包）与 socat。已在 GitHub runner 上实测通过 7/7。
DSH_NETNS="${DSH_NETNS:-0}"
DSH_SOCKET_DIR="${DSH_SOCKET_DIR:-$DSH_ROOT/dsh-sockets}"
DSH_DNS_FORWARD="${DSH_DNS_FORWARD:-10.0.2.3}"

log() { echo "[sandbox] $*" >&2; }
die() { echo "[sandbox] 错误: $*" >&2; exit 1; }

# ---------- 定位 bwrap ----------
# 只找到文件是不够的：内核禁用非特权 user namespace 时 bwrap 装着也跑不起来。
# 早先这里只判可执行，于是「存在但坏」会走进沙箱分支，每次启动都失败、实例
# 直接死掉，而 DSH_ALLOW_UNCONFINED 那条降级路径压根够不到——运维只能把
# bwrap 改名骗过检测。现在把「能不能真跑」并进查找条件，两种情况一视同仁。
bwrap_usable() {
  [ -x "$1" ] && "$1" --ro-bind / / --unshare-all --share-net true >/dev/null 2>&1
}

find_bwrap() {
  if [ -n "${BWRAP_BIN:-}" ]; then
    bwrap_usable "$BWRAP_BIN" && { echo "$BWRAP_BIN"; return 0; }
    return 1
  fi
  local c
  for c in "$(command -v bwrap 2>/dev/null || true)" \
           "$DSH_ROOT/bwrap/usr/bin/bwrap" \
           /usr/bin/bwrap /bin/bwrap; do
    [ -n "$c" ] && bwrap_usable "$c" && { echo "$c"; return 0; }
  done
  return 1
}

# 仅用于报错时区分「没装」和「装了但跑不起来」
find_bwrap_binary() {
  if [ -n "${BWRAP_BIN:-}" ] && [ -x "${BWRAP_BIN:-}" ]; then echo "$BWRAP_BIN"; return 0; fi
  local c
  for c in "$(command -v bwrap 2>/dev/null || true)" \
           "$DSH_ROOT/bwrap/usr/bin/bwrap" \
           /usr/bin/bwrap /bin/bwrap; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# ---------- 自检：bwrap 存在且 user namespace 真的能用 ----------
sandbox_check() {
  local bw
  if bw=$(find_bwrap); then echo "OK $bw"; return 0; fi
  if bw=$(find_bwrap_binary); then echo "BROKEN $bw"; return 1; fi
  echo "MISSING"; return 1
}

netns_check() {
  local missing=""
  command -v pasta >/dev/null 2>&1 || missing="$missing pasta(passt)"
  command -v socat >/dev/null 2>&1 || missing="$missing socat"
  [ -z "$missing" ] || { echo "MISSING_DEPS$missing"; return 1; }
  echo "OK"; return 0
}

if [ "${1:-}" = "--check" ]; then
  if out=$(sandbox_check); then
    log "沙箱可用: $out"
    if [ "$DSH_NETNS" = "1" ]; then
      if nout=$(netns_check); then
        log "网络隔离模式: 已启用（pasta + unix socket）"
      else
        log "网络隔离模式: 已请求但依赖缺失 -> $nout"
        log "  安装: sudo apt-get install -y passt socat"
        echo "$nout"; exit 1
      fi
    else
      log "网络隔离模式: 未启用（DSH_NETNS=1 可开启，见 OPS.md）"
    fi
    echo "$out"; exit 0
  else
    log "沙箱不可用: $out"
    case "$out" in
      MISSING*)
        log "  -> 运行 scripts/install-bubblewrap.sh 安装（rootless 解包，无需 root）"
        ;;
      BROKEN*)
        log "  -> bwrap 在，但跑不起来。具体报错:"
        # 这条必然失败（就是要看它的报错）；脚本开头有 set -e -o pipefail，
        # 不加 || true 会在这里直接退出，后面的排障提示就永远打不出来。
        { "${out#BROKEN }" --ro-bind / / --unshare-all --share-net true 2>&1 \
          | sed 's/^/     /' >&2; } || true
        aa=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
        if [ -r "$aa" ] && [ "$(cat "$aa")" = "1" ]; then
          log "  -> 已定位原因：AppArmor 拦截了非特权 user namespace"
          log "     （Ubuntu 24.04 起默认开启，报错为 'setting up uid map: Permission denied'）"
          log "     处理: sudo $DSH_ROOT/scripts/apparmor-allow-userns.sh"
          log "           （默认只给 bwrap 开口子；加 --sysctl 则全局关闭该限制）"
          log "     注意这是宿主机的内核设置，容器内改不了。"
        else
          log "  -> 其他可能原因:"
          log "     sysctl kernel.unprivileged_userns_clone / user.max_user_namespaces"
          log "     Docker 默认 seccomp 会拦 unshare(CLONE_NEWUSER)，需容器侧放开"
        fi
        ;;
    esac
    echo "$out"; exit 1
  fi
fi

# ---------- 参数 ----------
USERNAME="${1:?用法: dsh-sandbox.sh <username> <port> <dsh_home> <workspace>}"
PORT="${2:?缺少 port}"
DSH_HOME_DIR="${3:?缺少 dsh_home}"
WORKSPACE="${4:?缺少 workspace}"

# ---------- 取 bwrap，失败则 fail-closed ----------
if ! BWRAP=$(find_bwrap); then
  if bwrap_path=$(find_bwrap_binary); then
    why="bwrap 在 $bwrap_path 但跑不起来（多半是内核禁用了非特权 user namespace）"
    fix="放行: sudo $DSH_ROOT/scripts/apparmor-allow-userns.sh"
  else
    why="未找到 bwrap"
    fix="安装: $DSH_ROOT/scripts/install-bubblewrap.sh"
  fi

  if [ "${DSH_ALLOW_UNCONFINED:-0}" = "1" ]; then
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! 警告: $why"
    log "!! DSH_ALLOW_UNCONFINED=1 -> 无隔离启动 $USERNAME 的实例"
    log "!! 该实例可读写整台服务器的所有文件，包括其他部门的文件、"
    log "!! 明文初始密码和 TLS 私钥。仅供排障，不要长期这样跑。"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    # 降级路径同样要传【全部】 trusted-host：只传第一个（公网 IP）的话，
    # 云 NAT 场景下本机与局域网访问会被 dsh 的 Host 校验一律拒绝。
    dg_args=()
    for h in $DSH_TRUSTED_HOSTS; do dg_args+=(--trusted-host "$h"); done
    export DSH_HOME="$DSH_HOME_DIR" DSH_ALLOWED_ROOT="$WORKSPACE"
    export DSH_ALLOWED_ROOTS="$WORKSPACE" DSH_NODE_ROOT="$NODE_ROOT"
    export DSH_UPLOAD_DIR="${DSH_UPLOAD_DIR:-$WORKSPACE/uploads}"
    exec "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${dg_args[@]}"
  fi
  die "$why，拒绝以无隔离方式启动 $USERNAME 的实例。
       $fix
       排障临时放行(危险，全公司文件对该实例敞开): DSH_ALLOW_UNCONFINED=1"
fi

[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "端口不合法: $PORT"
[ -d "$DSH_HOME_DIR" ] || die "DSH_HOME 不存在: $DSH_HOME_DIR"
[ -d "$WORKSPACE" ]    || die "工作区不存在: $WORKSPACE"

# 工作区必须是真实路径（解析符号链接），否则 --bind 会把链接目标挂进来，
# 等于给了一条绕过隔离的路。
WORKSPACE=$(readlink -f "$WORKSPACE")
DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

# ---------- 组装挂载 ----------
args=(
  # 逐项 unshare 而非 --unshare-all：后者含 --unshare-net，
  # 在 netns 模式下会丢掉 pasta 刚配好的网络。
  --unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup
  --share-net            # 共享所在 netns（普通模式=宿主；netns 模式=pasta 的）
  --die-with-parent      # 父进程死则实例死，不留孤儿
  --new-session          # 断开控制终端，防 TIOCSTI 注入
  --proc /proc
  --dev /dev
  --tmpfs /tmp
)

# 系统只读目录（存在才挂）
for d in /usr /bin /sbin /lib /lib64 /lib32 /libx32 /etc /opt; do
  [ -e "$d" ] && args+=(--ro-bind "$d" "$d")
done

# node + dsh 本体（只读：用户改不了程序）
[ -d "$NODE_ROOT" ] || die "node 目录不存在: $NODE_ROOT"
args+=(--ro-bind "$NODE_ROOT" "$NODE_ROOT")

# 可写：本人实例状态 + 本人工作区。这两个是沙箱内仅有的可写持久化路径。
args+=(--bind "$DSH_HOME_DIR" "$DSH_HOME_DIR")
args+=(--bind "$WORKSPACE" "$WORKSPACE")

# 额外空间。allowed_roots 供选择器钳制插件使用（本人工作区永远在内）。
allowed_roots="$WORKSPACE"
if [ -n "$DSH_EXTRA_MOUNTS" ]; then
  while IFS=$'\t' read -r m_mode m_path; do
    [ -n "${m_path:-}" ] || continue
    if [ ! -d "$m_path" ]; then
      log "跳过不存在的额外挂载: $m_path"; continue
    fi
    m_real=$(readlink -f "$m_path")
    case "$m_mode" in
      rw) args+=(--bind "$m_real" "$m_real") ;;
      ro) args+=(--ro-bind "$m_real" "$m_real") ;;
      *)  die "额外挂载模式不合法: $m_mode ($m_path)" ;;
    esac
    log "  额外空间 [$m_mode] $m_real"
    allowed_roots="$allowed_roots"$'\n'"$m_real"
  done <<< "$DSH_EXTRA_MOUNTS"
fi

# 共享 profiles 只读挂载。
# 现状是每个 DSH_HOME 下 profiles 符号链接到同一个共享目录，而所有实例同为
# ubuntu 用户 —— 任何员工都能改写 clamped-picker/index.mjs 影响全体。
# 挂成只读即堵住这条路。若 dsh 需要写 profiles，改用每用户副本（见 core.py）。
# 必须排在 DSH_HOME 之后：admin 实例的 profiles 就在其 DSH_HOME 内部，
# 后挂载的会覆盖先挂载的，顺序反了 profiles 会变回可写。
if [ -d "$SHARED_PROFILES" ]; then
  args+=(--ro-bind "$SHARED_PROFILES" "$SHARED_PROFILES")
fi

# 网络隔离模式：把本用户【专属】的 socket 目录挂进去（不是整个 dsh-sockets，
# 否则沙箱里能看到别人的 socket 路径）。
if [ "$DSH_NETNS" = "1" ]; then
  USER_SOCK_DIR="$DSH_SOCKET_DIR/$USERNAME"
  mkdir -p "$USER_SOCK_DIR"; chmod 700 "$USER_SOCK_DIR"
  printf 'nameserver %s\n' "$DSH_DNS_FORWARD" > "$USER_SOCK_DIR/resolv.conf"
  args+=(--bind "$USER_SOCK_DIR" "$USER_SOCK_DIR")

  # 沙箱里的 DNS 必须指向 pasta 的转发器，否则解析会打到宿主的 stub resolver
  # （127.0.0.53），而那个地址在实例自己的 netns 里没人监听。
  #
  # 坑：Ubuntu 的 /etc/resolv.conf 是指向 /run/systemd/resolve/... 的符号链接。
  # /etc 被挂成只读，直接 --ro-bind 到 /etc/resolv.conf 会因为链接悬空、
  # 又无法在只读的 /etc 里造挂载点而失败：
  #   bwrap: Can't create file at /etc/resolv.conf: No such file or directory
  # 所以要按链接的真实目标来挂，并给目标所在的目录先铺一层 tmpfs。
  resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
  if [ -z "$resolv_target" ] || [ "$resolv_target" = "/etc/resolv.conf" ]; then
    args+=(--ro-bind "$USER_SOCK_DIR/resolv.conf" /etc/resolv.conf)
  elif [ "${resolv_target#/run/}" != "$resolv_target" ]; then
    # 链接指向 /run 下（systemd-resolved 的常见形态）。tmpfs 是可写的，
    # bwrap 会自动补出中间目录，顺带也把宿主的 /run 挡在外面。
    args+=(--tmpfs /run)
    args+=(--ro-bind "$USER_SOCK_DIR/resolv.conf" "$resolv_target")
  else
    die "/etc/resolv.conf 指向 $resolv_target，无法在沙箱内改写它。
       请把 DSH_DNS_FORWARD 的地址直接写进宿主的 resolv.conf，或改用 DSH_NETNS=0。"
  fi
  # 入口脚本必须显式挂进来：沙箱只挂了系统目录、node、DSH_HOME 和工作区，
  # dsh-runtime/ 不在其中，不挂的话沙箱里根本找不到这个文件。
  NETNS_ENTRY="$DSH_ROOT/dsh-runtime/dsh-netns-entry.sh"
  [ -r "$NETNS_ENTRY" ] || die "找不到 netns 入口脚本: $NETNS_ENTRY"
  args+=(--ro-bind "$NETNS_ENTRY" "$NETNS_ENTRY")
fi

args+=(--chdir "$WORKSPACE")

# ---------- 环境变量：清空后按白名单重建 ----------
args+=(--clearenv)
args+=(--setenv PATH "$NODE_ROOT/bin:/usr/local/bin:/usr/bin:/bin")
args+=(--setenv HOME "$DSH_HOME_DIR")
args+=(--setenv DSH_HOME "$DSH_HOME_DIR")
args+=(--setenv DSH_ALLOWED_ROOT "$WORKSPACE")     # 第二层：选择器 UX 钳制（主工作区）
args+=(--setenv DSH_ALLOWED_ROOTS "$allowed_roots") # 含额外空间的完整允许列表，每行一条

# 文件上传插件（dsh-file-uploads 之类）的落盘目录。
# 插件默认存到 $DSH_HOME/uploads —— 那个目录不在 FileBrowser 的 source 里，
# 员工在 dsh 里传的文件在文件服务器上根本看不见，与「两边看到同一个空间」
# 相矛盾。所以默认改到本人工作区之下，传完立刻能在 /files/ 里看到。
# 沙箱用了 --clearenv，不显式 setenv 的话插件读不到这个值。
# 未装上传插件时这个变量无人使用，留着无副作用。
args+=(--setenv DSH_UPLOAD_DIR "${DSH_UPLOAD_DIR:-$WORKSPACE/uploads}")
args+=(--setenv DSH_NODE_ROOT "$NODE_ROOT")     # 钳制插件据此定位 dsh 的内部包
args+=(--setenv USER "$USERNAME")
args+=(--setenv LANG "${LANG:-C.UTF-8}")
args+=(--setenv TZ "${TZ:-Asia/Shanghai}")
for varname in $DSH_SANDBOX_PASSENV; do
  if [ -n "${!varname:-}" ]; then args+=(--setenv "$varname" "${!varname}"); fi
done

# ---------- trusted-host（支持多个域）----------
host_args=()
for h in $DSH_TRUSTED_HOSTS; do host_args+=(--trusted-host "$h"); done

if [ "$DSH_NETNS" != "1" ]; then
  log "启动 $USERNAME: port=$PORT ws=$WORKSPACE (bwrap=$BWRAP, 共享网络)"
  exec "$BWRAP" "${args[@]}" -- \
    "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${host_args[@]}"
fi

# ---------- 网络隔离模式 ----------
nout=$(netns_check) || die "DSH_NETNS=1 但依赖缺失: $nout（sudo apt-get install -y passt socat）"

SOCKET="$USER_SOCK_DIR/dsh.sock"
args+=(--setenv DSH_SOCKET "$SOCKET")
args+=(--setenv DSH_PORT "$PORT")
args+=(--setenv DSH_NODE_BIN "$NODE_BIN")
args+=(--setenv DSH_BIN "$DSH_BIN")
args+=(--setenv DSH_TRUSTED_HOST_ARGS "${host_args[*]}")

log "启动 $USERNAME: socket=$SOCKET ws=$WORKSPACE (bwrap=$BWRAP, 独立网络命名空间)"
# pasta 建独立 netns 并提供出网；-t none -u none 表示不做任何入站端口转发，
# 入站只走 unix socket。--no-map-gw 断掉经网关回连宿主的路径。
# bwrap 在 pasta 的 netns 里用 --share-net（共享的是 pasta 的，不是宿主的）。
exec pasta --config-net --no-map-gw -t none -u none \
  --dns-forward "$DSH_DNS_FORWARD" -- \
  "$BWRAP" "${args[@]}" -- bash "$NETNS_ENTRY"
