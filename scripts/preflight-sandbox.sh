#!/bin/bash
# =====================================================================
# 隔离验收 —— 在真实服务器上实测「工作区以外的东西到底碰不碰得到」。
#
# 做法：在沙箱里跑一个探针，逐项尝试访问本不该访问的目标，
#       能访问到就是 FAIL。不看配置写了什么，只看实际能不能读到。
#
# 用法: preflight-sandbox.sh [username]
#       不传用户名时用登记表里的第一个员工；没有员工则建临时工作区自测。
# =====================================================================
set -uo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
SANDBOX="$DSH_ROOT/dsh-runtime/dsh-sandbox.sh"
PASS=0; FAIL=0
ok()   { printf '  ✅ %-46s %s\n' "$1" "${2:-}"; PASS=$((PASS+1)); }
bad()  { printf '  ❌ %-46s %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
info() { printf '  ·  %-46s %s\n' "$1" "${2:-}"; }

echo "=== 0. 隔离后端 ==="
if OUT=$("$SANDBOX" --check 2>&1 | tail -1); then
  BACKEND=$("$SANDBOX" --backend 2>/dev/null || echo unknown)
  ok "隔离后端可用" "$OUT"
  [ "$BACKEND" = "none" ] && bad "当前是【无隔离】模式" "DSH_ALLOW_UNCONFINED=1，下面的断言基本都会红"
else
  bad "挑不出隔离后端" "$OUT"
  echo; echo "逐项原因与处理建议: $SANDBOX --report"; exit 1
fi

# ---- 选一个受测用户 ----
USERNAME="${1:-}"
if [ -z "$USERNAME" ]; then
  USERNAME=$(python3 - "$DSH_ROOT" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
reg = Path(sys.argv[1]) / "dsh-users" / "registry.json"
if reg.exists():
    users = json.loads(reg.read_text(encoding="utf-8")).get("users", {})
    if users: print(sorted(users)[0])
PY
)
fi
if [ -n "$USERNAME" ]; then
  read -r WS HOME_DIR < <(python3 - "$DSH_ROOT" "$USERNAME" <<'PY'
import json, sys
from pathlib import Path
root, user = Path(sys.argv[1]), sys.argv[2]
rec = json.loads((root / "dsh-users" / "registry.json").read_text(encoding="utf-8"))["users"][user]
print(rec["workspace"], root / "dsh-users" / user)
PY
)
else
  USERNAME="_preflight"; WS="$DSH_ROOT/dsh-files/.preflight-ws"; HOME_DIR="$DSH_ROOT/dsh-users/_preflight"
  mkdir -p "$WS" "$HOME_DIR"
  echo "（登记表为空，使用临时工作区 $WS 自测）"
fi
echo "受测身份: $USERNAME    工作区: $WS"
echo

# ---- 找一个「别人的」目录做靶子 ----
VICTIM=$(find "$DSH_ROOT/dsh-files/departments" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
         | grep -vF "$WS" | head -1)
CANARY=""
if [ -n "$VICTIM" ]; then
  CANARY="$VICTIM/.preflight-canary"; echo "CANARY-OTHER-EMPLOYEE-FILE" > "$CANARY" 2>/dev/null || CANARY=""
fi

cat > "$HOME_DIR/.preflight-probe.sh" <<'PROBE'
# 在沙箱里执行：能读到 = 隔离失效
r() { cat "$1" >/dev/null 2>&1 && echo "LEAK" || echo "SEALED"; }
echo "CANARY=$(r "$P_CANARY")"
echo "CREDS=$(r "$P_ROOT/dsh-auth/initial-credentials.txt")"
echo "USERDB=$(r "$P_ROOT/dsh-auth/config/users_database.yml")"
echo "TLSKEY=$(r "$P_ROOT/nginx/certs/dsh.key")"
echo "FBDB=$(r "$P_ROOT/filebrowser/database.db")"
echo "ADMTOK=$(r "$P_ROOT/admin/.admin-token")"
echo "SCRIPTS=$(r "$P_ROOT/admin/core.py")"
echo "OTHERHOME=$(ls "$P_ROOT/dsh-users" 2>/dev/null | grep -v "^$P_USER\$" | wc -l)"
echo "DEPTS=$(ls "$P_ROOT/dsh-files/departments" 2>/dev/null | wc -l)"
echo "OWNRW=$(touch "$P_WS/.preflight-rw" 2>/dev/null && rm -f "$P_WS/.preflight-rw" && echo OK || echo NO)"
echo "PROCS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
# docker socket 是最致命的一条：够得到就能 `docker run -v /:/host` 拿到整台宿主，
# 前面所有的文件隔离一并作废。三个常见位置都要试。
echo "DOCKSOCK=$( { [ -S /var/run/docker.sock ] || [ -S /run/docker.sock ] \
                    || [ -n "${DOCKER_HOST:-}" ]; } && echo REACHABLE || echo SEALED)"
code() { curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
echo "FBAPI=$(code -H 'X-Forwarded-User: admin' http://127.0.0.1:18080/files/api/users)"
echo "ADMAPI=$(code -H 'Remote-User: admin' http://127.0.0.1:19200/admin/api/users)"
# 同僚端口由外层通过 P_PEER_PORT 传入：沙箱内读不到 registry.json 是【预期行为】，
# 不能因此把这项测试跳过。顺带把「能否读到登记表」本身也作为一项断言。
echo "REGISTRY=$(r "$P_ROOT/dsh-users/registry.json")"
# 同 uid 档（landlock）的三条旁路。它们都【不经过路径规则】，所以必须实测：
#   PEERFD  经 /proc/<同僚 pid>/fd/ 重开对方【已打开】的文件。这是 magic symlink
#           重开，绕过路径解析——Landlock 到底拦不拦，只有真跑一次才知道。
#   SHMPEER /dev/shm 若整个放行，同 uid 之间就是一块共享读写区
#   RUNPEER /run/user/UID 同理，且那儿常放 socket 与临时凭据
if [ -n "${P_PEER_PID:-}" ] && [ -d "/proc/$P_PEER_PID/fd" ]; then
  hit=LEAKNONE
  for fd in /proc/"$P_PEER_PID"/fd/*; do
    tgt=$(readlink "$fd" 2>/dev/null) || continue
    case "$tgt" in
      *preflight-canary*) cat "$fd" >/dev/null 2>&1 && hit=LEAK || hit=SEALED ;;
    esac
  done
  echo "PEERFD=$hit"
else
  echo "PEERFD=none"
fi
echo "SHMPEER=$([ -n "${P_SHM_CANARY:-}" ] && r "$P_SHM_CANARY" || echo none)"
echo "RUNPEER=$([ -n "${P_RUN_CANARY:-}" ] && r "$P_RUN_CANARY" || echo none)"
if [ -n "${P_PEER_PORT:-}" ]; then
  echo "PEERDSH=$(code "http://127.0.0.1:$P_PEER_PORT/")"
else
  echo "PEERDSH=none"
fi
PROBE

PEER_PORT=$(python3 - "$DSH_ROOT" "$USERNAME" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
reg = Path(sys.argv[1]) / "dsh-users" / "registry.json"
if reg.exists():
    users = json.loads(reg.read_text(encoding="utf-8")).get("users", {})
    print(next((r["port"] for u, r in sorted(users.items()) if u != sys.argv[2]), ""))
PY
)

# 「同僚端口连不上」这一项，必须确认是【被挡住】而不是【那边根本没人听】。
# 早先只要没起第二个实例，这项就恒绿——一条没验过的路披着通过的皮，
# 比红着更危险。所以这里在没人监听时自己起一个桩监听器，再去连。
PEER_STUB_PID=""
if [ -n "$PEER_PORT" ]; then
  if ! curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PEER_PORT/" 2>/dev/null; then
    python3 - "$PEER_PORT" >/dev/null 2>&1 <<'PY_STUB' &
import socket, sys, time
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(8)
except OSError:
    sys.exit(0)
end = time.time() + 60
srv.settimeout(1)
while time.time() < end:
    try:
        c, _ = srv.accept()
    except OSError:
        continue
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
    c.close()
PY_STUB
    PEER_STUB_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PEER_PORT/" 2>/dev/null && break
      sleep 0.3
    done
  fi
fi

# stderr 留档而不是丢掉：探针一个字都没输出时，真正的原因全在 stderr 里。
# 早先这里直接 2>/dev/null，实例根本没起来也只会表现成「16 项全红」，
# 让人以为隔离失效，其实是启动失败——两种情况的处置完全不同。
# 同 uid 旁路的靶子：一个【持有 canary 打开状态】的同僚进程，外加 shm / run 里的标记
PEER_HOLDER_PID=""
SHM_CANARY=""; RUN_CANARY=""
if [ -n "$CANARY" ]; then
  # 拿着 canary 的 fd 睡一会儿，模拟「另一个员工的实例正开着自己工作区的文件」
  python3 -c "import sys,time; f=open(sys.argv[1]); time.sleep(120)" "$CANARY" &
  PEER_HOLDER_PID=$!
fi
if [ -d /dev/shm ]; then
  SHM_CANARY="/dev/shm/.preflight-canary-shm"
  # 【必须 0600】这个 canary 代表的是「同僚员工自己的私有文件」。
  # 默认 umask 下它是 0644，那模拟的是「全世界可读的文件」，不是同僚的私有文件：
  # uid 档里员工各有各的 uid，本来就读不到同僚的 0600 文件，用 0644 会把
  # 那一档误判成泄露。同 uid 的档（landlock/bwrap）则不受 0600 影响——
  # 同一个 uid 读得到，正好是这条探针要问的问题。
  if echo "CANARY-PEER-SHM" > "$SHM_CANARY" 2>/dev/null; then
    chmod 600 "$SHM_CANARY" 2>/dev/null || true
  else
    SHM_CANARY=""
  fi
fi
if [ -d "/run/user/$(id -u)" ]; then
  RUN_CANARY="/run/user/$(id -u)/.preflight-canary-run"
  if echo "CANARY-PEER-RUN" > "$RUN_CANARY" 2>/dev/null; then
    chmod 600 "$RUN_CANARY" 2>/dev/null || true   # 同上：代表同僚的私有文件
  else
    RUN_CANARY=""
  fi
fi

PROBE_ERR="$HOME_DIR/.preflight-probe.err"
RES=$(DSH_ROOT="$DSH_ROOT" DSH_NODE_BIN=/bin/bash DSH_BIN="$HOME_DIR/.preflight-probe.sh" \
      DSH_SANDBOX_PASSENV="P_ROOT P_WS P_USER P_CANARY P_PEER_PORT P_PEER_PID P_SHM_CANARY P_RUN_CANARY" \
      P_PEER_PID="$PEER_HOLDER_PID" P_SHM_CANARY="$SHM_CANARY" \
      P_RUN_CANARY="$RUN_CANARY" \
      P_ROOT="$DSH_ROOT" P_WS="$WS" P_USER="$USERNAME" P_CANARY="${CANARY:-/nonexistent}" \
      P_PEER_PORT="$PEER_PORT" \
      "$SANDBOX" "$USERNAME" 13999 "$HOME_DIR" "$WS" 2>"$PROBE_ERR")
rm -f "$HOME_DIR/.preflight-probe.sh" "$CANARY"
[ -n "$PEER_STUB_PID" ] && kill "$PEER_STUB_PID" 2>/dev/null
[ -n "$PEER_HOLDER_PID" ] && kill "$PEER_HOLDER_PID" 2>/dev/null
[ -n "$SHM_CANARY" ] && rm -f "$SHM_CANARY"
[ -n "$RUN_CANARY" ] && rm -f "$RUN_CANARY"

if ! printf '%s' "$RES" | grep -q '='; then
  echo
  bad "探针没有任何输出" "实例没起来，不是隔离失效——下面是启动时的报错"
  echo "---- 启动输出 ----"
  tail -40 "$PROBE_ERR" 2>/dev/null || echo "(无)"
  echo "------------------"
  rm -f "$PROBE_ERR"
  echo "先把实例起得来，再谈隔离验收。"
  exit 1
fi
rm -f "$PROBE_ERR"

g() { printf '%s\n' "$RES" | sed -n "s/^$1=//p" | head -1; }

echo "=== 1. 文件系统隔离（沙箱内能否读到工作区以外的东西） ==="
[ -n "$CANARY" ] && { [ "$(g CANARY)" = "SEALED" ] && ok "其他员工的文件" || bad "其他员工的文件" "可读！"; } \
                 || info "其他员工的文件" "（没有第二个员工目录，跳过）"
for pair in "CREDS:全员明文初始密码 initial-credentials.txt" \
            "USERDB:Authelia 用户库 users_database.yml" \
            "TLSKEY:TLS 私钥 dsh.key" \
            "FBDB:FileBrowser 权限库 database.db" \
            "ADMTOK:管理后台 token" \
            "SCRIPTS:管理后台源码 core.py"; do
  k="${pair%%:*}"; label="${pair#*:}"
  [ "$(g "$k")" = "SEALED" ] && ok "$label" || bad "$label" "可读！"
done
[ "$(g REGISTRY)" = "SEALED" ] && ok "员工登记表 registry.json" || bad "员工登记表 registry.json" "可读！"
[ "$(g OTHERHOME)" = "0" ] && ok "其他用户的 DSH_HOME" "0 个可见" || bad "其他用户的 DSH_HOME" "$(g OTHERHOME) 个可见"
# 命名空间档下能看到 1 个（自己的部门，因为它是挂载点）；
# uid 档下 departments 只给了 x 位不给 r 位，ls 直接失败，看到 0 个——更严。
# 两种都算通过，超过 1 个才是漏。
D=$(g DEPTS)
[ "${D:-99}" -le 1 ] && ok "可见部门数" "$D 个（仅自己的，或连列都列不出）" \
                     || bad "可见部门数" "$D 个可见"

echo
echo "=== 2. 自身工作区应当可读写 ==="
[ "$(g OWNRW)" = "OK" ] && ok "自己的工作区可写" || bad "自己的工作区不可写" "实例会无法工作"

echo
echo "=== 3. 逃逸面 ==="
[ "$(g DOCKSOCK)" = "SEALED" ] && ok "docker socket 不可达" "实例内无法起兄弟容器" \
                               || bad "docker socket 可达" "一句 docker run -v /:/host 即可拿到整台宿主！"

echo
echo "=== 4. 进程隔离 ==="
P=$(g PROCS)
if [ "$BACKEND" = "uid" ] || [ "$BACKEND" = "landlock" ]; then
  # 这两档都没有 pid namespace（uid 只有 DAC，landlock 只管文件/网络/信号）。
  # 如实标注成 info，不伪装成通过。
  info "PID 命名空间" "$P 个进程可见 —— $BACKEND 后端【不提供】进程隔离（见 backends/$BACKEND.sh 文件头）"
else
  [ "${P:-999}" -lt 20 ] && ok "PID 命名空间隔离" "仅 $P 个进程可见（ps 看不到宿主进程）" \
                         || bad "PID 命名空间未隔离" "$P 个进程可见"
fi


echo "--- 同 uid 旁路（landlock 档所有实例同一个 OS 用户，这几条不经过路径规则）---"
PFD=$(g PEERFD)
case "$PFD" in
  SEALED)   ok "经 /proc/<同僚>/fd/ 重开其文件" "被拒 —— Landlock 拦住了 magic symlink 重开" ;;
  LEAK)     bad "经 /proc/<同僚>/fd/ 重开其文件" "读到了！这是绕过全部路径规则的跨租户直读。
       处理：换 container / bwrap 档（有 pid ns，看不到同僚的 /proc），或升级内核" ;;
  LEAKNONE) info "经 /proc/<同僚>/fd/" "同僚进程没有匹配的打开文件，本轮没测到" ;;
  none)     info "经 /proc/<同僚>/fd/" "（没有同僚进程可测，跳过）" ;;
  *)        info "经 /proc/<同僚>/fd/" "$PFD" ;;
esac
SH=$(g SHMPEER)
case "$SH" in
  SEALED) ok  "/dev/shm 中同僚留下的文件" "读不到（已改为每人私有子目录）" ;;
  LEAK)   bad "/dev/shm 中同僚留下的文件" "可读 —— 同 uid 共享读写区" ;;
  none)   info "/dev/shm" "埋不下标记（没有 /dev/shm 或不可写），本轮没测到" ;;
  *)      info "/dev/shm" "$SH" ;;
esac
RU=$(g RUNPEER)
case "$RU" in
  SEALED) ok  "/run/user/UID 中同僚留下的文件" "读不到（XDG_RUNTIME_DIR 已私有化）" ;;
  LEAK)   bad "/run/user/UID 中同僚留下的文件" "可读 —— 那里常放 socket 与临时凭据" ;;
  none)   info "/run/user/UID" "本机没有该目录（无 systemd-logind 会话），本轮没测到" ;;
  *)      info "/run/user/UID" "$RU" ;;
esac

echo
echo "=== 5. 网络面 ==="
if [ "$BACKEND" = "container" ]; then
  info "网络隔离" "容器后端天然每实例独立 netns，端口只发布到宿主回环"
  LEFTOVER=$(ss -ltn 2>/dev/null | grep -cE '0\.0\.0\.0:(3080|131[0-9][0-9])' || true)
  [ "${LEFTOVER:-0}" = "0" ] && ok "dsh 端口未暴露到 0.0.0.0" \
                             || bad "有 $LEFTOVER 个 dsh 端口监听在 0.0.0.0" "局域网可直连实例"
elif [ "$BACKEND" = "landlock" ]; then
  info "网络隔离" "Landlock TCP 端口限制：只允许监听本人端口 + 外连白名单端口"
  info "" "别人的实例端口不在白名单里，「驱动同事的 agent」这条路已封（需 ABI v4+）"
elif [ "$BACKEND" = "uid" ]; then
  info "网络隔离" "netfilter owner 匹配：按员工 uid 封掉同僚实例端口与内部服务端口"
  if command -v iptables >/dev/null 2>&1; then
    N=$(iptables -S OUTPUT 2>/dev/null | grep -c -- '-j DSH-ISO-' || true)
    [ "${N:-0}" -gt 0 ] && ok "OUTPUT 里有 $N 条 uid 封锁规则" \
                        || bad "OUTPUT 里一条 uid 封锁规则都没有" "同僚端口没封住"
  else
    bad "本机没有 iptables" "uid 档封不住同僚端口，本不该被选中"
  fi
elif [ "${DSH_NETNS:-0}" = "1" ]; then
  info "网络隔离模式" "已启用（每实例独立 netns，入站走 unix socket）"
  if command -v pasta >/dev/null 2>&1 && command -v socat >/dev/null 2>&1; then
    ok "pasta 与 socat 就位"
  else
    bad "pasta 或 socat 缺失" "sudo apt-get install -y passt socat"
  fi
  LEFTOVER=$(ss -ltn 2>/dev/null | grep -cE ':(3080|131[0-9][0-9])' || true)
  [ "${LEFTOVER:-0}" = "0" ] && ok "宿主回环上无 dsh 端口" "实例间无法互连" \
                             || bad "宿主回环上仍有 $LEFTOVER 个 dsh 端口" "实例间可互连"
else
  info "网络隔离模式" "未启用 —— 沙箱与宿主共享网络命名空间"
  info "" "开启方法见 OPS.md；下面几项是当前形态下的实测结果"
fi
FB=$(g FBAPI)
case "$FB" in
  401|403) ok "FileBrowser API 伪造 admin" "被拒 (HTTP $FB) —— 密钥头已生效" ;;
  200)     bad "FileBrowser API 伪造 admin" "HTTP 200，可读写全公司文件！请跑 scripts/init-secrets.sh 并重启 FileBrowser" ;;
  000)     info "FileBrowser API" "连不上（服务没起，或已被 uid 档的 netfilter 规则挡住）" ;;
  *)       info "FileBrowser API" "HTTP $FB" ;;
esac
AD=$(g ADMAPI)
case "$AD" in
  403) ok "管理后台 API 伪造 admin" "被拒 (HTTP 403) —— token 已生效" ;;
  200) bad "管理后台 API 伪造 admin" "HTTP 200，可任意增删员工！检查 nginx generated/admin-token.conf" ;;
  000) info "管理后台 API" "连不上（服务没起，或已被 uid 档的 netfilter 规则挡住）" ;;
  *)   info "管理后台 API" "HTTP $AD" ;;
esac
PD=$(g PEERDSH)
PEER_SRC=$([ -n "$PEER_STUB_PID" ] && echo "桩监听器" || echo "真实例")
case "$PD" in
  none) info "其他员工的 dsh 实例" "（登记表里没有第二个员工，无端口可测）" ;;
  000)  ok "其他员工的 dsh 实例" "端口 $PEER_PORT 上有人监听（$PEER_SRC），仍连不上 —— 确实被挡住了" ;;
  *)    bad "其他员工的 dsh 实例" "HTTP $PD 可达 —— 可驱动他人的 agent 读写其工作区。
       这条路不经过文件系统，DAC 拦不住：修复要么换 container 后端（天然独立 netns），
       要么 bwrap 后端开 DSH_NETNS=1，要么走 landlock / uid 档（端口白名单 / netfilter）" ;;
esac

echo
echo "================================================"
printf '  通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ 隔离验收通过" || echo "  ❌ 存在未封堵的路径，见上方 ❌ 条目"
echo "================================================"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
