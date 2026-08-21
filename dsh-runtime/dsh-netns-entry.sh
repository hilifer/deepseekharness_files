#!/bin/bash
# 沙箱内的入口（仅 DSH_NETNS=1 时使用）。
#
# 此时实例跑在自己私有的网络命名空间里：13101 这类端口只存在于本命名空间，
# 宿主回环上没有任何监听，别的员工的实例也就无从连起。
# nginx 经 bind-mount 进来的 unix socket 进来，socat 把它桥到本地端口。
set -euo pipefail
: "${DSH_SOCKET:?缺少 DSH_SOCKET}" "${DSH_PORT:?缺少 DSH_PORT}"
: "${DSH_NODE_BIN:?缺少 DSH_NODE_BIN}" "${DSH_BIN:?缺少 DSH_BIN}"

rm -f "$DSH_SOCKET"
socat "UNIX-LISTEN:$DSH_SOCKET,fork,mode=600" "TCP:127.0.0.1:$DSH_PORT" &
SOCAT_PID=$!
trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT

read -r -a host_args <<< "${DSH_TRUSTED_HOST_ARGS:-}"
exec "$DSH_NODE_BIN" "$DSH_BIN" web --port "$DSH_PORT" "${host_args[@]}"
