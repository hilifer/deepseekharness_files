#!/bin/bash
# =====================================================================
# 搭一棵仿真部署树，供 CI 在各种环境形状下跑隔离验收。
#
# 用法: make-fake-deploy.sh <目标根> [仓库路径]
#
# 树的形状与线上一致，并且把线上真正怕泄露的那几样东西都铺上假数据：
# 全员明文初始密码、Authelia 用户库、TLS 私钥、FileBrowser 权限库、
# 管理后台 token、其他部门与同部门同事的文件。隔离验收就是去读它们，
# 读到了就是红。
# =====================================================================
set -euo pipefail

R="${1:?用法: make-fake-deploy.sh <目标根> [仓库路径]}"
REPO="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$R"/{dsh-auth/config,nginx/certs,filebrowser,admin,dsh-runtime/backends,scripts,node/bin}
mkdir -p "$R"/dsh-files/departments/{研发部/{张三,赵六},财务部/王五}
mkdir -p "$R"/dsh-users/{zhangsan,zhaoliu} "$R"/.local/share/dsh/profiles

echo '全员明文初始密码' > "$R/dsh-auth/initial-credentials.txt"
echo 'users: {}'       > "$R/dsh-auth/config/users_database.yml"
echo 'PRIVKEY'         > "$R/nginx/certs/dsh.key"
echo 'SQLITE'          > "$R/filebrowser/database.db"
echo 'deadbeef'        > "$R/admin/.admin-token"
echo '财务机密'         > "$R/dsh-files/departments/财务部/王五/工资表.xlsx"
echo '赵六的笔记'       > "$R/dsh-files/departments/研发部/赵六/note.txt"
echo '张三的文档'       > "$R/dsh-files/departments/研发部/张三/我的文档.txt"
echo 'export default 1' > "$R/.local/share/dsh/profiles/index.mjs"

cp "$REPO/admin/core.py" "$REPO/admin/cli.py" "$R/admin/"
# 隔离层是「调度器 + 各后端 + 容器入口脚本」，少拷一个都会在运行时才炸
cp "$REPO/dsh-runtime/dsh-sandbox.sh" "$REPO/dsh-runtime/dsh-netns-entry.sh" \
   "$REPO/dsh-runtime/dsh-container-entry.sh" "$R/dsh-runtime/"
cp "$REPO"/dsh-runtime/backends/*.sh "$R/dsh-runtime/backends/"
cp "$REPO/dsh-runtime/Dockerfile.instance" "$R/dsh-runtime/"
cp "$REPO/scripts/preflight-sandbox.sh" "$R/scripts/"
# 冒充 node：探针脚本会被当成 dsh 本体执行
cp /bin/bash "$R/node/bin/node"

python3 - "$R" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
users = {}
for name, py, port in (("张三", "zhangsan", 13101), ("赵六", "zhaoliu", 13102)):
    users[py] = {"username": py, "name": name, "department": "研发部",
                 "role": "员工", "port": port,
                 "workspace": str(root / "dsh-files/departments/研发部" / name)}
(root / "dsh-users/registry.json").write_text(
    json.dumps({"version": 1, "users": users}, ensure_ascii=False, indent=2), encoding="utf-8")
PY

echo "仿真部署树已就绪: $R"
