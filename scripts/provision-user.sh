#!/bin/bash
# =====================================================================
# provision-user.sh — 一键建号脚本（公司文件服务器 + 每员工独立 dsh 实例）
# 用法: provision-user.sh <username> <部门> <角色:员工|主管> [中文姓名]
#   例: provision-user.sh zhang_san 研发部 主管 张三
#        provision-user.sh li_si    研发部 员工 李四
#
# 依次完成:
#   1. Authelia 建号（argon2 哈希 + users_database.yml + 重启 + 记录初始密码）
#   2. 部门/个人目录创建（/home/ubuntu/dsh-files/departments/<部门>/<姓名>）
#   3. FileBrowser 用户预创建（CLI 建号 + API 设 scope/权限：主管 delete=true scope=部门，员工 delete=false scope=个人目录）
#   4. DSH_HOME 创建 + profiles 共享链接 + workspace.json 预播种（v2 schema）
#   5. 端口分配（13101+，写入 ports.json）
#   6. nginx 路由追加（if 链 + reload）——首次运行自动完成 8099 块变量化改造
#   7. 启动 dsh 实例
# 幂等：重复执行不重复建号（检测已存在则跳过/复用）。
# =====================================================================
set -euo pipefail

# ---------- 参数 ----------
USERNAME="${1:?用法: provision-user.sh <username> <部门> <角色:员工|主管> [中文姓名]}"
DEPARTMENT="${2:?缺少部门参数，如: 研发部}"
ROLE="${3:?缺少角色参数，必须是 员工 或 主管}"
NAME="${4:-$USERNAME}"

if [[ "$ROLE" != "员工" && "$ROLE" != "主管" ]]; then
  echo "错误: 角色必须是 '员工' 或 '主管' (got: $ROLE)"; exit 1
fi

# ---------- 常量 ----------
AUTH_BIN=/home/ubuntu/dsh-auth/authelia
AUTH_USERS=/home/ubuntu/dsh-auth/config/users_database.yml
AUTH_START=/home/ubuntu/dsh-auth/authelia-start.sh
AUTH_HEALTH="http://127.0.0.1:19091/api/health"
CREDS_FILE=/home/ubuntu/dsh-auth/initial-credentials.txt

FB_BIN=/home/ubuntu/filebrowser/filebrowser
FB_CONF=/home/ubuntu/filebrowser/config.yaml
FB_START=/home/ubuntu/scripts/fb-start.sh
FB_BASE="http://127.0.0.1:18080/files"
FB_SOURCE_NAME="公司文件"

DSH_BIN=/home/ubuntu/node/bin/dsh
DSH_NODE=/home/ubuntu/node/bin/node
DSH_USERS_ROOT=/home/ubuntu/dsh-users
PORTS_FILE=$DSH_USERS_ROOT/ports.json
DSH_TRUSTED_HOST="218.17.143.249:8099"
SHARED_PROFILES=/home/ubuntu/.local/share/dsh/profiles

NGINX_BIN=/home/ubuntu/nginx/extracted/usr/sbin/nginx
NGINX_CONF=/home/ubuntu/nginx/conf/nginx.conf
NGINX_SITE=/home/ubuntu/nginx/conf/sites/dsh-auth.conf

DEPT_DIR="/home/ubuntu/dsh-files/departments/$DEPARTMENT"
PERSONAL_DIR="$DEPT_DIR/$NAME"

# 初始密码：默认随机 14 位；可用环境变量 INIT_PW 覆盖（示例演示用）
INIT_PW="${INIT_PW:-$(python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(14)))")}"

log() { echo "[provision] $*" >&2; }
die() { echo "[provision] 错误: $*" >&2; exit 1; }

# =====================================================================
# 1. Authelia 建号（幂等）
# =====================================================================
authelia_provision() {
  if grep -q "^  $USERNAME:" "$AUTH_USERS"; then
    log "Authelia: $USERNAME 已存在，跳过建号"
  else
    log "Authelia: 生成 $USERNAME 的 argon2 哈希..."
    HASH=$(cd /home/ubuntu/dsh-auth && "$AUTH_BIN" crypto hash generate argon2 --password "$INIT_PW" --no-confirm 2>/dev/null | sed -n 's/^Digest: //p')
    [[ -n "$HASH" ]] || die "argon2 哈希生成失败"
    cat >> "$AUTH_USERS" <<EOF
  $USERNAME:
    displayname: "$NAME（$DEPARTMENT$ROLE）"
    password: '$HASH'
    email: $USERNAME@company.local
    groups: []
EOF
    log "Authelia: 追加 $USERNAME 到 users_database.yml，重启..."
    "$AUTH_START" restart
    sleep 2
    curl -sf "$AUTH_HEALTH" > /dev/null || die "Authelia 重启后 health 检查失败"
    # 记录初始密码（600 权限）
    printf '%-12s %-18s %s\n' "$USERNAME" "$NAME（$DEPARTMENT$ROLE）" "$INIT_PW" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    log "Authelia: $USERNAME 创建完成，初始密码已记录到 $CREDS_FILE"
  fi
}

# =====================================================================
# 2. 部门/个人目录
# =====================================================================
mkdir_dirs() {
  mkdir -p "$DEPT_DIR" "$PERSONAL_DIR"
  log "目录: $PERSONAL_DIR 就绪"
}

# =====================================================================
# 3. FileBrowser 用户（幂等：存在则只更新 scope/权限，不存在先 CLI 建号）
# =====================================================================
fb_api() { # $1=method $2=path [$3=json-body]
  local method=$1 path=$2 body=${3:-}
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" -H "X-Forwarded-User: admin" -H "Content-Type: application/json" \
      "$FB_BASE$path" -d "$body"
  else
    curl -sf -X "$method" -H "X-Forwarded-User: admin" "$FB_BASE$path"
  fi
}

filebrowser_provision() {
  # 确保服务运行（API 需要）
  "$FB_START" start >/dev/null 2>&1 || true
  sleep 1

  # 查用户是否存在
  local exists uid
  exists=$(fb_api GET "/api/users" | python3 -c "
import json,sys
users=json.load(sys.stdin)
u=[x for x in users if x['username']=='$USERNAME']
print('yes' if u else 'no')
" 2>/dev/null || echo "no")

  if [[ "$exists" == "no" ]]; then
    log "FileBrowser: 停止服务后用 CLI 创建用户 $USERNAME..."
    "$FB_START" stop >/dev/null 2>&1 || true
    sleep 1
    RAND_PW=$(python3 -c "import secrets;print(secrets.token_urlsafe(12))")
    (cd /home/ubuntu/filebrowser && timeout 30 "$FB_BIN" set -u "$USERNAME,$RAND_PW" -c "$FB_CONF" </dev/null >/dev/null 2>&1) \
      || die "filebrowser set -u 创建用户失败"
    "$FB_START" start >/dev/null 2>&1 || true
    sleep 1
  fi

  # 更新 scope/权限（幂等，主管/员工按权限模型）
  local scope delete_flag
  if [[ "$ROLE" == "主管" ]]; then
    scope="/departments/$DEPARTMENT"        # 主管 scope = 整个部门
    delete_flag=true
  else
    scope="/departments/$DEPARTMENT/$NAME"  # 员工 scope = 个人目录
    delete_flag=false
  fi

  # 构造 UserRequest: {"which":["scopes","permissions","loginMethod"], "data": <完整用户对象>}
  # 注: CLI set -u 建的用户 loginMethod=password，proxy auth 强制要求 loginMethod=proxy，
  #     且员工必须 api=true 才能用 Web UI 上传下载（api=false 会阻断全部 API）。
  local py_delete
  if [[ "$delete_flag" == "true" ]]; then py_delete="True"; else py_delete="False"; fi
  fb_api PUT "/api/users?username=$USERNAME" "$(python3 -c "
import json,urllib.request
req=urllib.request.Request('$FB_BASE/api/users', headers={'X-Forwarded-User':'admin'})
users=json.load(urllib.request.urlopen(req))
u=[x for x in users if x['username']=='$USERNAME'][0]
u['loginMethod']='proxy'
u['scopes']=[{'name':'$FB_SOURCE_NAME','scope':'$scope'}]
u['permissions']={'api':True,'admin':False,'modify':True,'share':False,'realtime':True,'delete':$py_delete,'create':True,'download':True}
print(json.dumps({'which':['scopes','permissions','loginMethod'],'data':u}))
")" >/dev/null \
    && log "FileBrowser: $USERNAME scope=$scope delete=$delete_flag loginMethod=proxy 已设置"
}

# =====================================================================
# 4. DSH_HOME + workspace.json 预播种
# =====================================================================
dsh_home_provision() {
  local dsh_home="$DSH_USERS_ROOT/$USERNAME"
  mkdir -p "$dsh_home/storages"
  if [[ ! -e "$dsh_home/profiles" ]]; then
    ln -s "$SHARED_PROFILES" "$dsh_home/profiles" 2>/dev/null \
      || cp -r "$SHARED_PROFILES" "$dsh_home/profiles"
    log "DSH: profiles 链接建立 ($dsh_home/profiles)"
  fi
  if [[ ! -f "$dsh_home/storages/workspace.json" ]]; then
    local uuid now
    uuid=$(python3 -c "import uuid;print(uuid.uuid4())")
    now=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    cat > "$dsh_home/storages/workspace.json" <<EOF
{
  "unit": { "name": "workspace", "version": 2 },
  "global": { "initialized": true, "workspaceIds": ["$uuid"], "archivedSessionIds": [] },
  "tables": { "workspaces": { "$uuid": {
    "path": "$PERSONAL_DIR",
    "title": "$NAME", "sessionIds": [], "createdAt": "$now", "updatedAt": "$now"
  } } }
}
EOF
    log "DSH: workspace.json 已预播种 -> $PERSONAL_DIR"
  else
    log "DSH: workspace.json 已存在，跳过播种"
  fi
}

# =====================================================================
# 5. 端口分配（13101+，写入 ports.json）
# =====================================================================
port_alloc() {
  local port
  if [[ -f "$PORTS_FILE" ]] && python3 -c "import json;d=json.load(open('$PORTS_FILE'));assert '$USERNAME' in d" 2>/dev/null; then
    port=$(python3 -c "import json;d=json.load(open('$PORTS_FILE'));print(d['$USERNAME'])")
    log "端口: $USERNAME 已分配 $port（复用）"
  else
    port=$(python3 -c "
import json,os
f='$PORTS_FILE'
d=json.load(open(f)) if os.path.exists(f) else {}
used=set(d.values())
p=13101
while p in used: p+=1
d['$USERNAME']=p
json.dump(d,open(f,'w'),ensure_ascii=False,indent=2)
print(p)
")
    log "端口: $USERNAME -> $port（写入 $PORTS_FILE）"
  fi
  echo "$port"
}

# =====================================================================
# 6. nginx 路由追加（编辑 nginx.conf 的 map $user $dsh_upstream + reload）
#    注意：路由必须加在 http 段的 map 里。site 文件里 rewrite 阶段的
#    if ($user = ...) 无效——auth_request_set 的 $user 在 access 阶段才赋值，
#    proxy_pass 引用变量时的懒求值只对 map 生效。
# =====================================================================
nginx_provision() {
  local port=$1
  if grep -q "\"$USERNAME\"" "$NGINX_CONF"; then
    log "nginx: $USERNAME 路由已存在，跳过"
  else
    python3 - "$NGINX_CONF" "$USERNAME" "$port" <<'PYEOF'
import sys, re
p, u, port = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
m = re.search(r'(map \$user \$dsh_upstream \{)(.*?)(\n    \})', s, re.S)
assert m, 'map $user $dsh_upstream 块未找到'
line = f'\n        "{u}"      127.0.0.1:{port};'
s = s[:m.end(2)] + line + s[m.end(2):]
open(p, 'w').write(s)
PYEOF
    "$NGINX_BIN" -t -c "$NGINX_CONF" >/dev/null || die "nginx -t 失败"
    "$NGINX_BIN" -s reload -c "$NGINX_CONF" >/dev/null 2>&1 || die "nginx reload 失败"
    log "nginx: $USERNAME -> 127.0.0.1:$port 已加入 map 并 reload"
  fi
}

# =====================================================================
# 7. 启动 dsh 实例
# =====================================================================
dsh_start() {
  local port=$1 dsh_home="$DSH_USERS_ROOT/$USERNAME"
  if pgrep -f "dsh web --port $port" >/dev/null 2>&1; then
    log "dsh: $port 已有实例运行，跳过"
  else
    DSH_HOME="$dsh_home" DSH_ALLOWED_ROOT="$PERSONAL_DIR" setsid nohup "$DSH_NODE" "$DSH_BIN" web --port "$port" --trusted-host "$DSH_TRUSTED_HOST" \
      >> "$dsh_home/dsh.log" 2>&1 &
    sleep 2
    if curl -sf -o /dev/null "http://127.0.0.1:$port/"; then
      log "dsh: $USERNAME 实例已启动 (127.0.0.1:$port)"
    else
      log "警告: dsh 实例 $port 启动后健康检查未通过，见 $dsh_home/dsh.log"
    fi
  fi
}

# =====================================================================
# main
# =====================================================================
log "=== 开始为 $USERNAME ($NAME, $DEPARTMENT, $ROLE) 建号 ==="
authelia_provision
mkdir_dirs
filebrowser_provision
dsh_home_provision
PORT=$(port_alloc)
nginx_provision "$PORT"
dsh_start "$PORT"
log "=== $USERNAME 建号完成：dsh 端口 $PORT，初始密码见 $CREDS_FILE ==="
