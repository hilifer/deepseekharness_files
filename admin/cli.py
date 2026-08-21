#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""员工管理命令行 —— 与管理后台共用 admin/core.py，不存在第二套实现。

  cli.py create <username> <部门> <角色> [姓名] [--password PW]
  cli.py update <username> [--name N] [--department D] [--role R] [--no-move-files]
  cli.py delete <username> [--delete-files] [--yes]
  cli.py passwd <username> [--password PW]
  cli.py list [--json]
  cli.py sync-nginx
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core import Config, Engine, ProvisionError, ROLES  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(prog="cli.py", description="员工增删改（与管理后台同一套逻辑）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("create", help="新增员工")
    c.add_argument("username"); c.add_argument("department", metavar="部门")
    c.add_argument("role", metavar="角色", choices=ROLES)
    c.add_argument("name", metavar="姓名", nargs="?")
    c.add_argument("--password")

    u = sub.add_parser("update", help="改姓名/部门/角色")
    u.add_argument("username")
    u.add_argument("--name"); u.add_argument("--department")
    u.add_argument("--role", choices=ROLES)
    u.add_argument("--no-move-files", action="store_true", help="改路径时不迁移文件")

    d = sub.add_parser("delete", help="离职销号")
    d.add_argument("username")
    d.add_argument("--delete-files", action="store_true", help="同时永久删除工作区文件")
    d.add_argument("--yes", action="store_true", help="跳过交互确认")

    p = sub.add_parser("passwd", help="重置密码"); p.add_argument("username"); p.add_argument("--password")
    ls = sub.add_parser("list", help="列出员工与同步状态"); ls.add_argument("--json", action="store_true")
    sub.add_parser("sync-nginx", help="按登记表重写 nginx 路由并 reload")

    args = ap.parse_args()
    engine = Engine(Config.from_env())

    try:
        if args.cmd == "create":
            res = engine.create_user(args.username, args.name or args.username,
                                     args.department, args.role, password=args.password)
            print(f"✅ {res['username']} 建号完成")
            print(f"   姓名/部门/角色 : {res['name']} / {res['department']} / {res['role']}")
            print(f"   dsh 端口       : {res['port']}")
            print(f"   工作区         : {res['workspace']}")
            print(f"   初始密码       : {res['initial_password']}")
            print("   （请通过安全渠道转交本人，此处不落盘）")

        elif args.cmd == "update":
            res = engine.update_user(args.username, name=args.name, department=args.department,
                                     role=args.role, move_files=not args.no_move_files)
            print(f"✅ {args.username} 已更新: {res['name']} / {res['department']} / {res['role']}")
            print(f"   工作区: {res['workspace']}")

        elif args.cmd == "delete":
            if not args.yes:
                extra = "，并【永久删除】其工作区文件" if args.delete_files else "（保留工作区文件）"
                ans = input(f"确认删除 {args.username}{extra}？输入用户名确认: ").strip()
                if ans != args.username:
                    print("已取消"); return 1
            res = engine.delete_user(args.username, delete_files=args.delete_files)
            for step, status in res["steps"].items():
                print(f"   {'✅' if status == 'ok' else '❌'} {step}: {status}")
            print(f"   文件: {res['files']}")

        elif args.cmd == "passwd":
            res = engine.reset_password(args.username, args.password)
            print(f"✅ {res['username']} 新密码: {res['password']}")

        elif args.cmd == "list":
            rows = engine.list_users()
            if args.json:
                print(json.dumps(rows, ensure_ascii=False, indent=2)); return 0
            if not rows:
                print("（暂无员工）"); return 0
            print(f"{'用户名':<14}{'姓名':<10}{'部门':<10}{'角色':<6}{'端口':<7}状态")
            for r in rows:
                st = r.get("status", {})
                flags = "".join("✅" if st.get(k) else "❌"
                                for k in ("authelia", "nginx", "filebrowser", "dsh", "workspace"))
                print(f"{r['username']:<14}{r['name']:<10}{r['department']:<10}"
                      f"{r['role']:<6}{r['port']:<7}{flags}")
            print("\n状态列依次为: Authelia / nginx / FileBrowser / dsh 实例 / 工作区目录")

        elif args.cmd == "sync-nginx":
            engine.sync_nginx(); print("✅ nginx 路由已按登记表重写并 reload")

    except ProvisionError as exc:
        print(f"❌ {exc}", file=sys.stderr); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
