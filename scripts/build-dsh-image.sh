#!/bin/bash
# =====================================================================
# 构建员工实例容器镜像（container 后端用）。
#
# 用法:
#   scripts/build-dsh-image.sh              # 构建 dsh-instance:local
#   DSH_IMAGE=x:1 scripts/build-dsh-image.sh
#   DSH_IMAGE_BASE=debian:12 scripts/build-dsh-image.sh
#
# 基础镜像要与部署机同族：node 是以只读 volume 挂进容器的宿主二进制，
# 链接的是镜像里的 glibc。差太远会在容器里起不来（报 GLIBC_x.yy not found）。
# =====================================================================
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-$HOME}"
DOCKER_BIN="${DSH_DOCKER_BIN:-docker}"
DSH_IMAGE="${DSH_IMAGE:-dsh-instance:local}"
DSH_IMAGE_BASE="${DSH_IMAGE_BASE:-ubuntu:24.04}"
DOCKERFILE="$DSH_ROOT/dsh-runtime/Dockerfile.instance"

command -v "$DOCKER_BIN" >/dev/null 2>&1 || {
  echo "未找到 docker 客户端；容器后端不可用。" >&2
  echo "看看这台机器还能用哪一档: $DSH_ROOT/dsh-runtime/dsh-sandbox.sh --report" >&2
  exit 1
}
"$DOCKER_BIN" info >/dev/null 2>&1 || {
  echo "docker 客户端在，但连不上守护进程。" >&2
  echo "容器里跑的话需要把宿主 socket 挂进来: -v /var/run/docker.sock:/var/run/docker.sock" >&2
  exit 1
}
[ -r "$DOCKERFILE" ] || { echo "找不到 $DOCKERFILE" >&2; exit 1; }

echo "构建 $DSH_IMAGE（基础镜像 $DSH_IMAGE_BASE）..."
# 构建上下文用一个空目录：Dockerfile 里没有 COPY，把整个部署根当上下文
# 会白白把 dsh-files 全量打包发给守护进程（几个 G，还可能含机密）。
CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT
"$DOCKER_BIN" build --build-arg "BASE=$DSH_IMAGE_BASE" \
  -t "$DSH_IMAGE" -f "$DOCKERFILE" "$CTX"

echo
echo "完成。校验一下这台机器现在选哪一档:"
"$DSH_ROOT/dsh-runtime/dsh-sandbox.sh" --report || true
