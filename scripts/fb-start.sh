#!/bin/bash
# FileBrowser Quantum start/stop/restart (rootless, exec-based, idempotent)
DSH_ROOT="${DSH_ROOT:-$HOME}"
BIN="$DSH_ROOT/filebrowser/filebrowser"
CONF="$DSH_ROOT/filebrowser/config.yaml"
PIDFILE="$DSH_ROOT/filebrowser/fb.pid"
LOG="$DSH_ROOT/filebrowser/logs/fb.log"

is_up() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# 代理认证头是「证明请求来自 nginx」的共享密钥。init-secrets.sh 会就地改写
# config.yaml 写入真值，于是部署机上这个被跟踪的文件永远是脏的、git pull 会打架
# ——真值一度因此被提交进仓库，那等于把密钥公开。
#
# 现在把安全的路做成省事的路：每次启动先自动补齐真值（init-secrets.sh 幂等，
# 已有就不重新生成），补不上就【拒绝启动】。占位值人人皆知，带着它跑等于
# 任何员工都能 curl 伪造 admin 直调本 API 读写全公司文件。
current_header() {
  sed -n 's/^ *header: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$CONF" 2>/dev/null | head -1
}
is_placeholder() {
  case "$1" in
    ""|X-Fb-Auth-REPLACE_ME|X-Forwarded-User) return 0 ;;
    *) return 1 ;;
  esac
}
ensure_proxy_header() {
  local h; h=$(current_header)
  if is_placeholder "$h"; then
    echo "[fb] 代理认证头是占位值($h)，跑 init-secrets.sh 补真值…"
    DSH_ROOT="$DSH_ROOT" bash "$DSH_ROOT/scripts/init-secrets.sh" >/dev/null 2>&1 || true
    h=$(current_header)
  fi
  if is_placeholder "$h"; then
    echo "[fb] 拒绝启动：代理认证头仍是占位值($h)。"
    echo "     这个头名就是证明请求来自 nginx 的共享密钥，占位值写在仓库里人人可见，"
    echo "     带着它跑 = 任何员工都能在自己的 dsh 里 curl 伪造 admin 身份直调"
    echo "     127.0.0.1:18080 读写全公司文件，文件系统隔离全部白做。"
    echo "     处理: bash \"$DSH_ROOT/scripts/init-secrets.sh\" 然后重试"
    return 1
  fi
  return 0
}

start() {
  if is_up; then
    echo "filebrowser already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  ensure_proxy_header || return 1
  rm -f "$PIDFILE"
  python3 "$DSH_ROOT/scripts/reap.py" "$BIN" -c "$CONF" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
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