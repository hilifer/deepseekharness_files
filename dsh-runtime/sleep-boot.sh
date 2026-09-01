#!/bin/bash
LOG=/var/log/ssh-boot.log
TS() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  [ -w "$(dirname "$LOG")" ] && echo "[$(TS)] $*" >> "$LOG"
}

if [ "$$" -eq 1 ]; then
  log "sleep-boot: running as PID 1, args: $*"
  (
    log "sleep-boot: monitor started"
    while true; do
      # sshd
      live=0
      for p in $(pgrep -x sshd 2>/dev/null); do
        st=$(awk '/^State:/{print $2}' /proc/$p/status 2>/dev/null)
        [ "$st" != "Z" ] && live=1 && break
      done
      if [ "$live" -eq 0 ]; then
        log "sleep-boot: sshd not running, starting /usr/sbin/sshd -D"
        /usr/sbin/sshd -D &
        log "sleep-boot: sshd started pid $!"
      fi
      # dsh stack (independent from sshd; liveness = init-reaper.py subreaper)
      dsh_live=0
      for p in $(pgrep -f "init-reaper.py" 2>/dev/null); do
        st=$(awk '/^State:/{print $2}' /proc/$p/status 2>/dev/null)
        [ "$st" != "Z" ] && dsh_live=1 && break
      done
      if [ "$dsh_live" -eq 0 ]; then
        log "sleep-boot: dsh stack not running, starting start-all.sh"
        su -s /bin/bash ubuntu -c "nohup env DSH_ROOT=/home/ubuntu /home/ubuntu/dsh-runtime/start-all.sh >/tmp/start-all.log 2>&1 &"
        log "sleep-boot: dsh stack starter launched"
      fi
      sleep 5
    done
  ) </dev/null >/dev/null 2>&1 &
fi
log "sleep-boot: exec /lib/cargo/bin/coreutils/sleep $*"
exec /lib/cargo/bin/coreutils/sleep "$@"
