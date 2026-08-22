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

RES=$(DSH_ROOT="$DSH_ROOT" DSH_NODE_BIN=/bin/bash DSH_BIN="$HOME_DIR/.preflight-probe.sh" \
      DSH_SANDBOX_PASSENV="P_ROOT P_WS P_USER P_CANARY P_PEER_PORT" \
      P_ROOT="$DSH_ROOT" P_WS="$WS" P_USER="$USERNAME" P_CANARY="${CANARY:-/nonexistent}" \
      P_PEER_PORT="$PEER_PORT" \
      "$SANDBOX" "$USERNAME" 13999 "$HOME_DIR" "$WS" 2>/dev/null)
rm -f "$HOME_DIR/.preflight-probe.sh" "$CANARY"

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
if [ "$BACKEND" = "uid" ]; then
  # uid 档只有文件维度的强制点，本来就没有 pid ns。如实标注，不伪装成通过。
  info "PID 命名空间" "$P 个进程可见 —— uid 后端【不提供】进程隔离（见 backends/uid.sh 文件头）"
else
  [ "${P:-999}" -lt 20 ] && ok "PID 命名空间隔离" "仅 $P 个进程可见（ps 看不到宿主进程）" \
                         || bad "PID 命名空间未隔离" "$P 个进程可见"
fi

echo
echo "=== 5. 网络面 ==="
if [ "$BACKEND" = "container" ]; then
  info "网络隔离" "容器后端天然每实例独立 netns，端口只发布到宿主回环"
  LEFTOVER=$(ss -ltn 2>/dev/null | grep -cE '0\.0\.0\.0:(3080|131[0-9][0-9])' || true)
  [ "${LEFTOVER:-0}" = "0" ] && ok "dsh 端口未暴露到 0.0.0.0" \
                             || bad "有 $LEFTOVER 个 dsh 端口监听在 0.0.0.0" "局域网可直连实例"
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
  000)     info "FileBrowser API" "未连通（服务没起？）" ;;
  *)       info "FileBrowser API" "HTTP $FB" ;;
esac
AD=$(g ADMAPI)
case "$AD" in
  403) ok "管理后台 API 伪造 admin" "被拒 (HTTP 403) —— token 已生效" ;;
  200) bad "管理后台 API 伪造 admin" "HTTP 200，可任意增删员工！检查 nginx generated/admin-token.conf" ;;
  000) info "管理后台 API" "未连通（服务没起？）" ;;
  *)   info "管理后台 API" "HTTP $AD" ;;
esac
PD=$(g PEERDSH)
case "$PD" in
  none) info "其他员工的 dsh 实例" "（没有第二个实例，跳过）" ;;
  000)  ok "其他员工的 dsh 实例" "不可达" ;;
  *)    bad "其他员工的 dsh 实例" "HTTP $PD 可达 —— 可驱动他人的 agent 读写其工作区。
       修复：换 container 后端（天然独立 netns），或在 bwrap 后端上开 DSH_NETNS=1" ;;
esac

echo
echo "================================================"
printf '  通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ 隔离验收通过" || echo "  ❌ 存在未封堵的路径，见上方 ❌ 条目"
echo "================================================"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
