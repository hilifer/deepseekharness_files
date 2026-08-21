#!/bin/bash
# 生成 nginx 注入的两个共享密钥（幂等，已存在则不动）：
#   1. admin-token.conf  管理后台 API 的共享密钥
#   2. fb-auth.conf      FileBrowser 代理认证头（头名本身就是密钥）
#
# 这两个密钥解决同一个问题：dsh 沙箱共享宿主的网络命名空间，能连上
# 127.0.0.1 的任意端口；但沙箱看不到宿主文件系统，所以拿不到密钥。
# 于是「能连上」不等于「能调用」。
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
GEN="$DSH_ROOT/nginx/conf/generated"
FB_CONF="$DSH_ROOT/filebrowser/config.yaml"
ADMIN_TOKEN_FILE="$DSH_ROOT/admin/.admin-token"

mkdir -p "$GEN" "$DSH_ROOT/admin"
chmod 700 "$GEN"

# ---- 1. 管理后台 token ----
if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
  python3 -c "import secrets;print(secrets.token_hex(32))" > "$ADMIN_TOKEN_FILE"
  chmod 600 "$ADMIN_TOKEN_FILE"
  echo "[secrets] 已生成管理后台 token"
fi
TOKEN=$(cat "$ADMIN_TOKEN_FILE")
printf 'proxy_set_header X-Admin-Token "%s";\n' "$TOKEN" > "$GEN/admin-token.conf"
chmod 600 "$GEN/admin-token.conf"

# ---- 2. FileBrowser 代理认证头 ----
if [ -f "$GEN/fb-auth.conf" ]; then
  FB_HEADER=$(sed -n 's/^proxy_set_header \([^ ]*\) .*/\1/p' "$GEN/fb-auth.conf" | head -1)
else
  FB_HEADER="X-Fb-Auth-$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
  echo "[secrets] 已生成 FileBrowser 代理认证头: $FB_HEADER"
fi
printf 'proxy_set_header %s $user;\n' "$FB_HEADER" > "$GEN/fb-auth.conf"
chmod 600 "$GEN/fb-auth.conf"

# ---- 3. 同步到 filebrowser/config.yaml ----
if [ -f "$FB_CONF" ]; then
  CURRENT=$(sed -n 's/^ *header: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$FB_CONF" | head -1)
  if [ "$CURRENT" != "$FB_HEADER" ]; then
    cp -a "$FB_CONF" "$FB_CONF.bak.$(date +%s)"
    python3 - "$FB_CONF" "$FB_HEADER" <<'PYEOF'
import re, sys
path, header = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
new, n = re.subn(r'(\n\s*header:\s*).*', lambda m: f'{m.group(1)}"{header}"', text, count=1)
if n == 0:
    raise SystemExit(f"未在 {path} 找到 auth.methods.proxy.header 行，请手工设置为 {header}")
open(path, 'w', encoding='utf-8').write(new)
PYEOF
    echo "[secrets] filebrowser/config.yaml 的 proxy header 已同步 -> $FB_HEADER"
    echo "[secrets] 需要重启 FileBrowser 才生效: scripts/fb-start.sh restart"
  fi
fi
echo "[secrets] 完成。密钥文件均为 600，且已在 .gitignore 中。"
