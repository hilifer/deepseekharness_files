#!/bin/bash
# admin 主实例（端口 3080）start/stop/restart。
# 与员工实例一样经 dsh-sandbox.sh 启动（隔离档位由它按当前环境自动挑），
# 工作区为整个 dsh-files 根。
export PATH="$HOME/node/bin:$PATH"
DSH_ROOT="${DSH_ROOT:-$HOME}"; export DSH_ROOT
PIDFILE="$DSH_ROOT/dsh-runtime/dsh.pid"
LOG="$DSH_ROOT/dsh-runtime/dsh.log"
SANDBOX="$DSH_ROOT/dsh-runtime/dsh-sandbox.sh"
start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "dsh already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  if ! "$SANDBOX" --check >/dev/null 2>&1; then
    echo "挑不出隔离后端，拒绝启动 admin 实例。逐项原因: $SANDBOX --report"; return 1
  fi
  setsid nohup "$SANDBOX" admin 3080 "$DSH_ROOT/.local/share/dsh" "$DSH_ROOT/dsh-files" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "dsh started (pid $(cat "$PIDFILE"))"
}
stop() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi
  pkill -f "dsh web --port 3080 " 2>/dev/null
  echo "dsh stopped"
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;;
  *) echo "usage: $0 start|stop|restart";; esac
