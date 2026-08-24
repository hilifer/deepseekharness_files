#!/bin/bash
# =====================================================================
# 后端 landlock —— 用内核的非特权自我沙箱把实例钳在自己的工作区内
#
# 用法（由 dsh-sandbox.sh 调度，不直接调用）:
#   backends/landlock.sh probe
#   backends/landlock.sh run <username> <port> <dsh_home> <workspace>
#
# 它填的是这个空档：**拿不到 root、也拿不到 user namespace 的容器**。
# 那种环境下前面三档全断——docker 起不了兄弟容器、bwrap 开不出命名空间、
# uid 档 useradd 不了。而 Landlock 是内核专门为「非特权自我沙箱」设计的：
# 普通用户进程给自己上锁，上锁后【不可撤销】、【子进程继承】、【exec 后仍在】。
# 正好对上 dsh 那个能执行任意命令的 bash：dsh 起 bash、bash 起 cat，
# 全都带着这把锁，一个都跑不掉。
#
# 需要 Linux 5.13+ 且 landlock 在内核的 LSM 列表里。ABI 版本决定能锁到什么程度：
#   v1+  文件系统读写
#   v3+  截断
#   v4+  TCP bind/connect  —— 这一档能封死「员工 A 直连员工 B 的实例端口」
#   v5+  ioctl
#   v6+  scope：挡住给沙箱外进程发信号、连沙箱外的抽象 unix socket
#
# 相对挂载命名空间弱在哪（如实写，别让人以为等价）：
#   ✘ 越界是 EACCES「拒绝访问」不是 ENOENT「不存在」，路径存在性仍会泄露
#   ✘ 没有 pid namespace：`ps` 看得到全机进程和它们的命令行
#   ✘ 没有 cgroup 资源限额
# 强在哪：**不需要 root、不需要 userns、不需要任何人配合**，装上就能用。
# =====================================================================
set -euo pipefail

BACKEND_TAG=landlock
# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LANDLOCK_EXEC="$DSH_ROOT/dsh-runtime/dsh-landlock-exec.py"
# 允许外连的 TCP 端口。默认只放模型 API 与代码托管常用的三个。
# 【不要】把 13100-13199 加进来——那等于把「员工 A 连员工 B 的实例」这条
# 本档好不容易封住的路重新打开。
DSH_LANDLOCK_CONNECT_PORTS="${DSH_LANDLOCK_CONNECT_PORTS:-443 80 22}"

python_bin() { command -v python3 2>/dev/null || true; }

# ---------- probe ----------
backend_probe() {
  local py; py=$(python_bin)
  if [ -z "$py" ]; then
    echo "NO_PYTHON"; log "缺 python3（上锁器是纯 ctypes 脚本，需要它）"; return 1
  fi
  if [ ! -r "$LANDLOCK_EXEC" ]; then
    echo "NO_EXEC"; log "找不到上锁器: $LANDLOCK_EXEC"; return 1
  fi
  # 不看返回码猜——selftest 会真上一次锁再去读一个不该读的文件
  local out rc=0
  out=$("$py" "$LANDLOCK_EXEC" --selftest 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "UNAVAILABLE"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
    log "内核不支持 Landlock，或上锁后并未真正生效"
    return 1
  fi
  echo "OK $(printf '%s' "$out" | head -1)"
  return 0
}

# ---------- run ----------
backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  local py; py=$(python_bin)
  [ -n "$py" ] || die "缺 python3（调度器本应先 probe 过）"
  [ -r "$LANDLOCK_EXEC" ] || die "找不到上锁器: $LANDLOCK_EXEC"
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE"

  WORKSPACE=$(readlink -f "$WORKSPACE")
  DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

  local args=()

  # 系统运行时：只读。存在才加，不同发行版目录不一样。
  local d
  for d in /usr /bin /sbin /lib /lib64 /lib32 /libx32 /etc /opt; do
    [ -e "$d" ] && args+=(--ro "$d")
  done
  # /proc 与 /dev 要能读写（/dev/null、/dev/urandom、/proc/self/...），
  # 但用 rwio 而不是 rw：不给创建/删除权限。
  for d in /proc /dev; do
    [ -e "$d" ] && args+=(--rwio "$d")
  done
  # 这两个例外必须给完整读写，否则 node 起不来：
  #   /dev/shm      共享内存要能创建文件（rwio 不给 make_reg）
  #   /run/user/UID XDG 运行时目录，一些工具会往里写
  # 它们都是本用户专属或全局临时区，不含员工数据。
  [ -d /dev/shm ] && args+=(--rw /dev/shm)
  [ -d "/run/user/$(id -u)" ] && args+=(--rw "/run/user/$(id -u)")

  # 程序本体与共享插件：只读，员工改不了 dsh 也改不了别人的插件
  args+=(--ro "$NODE_ROOT")
  [ -d "$SHARED_PROFILES" ] && args+=(--ro "$SHARED_PROFILES")

  # 可写：本人实例状态 + 本人工作区
  args+=(--rw "$DSH_HOME_DIR" --rw "$WORKSPACE")

  # 私有临时目录。不放行 /tmp —— 那是全机共享的，员工之间会互相看见。
  local privtmp="$DSH_HOME_DIR/tmp"
  mkdir -p "$privtmp"; chmod 700 "$privtmp" 2>/dev/null || true
  args+=(--rw "$privtmp")

  # 额外空间（主管的部门目录、共享资料库等）
  parse_extra_mounts "$WORKSPACE"
  local i
  for i in "${!MOUNT_PATHS[@]}"; do
    case "${MOUNT_MODES[$i]}" in
      rw) args+=(--rw "${MOUNT_PATHS[$i]}") ;;
      ro) args+=(--ro "${MOUNT_PATHS[$i]}") ;;
    esac
  done

  # 网络：只允许监听自己那个端口、只允许外连白名单端口。
  # 别人的实例端口不在白名单里，于是「驱动同事的 agent」这条路被封死——
  # 这是 bwrap 档默认做不到、要额外开 DSH_NETNS 才有的效果。
  args+=(--bind-port "$PORT")
  local p
  for p in $DSH_LANDLOCK_CONNECT_PORTS; do args+=(--connect-port "$p"); done

  build_instance_env "$USERNAME" "$DSH_HOME_DIR" "$WORKSPACE" "$ALLOWED_ROOTS"
  build_trusted_host_args

  # 环境按白名单重建（与其它后端同一份），外加私有 TMPDIR
  local envargs=(env -i "TMPDIR=$privtmp" "TMP=$privtmp" "TEMP=$privtmp")
  local kv
  for kv in "${INSTANCE_ENV[@]}"; do envargs+=("$kv"); done

  cd "$WORKSPACE"
  log "启动 $USERNAME: port=$PORT ws=$WORKSPACE (Landlock 自我沙箱)"
  exec "${envargs[@]}" "$py" "$LANDLOCK_EXEC" "${args[@]}" -- \
    "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
}

case "${1:-}" in
  probe) backend_probe ;;
  run)   shift; backend_run "$@" ;;
  *) echo "用法: $0 probe | run <username> <port> <dsh_home> <workspace>" >&2; exit 2 ;;
esac
