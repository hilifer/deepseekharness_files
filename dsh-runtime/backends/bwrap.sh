#!/bin/bash
# =====================================================================
# 后端 bwrap —— 用 bubblewrap 的挂载命名空间把实例钳在自己的工作区内
#
# 用法（由 dsh-sandbox.sh 调度，不直接调用）:
#   backends/bwrap.sh probe
#   backends/bwrap.sh run <username> <port> <dsh_home> <workspace>
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
# 注意 /var 【不挂】：docker socket 常在 /var/run/docker.sock，挂进来等于
# 把整台宿主机送出去。已实测沙箱内 /var 不存在。
#
# 沙箱内【不存在】的（当前部署下的高危目标）：
#   dsh-auth/          Authelia 用户库、initial-credentials.txt（全员明文初始密码）
#   nginx/certs/       TLS 私钥
#   filebrowser/       database.db（全员权限模型）
#   scripts/ admin/    建号脚本与管理后台代码
#   其他部门/其他员工的目录、其他用户的 DSH_HOME
#
# 两种运行形态（probe 会自动挑一种，都不成立则本后端不可用）：
#   userns     非 root + 内核允许非特权 user namespace。最常见。
#   privileged 已是 root 且有 CAP_SYS_ADMIN（特权容器 / 宿主 root）。
#              此时不需要 user namespace，直接开 mount ns；再用 --uid/--gid
#              降到工作区属主，避免实例以 root 身份往工作区里写文件。
# =====================================================================
set -euo pipefail

BACKEND_TAG=bwrap
# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 网络隔离模式（可选，默认关闭）。
#   0 = 与宿主共享网络命名空间。文件系统仍完全隔离，但沙箱能连宿主 127.0.0.1
#       上的服务；FileBrowser 与管理后台已用密钥头挡住，但【员工 A 可以直连
#       员工 B 的 dsh 端口】驱动其 agent —— 这是已知残留风险。
#   1 = 每实例独立网络命名空间：pasta 提供出网，入站改走 unix socket，
#       宿主回环上不再留下任何 dsh 端口，实例间互连即被封死。
#       需要 pasta（passt 包）与 socat。已在 GitHub runner 上实测通过 7/7。
#   容器后端天然具备等价效果，不需要这一套。
DSH_NETNS="${DSH_NETNS:-0}"
DSH_SOCKET_DIR="${DSH_SOCKET_DIR:-$DSH_ROOT/dsh-sockets}"
DSH_DNS_FORWARD="${DSH_DNS_FORWARD:-10.0.2.3}"

# ---------- 定位 bwrap ----------
# 只找到文件是不够的：内核禁用非特权 user namespace 时 bwrap 装着也跑不起来。
# 早先这里只判可执行，于是「存在但坏」会走进沙箱分支，每次启动都失败、实例
# 直接死掉，而降级路径压根够不到——运维只能把 bwrap 改名骗过检测。
# 现在把「能不能真跑」并进查找条件，两种情况一视同仁。
bwrap_mode_of() { # $1=bwrap 路径；成功时 stdout 输出 userns 或 privileged
  [ -x "$1" ] || return 1
  if "$1" --ro-bind / / --unshare-all --share-net true >/dev/null 2>&1; then
    echo userns; return 0
  fi
  # root + CAP_SYS_ADMIN 时不需要 user namespace，mount ns 直接开
  if [ "$(id -u)" = "0" ] && have_cap_sys_admin \
     && "$1" --ro-bind / / --unshare-ipc --unshare-pid --unshare-uts true >/dev/null 2>&1; then
    echo privileged; return 0
  fi
  return 1
}

bwrap_candidates() {
  if [ -n "${BWRAP_BIN:-}" ]; then echo "$BWRAP_BIN"; return 0; fi
  command -v bwrap 2>/dev/null || true
  echo "$DSH_ROOT/bwrap/usr/bin/bwrap"
  echo /usr/bin/bwrap
  echo /bin/bwrap
}

# 成功时置 BWRAP / BWRAP_MODE
find_bwrap() {
  local c mode
  while read -r c; do
    [ -n "$c" ] || continue
    if mode=$(bwrap_mode_of "$c"); then BWRAP="$c"; BWRAP_MODE="$mode"; return 0; fi
  done < <(bwrap_candidates)
  return 1
}

# 仅用于报错时区分「没装」和「装了但跑不起来」
find_bwrap_binary() {
  local c
  while read -r c; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done < <(bwrap_candidates)
  return 1
}

netns_check() {
  local missing=""
  command -v pasta >/dev/null 2>&1 || missing="$missing pasta(passt)"
  command -v socat >/dev/null 2>&1 || missing="$missing socat"
  [ -z "$missing" ] || { echo "MISSING_DEPS$missing"; return 1; }
  # 【装了不等于能用】pasta 在嵌套/受限容器里会在 uid 映射那步失败：
  #   Couldn't configure user mappings / clone: Operation not permitted
  # 早先这里只判 command -v，probe 因此放行，实例却在真正启动时才炸——
  # 而那时调度器已经选定 bwrap，降级路径够不着了。这是本仓库反复清理的
  # 那类假绿：判「存在」而不判「能跑」。所以真跑一次。
  if ! pasta --config-net --no-map-gw -t none -u none -- true >/dev/null 2>&1; then
    echo "PASTA_UNUSABLE"; return 1
  fi
  echo "OK"; return 0
}

# ---------- probe ----------
backend_probe() {
  if find_bwrap; then
    if [ "$DSH_NETNS" = "1" ]; then
      local nout
      if ! nout=$(netns_check); then
        if [ "$nout" = "PASTA_UNUSABLE" ]; then
          log "pasta 装了但在本环境跑不起来（多半是嵌套容器里配不出 uid 映射）。"
          log "  没有独立 netns，本档就封不住「员工 A 直连员工 B 的实例端口」——"
          log "  那条路不经过文件系统，等于「个体不能访问其他空间的数据」没达成，"
          log "  所以这里【拒绝选用 bwrap】，让位给能封住它的档（landlock 的 TCP 白名单）。"
        else
          log "网络隔离模式已请求但依赖缺失 -> $nout（sudo apt-get install -y passt socat）"
        fi
        echo "$nout"; return 1
      fi
      echo "OK bwrap=$BWRAP mode=$BWRAP_MODE netns=on"; return 0
    fi
    echo "OK bwrap=$BWRAP mode=$BWRAP_MODE netns=off"; return 0
  fi

  local bwrap_path
  if bwrap_path=$(find_bwrap_binary); then
    echo "BROKEN $bwrap_path"
    log "bwrap 在 $bwrap_path，但跑不起来。具体报错:"
    # 这条必然失败（就是要看它的报错）；脚本开头有 set -e -o pipefail，
    # 不加 || true 会在这里直接退出，后面的排障提示就永远打不出来。
    { "$bwrap_path" --ro-bind / / --unshare-all --share-net true 2>&1 \
      | sed 's/^/     /' >&2; } || true
    local aa=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
    if [ -r "$aa" ] && [ "$(cat "$aa")" = "1" ]; then
      log "  -> 已定位原因：AppArmor 拦截了非特权 user namespace"
      log "     （Ubuntu 24.04 起默认开启，报错为 'setting up uid map: Permission denied'）"
      log "     宿主上处理: sudo $DSH_ROOT/scripts/apparmor-allow-userns.sh"
      log "     这是【宿主机】的内核设置，容器内改不了。容器里请改用 container 后端。"
    else
      log "  -> 其他可能原因:"
      log "     sysctl kernel.unprivileged_userns_clone / user.max_user_namespaces"
      log "     容器 seccomp 拦了 unshare(CLONE_NEWUSER)，需容器侧放开"
    fi
    return 1
  fi
  echo "MISSING"
  log "未找到 bwrap -> 运行 scripts/install-bubblewrap.sh（rootless 解包，无需 root）"
  return 1
}

# ---------- run ----------
backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  find_bwrap || die "bwrap 不可用（调度器本应先 probe 过）"
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE" "$USERNAME"

  # 工作区必须是真实路径（解析符号链接），否则 --bind 会把链接目标挂进来，
  # 等于给了一条绕过隔离的路。
  WORKSPACE=$(readlink -f "$WORKSPACE")
  DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

  local args=(
    # 逐项 unshare 而非 --unshare-all：后者含 --unshare-net，
    # 在 netns 模式下会丢掉 pasta 刚配好的网络。
    --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup
    --share-net            # 共享所在 netns（普通模式=宿主；netns 模式=pasta 的）
    --die-with-parent      # 父进程死则实例死，不留孤儿
    --new-session          # 断开控制终端，防 TIOCSTI 注入
    --proc /proc
    --dev /dev
    --tmpfs /tmp
  )
  if [ "$BWRAP_MODE" = "userns" ]; then
    args+=(--unshare-user)
  else
    # 特权形态：已经有 mount ns，不需要 user namespace；降到工作区属主，
    # 免得实例以 root 身份写文件，把 FileBrowser（普通用户）挡在外面。
    args+=(--uid "$(stat -c %u "$WORKSPACE")" --gid "$(stat -c %g "$WORKSPACE")")
  fi

  # 系统只读目录（存在才挂）。/var 故意不在列内，见文件头。
  local d
  for d in /usr /bin /sbin /lib /lib64 /lib32 /libx32 /etc /opt; do
    [ -e "$d" ] && args+=(--ro-bind "$d" "$d")
  done

  # node + dsh 本体（只读：用户改不了程序）
  args+=(--ro-bind "$NODE_ROOT" "$NODE_ROOT")

  # 可写：本人实例状态 + 本人工作区。这两个是沙箱内仅有的可写持久化路径。
  args+=(--bind "$DSH_HOME_DIR" "$DSH_HOME_DIR")
  args+=(--bind "$WORKSPACE" "$WORKSPACE")

  parse_extra_mounts "$WORKSPACE"
  local i
  for i in "${!MOUNT_PATHS[@]}"; do
    case "${MOUNT_MODES[$i]}" in
      rw) args+=(--bind "${MOUNT_PATHS[$i]}" "${MOUNT_PATHS[$i]}") ;;
      ro) args+=(--ro-bind "${MOUNT_PATHS[$i]}" "${MOUNT_PATHS[$i]}") ;;
    esac
  done

  # 共享 profiles 只读挂载。
  # 现状是每个 DSH_HOME 下 profiles 符号链接到同一个共享目录，而所有实例同为
  # 一个 OS 用户 —— 任何员工都能改写 clamped-picker/index.mjs 影响全体。
  # 挂成只读即堵住这条路。
  # 必须排在 DSH_HOME 之后：admin 实例的 profiles 就在其 DSH_HOME 内部，
  # 后挂载的会覆盖先挂载的，顺序反了 profiles 会变回可写。
  if [ -d "$SHARED_PROFILES" ]; then
    args+=(--ro-bind "$SHARED_PROFILES" "$SHARED_PROFILES")
  fi

  local USER_SOCK_DIR="" NETNS_ENTRY=""
  if [ "$DSH_NETNS" = "1" ]; then
    # 把本用户【专属】的 socket 目录挂进去（不是整个 dsh-sockets，
    # 否则沙箱里能看到别人的 socket 路径）。
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
    local resolv_target
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

  # 环境变量：清空后按白名单重建
  args+=(--clearenv)
  build_instance_env "$USERNAME" "$DSH_HOME_DIR" "$WORKSPACE" "$ALLOWED_ROOTS"
  local kv
  for kv in "${INSTANCE_ENV[@]}"; do args+=(--setenv "${kv%%=*}" "${kv#*=}"); done

  apply_rlimits
  build_trusted_host_args

  if [ "$DSH_NETNS" != "1" ]; then
    # 文件维度 bwrap 靠 mount+pid ns 已经隔死；但默认共享宿主网络，
    # 同僚的实例端口(127.0.0.1:1310x)在同一个 net ns 里连得到——员工 A 一句
    # curl 就能驱动 B 的 agent 读 B 的工作区，这条路不经过文件系统。
    # bwrap 是同 uid,netfilter owner 匹配区分不了同僚,唯一的封法是独立 netns。
    log "启动 $USERNAME: port=$PORT ws=$WORKSPACE (bwrap=$BWRAP/$BWRAP_MODE, 共享网络)"
    log "⚠ 共享网络档:同僚实例端口可直连,可被用来驱动他人的 agent 读其工作区。"
    log "  要封死这条路,开 DSH_NETNS=1(每实例独立 netns,需 passt+socat);"
    log "  或改用 container / landlock 档(前者独立 netns,后者 TCP 端口白名单)。"
    exec "$BWRAP" "${args[@]}" -- \
      "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
  fi

  local nout
  nout=$(netns_check) || die "DSH_NETNS=1 但依赖缺失: $nout（sudo apt-get install -y passt socat）"

  local SOCKET="$USER_SOCK_DIR/dsh.sock"
  args+=(--setenv DSH_SOCKET "$SOCKET")
  args+=(--setenv DSH_PORT "$PORT")
  args+=(--setenv DSH_NODE_BIN "$NODE_BIN")
  args+=(--setenv DSH_BIN "$DSH_BIN")
  args+=(--setenv DSH_TRUSTED_HOST_ARGS "${HOST_ARGS[*]}")

  log "启动 $USERNAME: socket=$SOCKET ws=$WORKSPACE (bwrap=$BWRAP/$BWRAP_MODE, 独立网络命名空间)"
  # pasta 建独立 netns 并提供出网；-t none -u none 表示不做任何入站端口转发，
  # 入站只走 unix socket。--no-map-gw 断掉经网关回连宿主的路径。
  # bwrap 在 pasta 的 netns 里用 --share-net（共享的是 pasta 的，不是宿主的）。
  exec pasta --config-net --no-map-gw -t none -u none \
    --dns-forward "$DSH_DNS_FORWARD" -- \
    "$BWRAP" "${args[@]}" -- bash "$NETNS_ENTRY"
}

case "${1:-}" in
  probe) backend_probe ;;
  run)   shift; backend_run "$@" ;;
  *) echo "用法: $0 probe | run <username> <port> <dsh_home> <workspace>" >&2; exit 2 ;;
esac
