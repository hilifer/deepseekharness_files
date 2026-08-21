#!/bin/bash
# FileBrowser Quantum start/stop/restart (rootless, setsid nohup, idempotent)
BIN="/home/ubuntu/filebrowser/filebrowser"
CONF="/home/ubuntu/filebrowser/config.yaml"
PIDFILE="/home/ubuntu/filebrowser/fb.pid"
LOG="/home/ubuntu/filebrowser/logs/fb.log"

is_up() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if is_up; then
    echo "filebrowser already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  setsid nohup "$BIN" -c "$CONF" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  # wait up to 10s for the port to open
  for i in $(seq 1 10); do
    if curl -s -o /dev/null http://127.0.0.1:18080/files/ 2>/dev/null; then break; fi
    sleep 1
  done
  if is_up; then echo "filebrowser started (pid $(cat "$PIDFILE"))"; else echo "filebrowser FAILED to start (see $LOG)"; return 1; fi
}

stop() {
  if is_up; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo "filebrowser stopped"; else echo "filebrowser not running"; fi
}

case "$1" in
  start) start;;
  stop) stop;;
  restart) stop; sleep 1; start;;
  *) echo "usage: $0 start|stop|restart"; exit 1;;
esac