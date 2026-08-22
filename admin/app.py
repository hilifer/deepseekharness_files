#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
员工管理后台 —— JSON API + 静态页面。

只用 Python 标准库（目标服务器是 rootless 容器，不保证能装第三方包）。
绑定 127.0.0.1，公网访问一律经 nginx，由 nginx 完成 Authelia 鉴权。

鉴权是两道，缺一不可：
  1. X-Admin-Token —— nginx 注入的共享密钥，值存在 admin/.admin-token（600）。
     这道是给沙箱里的 dsh 用的：沙箱共享宿主网络命名空间，能连到
     127.0.0.1 上的任何服务，但读不到宿主文件系统上的密钥文件，
     所以拿不到这个 token，也就调不动本 API。
  2. Remote-User —— Authelia 认证后的登录名，必须在管理员白名单里。
"""
from __future__ import annotations

import json
import os
import re
import secrets
import sys
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core import Config, Engine, ProvisionError  # noqa: E402

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
TOKEN_FILE = Path(os.environ.get("ADMIN_TOKEN_FILE", HERE / ".admin-token"))
AUDIT_LOG = Path(os.environ.get("ADMIN_AUDIT_LOG", HERE / "audit.log"))
ADMIN_USERS = {u for u in os.environ.get("ADMIN_USERS", "admin").split(",") if u.strip()}
LISTEN_HOST = os.environ.get("ADMIN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("ADMIN_PORT", "19200"))

ENGINE = Engine(Config.from_env())


def load_or_create_token() -> str:
    if TOKEN_FILE.exists():
        tok = TOKEN_FILE.read_text(encoding="utf-8").strip()
        if tok:
            return tok
    tok = secrets.token_hex(32)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(tok + "\n", encoding="utf-8")
    os.chmod(TOKEN_FILE, 0o600)
    return tok


ADMIN_TOKEN = load_or_create_token()


def audit(actor: str, action: str, detail: dict) -> None:
    AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "actor": actor, "action": action, "detail": detail,
    }
    with open(AUDIT_LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


USERNAME_PATH = re.compile(r"^/admin/api/users/([A-Za-z0-9_]{1,32})(/[a-z]+)?$")


class Handler(BaseHTTPRequestHandler):
    server_version = "dsh-admin"

    # ---------------- 基础工具 ----------------
    def _send(self, status: int, body: bytes, ctype: str = "application/json; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        if length > 1_000_000:
            raise ProvisionError("请求体过大")
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as exc:
            raise ProvisionError(f"请求体不是合法 JSON: {exc}") from exc

    def _actor(self) -> str | None:
        """两道校验都过了才返回登录名，否则 None。"""
        supplied = self.headers.get("X-Admin-Token", "")
        if not secrets.compare_digest(supplied, ADMIN_TOKEN):
            return None
        user = (self.headers.get("Remote-User") or "").strip()
        return user if user in ADMIN_USERS else None

    def log_message(self, fmt, *args):
        sys.stderr.write("[admin] %s - %s\n" % (self.address_string(), fmt % args))

    # ---------------- 路由 ----------------
    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def _dispatch(self, method: str):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/admin"
        query = parse_qs(parsed.query)

        # 静态页面同样要求登录（nginx 已挡了一层，这里是纵深防御）
        actor = self._actor()
        if actor is None:
            self._json(403, {"error": "无权访问管理后台（需要管理员身份且经由 nginx 访问）"})
            return

        try:
            if not path.startswith("/admin/api"):
                self._serve_static(path)
                return
            self._api(method, path, query, actor)
        except ProvisionError as exc:
            self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            self._json(500, {"error": f"内部错误: {exc}"})

    def _serve_static(self, path: str):
        rel = "index.html" if path in ("/admin", "/admin/index.html") else path[len("/admin/"):]
        target = (STATIC / rel).resolve()
        if not str(target).startswith(str(STATIC.resolve())) or not target.is_file():
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        ctype = {"html": "text/html; charset=utf-8", "js": "application/javascript; charset=utf-8",
                 "css": "text/css; charset=utf-8"}.get(target.suffix.lstrip("."), "application/octet-stream")
        self._send(200, target.read_bytes(), ctype)

    def _api(self, method: str, path: str, query: dict, actor: str):
        if path == "/admin/api/health" and method == "GET":
            ok, detail = ENGINE.sandbox_available()
            self._json(200, {"sandbox_ok": ok, "sandbox_detail": detail,
                             "backend": ENGINE.isolation_backend(),
                             "admin_users": sorted(ADMIN_USERS), "actor": actor})
            return

        if path == "/admin/api/users":
            if method == "GET":
                self._json(200, {"users": ENGINE.list_users()})
                return
            if method == "POST":
                body = self._body()
                res = ENGINE.create_user(
                    body.get("username", ""), body.get("name", ""),
                    body.get("department", ""), body.get("role", ""),
                    password=body.get("password") or None)
                audit(actor, "create_user", {k: v for k, v in res.items() if k != "initial_password"})
                self._json(201, res)
                return

        match = USERNAME_PATH.match(path)
        if match:
            username, sub = match.group(1), (match.group(2) or "")
            if sub == "" and method == "PATCH":
                body = self._body()
                res = ENGINE.update_user(
                    username, name=body.get("name"), department=body.get("department"),
                    role=body.get("role"), move_files=bool(body.get("move_files", True)))
                audit(actor, "update_user", res)
                self._json(200, res)
                return
            if sub == "" and method == "DELETE":
                delete_files = (query.get("delete_files", ["0"])[0] == "1")
                res = ENGINE.delete_user(username, delete_files=delete_files)
                audit(actor, "delete_user", res)
                self._json(200, res)
                return
            if sub == "/password" and method == "POST":
                res = ENGINE.reset_password(username, self._body().get("password") or None)
                audit(actor, "reset_password", {"username": username})
                self._json(200, res)
                return
            if sub == "/instance" and method == "POST":
                running = bool(self._body().get("running"))
                res = ENGINE.set_instance(username, running)
                audit(actor, "set_instance", res)
                self._json(200, res)
                return

        self._json(404, {"error": f"未知接口: {method} {path}"})


def main():
    if LISTEN_HOST not in ("127.0.0.1", "localhost", "::1"):
        print(f"[admin] 拒绝启动：ADMIN_HOST={LISTEN_HOST}，管理后台只允许绑定回环地址",
              file=sys.stderr)
        sys.exit(1)
    ok, detail = ENGINE.sandbox_available()
    print(f"[admin] 隔离自检: {'可用' if ok else '不可用'} — {detail}", file=sys.stderr)
    if not ok:
        print("[admin] 警告：挑不出隔离后端时将拒绝建号。"
              "逐项原因: dsh-runtime/dsh-sandbox.sh --report", file=sys.stderr)
    print(f"[admin] 监听 http://{LISTEN_HOST}:{LISTEN_PORT}/admin/  管理员={sorted(ADMIN_USERS)}",
          file=sys.stderr)
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
