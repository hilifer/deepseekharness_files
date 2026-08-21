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

# dsh 的 --trusted-host。OPS.md 记录本机/局域网/公网三个入口域，
# 但当前只信任公网域，从 127.0.0.1:8099 访问可能被 dsh 拒绝。
# 确认 dsh 接受重复的 --trusted-host 后，把三个域都填进来即可修复：
#   DSH_TRUSTED_HOSTS="218.17.143.249:8099 192.168.1.225:8099 127.0.0.1:8099"
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-218.17.143.249:8099}"

# 允许透传进沙箱的环境变量名（dsh 的模型 API Key 之类放这里）
DSH_SANDBOX_PASSENV="${DSH_SANDBOX_PASSENV:-}"

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
find_bwrap() {
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
  bw=$(find_bwrap) || { echo "MISSING"; return 1; }
  if "$bw" --ro-bind / / --unshare-all --share-net true >/dev/null 2>&1; then
    echo "OK $bw"; return 0
  fi
  echo "BROKEN $bw"; return 1
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
          log "     临时放开: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
          log "     永久放开: echo 'kernel.apparmor_restrict_unprivileged_userns=0' \\"
          log "                 | sudo tee /etc/sysctl.d/60-dsh-userns.conf && sudo sysctl --system"
          log "     容器内无法改这个 sysctl，需在宿主机上设置。"
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
  if [ "${DSH_ALLOW_UNCONFINED:-0}" = "1" ]; then
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! 警告: 未找到 bwrap，DSH_ALLOW_UNCONFINED=1 强制无隔离启动 !!"
    log "!! $USERNAME 的 dsh 可读写整台服务器的所有文件            !!"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    export DSH_HOME="$DSH_HOME_DIR" DSH_ALLOWED_ROOT="$WORKSPACE"
    exec "$NODE_BIN" "$DSH_BIN" web --port "$PORT" --trusted-host "${DSH_TRUSTED_HOSTS%% *}"
  fi
  die "未找到 bwrap，拒绝以无隔离方式启动 $USERNAME 的实例。
       安装: scripts/install-bubblewrap.sh
       排障临时放行(危险): DSH_ALLOW_UNCONFINED=1"
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
  args+=(--ro-bind "$USER_SOCK_DIR/resolv.conf" /etc/resolv.conf)
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
args+=(--setenv DSH_ALLOWED_ROOT "$WORKSPACE")   # 第二层：选择器 UX 钳制
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
