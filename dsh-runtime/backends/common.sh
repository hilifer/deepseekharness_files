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

# 各后端 run 之前统一做的参数校验
validate_run_args() { # $1=port $2=dsh_home $3=workspace
  [[ "$1" =~ ^[0-9]{2,5}$ ]] || die "端口不合法: $1"
  [ -d "$2" ] || die "DSH_HOME 不存在: $2"
  [ -d "$3" ] || die "工作区不存在: $3"
  [ -d "$NODE_ROOT" ] || die "node 目录不存在: $NODE_ROOT"
}
