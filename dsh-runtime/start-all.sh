#!/bin/bash
# Idempotent master start script: dsh (main + per-user) + authelia + nginx + filebrowser
# Rootless adaptation of F6 (systemd autostart unavailable: no systemd/cron in container).
# Boot autostart: have the container entrypoint run this script, OR it auto-fires
# from the ~/.bashrc guard hook on any interactive login.
export PATH="$HOME/node/bin:$PATH"
export DSH_HOME="$HOME/.local/share/dsh"

DSH_NODE="$HOME/node/bin/node"
DSH_BIN="$HOME/node/bin/dsh"
DSH_USERS_ROOT="$HOME/dsh-users"
PORTS_FILE="$DSH_USERS_ROOT/ports.json"
DSH_TRUSTED_HOST="218.17.143.249:8099"

is_up() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# 1) 核心服务：dsh 主实例(admin) / authelia / nginx / filebrowser
$HOME/dsh-runtime/dsh-start.sh start
$HOME/dsh-auth/authelia-start.sh start
$HOME/nginx/nginx-start.sh start
$HOME/scripts/fb-start.sh start

# 2) 每用户 dsh 实例：遍历 ports.json（username -> port），幂等启动
if [ -f "$PORTS_FILE" ]; then
  python3 - "$PORTS_FILE" <<'PYEOF' | while read -r user port; do
import json, sys
with open(sys.argv[1]) as f:
    ports = json.load(f)
for user, port in ports.items():
    print(f"{user} {port}")
PYEOF
    dsh_home="$DSH_USERS_ROOT/$user"
    if pgrep -f "dsh web --port $port" >/dev/null 2>&1; then
      echo "dsh:$user already running on $port"
    else
      allowed_root=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ids = d['global']['workspaceIds']
    print(d['tables']['workspaces'][ids[0]]['path'] if ids else '')
except Exception:
    print('')
" "$dsh_home/storages/workspace.json")
      if [ -z "$allowed_root" ]; then
        echo "dsh:$user warning: no workspace root found; picker UNCLAMPED"
      fi
      DSH_HOME="$dsh_home" DSH_ALLOWED_ROOT="$allowed_root" setsid nohup "$DSH_NODE" "$DSH_BIN" web --port "$port" --trusted-host "$DSH_TRUSTED_HOST" \
        >> "$dsh_home/dsh.log" 2>&1 &
      sleep 2
      if curl -sf -o /dev/null "http://127.0.0.1:$port/"; then
        echo "dsh:$user started (127.0.0.1:$port, root=$allowed_root)"
      else
        echo "dsh:$user FAILED health check (see $dsh_home/dsh.log)"
      fi
    fi
  done
else
  echo "warning: $PORTS_FILE missing; no per-user dsh instances"
fi

echo "--- status ---"
for name_pid in "dsh:$HOME/dsh-runtime/dsh.pid" "authelia:$HOME/dsh-auth/authelia.pid" "nginx:$HOME/nginx/nginx.pid" "filebrowser:$HOME/filebrowser/fb.pid"; do
  name="${name_pid%%:*}"; pidfile="${name_pid#*:}"
  if is_up "$pidfile"; then echo "$name: UP (pid $(cat "$pidfile"))"; else echo "$name: DOWN"; fi
done
if [ -f "$PORTS_FILE" ]; then
  python3 - "$PORTS_FILE" <<'PYEOF' | while read -r user port; do
import json, sys
with open(sys.argv[1]) as f:
    ports = json.load(f)
for user, port in ports.items():
    print(f"{user} {port}")
PYEOF
    if pgrep -f "dsh web --port $port" >/dev/null 2>&1; then
      echo "dsh:$user: UP (port $port)"
    else
      echo "dsh:$user: DOWN (port $port)"
    fi
  done
fi