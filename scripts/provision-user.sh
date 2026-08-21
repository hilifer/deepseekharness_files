#!/bin/bash
# 新员工建号。实际逻辑在 admin/core.py（与管理后台共用同一套实现）。
# 用法: provision-user.sh <username> <部门> <角色:员工|主管> [中文姓名]
#   例: provision-user.sh wang_er 研发部 员工 王二
#
# 更推荐用管理后台的图形界面: https://<IP>:8099/admin/
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-/home/ubuntu}"
if [ -n "${INIT_PW:-}" ]; then
  exec python3 "$DSH_ROOT/admin/cli.py" create "$@" --password "$INIT_PW"
fi
exec python3 "$DSH_ROOT/admin/cli.py" create "$@"
