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
#   ✘ 【同 uid 命门】本档所有实例都以同一个 OS 用户跑（没有 root 就 useradd
#      不了）。同 uid 之间：
#        · /proc/<别人 pid>/environ、cmdline 读得到（Landlock 不管 /proc 内层
#          文件的属主判定）——环境里若经 DSH_SANDBOX_PASSENV 塞了密钥就会外泄；
#        · 若内核的 yama ptrace_scope=0，A 能 PTRACE_ATTACH 到 B 的实例，
#          借 B 的进程（带着 B 的 Landlock 规则）读出 B 的整个工作区——
#          这会【直接击穿「个体不能访问其他空间的数据」】。
#      所以本档把 yama ptrace_scope>=1 列为【硬前提】：拿不到就 probe 失败，
#      让调度器往下退档而不是揣着这个洞裸奔（fail-closed）。
#      环境里不放密钥、且 ptrace 被 yama 挡住时，剩下的只是路径元数据泄露
#      （路径能不能打开仍由 Landlock 说了算，数据本身进不去）。
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

# 允许显式放行 ptrace 命门（危险，只在「同机只有一个员工」或你另有 MAC 兜底时用）
DSH_LANDLOCK_ALLOW_PTRACE="${DSH_LANDLOCK_ALLOW_PTRACE:-0}"

# yama ptrace_scope：本档所有实例同 uid，scope=0 时同僚之间可 PTRACE_ATTACH 互相
# 劫持，借对方进程读走对方工作区。>=1 才挡得住。文件不存在（没编 yama）当作 0。
ptrace_scope_value() {
  local f=/proc/sys/kernel/yama/ptrace_scope
  [ -r "$f" ] && cat "$f" 2>/dev/null || echo 0
}
ptrace_hardened() {
  [ "$DSH_LANDLOCK_ALLOW_PTRACE" = "1" ] && return 0
  [ "$(ptrace_scope_value)" -ge 1 ] 2>/dev/null
}

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
  if ! ptrace_hardened; then
    echo "PTRACE_OPEN"
    log "内核 yama ptrace_scope=$(ptrace_scope_value)（本档所有实例同 uid）。"
    log "  同 uid 之间可 PTRACE_ATTACH 劫持对方的实例进程，借它读走对方工作区——"
    log "  这会直接击穿「个体不能访问其他空间的数据」。Landlock 管不了 ptrace。"
    log "  处理，任选其一："
    log "    a) 宿主开启 yama:  sysctl -w kernel.yama.ptrace_scope=1（或写进 sysctl.d）"
    log "    b) 换 container / bwrap / uid 档（各自有 pid ns 或独立 uid，天然免疫）"
    log "    c) 确认同机只会有一个员工，再 DSH_LANDLOCK_ALLOW_PTRACE=1 显式放行"
    return 1
  fi
  echo "OK $(printf '%s' "$out" | head -1) yama=$(ptrace_scope_value)"
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
  if ! ptrace_hardened; then
    die "yama ptrace_scope=$(ptrace_scope_value)，同 uid 实例之间可互相 ptrace 劫持读走对方工作区，拒绝启动。
       处理: sysctl -w kernel.yama.ptrace_scope=1；或换 container/bwrap/uid 档；
       或（仅当同机只有一个员工）DSH_LANDLOCK_ALLOW_PTRACE=1 放行。"
  fi
  # 环境里若带了密钥（PASSENV），同 uid 同僚能从 /proc/<pid>/environ 读到——提醒一次
  if [ -n "$DSH_SANDBOX_PASSENV" ]; then
    log "注意: DSH_SANDBOX_PASSENV 非空，其值会进 environ；本档同 uid 同僚可经 /proc 读到。"
    log "  密钥类务必改为落在本人 DSH_HOME 下的文件（Landlock 已把同僚挡在其外），勿走环境变量。"
  fi

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
