#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""管理后台 HTTP 接口测试：路由、鉴权双闸门、错误处理。"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "admin"))
sys.path.insert(0, str(ROOT / "tests"))

_TMP = tempfile.TemporaryDirectory()
os.environ["ADMIN_TOKEN_FILE"] = str(Path(_TMP.name) / "token")
os.environ["ADMIN_AUDIT_LOG"] = str(Path(_TMP.name) / "audit.log")
os.environ["ADMIN_USERS"] = "admin,boss"

import app  # noqa: E402
import core  # noqa: E402
from test_core import build  # noqa: E402


class AppTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        engine, cfg, runner, fb = build(Path(cls.tmp.name))
        app.ENGINE = engine
        cls.engine, cls.cfg, cls.runner, cls.fb = engine, cfg, runner, fb
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.tmp.cleanup()

    def call(self, method, path, body=None, *, token=app.ADMIN_TOKEN, user="admin"):
        url = f"http://127.0.0.1:{self.port}{path}"
        headers = {}
        if token is not None:
            headers["X-Admin-Token"] = token
        if user is not None:
            headers["Remote-User"] = user
        data = json.dumps(body).encode() if body is not None else None
        if data:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return exc.code, {"raw": raw.decode(errors="replace")}

    # ---------------- 鉴权 ----------------
    def test_rejects_without_token(self):
        """沙箱内的 dsh 能连到本服务的端口，但读不到密钥文件，必须被挡住。"""
        status, body = self.call("GET", "/admin/api/users", token=None)
        self.assertEqual(status, 403)
        self.assertIn("无权", body["error"])

    def test_rejects_wrong_token(self):
        status, _ = self.call("GET", "/admin/api/users", token="0" * 64)
        self.assertEqual(status, 403)

    def test_rejects_non_admin_user(self):
        """token 对但登录名不在管理员白名单——普通员工不能管理员工。"""
        status, _ = self.call("GET", "/admin/api/users", user="zhangsan")
        self.assertEqual(status, 403)

    def test_rejects_missing_remote_user(self):
        status, _ = self.call("GET", "/admin/api/users", user=None)
        self.assertEqual(status, 403)

    def test_second_admin_allowed(self):
        status, _ = self.call("GET", "/admin/api/health", user="boss")
        self.assertEqual(status, 200)

    # ---------------- 生命周期 ----------------
    def test_full_lifecycle(self):
        status, health = self.call("GET", "/admin/api/health")
        self.assertEqual(status, 200)
        self.assertTrue(health["sandbox_ok"])

        status, created = self.call("POST", "/admin/api/users", {
            "username": "wang_er", "name": "王二", "department": "研发部", "role": "员工"})
        self.assertEqual(status, 201, created)
        self.assertEqual(len(created["initial_password"]), 14)
        self.assertGreaterEqual(created["port"], core.PORT_BASE)
        self.assertLessEqual(created["port"], core.PORT_MAX)

        status, listing = self.call("GET", "/admin/api/users")
        self.assertEqual(status, 200)
        row = next(u for u in listing["users"] if u["username"] == "wang_er")
        self.assertTrue(row["healthy"], row["status"])

        status, updated = self.call("PATCH", "/admin/api/users/wang_er", {"role": "主管"})
        self.assertEqual(status, 200)
        self.assertEqual(updated["role"], "主管")
        self.assertTrue(self.fb.users["wang_er"]["permissions"]["delete"])

        status, pw = self.call("POST", "/admin/api/users/wang_er/password", {})
        self.assertEqual(status, 200)
        self.assertEqual(len(pw["password"]), 14)

        status, inst = self.call("POST", "/admin/api/users/wang_er/instance", {"running": False})
        self.assertEqual(status, 200)
        self.assertFalse(inst["running"])

        status, deleted = self.call("DELETE", "/admin/api/users/wang_er?delete_files=1")
        self.assertEqual(status, 200)
        self.assertTrue(all(v == "ok" for v in deleted["steps"].values()), deleted["steps"])

        status, listing = self.call("GET", "/admin/api/users")
        self.assertEqual([u for u in listing["users"] if u["username"] == "wang_er"], [])

    # ---------------- 错误处理 ----------------
    def test_invalid_input_returns_400_not_500(self):
        status, body = self.call("POST", "/admin/api/users", {
            "username": 'evil"; return 403; #', "name": "X", "department": "Y", "role": "员工"})
        self.assertEqual(status, 400)
        self.assertIn("用户名", body["error"])

    def test_unknown_route_404(self):
        status, _ = self.call("GET", "/admin/api/nope")
        self.assertEqual(status, 404)

    def test_path_traversal_on_static_blocked(self):
        status, _ = self.call("GET", "/admin/../../etc/passwd")
        self.assertIn(status, (403, 404))

    def test_static_index_served(self):
        url = f"http://127.0.0.1:{self.port}/admin/"
        req = urllib.request.Request(url, headers={
            "X-Admin-Token": app.ADMIN_TOKEN, "Remote-User": "admin"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            self.assertEqual(resp.status, 200)
            self.assertIn("员工管理", resp.read().decode())

    def test_audit_log_written(self):
        self.call("POST", "/admin/api/users", {
            "username": "audit_me", "name": "审计", "department": "研发部", "role": "员工"})
        lines = Path(os.environ["ADMIN_AUDIT_LOG"]).read_text(encoding="utf-8").strip().splitlines()
        entry = json.loads(lines[-1])
        self.assertEqual(entry["action"], "create_user")
        self.assertEqual(entry["actor"], "admin")
        self.assertNotIn("initial_password", entry["detail"], "审计日志不得记录明文密码")


if __name__ == "__main__":
    unittest.main(verbosity=2)
