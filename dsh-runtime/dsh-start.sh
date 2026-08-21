#!/bin/bash
export PATH="$HOME/node/bin:$PATH"
export DSH_HOME="$HOME/.local/share/dsh"
PIDFILE="$HOME/dsh-runtime/dsh.pid"
LOG="$HOME/dsh-runtime/dsh.log"
start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "dsh already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  setsid nohup env DSH_ALLOWED_ROOT="$HOME/dsh-files" "$HOME/node/bin/dsh" web --port 3080 --trusted-host 218.17.143.249:8099 > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "dsh started (pid $(cat "$PIDFILE"))"
}
stop() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo "dsh stopped"; fi
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;; *) echo "usage: $0 start|stop|restart";; esac
