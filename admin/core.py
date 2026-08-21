#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
员工全生命周期引擎 —— 增删改的唯一实现。

管理后台 (app.py) 和命令行 (scripts/provision-user.sh) 都调用这里，
避免两套实现漂移。一次建号要同时落地四个子系统：

    Authelia      登录凭据      users_database.yml
    nginx         用户 -> 端口   nginx.conf 的 map $user $dsh_upstream
    FileBrowser   scope + 权限   database.db（走 HTTP API）
    dsh           实例 + 工作区  registry.json + 沙箱进程

registry.json 是这四者的权威登记表。特别重要的是它取代了原先
start-all.sh 从 `$DSH_HOME/storages/workspace.json` 推导钳制根的做法——
那个文件是 dsh 实例自己（也就是被约束方）在写的，用户删光工作区就能
让推导结果为空，进而拿到不设限的实例。约束的依据不能由被约束方提供。
"""
from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import string
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

# --------------------------------------------------------------------------
# 常量与校验
# --------------------------------------------------------------------------
ROLE_STAFF = "员工"
ROLE_LEAD = "主管"
ROLES = (ROLE_STAFF, ROLE_LEAD)

# 用户名会被拼进 YAML 键、nginx 配置、进程命令行和文件路径。
# 原 provision-user.sh 未做任何校验，含引号/分号/换行的输入可以破坏
# users_database.yml、注入 nginx 指令。这里用白名单一次性堵死。
USERNAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,31}$")

# 姓名/部门会成为目录名并进入 YAML 字符串。禁掉路径分隔符、控制字符、
# 引号和会被 YAML 特殊解释的前导字符。
_LABEL_FORBIDDEN = set('/\\:*?"\'<>|`$\r\n\t\x00')
RESERVED_USERNAMES = {"admin", "root", "default", "nobody", "system", "authelia", "filebrowser"}

PORT_BASE = 13101
PORT_MAX = 13999


class ProvisionError(Exception):
    """建号流程中的可预期错误，会被后台原样展示给管理员。"""


def validate_username(value: str) -> str:
    value = (value or "").strip()
    if not USERNAME_RE.match(value):
        raise ProvisionError(
            "用户名必须是小写字母开头、由小写字母/数字/下划线组成的 2-32 位字符串"
            f"（收到: {value!r}）"
        )
    if value in RESERVED_USERNAMES:
        raise ProvisionError(f"用户名 {value!r} 是保留名，不能使用")
    return value


def validate_label(value: str, field_name: str) -> str:
    value = (value or "").strip()
    if not value:
        raise ProvisionError(f"{field_name}不能为空")
    if len(value) > 32:
        raise ProvisionError(f"{field_name}不能超过 32 个字符")
    bad = _LABEL_FORBIDDEN & set(value)
    if bad:
        raise ProvisionError(f"{field_name}不能包含这些字符: {''.join(sorted(bad))}")
    if value in (".", "..") or value.startswith("-"):
        raise ProvisionError(f"{field_name}不合法: {value!r}")
    return value


def validate_role(value: str) -> str:
    value = (value or "").strip()
    if value not in ROLES:
        raise ProvisionError(f"角色必须是 {ROLE_STAFF} 或 {ROLE_LEAD}（收到: {value!r}）")
    return value


def generate_password(length: int = 14) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


# --------------------------------------------------------------------------
# users_database.yml 的读写
#
# 不依赖 PyYAML（目标服务器不保证装了）。这个文件的结构完全由我们自己
# 生成，是固定的两层映射，所以用一个针对性的解析器 + 全量重写，
# 比行内 grep/append（原做法）安全得多。
# --------------------------------------------------------------------------
_YAML_HEADER = """\
# Authelia 用户库 —— 由管理后台 (admin/core.py) 自动生成，请勿手工编辑。
# 手工改动会在下一次建号/改号时被覆盖。
# 生成 argon2 哈希: authelia crypto hash generate argon2 --password '...'
"""


def _yaml_unquote(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
        inner = raw[1:-1]
        return inner.replace("''", "'") if raw[0] == "'" else inner
    return raw


def _yaml_quote(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def parse_users_yaml(text: str) -> dict[str, dict[str, Any]]:
    """解析 users_database.yml，返回 {username: {field: value}}。"""
    users: dict[str, dict[str, Any]] = {}
    current: str | None = None
    last_key: str | None = None
    in_users = False
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 0:
            in_users = stripped.rstrip(":") == "users" and stripped.endswith(":")
            current = None
            last_key = None
            continue
        if not in_users:
            continue
        if indent == 2 and stripped.endswith(":") and ": " not in stripped:
            current = stripped[:-1].strip()
            users[current] = {}
            last_key = None
            continue
        # 列表项（groups 的 `- xxx`）：接到上一个空值键上
        if indent >= 4 and current is not None and stripped.startswith("- "):
            if last_key is not None:
                users[current].setdefault(last_key, [])
                if isinstance(users[current][last_key], list):
                    users[current][last_key].append(_yaml_unquote(stripped[2:]))
            continue
        if indent >= 4 and current is not None and ":" in stripped:
            key, _, val = stripped.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "[]":
                users[current][key] = []
                last_key = None
            elif val:
                users[current][key] = _yaml_unquote(val)
                last_key = None
            else:
                # `groups:` 后面跟 `- xxx` 列表项
                users[current][key] = []
                last_key = key
    return users


def dump_users_yaml(users: dict[str, dict[str, Any]]) -> str:
    out = [_YAML_HEADER, "users:"]
    for username in sorted(users):
        rec = users[username]
        out.append(f"  {username}:")
        for key in ("displayname", "password", "email"):
            if key in rec:
                out.append(f"    {key}: {_yaml_quote(rec[key])}")
        groups = rec.get("groups") or []
        if groups:
            out.append("    groups:")
            out.extend(f"      - {_yaml_quote(g)}" for g in groups)
        else:
            out.append("    groups: []")
        for key, val in rec.items():
            if key not in ("displayname", "password", "email", "groups"):
                out.append(f"    {key}: {_yaml_quote(val)}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# 外部依赖的可注入封装（测试时打桩）
# --------------------------------------------------------------------------
class Runner:
    """子进程调用。测试用 FakeRunner 替换。"""

    def run(self, argv: list[str], *, env: dict | None = None, timeout: int = 60,
            check: bool = False, cwd: str | None = None) -> subprocess.CompletedProcess:
        full_env = {**os.environ, **(env or {})}
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                              check=check, env=full_env, cwd=cwd)

    def spawn(self, argv: list[str], *, logfile: Path, env: dict | None = None) -> int:
        full_env = {**os.environ, **(env or {})}
        logfile.parent.mkdir(parents=True, exist_ok=True)
        fh = open(logfile, "ab")
        proc = subprocess.Popen(argv, stdout=fh, stderr=fh, stdin=subprocess.DEVNULL,
                                start_new_session=True, env=full_env)
        return proc.pid

    def pgrep(self, pattern: str) -> list[int]:
        res = self.run(["pgrep", "-f", pattern], timeout=10)
        return [int(x) for x in res.stdout.split() if x.isdigit()]

    def pkill(self, pattern: str) -> None:
        self.run(["pkill", "-f", pattern], timeout=10)


class Http:
    """HTTP 调用（FileBrowser API / 健康检查）。测试用 FakeHttp 替换。"""

    def request(self, method: str, url: str, *, headers: dict | None = None,
                body: bytes | None = None, timeout: int = 15) -> tuple[int, bytes]:
        req = urllib.request.Request(url, method=method, data=body, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except Exception as exc:  # noqa: BLE001 - 网络错误统一成 0
            return 0, str(exc).encode()


def read_fb_proxy_header(root: Path) -> str:
    """读出 nginx 注入 FileBrowser 的那个「名字即密钥」的认证头。

    init-secrets.sh 会把头名随机化并同步到 filebrowser/config.yaml，之后
    FileBrowser 不再认 X-Forwarded-User。管理后台是直连 127.0.0.1:18080 调
    API 的（不经 nginx），所以必须自己读出同一个头名，否则全部请求 401。
    """
    generated = root / "nginx" / "conf" / "generated" / "fb-auth.conf"
    try:
        match = re.search(r"proxy_set_header\s+(\S+)\s", generated.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    except OSError:
        pass
    return "X-Forwarded-User"


# --------------------------------------------------------------------------
# 路径配置
# --------------------------------------------------------------------------
@dataclass
class Config:
    root: Path = Path("/home/ubuntu")
    fb_base: str = "http://127.0.0.1:18080/files"
    fb_source_name: str = "公司文件"
    fb_proxy_header: str = "X-Forwarded-User"
    authelia_health: str = "http://127.0.0.1:19091/api/health"
    trusted_hosts: str = "218.17.143.249:8099"
    # 网络隔离模式：每实例独立网络命名空间，入站走 unix socket，
    # 宿主回环上不再留 dsh 端口，员工之间无法互连实例。详见 dsh-sandbox.sh。
    netns: bool = False

    @property
    def files_root(self) -> Path: return self.root / "dsh-files"
    @property
    def departments(self) -> Path: return self.files_root / "departments"
    @property
    def users_root(self) -> Path: return self.root / "dsh-users"
    @property
    def registry(self) -> Path: return self.users_root / "registry.json"
    @property
    def legacy_ports(self) -> Path: return self.users_root / "ports.json"
    @property
    def auth_dir(self) -> Path: return self.root / "dsh-auth"
    @property
    def auth_bin(self) -> Path: return self.auth_dir / "authelia"
    @property
    def auth_users(self) -> Path: return self.auth_dir / "config" / "users_database.yml"
    @property
    def auth_start(self) -> Path: return self.auth_dir / "authelia-start.sh"
    @property
    def nginx_conf(self) -> Path: return self.root / "nginx" / "conf" / "nginx.conf"
    @property
    def nginx_bin(self) -> Path: return self.root / "nginx" / "extracted" / "usr" / "sbin" / "nginx"
    @property
    def sandbox_sh(self) -> Path: return self.root / "dsh-runtime" / "dsh-sandbox.sh"
    @property
    def shared_profiles(self) -> Path: return self.root / ".local" / "share" / "dsh" / "profiles"
    @property
    def socket_dir(self) -> Path: return self.root / "dsh-sockets"

    def upstream_for(self, username: str, port: int) -> str:
        """该用户在 nginx map 里的 upstream 值。"""
        if self.netns:
            # nginx 支持 proxy_pass http://$var，变量展开成 unix: 形式；
            # 已实测可行（含与 TCP 形式在同一张 map 里混用）。
            return f"unix:{self.socket_dir / username / 'dsh.sock'}:"
        return f"127.0.0.1:{port}"

    @classmethod
    def from_env(cls) -> "Config":
        root = Path(os.environ.get("DSH_ROOT", "/home/ubuntu"))
        return cls(
            root=root,
            fb_base=os.environ.get("FB_BASE", "http://127.0.0.1:18080/files"),
            fb_proxy_header=(os.environ.get("FB_PROXY_HEADER")
                             or read_fb_proxy_header(root)),
            trusted_hosts=os.environ.get("DSH_TRUSTED_HOSTS", "218.17.143.249:8099"),
            netns=os.environ.get("DSH_NETNS", "0") == "1",
        )


# --------------------------------------------------------------------------
# 引擎
# --------------------------------------------------------------------------
class Engine:
    def __init__(self, cfg: Config, runner: Runner | None = None, http: Http | None = None):
        self.cfg = cfg
        self.run = runner or Runner()
        self.http = http or Http()

    # ---------------- registry ----------------
    def load_registry(self) -> dict:
        path = self.cfg.registry
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if "users" in data:
                return data
        # 首次运行：从旧的 ports.json 迁移
        data = {"version": 1, "users": {}}
        if self.cfg.legacy_ports.exists():
            try:
                ports = json.loads(self.cfg.legacy_ports.read_text(encoding="utf-8"))
            except Exception:
                ports = {}
            for username, port in ports.items():
                data["users"][username] = {
                    "username": username, "name": username, "department": "未分配",
                    "role": ROLE_STAFF, "port": int(port),
                    "workspace": "", "migrated_from_ports_json": True,
                    "created_at": _now(), "updated_at": _now(),
                }
        return data

    def save_registry(self, data: dict) -> None:
        self.cfg.users_root.mkdir(parents=True, exist_ok=True)
        _atomic_write(self.cfg.registry, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        # start-all.sh 之外可能还有别的东西读 ports.json，保持同步
        ports = {u: r["port"] for u, r in data["users"].items()}
        _atomic_write(self.cfg.legacy_ports, json.dumps(ports, ensure_ascii=False, indent=2) + "\n")

    def _alloc_port(self, reg: dict) -> int:
        used = {r["port"] for r in reg["users"].values()}
        for port in range(PORT_BASE, PORT_MAX + 1):
            if port not in used:
                return port
        raise ProvisionError(f"端口池已耗尽（{PORT_BASE}-{PORT_MAX}）")

    def workspace_for(self, department: str, name: str) -> Path:
        return self.cfg.departments / department / name

    # ---------------- Authelia ----------------
    def _read_auth_users(self) -> dict:
        path = self.cfg.auth_users
        return parse_users_yaml(path.read_text(encoding="utf-8")) if path.exists() else {}

    def _write_auth_users(self, users: dict) -> None:
        path = self.cfg.auth_users
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            backup = path.with_suffix(f".yml.bak.{int(time.time())}")
            shutil.copy2(path, backup)
            _prune_backups(path.parent, path.name + ".bak.", keep=10)
        _atomic_write(path, dump_users_yaml(users), mode=0o600)

    def _argon2_hash(self, password: str) -> str:
        res = self.run.run([str(self.cfg.auth_bin), "crypto", "hash", "generate", "argon2",
                            "--password", password, "--no-confirm"],
                           cwd=str(self.cfg.auth_dir), timeout=60)
        for line in res.stdout.splitlines():
            if line.startswith("Digest: "):
                return line[len("Digest: "):].strip()
        raise ProvisionError(f"argon2 哈希生成失败: {res.stderr.strip() or res.stdout.strip()}")

    def _restart_authelia(self) -> None:
        self.run.run([str(self.cfg.auth_start), "restart"], timeout=60)
        for _ in range(15):
            status, _body = self.http.request("GET", self.cfg.authelia_health, timeout=3)
            if status == 200:
                return
            time.sleep(1)
        raise ProvisionError("Authelia 重启后健康检查未通过，请查看 dsh-auth/authelia.log")

    # ---------------- FileBrowser ----------------
    def _fb(self, method: str, path: str, body: dict | None = None) -> tuple[int, bytes]:
        headers = {self.cfg.fb_proxy_header: "admin"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        return self.http.request(method, f"{self.cfg.fb_base}{path}", headers=headers, body=data)

    def _fb_users(self) -> list[dict]:
        status, body = self._fb("GET", "/api/users")
        if status != 200:
            raise ProvisionError(f"FileBrowser 用户列表读取失败 (HTTP {status}): {body[:200]!r}")
        return json.loads(body or b"[]")

    def _fb_apply(self, username: str, department: str, name: str, role: str) -> None:
        """设置 scope 与权限。主管 = 整个部门可删；员工 = 仅个人目录不可删。"""
        if role == ROLE_LEAD:
            scope, can_delete = f"/departments/{department}", True
        else:
            scope, can_delete = f"/departments/{department}/{name}", False

        users = self._fb_users()
        match = [u for u in users if u.get("username") == username]
        if not match:
            raise ProvisionError(f"FileBrowser 中不存在用户 {username}")
        user = match[0]
        user["loginMethod"] = "proxy"   # CLI 建的用户默认 password，proxy auth 下会全量 401
        user["scopes"] = [{"name": self.cfg.fb_source_name, "scope": scope}]
        # 必须提交完整 permissions 对象：缺字段会被重置为 false（尤其 delete）
        user["permissions"] = {
            "api": True,        # 为 false 会阻断 Web UI 的全部 API
            "admin": False,
            "modify": True,
            "share": False,
            "realtime": True,
            "delete": can_delete,
            "create": True,
            "download": True,
        }
        status, body = self._fb("PUT", f"/api/users?username={username}",
                                {"which": ["scopes", "permissions", "loginMethod"], "data": user})
        if status not in (200, 201, 204):
            raise ProvisionError(f"FileBrowser 权限设置失败 (HTTP {status}): {body[:200]!r}")

    def _fb_create(self, username: str) -> None:
        """先试 API 建号；该版本若不支持，回退到 CLI（会短暂停服，原做法如此）。"""
        status, body = self._fb("POST", "/api/users", {
            "which": ["all"],
            "data": {"username": username, "password": generate_password(20),
                     "loginMethod": "proxy", "scopes": [], "permissions": {}},
        })
        if status in (200, 201):
            return
        api_err = f"HTTP {status}: {body[:160]!r}"

        fb_dir = self.cfg.root / "filebrowser"
        fb_start = self.cfg.root / "scripts" / "fb-start.sh"
        self.run.run([str(fb_start), "stop"], timeout=30)
        time.sleep(1)
        try:
            res = self.run.run(
                [str(fb_dir / "filebrowser"), "set", "-u",
                 f"{username},{generate_password(20)}", "-c", str(fb_dir / "config.yaml")],
                cwd=str(fb_dir), timeout=60)
        finally:
            self.run.run([str(fb_start), "start"], timeout=60)
            time.sleep(1)
        if res.returncode != 0:
            raise ProvisionError(
                f"FileBrowser 建号失败。API 方式: {api_err}；"
                f"CLI 方式: {(res.stderr or res.stdout).strip()[:200]}")

    def _fb_delete(self, username: str) -> None:
        self._fb("DELETE", f"/api/users?username={username}")

    # ---------------- nginx ----------------
    _MAP_RE = re.compile(r"(map \$user \$dsh_upstream \{)(.*?)(\n\s*\})", re.S)

    def _nginx_write_routes(self, routes: dict[str, int]) -> None:
        path = self.cfg.nginx_conf
        text = path.read_text(encoding="utf-8")
        match = self._MAP_RE.search(text)
        if not match:
            raise ProvisionError("nginx.conf 中未找到 `map $user $dsh_upstream` 块")
        # default 始终保持 TCP 黑洞：未匹配的用户要的是 403，
        # 而不是 unix socket 不存在导致的 502。
        lines = ["\n        default     127.0.0.1:13100;"]
        if "admin" not in routes:
            lines.append(f'\n        "admin"     {self.cfg.upstream_for("admin", 3080)};')
        for username in sorted(routes):
            lines.append(f'\n        "{username}"  {self.cfg.upstream_for(username, routes[username])};')
        new_text = text[:match.start(2)] + "".join(lines) + text[match.end(2):]
        _atomic_write(path, new_text)

    def _nginx_reload(self) -> None:
        test = self.run.run([str(self.cfg.nginx_bin), "-t", "-c", str(self.cfg.nginx_conf)], timeout=30)
        if test.returncode != 0:
            raise ProvisionError(f"nginx 配置校验失败: {test.stderr.strip()[:400]}")
        reload_res = self.run.run([str(self.cfg.nginx_bin), "-s", "reload",
                                   "-c", str(self.cfg.nginx_conf)], timeout=30)
        if reload_res.returncode != 0:
            raise ProvisionError(f"nginx reload 失败: {reload_res.stderr.strip()[:400]}")

    def sync_nginx(self, reg: dict | None = None) -> None:
        reg = reg or self.load_registry()
        self._nginx_write_routes({u: r["port"] for u, r in reg["users"].items()})
        self._nginx_reload()

    # ---------------- dsh 实例 ----------------
    def _dsh_pattern(self, port: int) -> str:
        return f"dsh web --port {port} "

    def dsh_running(self, port: int) -> bool:
        return bool(self.run.pgrep(self._dsh_pattern(port)))

    def dsh_stop(self, port: int) -> None:
        self.run.pkill(self._dsh_pattern(port))

    def dsh_start(self, username: str, rec: dict) -> None:
        port = rec["port"]
        if self.dsh_running(port):
            return
        dsh_home = self.cfg.users_root / username
        workspace = Path(rec["workspace"])
        if not workspace.is_dir():
            raise ProvisionError(f"工作区不存在，拒绝启动实例: {workspace}")
        dsh_home.mkdir(parents=True, exist_ok=True)
        self.run.spawn(
            [str(self.cfg.sandbox_sh), username, str(port), str(dsh_home), str(workspace)],
            logfile=dsh_home / "dsh.log",
            env={"DSH_ROOT": str(self.cfg.root),
                 "DSH_TRUSTED_HOSTS": self.cfg.trusted_hosts,
                 "DSH_NETNS": "1" if self.cfg.netns else "0"},
        )

    def dsh_restart(self, username: str, rec: dict) -> None:
        self.dsh_stop(rec["port"])
        time.sleep(1)
        self.dsh_start(username, rec)

    def sandbox_available(self) -> tuple[bool, str]:
        res = self.run.run([str(self.cfg.sandbox_sh), "--check"], timeout=30,
                           env={"DSH_NETNS": "1" if self.cfg.netns else "0",
                                "DSH_ROOT": str(self.cfg.root)})
        return res.returncode == 0, (res.stdout or res.stderr).strip()

    # ---------------- DSH_HOME 播种 ----------------
    def _seed_dsh_home(self, username: str, name: str, workspace: Path) -> None:
        dsh_home = self.cfg.users_root / username
        (dsh_home / "storages").mkdir(parents=True, exist_ok=True)
        profiles = dsh_home / "profiles"
        if not profiles.exists() and self.cfg.shared_profiles.exists():
            try:
                profiles.symlink_to(self.cfg.shared_profiles)
            except OSError:
                shutil.copytree(self.cfg.shared_profiles, profiles)
        ws_file = dsh_home / "storages" / "workspace.json"
        if not ws_file.exists():
            wsid = secrets.token_hex(16)
            now = _now()
            ws_file.write_text(json.dumps({
                "unit": {"name": "workspace", "version": 2},
                "global": {"initialized": True, "workspaceIds": [wsid], "archivedSessionIds": []},
                "tables": {"workspaces": {wsid: {
                    "path": str(workspace), "title": name, "sessionIds": [],
                    "createdAt": now, "updatedAt": now}}},
            }, ensure_ascii=False, indent=2), encoding="utf-8")

    # ======================================================================
    # 对外接口
    # ======================================================================
    def list_users(self, *, with_status: bool = True) -> list[dict]:
        reg = self.load_registry()
        auth_users = self._read_auth_users() if self.cfg.auth_users.exists() else {}
        nginx_text = self.cfg.nginx_conf.read_text(encoding="utf-8") if self.cfg.nginx_conf.exists() else ""
        fb_names: set[str] = set()
        if with_status:
            try:
                fb_names = {u.get("username") for u in self._fb_users()}
            except ProvisionError:
                fb_names = set()

        out = []
        for username, rec in sorted(reg["users"].items()):
            row = dict(rec)
            if with_status:
                row["status"] = {
                    "authelia": username in auth_users,
                    "nginx": f'"{username}"' in nginx_text,
                    "filebrowser": username in fb_names,
                    "dsh": self.dsh_running(rec["port"]),
                    "workspace": bool(rec.get("workspace")) and Path(rec["workspace"]).is_dir(),
                }
                row["healthy"] = all(row["status"].values())
            out.append(row)
        return out

    def create_user(self, username: str, name: str, department: str, role: str,
                    password: str | None = None) -> dict:
        username = validate_username(username)
        name = validate_label(name, "姓名")
        department = validate_label(department, "部门")
        role = validate_role(role)

        reg = self.load_registry()
        if username in reg["users"]:
            raise ProvisionError(f"用户 {username} 已存在")

        ok, detail = self.sandbox_available()
        if not ok:
            raise ProvisionError(
                f"沙箱不可用，拒绝建号（否则新实例将不受隔离）: {detail}\n"
                "请先运行 scripts/install-bubblewrap.sh 并用 scripts/preflight-sandbox.sh 验证。")

        password = password or generate_password()
        workspace = self.workspace_for(department, name)
        port = self._alloc_port(reg)

        workspace.mkdir(parents=True, exist_ok=True)

        auth_users = self._read_auth_users()
        auth_users[username] = {
            "displayname": f"{name}（{department}{role}）",
            "password": self._argon2_hash(password),
            "email": f"{username}@company.local",
            "groups": [],
        }
        self._write_auth_users(auth_users)
        self._restart_authelia()

        if username not in {u.get("username") for u in self._fb_users()}:
            self._fb_create(username)
        self._fb_apply(username, department, name, role)

        rec = {
            "username": username, "name": name, "department": department, "role": role,
            "port": port, "workspace": str(workspace),
            "created_at": _now(), "updated_at": _now(),
        }
        reg["users"][username] = rec
        self.save_registry(reg)

        self._seed_dsh_home(username, name, workspace)
        self.sync_nginx(reg)
        self.dsh_start(username, rec)

        return {**rec, "initial_password": password}

    def update_user(self, username: str, *, name: str | None = None,
                    department: str | None = None, role: str | None = None,
                    move_files: bool = True) -> dict:
        username = validate_username(username)
        reg = self.load_registry()
        rec = reg["users"].get(username)
        if not rec:
            raise ProvisionError(f"用户 {username} 不存在")

        new_name = validate_label(name, "姓名") if name is not None else rec["name"]
        new_dept = validate_label(department, "部门") if department is not None else rec["department"]
        new_role = validate_role(role) if role is not None else rec["role"]

        old_ws = Path(rec["workspace"]) if rec.get("workspace") else None
        new_ws = self.workspace_for(new_dept, new_name)
        path_changed = old_ws is not None and old_ws != new_ws

        if path_changed and move_files:
            if new_ws.exists():
                raise ProvisionError(f"目标目录已存在，拒绝覆盖: {new_ws}")
            new_ws.parent.mkdir(parents=True, exist_ok=True)
            if old_ws.exists():
                shutil.move(str(old_ws), str(new_ws))
            else:
                new_ws.mkdir(parents=True, exist_ok=True)
        elif path_changed:
            new_ws.mkdir(parents=True, exist_ok=True)
        else:
            new_ws.mkdir(parents=True, exist_ok=True)

        if (new_name, new_dept, new_role) != (rec["name"], rec["department"], rec["role"]):
            auth_users = self._read_auth_users()
            if username in auth_users:
                auth_users[username]["displayname"] = f"{new_name}（{new_dept}{new_role}）"
                self._write_auth_users(auth_users)
                self._restart_authelia()

        self._fb_apply(username, new_dept, new_name, new_role)

        rec.update({"name": new_name, "department": new_dept, "role": new_role,
                    "workspace": str(new_ws), "updated_at": _now()})
        self.save_registry(reg)

        if path_changed:
            # 工作区路径变了：workspace.json 与沙箱挂载点都要跟着换，必须重启实例。
            ws_file = self.cfg.users_root / username / "storages" / "workspace.json"
            if ws_file.exists():
                ws_file.unlink()
            self._seed_dsh_home(username, new_name, new_ws)
            self.dsh_restart(username, rec)

        return rec

    def reset_password(self, username: str, password: str | None = None) -> dict:
        username = validate_username(username)
        reg = self.load_registry()
        if username not in reg["users"]:
            raise ProvisionError(f"用户 {username} 不存在")
        password = password or generate_password()
        auth_users = self._read_auth_users()
        if username not in auth_users:
            raise ProvisionError(f"Authelia 中不存在用户 {username}")
        auth_users[username]["password"] = self._argon2_hash(password)
        self._write_auth_users(auth_users)
        self._restart_authelia()
        return {"username": username, "password": password}

    def delete_user(self, username: str, *, delete_files: bool = False) -> dict:
        username = validate_username(username)
        reg = self.load_registry()
        rec = reg["users"].get(username)
        if not rec:
            raise ProvisionError(f"用户 {username} 不存在")

        report: dict[str, Any] = {"username": username, "steps": {}}

        def step(key, fn):
            try:
                fn()
                report["steps"][key] = "ok"
            except Exception as exc:  # noqa: BLE001 - 销号要尽量走完所有步骤
                report["steps"][key] = f"失败: {exc}"

        step("停止 dsh 实例", lambda: self.dsh_stop(rec["port"]))

        def _drop_auth():
            auth_users = self._read_auth_users()
            if auth_users.pop(username, None) is not None:
                self._write_auth_users(auth_users)
                self._restart_authelia()
        step("移除 Authelia 账号", _drop_auth)
        step("移除 FileBrowser 用户", lambda: self._fb_delete(username))

        reg["users"].pop(username, None)
        self.save_registry(reg)
        report["steps"]["移除登记表"] = "ok"
        step("更新 nginx 路由", lambda: self.sync_nginx(reg))

        def _drop_home():
            home = self.cfg.users_root / username
            if home.exists():
                shutil.rmtree(home)
        step("删除 DSH_HOME", _drop_home)

        if delete_files:
            def _drop_files():
                ws = Path(rec["workspace"])
                if ws.exists():
                    shutil.rmtree(ws)
            step("删除工作区文件", _drop_files)
            report["files"] = "已删除"
        else:
            report["files"] = f"已保留: {rec.get('workspace')}"

        return report

    def set_instance(self, username: str, running: bool) -> dict:
        reg = self.load_registry()
        rec = reg["users"].get(username)
        if not rec:
            raise ProvisionError(f"用户 {username} 不存在")
        if running:
            self.dsh_start(username, rec)
        else:
            self.dsh_stop(rec["port"])
        time.sleep(1)
        return {"username": username, "running": self.dsh_running(rec["port"])}


def _atomic_write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def _prune_backups(directory: Path, prefix: str, keep: int) -> None:
    backups = sorted(directory.glob(prefix + "*"))
    for old in backups[:-keep]:
        try:
            old.unlink()
        except OSError:
            pass
