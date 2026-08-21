#!/bin/bash
# 无 root 安装 bubblewrap —— 与本仓库安装 nginx 的方式一致（解包 deb，不装进系统）。
# 装到 $DSH_ROOT/bwrap/usr/bin/bwrap，dsh-sandbox.sh 会自动找到它。
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
DEST="$DSH_ROOT/bwrap"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

if command -v bwrap >/dev/null 2>&1; then
  echo "系统已有 bwrap: $(command -v bwrap) ($(bwrap --version 2>&1))"
  exit 0
fi
if [ -x "$DEST/usr/bin/bwrap" ]; then
  echo "已安装: $DEST/usr/bin/bwrap"; exit 0
fi

echo "[1/3] 下载 bubblewrap deb..."
cd "$WORK"
if command -v apt-get >/dev/null 2>&1 && apt-get download bubblewrap 2>/dev/null; then
  :
elif command -v curl >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  echo "  apt-get download 不可用，尝试从 Ubuntu 归档直接取包（arch=$ARCH）"
  BASE="http://archive.ubuntu.com/ubuntu/pool/main/b/bubblewrap"
  LISTING=$(curl -fsSL "$BASE/" || true)
  PKG=$(printf '%s' "$LISTING" | grep -o "bubblewrap_[^\"]*_${ARCH}\.deb" | sort -V | tail -1)
  [ -n "$PKG" ] || { echo "无法确定包名，请手工下载 bubblewrap deb 放到 $WORK 后重跑"; exit 1; }
  curl -fsSLO "$BASE/$PKG"
else
  echo "既没有 apt-get 也没有 curl，请手工下载 bubblewrap 的 .deb 并解包到 $DEST"; exit 1
fi

DEB=$(ls -1 ./*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || { echo "没找到下载的 deb"; exit 1; }

echo "[2/3] 解包到 $DEST ..."
mkdir -p "$DEST"
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$DEB" "$DEST"
else
  ar x "$DEB"
  tar -xf data.tar.* -C "$DEST"
fi
[ -x "$DEST/usr/bin/bwrap" ] || { echo "解包后未找到 $DEST/usr/bin/bwrap"; exit 1; }

echo "[3/3] 自检..."
if "$DSH_ROOT/dsh-runtime/dsh-sandbox.sh" --check; then
  echo
  echo "✅ 安装完成。接下来："
  echo "   1. 验证隔离真的生效: $DSH_ROOT/scripts/preflight-sandbox.sh"
  echo "   2. 重启全栈让实例进沙箱: $DSH_ROOT/dsh-runtime/start-all.sh"
else
  echo
  echo "❌ bwrap 已就位但跑不起来。上面 --check 的输出已定位到具体原因，按提示处理。"
  echo "   最常见的一种：Ubuntu 24.04 起 AppArmor 默认拦截非特权 user namespace，"
  echo "   报错为 'setting up uid map: Permission denied'，需在宿主机上放开 sysctl"
  echo "   kernel.apparmor_restrict_unprivileged_userns=0（容器内改不了）。"
  exit 1
fi
