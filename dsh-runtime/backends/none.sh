#!/bin/bash
# =====================================================================
# 后端 none —— 不做任何隔离，仅供排障
#
# 用法（由 dsh-sandbox.sh 调度，不直接调用）:
#   backends/none.sh probe
#   backends/none.sh run <username> <port> <dsh_home> <workspace>
#
# 只有显式设置 DSH_ALLOW_UNCONFINED=1 时 probe 才会通过。默认情况下
# 三档隔离全不可用 = 拒绝启动实例（fail-closed），宁可服务不可用，
# 也不让全公司文件对每个员工的 agent 敞开。
# =====================================================================
set -euo pipefail

BACKEND_TAG=none
# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

backend_probe() {
  if [ "${DSH_ALLOW_UNCONFINED:-0}" = "1" ]; then
    echo "OK 无隔离（DSH_ALLOW_UNCONFINED=1）"; return 0
  fi
  echo "REFUSED"
  return 1
}

warn_loudly() { # $1=username
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  log "!! DSH_ALLOW_UNCONFINED=1 -> 无隔离启动 $1 的实例"
  log "!! 该实例可读写整台服务器的所有文件，包括其他部门的文件、"
  log "!! Authelia 用户库和 TLS 私钥；机器上若有 docker socket，"
  log "!! 它还能一句话逃到宿主 root。仅供排障，不要长期这样跑。"
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  [ "${DSH_ALLOW_UNCONFINED:-0}" = "1" ] || die "未显式放行，拒绝无隔离启动"
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE" "$USERNAME"
  warn_loudly "$USERNAME"

  WORKSPACE=$(readlink -f "$WORKSPACE")
  DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

  parse_extra_mounts "$WORKSPACE"
  build_instance_env "$USERNAME" "$DSH_HOME_DIR" "$WORKSPACE" "$ALLOWED_ROOTS"
  build_trusted_host_args

  local kv
  for kv in "${INSTANCE_ENV[@]}"; do export "${kv?}"; done

  cd "$WORKSPACE"
  exec "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
}

case "${1:-}" in
  probe) backend_probe ;;
  run)   shift; backend_run "$@" ;;
  *) echo "用法: $0 probe | run <username> <port> <dsh_home> <workspace>" >&2; exit 2 ;;
esac
