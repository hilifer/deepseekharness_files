#!/bin/bash
DSH_ROOT="${DSH_ROOT:-$HOME}"
NGINX="$DSH_ROOT/nginx/extracted/usr/sbin/nginx"
CONF="$DSH_ROOT/nginx/conf/nginx.conf"
# 站点配置 include 了 conf/generated/ 下的密钥文件，缺失会导致 nginx -t 失败
ensure_secrets() {
  if [ ! -f "$DSH_ROOT/nginx/conf/generated/admin-token.conf" ] \
  || [ ! -f "$DSH_ROOT/nginx/conf/generated/fb-auth.conf" ]; then
    echo "generated/ 缺失，先运行 init-secrets.sh"
    "$DSH_ROOT/scripts/init-secrets.sh" || return 1
  fi
}
is_up() {
  local pid; pid=$(cat "$DSH_ROOT/nginx/nginx.pid" 2>/dev/null)
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && [ "$(awk '/^State:/{print $2}' /proc/$pid/status 2>/dev/null)" != "Z" ]
}
start() {
  ensure_secrets || { echo "nginx 未启动：密钥生成失败"; return 1; }
  if is_up; then
    echo "nginx already running (pid $(cat "$DSH_ROOT/nginx/nginx.pid"))"; return 0
  fi
  "$NGINX" -c "$CONF" && echo "nginx started (pid $(cat "$DSH_ROOT/nginx/nginx.pid"))"
}
stop() {
  if [ -f "$DSH_ROOT/nginx/nginx.pid" ]; then
    "$NGINX" -c "$CONF" -s stop && echo "nginx stopped"
  fi
}
reload() {
  if [ -f "$DSH_ROOT/nginx/nginx.pid" ]; then
    "$NGINX" -c "$CONF" -s reload && echo "nginx reloaded"
  fi
}
case "$1" in start) start;; stop) stop;; restart) stop; sleep 1; start;; reload) reload;; *) echo "usage: $0 start|stop|restart|reload";; esac
