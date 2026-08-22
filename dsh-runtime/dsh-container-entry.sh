#!/bin/bash
# =====================================================================
# 容器后端在【实例容器内部】的入口（由 backends/container.sh bind-mount 进去）。
#
# 为什么不能直接 exec dsh：
#   dsh 的 web 服务默认只监听 127.0.0.1。容器里的 127.0.0.1 是容器自己的回环，
#   `docker run -p 127.0.0.1:13101:13101` 转发到的是容器的 eth0，连不上回环，
#   端口发布形同虚设，nginx 也就打不通。
#   所以固定让 dsh 跑在容器内部端口（默认 3000），再用 socat 在 0.0.0.0 上
#   开对外端口桥过去。dsh 若本来就监听 0.0.0.0，这一层也无害（端口不冲突）。
#
# 调用形态刻意保留了宿主侧能认出来的样子：
#   dsh-container-entry.sh <node> <dsh> web --port <外部端口> --trusted-host ...
# 宿主上 `docker run` 进程的 argv 里因此含有 "dsh web --port <端口> "，
# core.py 的 pgrep/pkill 与其他后端共用同一套识别方式，不必分叉。
# 本脚本把 --port 的值改写成内部端口后再 exec。
# =====================================================================
set -euo pipefail

INNER="${DSH_INNER_PORT:-3000}"
args=("$@")
ext=""
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "--port" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
    ext="${args[$((i + 1))]}"
    args[$((i + 1))]="$INNER"
    break
  fi
done
[ -n "$ext" ] || { echo "[entry] 错误: 命令行里没有 --port" >&2; exit 2; }

if [ "$ext" != "$INNER" ]; then
  if command -v socat >/dev/null 2>&1; then
    socat "TCP-LISTEN:$ext,fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:$INNER" &
    SOCAT_PID=$!
    trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT
  else
    # 镜像里没有 socat：只能寄望 dsh 自己监听 0.0.0.0。不静默——起不来时
    # 要能一眼看出是这个原因。
    echo "[entry] 警告: 镜像内无 socat，直接让 dsh 监听 $ext；" \
         "若 dsh 只绑 127.0.0.1 则端口发布无效（请在镜像里装 socat）" >&2
    args[$((i + 1))]="$ext"
  fi
fi

exec "${args[@]}"
