#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
core.py 单元测试。

目标服务器上的 authelia / nginx / filebrowser / dsh 在开发环境都不可用，
所以外部依赖全部打桩（FakeRunner / FakeFileBrowser），只验证引擎自身的逻辑：
四个子系统的写入内容是否正确、幂等性、注入防御、以及销号是否清理干净。
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "admin"))

import core  # noqa: E402
from core import Config, Engine, ProvisionError  # noqa: E402

NGINX_TEMPLATE = """\
http {
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    map $user $dsh_upstream {
        default     127.0.0.1:13100;
        "admin"     127.0.0.1:3080;
    }

    include /home/ubuntu/nginx/conf/sites/*.conf;
}
"""


class FakeRunner:
    """把所有外部命令替换成可断言的记录。"""

    def __init__(self):
        self.calls: list[list[str]] = []
        self.spawned: list[list[str]] = []
        self.running_ports: set[int] = set()
        self.sandbox_ok = True
        self.nginx_test_ok = True

    def run(self, argv, *, env=None, timeout=60, check=False, cwd=None):
        import subprocess
        self.calls.append(argv)
        argv_s = " ".join(argv)
        if "--check" in argv and "dsh-sandbox.sh" in argv_s:
            rc = 0 if self.sandbox_ok else 1
            return subprocess.CompletedProcess(argv, rc, "OK /usr/bin/bwrap" if rc == 0 else "MISSING", "")
        if "crypto" in argv and "hash" in argv:
            pw = argv[argv.index("--password") + 1]
            return subprocess.CompletedProcess(argv, 0, f"Digest: $argon2id$v=19$m=65536,t=3,p=4$FAKE${len(pw)}\n", "")
        if argv_s.endswith("authelia-start.sh restart"):
            return subprocess.CompletedProcess(argv, 0, "authelia restarted", "")
        if "nginx" in argv_s and "-t" in argv:
            rc = 0 if self.nginx_test_ok else 1
            return subprocess.CompletedProcess(argv, rc, "", "" if rc == 0 else "syntax error")
        if "nginx" in argv_s and "reload" in argv_s:
            return subprocess.CompletedProcess(argv, 0, "", "")
        if argv[0] == "pgrep":
            port = _port_from_pattern(argv[-1])
            out = "4242\n" if port in self.running_ports else ""
            return subprocess.CompletedProcess(argv, 0 if out else 1, out, "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    def spawn(self, argv, *, logfile, env=None):
        self.spawned.append(argv)
        self.running_ports.add(int(argv[2]))
        return 12345

    def pgrep(self, pattern):
        port = _port_from_pattern(pattern)
        return [4242] if port in self.running_ports else []

    def pkill(self, pattern):
        self.running_ports.discard(_port_from_pattern(pattern))


def _port_from_pattern(pattern: str) -> int:
    for tok in pattern.split():
        if tok.isdigit():
            return int(tok)
    return -1


class FakeFileBrowser:
    """有状态的 FileBrowser API 替身。"""

    def __init__(self):
        self.users: dict[str, dict] = {
            "admin": {"username": "admin", "loginMethod": "proxy", "scopes": [], "permissions": {"admin": True}}
        }

    def request(self, method, url, *, headers=None, body=None, timeout=15):
        if "api/health" in url:
            return 200, b'{"status":"OK"}'
        if "/api/users" not in url:
            return 404, b""
        payload = json.loads(body) if body else None
        if method == "GET":
            return 200, json.dumps(list(self.users.values())).encode()
        if method == "POST":
            data = payload["data"]
            self.users[data["username"]] = data
            return 201, b"{}"
        if method == "PUT":
            username = url.split("username=")[1]
            self.users[username] = payload["data"]
            return 200, b"{}"
        if method == "DELETE":
            self.users.pop(url.split("username=")[1], None)
            return 200, b"{}"
        return 405, b""


def build(tmp: Path):
    root = tmp / "home"
    for sub in ("dsh-auth/config", "nginx/conf", "nginx/extracted/usr/sbin",
                "dsh-runtime", "dsh-users", "dsh-files/departments", ".local/share/dsh/profiles"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    (root / "nginx/conf/nginx.conf").write_text(NGINX_TEMPLATE, encoding="utf-8")
    (root / "dsh-auth/config/users_database.yml").write_text(
        "users:\n  admin:\n    displayname: admin\n    password: '$argon2id$OLD'\n"
        "    email: admin@example.com\n    groups: []\n", encoding="utf-8")
    (root / "dsh-runtime/dsh-sandbox.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    (root / "nginx/extracted/usr/sbin/nginx").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    cfg = Config(root=root)
    runner, fb = FakeRunner(), FakeFileBrowser()
    return Engine(cfg, runner=runner, http=fb), cfg, runner, fb


class TempCase(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.engine, self.cfg, self.runner, self.fb = build(self.tmp)

    def tearDown(self):
        self._tmp.cleanup()


# ==========================================================================
class TestValidation(unittest.TestCase):
    def test_valid_usernames(self):
        for name in ("zhangsan", "wang_er", "a1", "x_9_y"):
            self.assertEqual(core.validate_username(name), name)

    def test_rejects_injection_usernames(self):
        # 原 provision-user.sh 会把这些直接拼进 YAML / nginx / python 字符串
        bad = [
            'a"; return 403; #',          # nginx 指令注入
            "a':\n  evil:",               # YAML 结构破坏
            "a' or '1'=='1",              # python 单引号注入
            "../../etc/passwd",           # 路径穿越
            "Zhang",                      # 大写
            "1abc",                       # 数字开头
            "a", "",                      # 太短/空
            "a" * 33,                     # 太长
            "admin",                      # 保留名
        ]
        for name in bad:
            with self.subTest(name=name), self.assertRaises(ProvisionError):
                core.validate_username(name)

    def test_label_rejects_path_and_quotes(self):
        for bad in ["研发/部", "..", "", "a" * 33, "张'三", '李"四', "王\n五", "-开头"]:
            with self.subTest(bad=bad), self.assertRaises(ProvisionError):
                core.validate_label(bad, "部门")

    def test_label_accepts_chinese(self):
        self.assertEqual(core.validate_label(" 研发部 ", "部门"), "研发部")

    def test_role(self):
        self.assertEqual(core.validate_role("主管"), "主管")
        with self.assertRaises(ProvisionError):
            core.validate_role("经理")


class TestUsersYaml(unittest.TestCase):
    def test_roundtrip_preserves_records(self):
        src = (
            "# 注释\n"
            "users:\n"
            "  admin:\n"
            "    displayname: admin\n"
            "    password: '$argon2id$v=19$m=65536,t=3,p=4$abc'\n"
            "    email: admin@example.com\n"
            "    groups: []\n"
            "  zhangsan:\n"
            '    displayname: "张三（研发部员工）"\n'
            "    password: '$argon2id$xyz'\n"
            "    email: zhangsan@company.local\n"
            "    groups:\n"
            "      - dev\n"
        )
        parsed = core.parse_users_yaml(src)
        self.assertEqual(set(parsed), {"admin", "zhangsan"})
        self.assertEqual(parsed["zhangsan"]["displayname"], "张三（研发部员工）")
        self.assertEqual(parsed["zhangsan"]["groups"], ["dev"])
        self.assertEqual(parsed["admin"]["groups"], [])
        reparsed = core.parse_users_yaml(core.dump_users_yaml(parsed))
        self.assertEqual(reparsed, parsed)

    def test_quote_escaping(self):
        users = {"u1": {"displayname": "O'Brien（研发部员工）", "password": "$argon2id$x",
                        "email": "u1@x.com", "groups": []}}
        out = core.dump_users_yaml(users)
        self.assertEqual(core.parse_users_yaml(out)["u1"]["displayname"], "O'Brien（研发部员工）")


class TestFbProxyHeader(TempCase):
    def test_reads_generated_secret_header(self):
        """管理后台直连 FileBrowser，必须用 init-secrets.sh 生成的密钥头名。"""
        gen = self.cfg.root / "nginx/conf/generated"
        gen.mkdir(parents=True, exist_ok=True)
        (gen / "fb-auth.conf").write_text("proxy_set_header X-Fb-Auth-deadbeef $user;\n", encoding="utf-8")
        self.assertEqual(core.read_fb_proxy_header(self.cfg.root), "X-Fb-Auth-deadbeef")

    def test_falls_back_when_not_generated_yet(self):
        self.assertEqual(core.read_fb_proxy_header(self.cfg.root), "X-Forwarded-User")

    def test_engine_sends_that_header(self):
        captured = {}
        real = self.fb.request
        def spy(method, url, *, headers=None, body=None, timeout=15):
            captured.update(headers or {})
            return real(method, url, headers=headers, body=body, timeout=timeout)
        self.fb.request = spy
        self.engine.cfg.fb_proxy_header = "X-Fb-Auth-deadbeef"
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertEqual(captured.get("X-Fb-Auth-deadbeef"), "admin")
        self.assertNotIn("X-Forwarded-User", captured)


class TestCreate(TempCase):
    def test_create_writes_all_four_subsystems(self):
        res = self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertEqual(res["port"], core.PORT_BASE)
        self.assertTrue(res["initial_password"])

        # 1) Authelia
        auth = core.parse_users_yaml(self.cfg.auth_users.read_text(encoding="utf-8"))
        self.assertIn("zhangsan", auth)
        self.assertEqual(auth["zhangsan"]["displayname"], "张三（研发部员工）")
        self.assertTrue(auth["zhangsan"]["password"].startswith("$argon2id$"))
        self.assertIn("admin", auth, "不得破坏已有账号")

        # 2) nginx
        conf = self.cfg.nginx_conf.read_text(encoding="utf-8")
        self.assertIn('"zhangsan"  127.0.0.1:13101;', conf)
        self.assertIn("default     127.0.0.1:13100;", conf)
        self.assertIn("map $http_upgrade", conf, "不得破坏其他 map 块")

        # 3) FileBrowser：员工 scope=个人目录、不可删、loginMethod=proxy
        fbu = self.fb.users["zhangsan"]
        self.assertEqual(fbu["loginMethod"], "proxy")
        self.assertEqual(fbu["scopes"], [{"name": "公司文件", "scope": "/departments/研发部/张三"}])
        self.assertFalse(fbu["permissions"]["delete"])
        self.assertTrue(fbu["permissions"]["api"], "api=false 会阻断 Web UI 全部请求")

        # 4) dsh：通过沙箱启动器拉起，参数正确
        self.assertEqual(len(self.runner.spawned), 1)
        argv = self.runner.spawned[0]
        self.assertTrue(argv[0].endswith("dsh-sandbox.sh"))
        self.assertEqual(argv[1:3], ["zhangsan", "13101"])
        self.assertEqual(argv[4], str(self.cfg.departments / "研发部" / "张三"))

        # registry 与工作区
        reg = json.loads(self.cfg.registry.read_text(encoding="utf-8"))
        self.assertEqual(reg["users"]["zhangsan"]["workspace"], argv[4])
        self.assertTrue(Path(argv[4]).is_dir())
        ws = json.loads((self.cfg.users_root / "zhangsan/storages/workspace.json").read_text(encoding="utf-8"))
        wsid = ws["global"]["workspaceIds"][0]
        self.assertEqual(ws["tables"]["workspaces"][wsid]["path"], argv[4])

    def test_lead_gets_department_scope_and_delete(self):
        self.engine.create_user("lisi", "李四", "研发部", "主管")
        fbu = self.fb.users["lisi"]
        self.assertEqual(fbu["scopes"][0]["scope"], "/departments/研发部")
        self.assertTrue(fbu["permissions"]["delete"])

    def test_ports_increment_and_never_collide(self):
        for i, u in enumerate(["a_one", "b_two", "c_three"]):
            rec = self.engine.create_user(u, f"员工{i}", "研发部", "员工")
            self.assertEqual(rec["port"], core.PORT_BASE + i)
        conf = self.cfg.nginx_conf.read_text(encoding="utf-8")
        for i, u in enumerate(["a_one", "b_two", "c_three"]):
            self.assertIn(f'"{u}"  127.0.0.1:{core.PORT_BASE + i};', conf)

    def test_duplicate_rejected(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        with self.assertRaises(ProvisionError):
            self.engine.create_user("zhangsan", "张三", "研发部", "员工")

    def test_refuses_when_sandbox_unavailable(self):
        """没有内核级隔离就不建号——绝不退回无隔离运行。"""
        self.runner.sandbox_ok = False
        with self.assertRaises(ProvisionError) as ctx:
            self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertIn("沙箱不可用", str(ctx.exception))
        self.assertNotIn("zhangsan", core.parse_users_yaml(
            self.cfg.auth_users.read_text(encoding="utf-8")), "失败时不得留下半个账号")

    def test_nginx_rollback_on_bad_config(self):
        self.runner.nginx_test_ok = False
        with self.assertRaises(ProvisionError):
            self.engine.create_user("zhangsan", "张三", "研发部", "员工")


class TestUpdate(TempCase):
    def setUp(self):
        super().setUp()
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.runner.spawned.clear()

    def test_promote_to_lead_updates_filebrowser_only(self):
        self.engine.update_user("zhangsan", role="主管")
        fbu = self.fb.users["zhangsan"]
        self.assertEqual(fbu["scopes"][0]["scope"], "/departments/研发部")
        self.assertTrue(fbu["permissions"]["delete"])
        self.assertEqual(self.runner.spawned, [], "角色变更不改路径，无需重启实例")
        auth = core.parse_users_yaml(self.cfg.auth_users.read_text(encoding="utf-8"))
        self.assertEqual(auth["zhangsan"]["displayname"], "张三（研发部主管）")

    def test_department_move_relocates_files_and_restarts(self):
        old = self.cfg.departments / "研发部" / "张三"
        (old / "我的文档.txt").write_text("内容", encoding="utf-8")

        self.engine.update_user("zhangsan", department="市场部")

        new = self.cfg.departments / "市场部" / "张三"
        self.assertTrue((new / "我的文档.txt").is_file(), "文件应随部门迁移")
        self.assertFalse(old.exists())
        self.assertEqual(self.fb.users["zhangsan"]["scopes"][0]["scope"], "/departments/市场部/张三")

        reg = json.loads(self.cfg.registry.read_text(encoding="utf-8"))
        self.assertEqual(reg["users"]["zhangsan"]["workspace"], str(new))
        # 沙箱挂载点变了，必须以新工作区重启实例
        self.assertEqual(len(self.runner.spawned), 1)
        self.assertEqual(self.runner.spawned[0][4], str(new))
        ws = json.loads((self.cfg.users_root / "zhangsan/storages/workspace.json").read_text(encoding="utf-8"))
        wsid = ws["global"]["workspaceIds"][0]
        self.assertEqual(ws["tables"]["workspaces"][wsid]["path"], str(new))

    def test_move_refuses_to_overwrite(self):
        (self.cfg.departments / "市场部" / "张三").mkdir(parents=True)
        with self.assertRaises(ProvisionError):
            self.engine.update_user("zhangsan", department="市场部")

    def test_update_rejects_invalid_input(self):
        with self.assertRaises(ProvisionError):
            self.engine.update_user("zhangsan", department="市场/部")


class TestDelete(TempCase):
    def setUp(self):
        super().setUp()
        self.rec = self.engine.create_user("zhangsan", "张三", "研发部", "员工")

    def test_delete_cleans_every_subsystem(self):
        report = self.engine.delete_user("zhangsan")
        self.assertTrue(all(v == "ok" for v in report["steps"].values()), report["steps"])

        self.assertNotIn("zhangsan", core.parse_users_yaml(
            self.cfg.auth_users.read_text(encoding="utf-8")))
        self.assertNotIn("zhangsan", self.fb.users)
        conf = self.cfg.nginx_conf.read_text(encoding="utf-8")
        self.assertNotIn('"zhangsan"', conf, "nginx 路由必须删除，否则同名重建会接管旧实例")
        self.assertNotIn("zhangsan", json.loads(self.cfg.registry.read_text(encoding="utf-8"))["users"])
        self.assertFalse((self.cfg.users_root / "zhangsan").exists())
        self.assertFalse(self.runner.running_ports)

    def test_delete_keeps_files_by_default(self):
        ws = Path(self.rec["workspace"])
        (ws / "重要.txt").write_text("x", encoding="utf-8")
        self.engine.delete_user("zhangsan")
        self.assertTrue((ws / "重要.txt").is_file(), "默认必须保留离职员工的文件")

    def test_delete_files_when_asked(self):
        ws = Path(self.rec["workspace"])
        self.engine.delete_user("zhangsan", delete_files=True)
        self.assertFalse(ws.exists())

    def test_port_reused_after_delete(self):
        self.engine.delete_user("zhangsan")
        rec = self.engine.create_user("wang_er", "王二", "研发部", "员工")
        self.assertEqual(rec["port"], core.PORT_BASE)


class TestRegistryAndStatus(TempCase):
    def test_migrates_legacy_ports_json(self):
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        self.cfg.legacy_ports.write_text(json.dumps({"lisi": 13102}), encoding="utf-8")
        reg = self.engine.load_registry()
        self.assertEqual(reg["users"]["lisi"]["port"], 13102)
        self.assertTrue(reg["users"]["lisi"]["migrated_from_ports_json"])

    def test_ports_json_stays_in_sync(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertEqual(json.loads(self.cfg.legacy_ports.read_text(encoding="utf-8")), {"zhangsan": 13101})

    def test_status_reports_drift(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        rows = self.engine.list_users()
        self.assertTrue(rows[0]["healthy"], rows[0]["status"])

        # 模拟人为改坏：nginx 路由被删掉
        conf = self.cfg.nginx_conf.read_text(encoding="utf-8").replace('"zhangsan"  127.0.0.1:13101;', "")
        self.cfg.nginx_conf.write_text(conf, encoding="utf-8")
        rows = self.engine.list_users()
        self.assertFalse(rows[0]["status"]["nginx"])
        self.assertFalse(rows[0]["healthy"])


class TestInstanceControl(TempCase):
    def test_stop_and_start(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertTrue(self.engine.list_users()[0]["status"]["dsh"])
        self.assertFalse(self.engine.set_instance("zhangsan", False)["running"])
        self.assertTrue(self.engine.set_instance("zhangsan", True)["running"])

    def test_start_refuses_without_workspace(self):
        rec = self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.engine.set_instance("zhangsan", False)
        import shutil as _sh
        _sh.rmtree(rec["workspace"])
        with self.assertRaises(ProvisionError):
            self.engine.set_instance("zhangsan", True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
