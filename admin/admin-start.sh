#!/bin/bash
# 员工管理后台 start/stop/restart（rootless，幂等）
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
PIDFILE="$DSH_ROOT/admin/admin.pid"
LOG="$DSH_ROOT/admin/admin.log"
APP="$DSH_ROOT/admin/app.py"
export ADMIN_USERS="${ADMIN_USERS:-admin}"
export ADMIN_PORT="${ADMIN_PORT:-19200}"
export ADMIN_HOST=127.0.0.1
export DSH_ROOT

is_up() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if is_up; then echo "admin already running (pid $(cat "$PIDFILE"))"; return 0; fi
  mkdir -p "$(dirname "$LOG")"
  setsid nohup python3 "$APP" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 10); do
    curl -sf -o /dev/null "http://127.0.0.1:$ADMIN_PORT/admin/api/health" && break
    sleep 1
  done
  if is_up; then echo "admin started (pid $(cat "$PIDFILE"), port $ADMIN_PORT)";
  else echo "admin FAILED to start (see $LOG)"; return 1; fi
}
stop() {
  if is_up; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo "admin stopped";
  else echo "admin not running"; fi
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;;
  *) echo "usage: $0 start|stop|restart"; exit 1;; esac
