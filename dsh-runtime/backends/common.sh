#!/bin/bash
# =====================================================================
# 各隔离后端共用的路径、环境变量与挂载解析。由 backends/*.sh source。
#
# 这里【只放事实计算】，不做任何隔离决策——决策在 dsh-sandbox.sh。
# =====================================================================

DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
NODE_ROOT="${DSH_NODE_ROOT:-$DSH_ROOT/node}"
NODE_BIN="${DSH_NODE_BIN:-$NODE_ROOT/bin/node}"
DSH_BIN="${DSH_BIN:-$NODE_ROOT/bin/dsh}"
SHARED_PROFILES="${DSH_SHARED_PROFILES:-$DSH_ROOT/.local/share/dsh/profiles}"

# dsh 的 --trusted-host，三个入口域全填（见 OPS.md）。
# 公网 IP 是云 NAT，不绑在本机网卡上，只填它的话本机与局域网访问会被
# dsh 的 Host 校验一律拒绝。现场实测已确认 dsh 接受重复的 --trusted-host。
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-218.17.143.249:8099 192.168.1.225:8099 127.0.0.1:8099}"

# 实例端口段与本机内部服务端口。uid 档要靠它们做网络封锁：
# 「A 直连 B 的实例端口驱动 B 的 agent」这条路不经过文件系统，DAC 拦不住。
DSH_PORT_RANGE="${DSH_PORT_RANGE:-13100:13199}"
DSH_INTERNAL_PORTS="${DSH_INTERNAL_PORTS:-18080 19091 19200}"

# 允许透传进实例的环境变量名（dsh 的模型 API Key 之类放这里）
DSH_SANDBOX_PASSENV="${DSH_SANDBOX_PASSENV:-}"

# 本人工作区之外还要挂载的空间，由 core.py 计算后传入。
# 每行一条 "mode<TAB>path"，mode 为 ro 或 rw。典型来源：
#   - 主管：整个部门目录（rw），与 FileBrowser 的部门级 scope 对齐
#   - 管理员在后台为某人单独配置的共享目录 / 只读资料库
# core.py 已校验过每条路径解析符号链接后仍在 dsh-files 之内。
DSH_EXTRA_MOUNTS="${DSH_EXTRA_MOUNTS:-}"

BACKEND_TAG="${BACKEND_TAG:-backend}"
log() { echo "[$BACKEND_TAG] $*" >&2; }
die() { echo "[$BACKEND_TAG] 错误: $*" >&2; exit 1; }

# ---------- 环境形状探测（所有后端与调度器共用同一份事实）----------
in_container() {
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0
  grep -qE '(docker|containerd|kubepods|lxc|podman)' /proc/1/cgroup 2>/dev/null && return 0
  # cgroup v2 的容器里 /proc/1/cgroup 是 "0::/"，宿主上 pid 1 是 init/systemd
  if [ "$(cat /proc/1/cgroup 2>/dev/null)" = "0::/" ] \
     && [ "$(tr -d '\0' < /proc/1/comm 2>/dev/null)" != "systemd" ] \
     && [ "$(tr -d '\0' < /proc/1/comm 2>/dev/null)" != "init" ]; then
    return 0
  fi
  return 1
}

userns_allowed() {
  # 只回答内核/LSM 层面允不允许，不代表 bwrap 一定能跑（那要真跑一次）。
  local f
  f=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  [ -r "$f" ] && [ "$(cat "$f")" = "1" ] && [ "$(id -u)" != "0" ] && return 1
  f=/proc/sys/kernel/unprivileged_userns_clone
  [ -r "$f" ] && [ "$(cat "$f")" = "0" ] && return 1
  f=/proc/sys/user/max_user_namespaces
  [ -r "$f" ] && [ "$(cat "$f")" = "0" ] && return 1
  return 0
}

have_cap_sys_admin() {
  # CapEff 是十六进制位图，CAP_SYS_ADMIN = 21
  local eff
  eff=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null) || return 1
  [ -n "$eff" ] || return 1
  python3 - "$eff" <<'PY' 2>/dev/null
import sys
sys.exit(0 if (int(sys.argv[1], 16) >> 21) & 1 else 1)
PY
}

# ---------- docker socket 可达性 ----------
# 「文件存在」不等于「能逃逸」：容器里常留着一个没有守护进程在听的死 socket
# （装了 docker 包但 dockerd 没起、或宿主 socket 挂进来后对端已停）。
# 死 socket 连不上任何守护进程，起不了兄弟容器，不构成逃逸路径。
# 所以这里【真去连一次】，而不是看有没有那个文件——现场就撞见过这种情况，
# 按文件存在判定会把本来可用的 uid 档误判成不可用。
#
# 判不出来的时候（既没有 python3 也没有 curl）一律当作「可达」，方向朝安全那边倒。
docker_socket_candidates() {
  local dh="${DOCKER_HOST:-}"
  printf '%s\n' /var/run/docker.sock /run/docker.sock "${dh#unix://}"
}

_socket_answers() { # $1=socket 路径；能连上守护进程则 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
' "$1" 2>/dev/null
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 2 --unix-socket "$1" http://localhost/_ping >/dev/null 2>&1
    return $?
  fi
  return 0   # 测不了就当作可达
}

docker_socket_live() {
  local s
  while read -r s; do
    { [ -n "$s" ] && [ -S "$s" ]; } || continue
    _socket_answers "$s" && return 0
  done < <(docker_socket_candidates)
  return 1
}

# 只有文件、后面没人听：不是逃逸路径，但哪天有人把 dockerd 起起来就是了
docker_socket_file_exists() {
  local s
  while read -r s; do
    { [ -n "$s" ] && [ -S "$s" ]; } && return 0
  done < <(docker_socket_candidates)
  return 1
}

# ---------- 挂载解析 ----------
# 输出到全局：MOUNT_MODES[] / MOUNT_PATHS[] / ALLOWED_ROOTS（每行一条）
parse_extra_mounts() { # $1=workspace(已 readlink)
  MOUNT_MODES=(); MOUNT_PATHS=()
  ALLOWED_ROOTS="$1"
  [ -n "$DSH_EXTRA_MOUNTS" ] || return 0
  local m_mode m_path m_real
  while IFS=$'\t' read -r m_mode m_path; do
    [ -n "${m_path:-}" ] || continue
    if [ ! -d "$m_path" ]; then
      log "跳过不存在的额外挂载: $m_path"; continue
    fi
    case "$m_mode" in
      ro|rw) ;;
      *) die "额外挂载模式不合法: $m_mode ($m_path)" ;;
    esac
    m_real=$(readlink -f "$m_path")
    MOUNT_MODES+=("$m_mode"); MOUNT_PATHS+=("$m_real")
    log "  额外空间 [$m_mode] $m_real"
    ALLOWED_ROOTS="$ALLOWED_ROOTS"$'\n'"$m_real"
  done <<< "$DSH_EXTRA_MOUNTS"
}

# ---------- 实例环境变量 ----------
# 输出到全局 INSTANCE_ENV[]（每项 "NAME=VALUE"）。所有后端共用同一份白名单，
# 换后端不会悄悄改变 dsh 看到的环境。
build_instance_env() { # $1=username $2=dsh_home $3=workspace $4=allowed_roots
  local username=$1 home=$2 ws=$3 roots=$4
  INSTANCE_ENV=(
    "PATH=$NODE_ROOT/bin:/usr/local/bin:/usr/bin:/bin"
    "HOME=$home"
    "DSH_HOME=$home"
    "DSH_ALLOWED_ROOT=$ws"       # 第二层：选择器 UX 钳制（主工作区）
    "DSH_ALLOWED_ROOTS=$roots"   # 含额外空间的完整允许列表，每行一条
    # 文件上传插件的落盘目录。插件默认存到 $DSH_HOME/uploads —— 那个目录不在
    # FileBrowser 的 source 里，员工在 dsh 里传的文件在文件服务器上根本看不见，
    # 与「两边看到同一个空间」相矛盾。默认改到本人工作区之下。
    "DSH_UPLOAD_DIR=${DSH_UPLOAD_DIR:-$ws/uploads}"
    "DSH_NODE_ROOT=$NODE_ROOT"   # 钳制插件据此定位 dsh 的内部包
    "USER=$username"
    "LANG=${LANG:-C.UTF-8}"
    "TZ=${TZ:-Asia/Shanghai}"
  )
  local varname
  for varname in $DSH_SANDBOX_PASSENV; do
    if [ -n "${!varname:-}" ]; then INSTANCE_ENV+=("$varname=${!varname}"); fi
  done
}

# 输出到全局 HOST_ARGS[]
build_trusted_host_args() {
  HOST_ARGS=()
  local h
  for h in $DSH_TRUSTED_HOSTS; do HOST_ARGS+=(--trusted-host "$h"); done
}

# ---------- 资源限额（非 container 档）----------
# container 档有 cgroup（见 container.sh 的 build_limit_args）；其余三档没有任何
# 限额，一个员工的 fork 炸弹或内存膨胀会拖垮整机——所有人一起完蛋。
# RLIMIT 是进程属性，exec 后继承，所以在 exec 前设一次就够。
#
# 【为什么默认不设 RLIMIT_AS】V8 会预留大量【虚拟】地址空间（远超实际用量），
# 设了 -v 之后 node 经常直接起不来。要限内存请用 container 档的 cgroup，
# 那才是按【实际驻留】算的。这里留出开关，但默认空。
DSH_RLIMIT_NPROC="${DSH_RLIMIT_NPROC:-512}"     # 进程数，挡 fork 炸弹
DSH_RLIMIT_NOFILE="${DSH_RLIMIT_NOFILE:-4096}"  # 打开文件数
DSH_RLIMIT_FSIZE="${DSH_RLIMIT_FSIZE:-}"        # 单文件大小(block)，空=不限
DSH_RLIMIT_AS="${DSH_RLIMIT_AS:-}"              # 虚拟内存(KB)，空=不限，见上

apply_rlimits() {
  # 崩溃转储可能很大又没人看，直接关掉，顺带免得写满磁盘
  ulimit -c 0 2>/dev/null || true
  local applied=""
  if [ -n "$DSH_RLIMIT_NPROC" ] && ulimit -u "$DSH_RLIMIT_NPROC" 2>/dev/null; then
    applied="$applied nproc=$DSH_RLIMIT_NPROC"
  fi
  if [ -n "$DSH_RLIMIT_NOFILE" ] && ulimit -n "$DSH_RLIMIT_NOFILE" 2>/dev/null; then
    applied="$applied nofile=$DSH_RLIMIT_NOFILE"
  fi
  if [ -n "$DSH_RLIMIT_FSIZE" ] && ulimit -f "$DSH_RLIMIT_FSIZE" 2>/dev/null; then
    applied="$applied fsize=$DSH_RLIMIT_FSIZE"
  fi
  if [ -n "$DSH_RLIMIT_AS" ] && ulimit -v "$DSH_RLIMIT_AS" 2>/dev/null; then
    applied="$applied as=$DSH_RLIMIT_AS"
  fi
  log "资源限额:${applied:- 无（设不上，多半是已有更低的硬限制）} core=0"
  # 同 uid 的档（landlock / bwrap）要说清楚 nproc 的真实语义，别让人以为是每人独立配额
  if [ "$BACKEND_TAG" = "landlock" ] || [ "$BACKEND_TAG" = "bwrap" ]; then
    log "  注意: 本档同 uid，RLIMIT_NPROC 是【按 uid 全局计数】的——它挡得住单个"
    log "  实例的 fork 炸弹，但同僚之间仍共享这个进程数池。要真正各算各的用 container 档。"
  fi
}

# 工作区收容校验。这一层才是真正执行挂载/授权的地方，所以它【不能】依赖
# core.py 传来的东西是对的：登记表可能被手改、被坏掉的迁移写脏、从备份恢复。
# 只看解析符号链接之后到底指向哪儿。
#
# 允许的形状只有 departments/<部门> 或 departments/<部门>/<姓名>。
# 指向 dsh-files 根、指向 departments 本身、指向外部路径，一律拒绝启动——
# 那些都等于把远超本人空间的范围挂进实例。
DSH_FILES_ROOT="${DSH_FILES_ROOT:-$DSH_ROOT/dsh-files}"
assert_workspace_contained() { # $1=workspace(已存在)
  local ws depts rel
  ws=$(readlink -f "$1") || die "工作区路径解析失败: $1"
  depts=$(readlink -f "$DSH_FILES_ROOT/departments" 2>/dev/null) || {
    log "注意: $DSH_FILES_ROOT/departments 不存在，跳过收容校验（非标准部署树）"
    return 0
  }
  case "$ws" in
    "$depts"/*) rel="${ws#"$depts"/}" ;;
    *) die "工作区不在 $depts 之内，拒绝启动: $ws
       指向公司根或外部路径的工作区会把远超本人空间的范围挂进实例。
       请在管理后台重设该员工的部门与姓名。" ;;
  esac
  # 层级只能是 1（主管=部门目录）或 2（员工=个人目录）
  case "$rel" in
    */*/*) die "工作区层级过深（应为 departments/<部门>[/<姓名>]），拒绝启动: $ws" ;;
  esac
}

# 各后端 run 之前统一做的参数校验
validate_run_args() { # $1=port $2=dsh_home $3=workspace
  [[ "$1" =~ ^[0-9]{2,5}$ ]] || die "端口不合法: $1"
  [ -d "$2" ] || die "DSH_HOME 不存在: $2"
  [ -d "$3" ] || die "工作区不存在: $3"
  [ -d "$NODE_ROOT" ] || die "node 目录不存在: $NODE_ROOT"
  [ "${DSH_SKIP_WORKSPACE_CHECK:-0}" = "1" ] || assert_workspace_contained "$3"
}
