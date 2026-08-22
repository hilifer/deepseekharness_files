#!/bin/bash
# =====================================================================
# dsh-sandbox.sh —— 隔离调度器：按【当前环境实际拿得到什么】挑后端
#
# 用法（对上层的接口没变，core.py / start-all.sh 照旧调这一个入口）:
#   dsh-sandbox.sh <username> <port> <dsh_home> <workspace>
#   dsh-sandbox.sh --check      # 选得出后端则 0，选不出则 1（fail-closed）
#   dsh-sandbox.sh --backend    # 只打印选中的后端名
#   dsh-sandbox.sh --report     # 打印完整的环境能力报告（排障用）
#
# 为什么要有这一层：
#   这个项目要能跑在【任何形状的机器】上——裸宿主、普通 docker 容器、
#   挂了宿主 socket 的容器、DinD、特权容器、以 root 跑的容器。
#   不同形状下能拿到的强制点完全不同，写死任何一种都会在别处失效：
#     · bwrap 需要非特权 user namespace，而它是【宿主】的内核开关，
#       容器内改不了。此前整个方案押在它上面，现场因此一天没生效过。
#     · 容器后端需要够得到 docker 守护进程。
#     · UID 后端需要容器内 root，且一旦有可达的 docker socket 就作废。
#   所以正确的做法不是选一种，而是【探测 + 按隔离强度择优 + 探不到就拒绝启动】。
#
# 选择顺序（强 -> 弱），DSH_ISOLATION 可以强制指定某一档：
#   1 container  独立容器：mount/net/pid/user ns + cgroup 限额，全套
#   2 bwrap      挂载命名空间：文件系统隔离足够强，网络默认与宿主共享
#                （DSH_NETNS=1 可补上独立 netns）
#   3 uid        独立 OS 用户 + DAC：只有文件维度，无 ns。最后一档
#   4 none       无隔离，必须 DSH_ALLOW_UNCONFINED=1 显式放行，仅供排障
#
# 一律 FAIL-CLOSED：四档都不成立时【拒绝启动实例】，而不是退回裸跑。
# =====================================================================
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backends"
# 强制指定后端：auto（默认）| container | bwrap | uid | none
DSH_ISOLATION="${DSH_ISOLATION:-auto}"
# 自动挑选时的顺序，按隔离强度从强到弱
AUTO_ORDER="container bwrap uid none"

log() { echo "[isolate] $*" >&2; }

backend_script() { echo "$BACKEND_DIR/$1.sh"; }

probe_backend() { # $1=后端名；stdout=该后端的自检输出
  local s; s=$(backend_script "$1")
  [ -r "$s" ] || { echo "NO_SCRIPT"; return 1; }
  bash "$s" probe
}

# 选中的后端写到 SELECTED / SELECTED_DETAIL
select_backend() { # $1=1 表示把每一档的探测结果都打出来
  local verbose="${1:-0}" b out rc
  local candidates="$AUTO_ORDER"
  if [ "$DSH_ISOLATION" != "auto" ]; then
    candidates="$DSH_ISOLATION"
  fi
  SELECTED=""; SELECTED_DETAIL=""
  for b in $candidates; do
    # 静默挑选时吞掉各后端的排障输出；verbose（--report / 失败诊断）时放行，
    # 那正是运维要看的东西。
    if [ "$verbose" = "1" ]; then
      rc=0; out=$(probe_backend "$b") || rc=$?
    else
      rc=0; out=$(probe_backend "$b" 2>/dev/null) || rc=$?
    fi
    [ "$verbose" = "1" ] && echo "  · $b: ${out:-（无输出）}"
    if [ "$rc" = 0 ] && [ -z "$SELECTED" ]; then
      SELECTED="$b"; SELECTED_DETAIL="$out"
      [ "$verbose" = "1" ] || break
    fi
  done
  [ -n "$SELECTED" ]
}

# ---------- --report ----------
env_report() {
  BACKEND_TAG=isolate
  # shellcheck source=backends/common.sh
  . "$BACKEND_DIR/common.sh"
  # 中文标签的显示宽度和字节数不是一回事，printf 的 %-18s 会对歪，
  # 所以这里不做列对齐，一行一个「标签: 值」。
  item() { echo "  · $1: $2"; }
  echo "环境探测:"
  item "部署根" "$DSH_ROOT"
  item "跑在容器里" "$(in_container && echo 是 || echo 否)"
  item "当前 uid" "$(id -u)（$([ "$(id -u)" = 0 ] && echo root || echo 非 root)）"
  local aa=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if userns_allowed; then
    item "非特权 userns" "内核层面允许"
  else
    item "非特权 userns" "被拦（$([ -r "$aa" ] && echo "apparmor_restrict_unprivileged_userns=$(cat "$aa")" || echo "sysctl 限制")）"
  fi
  item "CAP_SYS_ADMIN" "$(have_cap_sys_admin && echo 有 || echo 无)"
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      item "docker" "客户端在，守护进程可达"
    else
      item "docker" "客户端在，守护进程【不可达】"
    fi
  else
    item "docker" "无客户端"
  fi
  local s found=无
  for s in /var/run/docker.sock /run/docker.sock; do
    [ -S "$s" ] && found="$s$([ -w "$s" ] && echo "（当前用户可写 => 可一句话逃逸到宿主）" || echo "（当前用户不可写）")"
  done
  item "docker socket" "$found"
  echo
  echo "后端可用性（DSH_ISOLATION=$DSH_ISOLATION）:"
  if select_backend 1; then
    echo
    echo "选定: $SELECTED  $SELECTED_DETAIL"
    return 0
  fi
  echo
  echo "选定: 无 —— 四档隔离全不可用，实例将【拒绝启动】"
  return 1
}

case "${1:-}" in
  --report|--probe)
    env_report; exit $?
    ;;
  --backend)
    if select_backend; then echo "$SELECTED"; exit 0; fi
    echo none-unavailable; exit 1
    ;;
  --check)
    if select_backend; then
      log "隔离后端: $SELECTED — $SELECTED_DETAIL"
      [ "$SELECTED" = "none" ] && log "警告: 当前是【无隔离】模式，仅应用于排障"
      echo "OK $SELECTED ${SELECTED_DETAIL#OK }"
      exit 0
    fi
    log "四档隔离全不可用，实例将拒绝启动。逐项原因:"
    select_backend 1 >&2 || true
    log "完整报告: $0 --report"
    echo "UNAVAILABLE"
    exit 1
    ;;
esac

# ---------- 启动实例 ----------
USERNAME="${1:?用法: dsh-sandbox.sh <username> <port> <dsh_home> <workspace>}"
PORT="${2:?缺少 port}"
DSH_HOME_DIR="${3:?缺少 dsh_home}"
WORKSPACE="${4:?缺少 workspace}"

if ! select_backend; then
  log "四档隔离全不可用，拒绝启动 $USERNAME 的实例（fail-closed）。逐项原因:"
  select_backend 1 >&2 || true
  log "完整报告: $0 --report"
  log "排障临时放行（危险，全公司文件对该实例敞开）: DSH_ALLOW_UNCONFINED=1"
  exit 1
fi

# 留一份给运维和验收脚本看：这台机器最终用的是哪一档
mkdir -p "$DSH_ROOT/dsh-runtime" 2>/dev/null || true
echo "$SELECTED" > "$DSH_ROOT/dsh-runtime/.backend" 2>/dev/null || true

log "后端 $SELECTED 启动 $USERNAME"
exec bash "$(backend_script "$SELECTED")" run "$USERNAME" "$PORT" "$DSH_HOME_DIR" "$WORKSPACE"
