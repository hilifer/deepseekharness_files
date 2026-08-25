#!/bin/bash
DSH_ROOT="${DSH_ROOT:-$HOME}"
PIDFILE="$DSH_ROOT/dsh-auth/authelia.pid"
LOG="$DSH_ROOT/dsh-auth/authelia.log"
TIMEOUT=10  # 等待进程退出的最大秒数

_kill_authelia() {
  # 1) 先按 PID 文件里的 PID 杀
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  fi
  # 2) 再把所有残留的 authelia 进程全部杀掉（防堆积）
  pkill -x authelia 2>/dev/null
}

_live_authelia_pids() {
  # 只返回活的（非僵尸）authelia 进程 PID；僵尸（Z 状态）无法被杀，忽略
  ps -eo pid,stat,comm 2>/dev/null | awk '$3 == "authelia" && $2 !~ /Z/ {print $1}'
}

_wait_dead() {
  local i=0
  while read -r pid; do
    [ -z "$pid" ] && break
    while [ $i -lt $TIMEOUT ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
      i=$((i+1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "警告: PID $pid ${TIMEOUT}s 内未退出，强制 kill -9"
      kill -9 "$pid" 2>/dev/null
    fi
  done < <(_live_authelia_pids)
}

start() {
  if _live_authelia_pids | read -r _; then
    echo "检测到残留 authelia 进程，先清理..."
    _kill_authelia
    _wait_dead
  fi
  rm -f "$PIDFILE"
  python3 "$DSH_ROOT/scripts/reap.py" "$DSH_ROOT/dsh-auth/authelia" --config "$DSH_ROOT/dsh-auth/config/configuration.yml" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "authelia started (pid $(cat "$PIDFILE"))"
}
stop() {
  _kill_authelia
  _wait_dead
  rm -f "$PIDFILE"
  echo "authelia stopped"
}
case "$1" in start) start;; stop) stop;; restart) stop; start;; *) echo "usage: $0 start|stop|restart";; esac
