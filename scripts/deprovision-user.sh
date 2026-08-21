#!/bin/bash
# 员工离职销号：停实例 + 删 Authelia 账号 + 删 FileBrowser 用户 + 清 nginx 路由
#              + 删实例状态目录（工作区文件默认保留）。
# 用法: deprovision-user.sh <username> [--delete-files] [--yes]
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
exec python3 "$DSH_ROOT/admin/cli.py" delete "$@"
