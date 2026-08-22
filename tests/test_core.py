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


class TestSpaceSync(TempCase):
    """FileBrowser 的 scope 与 dsh 的可访问范围必须是同一个目录。"""

    def test_staff_both_sides_are_personal_dir(self):
        rec = self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        personal = str(self.cfg.departments / "研发部" / "张三")
        self.assertEqual(self.fb.users["zhangsan"]["scopes"][0]["scope"],
                         "/departments/研发部/张三")
        self.assertEqual(rec["workspace"], personal)
        info = self.engine.space_consistency(rec)
        self.assertEqual(info["space"], personal)
        self.assertTrue(info["in_sync"])

    def test_lead_both_sides_are_department_dir(self):
        rec = self.engine.create_user("lisi", "李四", "研发部", "主管")
        self.assertEqual(self.fb.users["lisi"]["scopes"][0]["scope"], "/departments/研发部")
        info = self.engine.space_consistency(rec)
        self.assertEqual(info["space"], str(self.cfg.departments / "研发部"))
        self.assertTrue(info["in_sync"])

    def test_department_move_keeps_both_sides_in_sync(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.engine.update_user("zhangsan", department="市场部")
        self.assertEqual(self.fb.users["zhangsan"]["scopes"][0]["scope"],
                         "/departments/市场部/张三")
        reg = json.loads(self.cfg.registry.read_text(encoding="utf-8"))
        rec = reg["users"]["zhangsan"]
        self.assertEqual(rec["workspace"], str(self.cfg.departments / "市场部" / "张三"))
        self.assertTrue(self.engine.space_consistency(rec)["in_sync"])

    def test_admin_space_is_whole_company(self):
        self.assertEqual(self.engine.admin_space(), self.cfg.files_root)

    def test_startup_scripts_launch_admin_with_whole_company(self):
        """光有 admin_space() 不够——启动脚本必须真的用这个路径。

        「函数里定义一套、脚本里写死另一套」正是本项目此前空间漂移的成因，
        所以这里直接盯住启动脚本。
        """
        repo = Path(__file__).resolve().parent.parent
        for name in ("start-all.sh", "dsh-start.sh"):
            text = (repo / "dsh-runtime" / name).read_text(encoding="utf-8")
            admin_lines = [ln for ln in text.splitlines()
                           if "admin" in ln and "3080" in ln and "dsh-files" in ln]
            self.assertTrue(
                admin_lines,
                f"{name} 里没有以 dsh-files 为工作区拉起 admin 3080 实例的那一行")
            self.assertTrue(
                all("$DSH_ROOT/dsh-files" in ln for ln in admin_lines),
                f"{name} 的 admin 实例工作区应为 $DSH_ROOT/dsh-files: {admin_lines}")

    def test_detects_drift_when_someone_edits_filebrowser_by_hand(self):
        """有人绕过后台、直接在 FileBrowser 上把 scope 改宽了，状态要能看出来。"""
        rec = self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertTrue(self.engine.space_consistency(rec, "/departments/研发部/张三")["in_sync"])

        info = self.engine.space_consistency(rec, "/departments/研发部")   # 被改宽了
        self.assertFalse(info["filebrowser_ok"])
        self.assertFalse(info["in_sync"])
        self.assertEqual(info["expected_scope"], "/departments/研发部/张三")
        self.assertEqual(info["actual_scope"], "/departments/研发部")

    def test_list_users_surfaces_drift(self):
        """后台列表要直接把漂移显示出来，不用人去比对。"""
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertTrue(self.engine.list_users()[0]["space"]["in_sync"])
        self.fb.users["zhangsan"]["scopes"] = [{"name": "公司文件", "scope": "/departments"}]
        row = self.engine.list_users()[0]
        self.assertFalse(row["space"]["in_sync"])
        self.assertEqual(row["space"]["actual_scope"], "/departments")


class TestMounts(TempCase):
    """额外空间：校验与生效计算。"""

    def test_lead_gets_department_dir(self):
        """此前只有 FileBrowser 给主管部门级 scope，dsh 侧却钳在个人目录。"""
        rec = self.engine.create_user("lisi", "李四", "研发部", "主管")
        mounts = self.engine.effective_mounts(rec)
        self.assertEqual(mounts, [{"path": str(self.cfg.departments / "研发部"), "mode": "rw"}])

    def test_staff_gets_nothing_extra(self):
        rec = self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.assertEqual(self.engine.effective_mounts(rec), [])

    def test_set_mounts_validates_and_restarts(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        shared = self.cfg.files_root / "shared" / "公共资料"
        shared.mkdir(parents=True)
        self.runner.spawned.clear()
        rec = self.engine.set_mounts("zhangsan", [{"path": str(shared), "mode": "ro"}])
        self.assertEqual(rec["mounts"], [{"path": str(shared.resolve()), "mode": "ro"}])
        self.assertTrue(self.runner.spawned, "挂载集变了必须重启实例")

    def test_rejects_path_outside_files_root(self):
        """管理后台不能把 /etc 之类挂进员工的沙箱。"""
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        for bad in ["/etc", "/", str(self.cfg.root / "dsh-auth")]:
            with self.subTest(bad=bad), self.assertRaises(ProvisionError):
                self.engine.set_mounts("zhangsan", [{"path": bad, "mode": "ro"}])

    def test_rejects_symlink_escape(self):
        """dsh-files 里放个指向外面的软链，解析后必须被拒。"""
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        link = self.cfg.files_root / "escape"
        link.symlink_to("/etc")
        with self.assertRaises(ProvisionError):
            self.engine.set_mounts("zhangsan", [{"path": str(link), "mode": "ro"}])

    def test_rejects_bad_mode_and_missing_path(self):
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        good = self.cfg.files_root / "ok"; good.mkdir()
        with self.assertRaises(ProvisionError):
            self.engine.set_mounts("zhangsan", [{"path": str(good), "mode": "rwx"}])
        with self.assertRaises(ProvisionError):
            self.engine.set_mounts("zhangsan", [{"path": str(self.cfg.files_root / "nope"), "mode": "ro"}])
        with self.assertRaises(ProvisionError):
            self.engine.set_mounts("zhangsan", [{"path": "relative/path", "mode": "ro"}])

    def test_mounts_reach_sandbox_env(self):
        rec = self.engine.create_user("lisi", "李四", "研发部", "主管")
        encoded = self.engine._encode_mounts(self.engine.effective_mounts(rec))
        self.assertEqual(encoded, f"rw\t{self.cfg.departments / '研发部'}")

    def test_promotion_restarts_instance(self):
        """员工升主管会多挂部门目录，必须重启才生效。"""
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.runner.spawned.clear()
        self.engine.update_user("zhangsan", role="主管")
        self.assertTrue(self.runner.spawned, "角色变更改变了挂载集，应重启实例")


class TestNetnsMode(TempCase):
    """网络隔离模式：nginx upstream 改用 unix socket，宿主回环上不留 dsh 端口。"""

    def test_upstream_is_tcp_by_default(self):
        self.assertEqual(self.cfg.upstream_for("zhangsan", 13101), "127.0.0.1:13101")

    def test_upstream_is_unix_socket_when_enabled(self):
        self.cfg.netns = True
        self.assertEqual(self.cfg.upstream_for("zhangsan", 13101),
                         f"unix:{self.cfg.root}/dsh-sockets/zhangsan/dsh.sock:")

    def test_nginx_map_uses_unix_sockets(self):
        self.cfg.netns = True
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        conf = self.cfg.nginx_conf.read_text(encoding="utf-8")
        self.assertIn(f'"zhangsan"  unix:{self.cfg.root}/dsh-sockets/zhangsan/dsh.sock:;', conf)
        # 未匹配用户仍走 TCP 黑洞 -> 403，而不是 socket 不存在的 502
        self.assertIn("default     127.0.0.1:13100;", conf)

    def test_netns_flag_reaches_sandbox_launcher(self):
        self.cfg.netns = True
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        # --check 必须带着 DSH_NETNS=1，才能顺带校验 pasta/socat 是否就位
        checks = [c for c in self.runner.calls if "--check" in c]
        self.assertTrue(checks, "建号前应先自检沙箱")


class TestUpdate(TempCase):
    def setUp(self):
        super().setUp()
        self.engine.create_user("zhangsan", "张三", "研发部", "员工")
        self.runner.spawned.clear()

    def test_promote_to_lead_syncs_both_sides(self):
        """升主管后，FileBrowser 的 scope 与 dsh 的挂载必须同时变成部门目录。

        旧行为只改了 FileBrowser 一侧，dsh 仍钳在个人目录，两边对不上；
        而且挂载集变了就必须重启实例，否则改动不生效。
        """
        self.engine.update_user("zhangsan", role="主管")

        fbu = self.fb.users["zhangsan"]
        self.assertEqual(fbu["scopes"][0]["scope"], "/departments/研发部")
        self.assertTrue(fbu["permissions"]["delete"])

        reg = json.loads(self.cfg.registry.read_text(encoding="utf-8"))
        rec = reg["users"]["zhangsan"]
        dept_dir = str(self.cfg.departments / "研发部")
        self.assertIn({"path": dept_dir, "mode": "rw"}, self.engine.effective_mounts(rec))
        self.assertTrue(self.engine.space_consistency(rec)["in_sync"])
        self.assertTrue(self.runner.spawned, "挂载集变了，必须重启实例才生效")

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
    def _seed_legacy(self, username: str, path: Path, title: str = ""):
        """造一个老实例的 storages/workspace.json（迁移时的唯一数据来源）。"""
        d = self.cfg.users_root / username / "storages"
        d.mkdir(parents=True, exist_ok=True)
        wsid = "abc123"
        (d / "workspace.json").write_text(json.dumps({
            "unit": {"name": "workspace", "version": 2},
            "global": {"initialized": True, "workspaceIds": [wsid]},
            "tables": {"workspaces": {wsid: {"path": str(path), "title": title}}},
        }, ensure_ascii=False), encoding="utf-8")

    def test_migrates_legacy_ports_json(self):
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        self.cfg.legacy_ports.write_text(json.dumps({"lisi": 13102}), encoding="utf-8")
        reg = self.engine.load_registry()
        self.assertEqual(reg["users"]["lisi"]["port"], 13102)
        self.assertTrue(reg["users"]["lisi"]["migrated_from_ports_json"])

    def test_migration_recovers_workspace_and_identity(self):
        """迁移必须把工作区一并恢复。

        早先留空，start-all.sh 见空即跳过，所有老员工实例全部拒启，
        运维只能手工把整张登记表补出来——现场就是这么卡住的。
        """
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        self.cfg.legacy_ports.write_text(json.dumps({"zhangsan": 13101}), encoding="utf-8")
        personal = self.cfg.departments / "研发部" / "张三"
        personal.mkdir(parents=True)
        self._seed_legacy("zhangsan", personal, title="张三")

        rec = self.engine.load_registry()["users"]["zhangsan"]
        self.assertEqual(rec["workspace"], str(personal))
        self.assertEqual(rec["department"], "研发部")
        self.assertEqual(rec["name"], "张三")
        self.assertEqual(rec["role"], "员工")

    def test_migration_infers_lead_from_department_level_workspace(self):
        """工作区就是部门目录 -> 这人是主管。"""
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        self.cfg.legacy_ports.write_text(json.dumps({"lisi": 13102}), encoding="utf-8")
        dept = self.cfg.departments / "研发部"
        dept.mkdir(parents=True)
        self._seed_legacy("lisi", dept)

        rec = self.engine.load_registry()["users"]["lisi"]
        self.assertEqual(rec["workspace"], str(dept))
        self.assertEqual(rec["department"], "研发部")
        self.assertEqual(rec["role"], "主管")

    def test_migration_leaves_workspace_empty_when_unrecoverable(self):
        """恢复不出来就留空由管理员补，不猜一个错的路径。"""
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        self.cfg.legacy_ports.write_text(json.dumps({"wang_er": 13103}), encoding="utf-8")
        rec = self.engine.load_registry()["users"]["wang_er"]
        self.assertEqual(rec["workspace"], "")

    def test_trusted_hosts_include_all_three_entry_domains(self):
        """只传公网 IP 的话，云 NAT 场景下本机与局域网访问会被 dsh 拒绝。"""
        hosts = self.cfg.trusted_hosts.split()
        self.assertIn("218.17.143.249:8099", hosts)
        self.assertIn("192.168.1.225:8099", hosts)
        self.assertIn("127.0.0.1:8099", hosts)

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
