#!/bin/bash
# =====================================================================
# 诊断 dsh 接口 403 —— 页面能开、API 却 403 的那种。
#
# 用法: diag-403.sh [用户名]   不传则诊断 admin(3080)
#
# 这套部署里 403 只有两个来源，现象完全不同：
#   黑洞 13100（map 未匹配用户）-> 整个界面都打不开
#   dsh 实例自己拒绝            -> 页面正常，只有 API 403  ← 本脚本查这个
# dsh 拒绝 API 的判据是 --trusted-host（Host/Origin 校验）。浏览器地址栏里的
# host:port 不在白名单里时，静态页照发、API 一律 403。
# =====================================================================
set -uo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
USER_ARG="${1:-admin}"

PORT=$(python3 - "$DSH_ROOT" "$USER_ARG" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
root, user = Path(sys.argv[1]), sys.argv[2]
if user == "admin":
    print(3080); raise SystemExit
reg = root / "dsh-users" / "registry.json"
if reg.exists():
    u = json.loads(reg.read_text(encoding="utf-8")).get("users", {})
    if user in u: print(u[user]["port"])
PY
)
[ -n "$PORT" ] || { echo "登记表里找不到用户 $USER_ARG"; exit 1; }
echo "受测: $USER_ARG  端口: $PORT"
echo

echo "=== 1. 该实例进程实际带了哪些 --trusted-host ==="
PS=$(pgrep -af "dsh web --port $PORT" | head -1)
if [ -z "$PS" ]; then
  echo "  ❌ 实例没在跑（端口 $PORT 上没有 dsh 进程）"
  exit 1
fi
echo "$PS" | tr ' ' '\n' | grep -A1 '^--trusted-host$' | grep -v '^--trusted-host$' \
  | sed 's/^/  · /' || echo "  （一个都没有）"
echo

echo "=== 2. 直连实例，逐个 Host 试 /api/settings.describe ==="
# 用 curl 直接打实例端口，绕开 nginx。Host 头就是判据本身。
for H in "127.0.0.1:8099" "$(hostname):8099" "localhost:8099" "127.0.0.1:$PORT"; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
         -H "Host: $H" -H "Origin: https://$H" \
         "http://127.0.0.1:$PORT/api/settings.describe" 2>/dev/null)
  case "$CODE" in
    403) echo "  ❌ Host: $H  -> 403（不在 --trusted-host 白名单里）" ;;
    000) echo "  ·  Host: $H  -> 连不上" ;;
    *)   echo "  ✅ Host: $H  -> HTTP $CODE（这个 host 是被接受的）" ;;
  esac
done
echo
echo "=== 3. 结论 ==="
echo "  浏览器地址栏里用的 host:port，必须出现在第 1 节那份白名单里。"
echo "  不在的话，把它加进去："
echo "    DSH_TRUSTED_HOSTS=\"已有的三个 你要用的host:端口\""
echo "  改 admin/core.py 的 trusted_hosts 默认值（或用环境变量），然后重启实例。"
