#!/bin/bash
NGINX="$HOME/nginx/extracted/usr/sbin/nginx"
CONF="$HOME/nginx/conf/nginx.conf"
# 站点配置 include 了 conf/generated/ 下的密钥文件，缺失会导致 nginx -t 失败
ensure_secrets() {
  if [ ! -f "$HOME/nginx/conf/generated/admin-token.conf" ] \
  || [ ! -f "$HOME/nginx/conf/generated/fb-auth.conf" ]; then
    echo "generated/ 缺失，先运行 init-secrets.sh"
    "$HOME/scripts/init-secrets.sh" || return 1
  fi
}
start() {
  ensure_secrets || { echo "nginx 未启动：密钥生成失败"; return 1; }
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
