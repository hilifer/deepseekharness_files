#!/bin/bash
# =====================================================================
# 全栈幂等启动入口（容器 entrypoint 调用）
#   密钥 -> authelia -> nginx -> filebrowser -> 管理后台 -> 各 dsh 实例
#
# 所有 dsh 实例（含 admin）一律经 dsh-sandbox.sh 启动。它会按【这台机器实际
# 拿得到什么】挑隔离档位：独立容器 > bubblewrap 挂载命名空间 > 独立 OS 用户，
# 一档都挑不出来时【不启动任何实例】，而不是退回无隔离运行——
# 宁可服务不可用，也不让全公司文件敞开。
# 排障可用 DSH_ALLOW_UNCONFINED=1 显式放行（会大声告警）。
# 当前机器选了哪一档、为什么: dsh-runtime/dsh-sandbox.sh --report
#
# 用户清单来自 dsh-users/registry.json（管理后台维护）。
# 旧的 ports.json 会在首次读取时自动迁移，之后由 core.py 保持同步。
# =====================================================================
export PATH="$HOME/node/bin:$PATH"
DSH_ROOT="${DSH_ROOT:-$HOME}"
export DSH_ROOT
REGISTRY="$DSH_ROOT/dsh-users/registry.json"
SANDBOX="$DSH_ROOT/dsh-runtime/dsh-sandbox.sh"

is_up() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# 0) 生成/校准 nginx 注入的共享密钥（nginx 的 include 依赖这些文件先存在）
"$DSH_ROOT/scripts/init-secrets.sh" || echo "warning: init-secrets.sh 失败，nginx 可能起不来"

# 1) 核心服务
"$DSH_ROOT/dsh-auth/authelia-start.sh" start
"$DSH_ROOT/nginx/nginx-start.sh" start
"$DSH_ROOT/scripts/fb-start.sh" start
"$DSH_ROOT/admin/admin-start.sh" start

# 2) 隔离自检——决定要不要启动 dsh 实例
if "$SANDBOX" --check >/dev/null 2>&1; then
  SANDBOX_OK=1
  echo "隔离后端: $("$SANDBOX" --backend 2>/dev/null || echo unknown)"
else
  SANDBOX_OK=0
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! 挑不出隔离后端，所有 dsh 实例【不予启动】。                    !!"
  echo "!! 逐项原因: $DSH_ROOT/dsh-runtime/dsh-sandbox.sh --report         !!"
  echo "!! 验证:     $DSH_ROOT/scripts/preflight-sandbox.sh                !!"
  echo "!! 排障放行(危险): DSH_ALLOW_UNCONFINED=1 $0                       !!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  "$SANDBOX" --report 2>&1 | sed 's/^/   /'
  [ "${DSH_ALLOW_UNCONFINED:-0}" = "1" ] && SANDBOX_OK=1
fi

start_instance() { # $1=user $2=port $3=dsh_home $4=workspace
  local user=$1 port=$2 home=$3 ws=$4
  if pgrep -f "dsh web --port $port " >/dev/null 2>&1; then
    echo "dsh:$user 已在运行 (port $port)"; return 0
  fi
  if [ ! -d "$ws" ]; then
    echo "dsh:$user 跳过：工作区不存在 ($ws)"; return 1
  fi
  mkdir -p "$home"
  setsid nohup "$SANDBOX" "$user" "$port" "$home" "$ws" >> "$home/dsh.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    curl -sf -o /dev/null "http://127.0.0.1:$port/" && { echo "dsh:$user 已启动 (127.0.0.1:$port, ws=$ws)"; return 0; }
  done
  echo "dsh:$user 健康检查未通过，见 $home/dsh.log"; return 1
}

if [ "$SANDBOX_OK" = "1" ]; then
  # 2a) admin 主实例：工作区为整个文件根
  start_instance admin 3080 "$DSH_ROOT/.local/share/dsh" "$DSH_ROOT/dsh-files"

  # 2b) 每员工实例
  if [ -f "$REGISTRY" ] || [ -f "$DSH_ROOT/dsh-users/ports.json" ]; then
    while IFS=$'\t' read -r user port home ws; do
      [ -n "$user" ] && start_instance "$user" "$port" "$home" "$ws"
    done < <(python3 - "$DSH_ROOT" <<'PYEOF'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "admin"))
from core import Config, Engine          # noqa: E402
engine = Engine(Config(root=Path(sys.argv[1])))
reg = engine.load_registry()
engine.save_registry(reg)                # 首次运行会把 ports.json 落成 registry.json
for user, rec in sorted(reg["users"].items()):
    ws = rec.get("workspace") or ""
    if not ws:
        print(f"# {user}: 登记表缺工作区路径（可能是从 ports.json 迁移来的），"
              f"请在管理后台补全后再启动", file=sys.stderr)
        continue
    print(f"{user}\t{rec['port']}\t{Path(sys.argv[1]) / 'dsh-users' / user}\t{ws}")
PYEOF
    )
  else
    echo "warning: 无 registry.json / ports.json，未启动任何员工实例"
  fi
fi

# 3) 状态汇总
echo "--- status ---"
for entry in "authelia:$DSH_ROOT/dsh-auth/authelia.pid" \
             "nginx:$DSH_ROOT/nginx/nginx.pid" \
             "filebrowser:$DSH_ROOT/filebrowser/fb.pid" \
             "admin:$DSH_ROOT/admin/admin.pid"; do
  name="${entry%%:*}"; pidfile="${entry#*:}"
  if is_up "$pidfile"; then echo "$name: UP (pid $(cat "$pidfile"))"; else echo "$name: DOWN"; fi
done
echo "隔离: $($SANDBOX --check 2>&1 | tail -1)"
python3 "$DSH_ROOT/admin/cli.py" list 2>/dev/null || echo "（登记表为空或管理后台未就绪）"
