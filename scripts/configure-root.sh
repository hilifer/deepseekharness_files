#!/bin/bash
# =====================================================================
# 把各配置文件里的部署根路径改成指定值。
#
# nginx / FileBrowser / Authelia 的配置只能写绝对路径，没法用环境变量，
# 所以仓库里默认写的是 /home/ubuntu。若实际部署在别的用户下
# （比如 /home/robot），先跑一次本脚本，全部改过来。
#
# 用法:
#   scripts/configure-root.sh                 # 改成当前 $HOME
#   scripts/configure-root.sh /home/robot     # 改成指定路径
#   scripts/configure-root.sh --show          # 只显示当前配置里的根，不改动
#
# 幂等：已经是目标值则不动。可重复执行，也可反复改到不同的根。
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根

# 这些文件里含有必须跟着部署根走的绝对路径
FILES=(
  nginx/conf/nginx.conf
  nginx/conf/sites/dsh-auth.conf
  filebrowser/config.yaml
  dsh-auth/config/configuration.example.yml
)
[ -f dsh-auth/config/configuration.yml ] && FILES+=(dsh-auth/config/configuration.yml)

detect_root() {
  # 以 nginx.conf 的 pid 行为准：pid <root>/nginx/nginx.pid
  sed -n 's#^pid \(.*\)/nginx/nginx\.pid;#\1#p' nginx/conf/nginx.conf | head -1
}

CURRENT=$(detect_root)
[ -n "$CURRENT" ] || { echo "无法从 nginx/conf/nginx.conf 判定当前部署根"; exit 1; }

if [ "${1:-}" = "--show" ]; then
  echo "配置文件里的当前部署根: $CURRENT"
  echo "各文件中该路径的出现次数:"
  for f in "${FILES[@]}"; do
    printf '  %-46s %s\n' "$f" "$(grep -c -- "$CURRENT" "$f" || true)"
  done
  exit 0
fi

NEW_ROOT="${1:-$HOME}"
case "$NEW_ROOT" in
  /*) ;;
  *) echo "部署根必须是绝对路径: $NEW_ROOT"; exit 1;;
esac
NEW_ROOT="${NEW_ROOT%/}"

if [ "$CURRENT" = "$NEW_ROOT" ]; then
  echo "部署根已经是 $NEW_ROOT，无需改动"
  exit 0
fi

echo "部署根: $CURRENT  ->  $NEW_ROOT"
total=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  n=$(grep -c -- "$CURRENT" "$f" || true)
  [ "$n" = "0" ] && continue
  # 用 | 作分隔符：路径里有 /，但不会有 |
  sed -i "s|${CURRENT}|${NEW_ROOT}|g" "$f"
  printf '  %-46s 替换 %s 处\n' "$f" "$n"
  total=$((total + n))
done
echo "共替换 $total 处"

left=$(grep -rl -- "$CURRENT" "${FILES[@]}" 2>/dev/null || true)
[ -z "$left" ] || { echo "仍有文件残留旧路径: $left"; exit 1; }

echo
echo "接下来："
echo "  1. 确认 $NEW_ROOT 下已有 nginx/ filebrowser/ dsh-auth/ dsh-files/ 等目录"
echo "  2. DSH_ROOT=$NEW_ROOT $NEW_ROOT/scripts/init-secrets.sh"
echo "  3. DSH_ROOT=$NEW_ROOT $NEW_ROOT/dsh-runtime/start-all.sh"
echo "  注意：各启动脚本默认取 \$HOME，若以别的用户运行请显式传 DSH_ROOT。"
