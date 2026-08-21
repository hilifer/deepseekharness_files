#!/bin/bash
# =====================================================================
# 放开 bwrap 的非特权 user namespace 权限（Ubuntu 24.04+ 需要）
#
# 现象：bwrap 报 "setting up uid map: Permission denied"
# 原因：Ubuntu 24.04 起 AppArmor 默认拦截非特权 user namespace
#       （kernel.apparmor_restrict_unprivileged_userns = 1）
#
# 两种做法：
#   profile（默认，推荐）—— 只给 bwrap 这一个可执行文件开 userns 权限，
#                            系统里其余程序仍然受限
#   sysctl              —— 全局关掉该限制。一行搞定，但削弱整机防护
#
# 用法:
#   sudo scripts/apparmor-allow-userns.sh            # 装 AppArmor profile
#   sudo scripts/apparmor-allow-userns.sh --sysctl   # 改用全局 sysctl
#   scripts/apparmor-allow-userns.sh --status        # 只看当前状态，不改动
# =====================================================================
set -euo pipefail

# 本脚本要用 sudo 跑，但 bwrap 可能是免 root 装在【调用者】的家目录下
# （install-bubblewrap.sh 装到 $HOME/bwrap/）。sudo 下 $HOME 会变成 /root，
# 直接用 $HOME 会找不到那个 bwrap。所以优先按 SUDO_USER 的家目录来定位。
if [ -z "${DSH_ROOT:-}" ] && [ -n "${SUDO_USER:-}" ]; then
  DSH_ROOT=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
fi
DSH_ROOT="${DSH_ROOT:-$HOME}"
AA_SYSCTL=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
MODE="${1:-profile}"

find_bwrap() {
  local c
  for c in "$(command -v bwrap 2>/dev/null || true)" \
           "$DSH_ROOT/bwrap/usr/bin/bwrap" /usr/bin/bwrap /bin/bwrap; do
    [ -n "$c" ] && [ -x "$c" ] && { readlink -f "$c"; return 0; }
  done
  return 1
}

show_status() {
  if [ -r "$AA_SYSCTL" ]; then
    echo "  kernel.apparmor_restrict_unprivileged_userns = $(cat "$AA_SYSCTL")  (1 = 拦截中)"
  else
    echo "  本机没有 apparmor_restrict_unprivileged_userns（不是 Ubuntu 24.04+，或未启用 AppArmor）"
  fi
  if BW=$(find_bwrap); then
    echo "  bwrap: $BW"
    if "$BW" --ro-bind / / --unshare-all --share-net true 2>/dev/null; then
      echo "  实测: ✅ 可用"
    else
      echo "  实测: ❌ 不可用 -> $("$BW" --ro-bind / / --unshare-all --share-net true 2>&1 | head -1)"
    fi
  else
    echo "  bwrap: 未安装（先跑 scripts/install-bubblewrap.sh）"
  fi
}

if [ "$MODE" = "--status" ]; then
  echo "当前状态："; show_status; exit 0
fi

echo "改动前："; show_status; echo

[ "$(id -u)" = "0" ] || { echo "需要 root：sudo $0 $MODE"; exit 1; }

if [ "$MODE" = "--sysctl" ]; then
  echo "[全局 sysctl] 关闭 AppArmor 对非特权 user namespace 的限制"
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' > /etc/sysctl.d/60-dsh-userns.conf
  sysctl --system >/dev/null
else
  BW=$(find_bwrap) || { echo "未找到 bwrap，先跑 scripts/install-bubblewrap.sh"; exit 1; }
  command -v apparmor_parser >/dev/null 2>&1 || {
    echo "没有 apparmor_parser。要么装 apparmor 工具包，要么改用: sudo $0 --sysctl"; exit 1; }

  # profile 名不能含 '/'，用路径去掉分隔符生成一个稳定的名字
  PROFILE_NAME="dsh-bwrap$(echo "$BW" | tr '/' '.')"
  PROFILE_PATH="/etc/apparmor.d/$PROFILE_NAME"
  echo "[AppArmor profile] 只为 $BW 开放 userns 权限"
  cat > "$PROFILE_PATH" <<EOF
# 由 scripts/apparmor-allow-userns.sh 生成。
# 只给这一个 bwrap 可执行文件开放非特权 user namespace 权限，
# 系统里其他程序仍受 kernel.apparmor_restrict_unprivileged_userns=1 限制。
abi <abi/4.0>,
include <tunables/global>

profile $PROFILE_NAME $BW flags=(unconfined) {
  userns,
  include if exists <local/$PROFILE_NAME>
}
EOF
  apparmor_parser -r "$PROFILE_PATH"
  echo "  已写入 $PROFILE_PATH 并加载"
fi

echo
echo "改动后："; show_status
echo
if BW=$(find_bwrap) && "$BW" --ro-bind / / --unshare-all --share-net true 2>/dev/null; then
  echo "✅ 沙箱可用。下一步："
  echo "   DSH_ROOT=$DSH_ROOT $DSH_ROOT/scripts/preflight-sandbox.sh"
else
  echo "❌ 仍不可用。若用的是 profile 方式，改试全局 sysctl: sudo $0 --sysctl"
  exit 1
fi
