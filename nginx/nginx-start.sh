#!/bin/bash
NGINX="$HOME/nginx/extracted/usr/sbin/nginx"
CONF="$HOME/nginx/conf/nginx.conf"
start() {
  if [ -f "$HOME/nginx/nginx.pid" ] && kill -0 "$(cat "$HOME/nginx/nginx.pid")" 2>/dev/null; then
    echo "nginx already running (pid $(cat "$HOME/nginx/nginx.pid"))"; return 0
  fi
  "$NGINX" -c "$CONF" && echo "nginx started (pid $(cat "$HOME/nginx/nginx.pid"))"
}
stop() {
  if [ -f "$HOME/nginx/nginx.pid" ]; then
    "$NGINX" -c "$CONF" -s stop && echo "nginx stopped"
  fi
}
reload() {
  if [ -f "$HOME/nginx/nginx.pid" ]; then
    "$NGINX" -c "$CONF" -s reload && echo "nginx reloaded"
  fi
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;; reload) reload;; *) echo "usage: $0 start|stop|restart|reload";; esac
