#!/bin/bash
DSH_ROOT="${DSH_ROOT:-$HOME}"
PIDFILE="$DSH_ROOT/dsh-auth/authelia.pid"
LOG="$DSH_ROOT/dsh-auth/authelia.log"
start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "authelia already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  setsid nohup "$DSH_ROOT/dsh-auth/authelia" --config "$DSH_ROOT/dsh-auth/config/configuration.yml" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "authelia started (pid $(cat "$PIDFILE"))"
}
stop() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo "authelia stopped"; fi
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;; *) echo "usage: $0 start|stop|restart";; esac
