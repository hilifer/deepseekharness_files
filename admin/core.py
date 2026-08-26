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

# 内置管理员账号：不在员工登记表里，空间是整个文件根
ADMIN_USERNAME = "admin"

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


MOUNT_MODES = ("ro", "rw")


def validate_mount(root_dir: Path, path: str, mode: str) -> dict:
    """校验一条额外挂载。

    这是管理后台能写进沙箱的东西，等于把宿主上的一段文件系统交给员工的
    agent，所以校验必须严：绝对路径、解析符号链接后仍在文件根之内、
    真实存在、模式只能是 ro/rw。少一条都可能被用来把 /etc 或别人的
    DSH_HOME 挂进沙箱。
    """
    mode = (mode or "ro").strip().lower()
    if mode not in MOUNT_MODES:
        raise ProvisionError(f"挂载模式只能是 ro 或 rw（收到: {mode!r}）")
    raw = (path or "").strip()
    if not raw.startswith("/"):
        raise ProvisionError(f"挂载路径必须是绝对路径: {raw!r}")
    try:
        resolved = Path(raw).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ProvisionError(f"挂载路径不存在或无法解析: {raw}（{exc}）") from exc
    if not resolved.is_dir():
        raise ProvisionError(f"挂载路径必须是目录: {resolved}")
    files_root = root_dir.resolve()
    # 解析符号链接之后再比较，否则 dsh-files 里放个指向 / 的链接就穿透了
    if resolved != files_root and files_root not in resolved.parents:
        raise ProvisionError(
            f"挂载路径必须位于 {files_root} 之内（解析后为 {resolved}）")
    return {"path": str(resolved), "mode": mode}


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
    # 三个入口域全填：公网 IP 是云 NAT，本机与局域网访问只认后两个
    trusted_hosts: str = "218.17.143.249:8099 192.168.1.225:8099 127.0.0.1:8099"
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
            trusted_hosts=os.environ.get(
                "DSH_TRUSTED_HOSTS",
                "218.17.143.249:8099 192.168.1.225:8099 127.0.0.1:8099"),
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
                rec = {
                    "username": username, "name": username, "department": "未分配",
                    "role": ROLE_STAFF, "port": int(port), "workspace": "", "mounts": [],
                    "migrated_from_ports_json": True,
                    "created_at": _now(), "updated_at": _now(),
                }
                rec.update(self._recover_from_legacy_workspace(username))
                data["users"][username] = rec
        return data

    def _recover_from_legacy_workspace(self, username: str) -> dict:
        """迁移老用户时，从其 storages/workspace.json 恢复工作区与部门/姓名。

        ports.json 只有 username -> port，没有工作区路径。早先迁移直接留空，
        结果 start-all.sh 见空即跳过，所有老员工的实例全部拒启——运维只能
        手工把整张登记表补出来。老实例自己的 workspace.json 里恰好有这个路径，
        这是迁移时唯一可靠的来源。

        注意这和「运行时从用户可写文件推导钳制根」是两回事：那个是每次启动
        都信任被约束方写的数据，这个是一次性把历史数据搬进管理侧登记表，
        搬完就以登记表为准。恢复不出来也不猜，留空由管理员在后台补。
        """
        ws_file = self.cfg.users_root / username / "storages" / "workspace.json"
        try:
            doc = json.loads(ws_file.read_text(encoding="utf-8"))
            ids = doc["global"]["workspaceIds"]
            entry = doc["tables"]["workspaces"][ids[0]]
            path = Path(entry["path"])
        except Exception:
            return {}
        if not path.is_absolute():
            return {}

        # workspace.json 在员工【自己可写】的 DSH_HOME 里，是被约束方能改的数据。
        # 所以这里恢复出来的路径必须先证明它落在 departments/<部门>[/<姓名>] 上；
        # 证明不了就整条丢弃，留空让管理员在后台补。
        #
        # 早先这里在 relative_to 抛 ValueError 时仍然 `return out`，等于把员工
        # 写进那个文件的【任意绝对路径】当成工作区收下。可达路径：员工在 dsh 里
        # 「添加工作区」指到 dsh-files 根，再赶上一次 registry.json 重建（恢复备份
        # 或首次迁移），全公司根目录就成了他的工作区——沙箱据此 rw 挂载、钳制根据此
        # 设定、FileBrowser scope 据此推导，三层一起放大。
        # 【未在现场发生过】：这是代码审计发现的潜在路径，不是事故复盘。
        try:
            rel = path.resolve().relative_to(self.cfg.departments.resolve()).parts
        except (ValueError, OSError):
            return {}
        out: dict[str, Any] = {"workspace": str(path)}
        if len(rel) == 2:
            out["department"], out["name"] = rel[0], rel[1]
        elif len(rel) == 1:
            # 工作区就是部门目录 -> 这是个主管
            out["department"], out["role"] = rel[0], ROLE_LEAD
        else:
            # 0 层（就是 departments 本身）或 3 层以上，都不是合法的空间形状
            return {}
        # title 只在路径已被证明合法之后才采信，否则等于让员工自选显示名
        if entry.get("title"):
            out["name"] = entry["title"]
        return out

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

    def space_for(self, department: str, name: str, role: str) -> Path:
        """该用户的空间——**唯一**的权威定义。

        三层：

          员工   -> departments/<部门>/<姓名>   只有自己的目录
          主管   -> departments/<部门>          整个部门
          admin  -> dsh-files                  整个公司（见 admin_space）

        FileBrowser 的 scope 和 dsh 沙箱的挂载都由它推导，两边不再各写一套。
        此前就漂过：FileBrowser 给了主管部门级 scope，dsh 侧却仍钳在个人
        目录，同一个人在文件服务器和工作台里看到的范围对不上。
        """
        if role == ROLE_LEAD:
            return self.cfg.departments / department
        return self.cfg.departments / department / name

    def admin_space(self) -> Path:
        """内置管理员的空间：整个文件根。

        start-all.sh 就是用这个路径拉起 admin 的 3080 实例的；
        FileBrowser 侧 adminUsername 天然拥有 source 全量访问。
        """
        return self.cfg.files_root

    def fb_scope_for(self, department: str, name: str, role: str) -> str:
        """space_for 的 FileBrowser 表示：相对 source 根的路径。"""
        space = self.space_for(department, name, role)
        return "/" + str(space.relative_to(self.cfg.files_root))

    def effective_mounts(self, rec: dict) -> list[dict]:
        """该用户的 dsh 实例除本人工作区外还应挂载的目录。

        主管自动获得整个部门目录（可写）——此前只有 FileBrowser 侧给了主管
        部门级 scope，dsh 侧却仍钳在个人目录，两边对不上。
        再加上管理员在后台为其单独配置的额外挂载。
        """
        mounts: list[dict] = []
        own = rec.get("workspace") or ""
        space = self.space_for(rec.get("department", ""), rec.get("name", ""),
                               rec.get("role", ROLE_STAFF))
        # 主管的空间是整个部门，比其个人工作区更大，要额外挂上去；
        # 员工的空间就等于个人工作区，这里不会多挂任何东西。
        if str(space) != own and space.is_dir():
            mounts.append({"path": str(space), "mode": "rw"})
        for m in rec.get("mounts") or []:
            mounts.append({"path": m["path"], "mode": m.get("mode", "ro")})
        # 已被本人工作区或部门目录覆盖的条目去掉，避免重复挂载
        seen: set[str] = {own}
        out = []
        for m in mounts:
            if m["path"] in seen:
                continue
            seen.add(m["path"])
            out.append(m)
        return out

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
        # scope 与 dsh 的挂载同源，见 space_for
        scope = self.fb_scope_for(department, name, role)
        can_delete = role == ROLE_LEAD

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
        self.run.run(["pkill", "-f", f"filebrowser -c {fb_dir / 'config.yaml'}"],
                      timeout=10)
        time.sleep(2)
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
        users = self._fb_users()
        match = [u for u in users if u.get("username") == username]
        if not match:
            return
        user_id = match[0].get("id")
        if user_id is None:
            raise ProvisionError(f"FileBrowser 用户 {username} 缺少 id 字段")
        status, body = self._fb("DELETE", f"/api/users?id={user_id}")
        if status not in (200, 204):
            raise ProvisionError(f"FileBrowser 删除用户失败 (HTTP {status}): {body[:200]!r}")

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

    @staticmethod
    def _encode_mounts(mounts: list[dict]) -> str:
        # 每行一条 "mode<TAB>path"：路径里可能有中文和空格，用制表符最稳
        return "\n".join(f"{m['mode']}\t{m['path']}" for m in mounts)

    def dsh_start(self, username: str, rec: dict) -> None:
        port = rec["port"]
        if self.dsh_running(port):
            return
        dsh_home = self.cfg.users_root / username
        workspace = Path(rec["workspace"])
        if not workspace.is_dir():
            raise ProvisionError(f"工作区不存在，拒绝启动实例: {workspace}")
        self._assert_workspace_contained(username, workspace)
        dsh_home.mkdir(parents=True, exist_ok=True)
        self.run.spawn(
            [str(self.cfg.sandbox_sh), username, str(port), str(dsh_home), str(workspace)],
            logfile=dsh_home / "dsh.log",
            env={"DSH_ROOT": str(self.cfg.root),
                 "DSH_TRUSTED_HOSTS": self.cfg.trusted_hosts,
                 "DSH_NETNS": "1" if self.cfg.netns else "0",
                 "DSH_EXTRA_MOUNTS": self._encode_mounts(self.effective_mounts(rec))},
        )

    def _assert_workspace_contained(self, username: str, workspace: Path) -> None:
        """工作区必须真落在 departments 之内——启动路径上的最后一道闸。

        登记表不是不可信的：它可能被手工改坏、被旧版本的迁移逻辑写脏、或从
        备份里恢复回来。这一条不看它写了什么，只看解析符号链接之后到底指向
        哪儿。挡不住就【不启动】，而不是带着一个指向全公司根目录的工作区把
        实例拉起来。
        """
        depts = self.cfg.departments.resolve()
        # 内置管理员的空间就是全公司根（admin_space()），设计如此。
        # 但只看路径分不出 admin 和一个工作区被放大了的员工，所以判定带身份。
        if username == "admin" and workspace.resolve() == self.cfg.files_root.resolve():
            return
        try:
            rel = workspace.resolve().relative_to(depts).parts
        except (ValueError, OSError):
            raise ProvisionError(
                f"{username} 的工作区不在 {depts} 之内，拒绝启动实例: {workspace}\n"
                "  这通常意味着登记表被改坏或从旧数据恢复过。请在管理后台重设该员工的部门与姓名。"
            ) from None
        if not 1 <= len(rel) <= 2:
            raise ProvisionError(
                f"{username} 的工作区层级不合法（应为 departments/<部门>[/<姓名>]），"
                f"拒绝启动实例: {workspace}"
            )

    def dsh_restart(self, username: str, rec: dict) -> None:
        self.dsh_stop(rec["port"])
        time.sleep(1)
        self.dsh_start(username, rec)

    def _sandbox_env(self) -> dict:
        return {"DSH_NETNS": "1" if self.cfg.netns else "0",
                "DSH_ROOT": str(self.cfg.root)}

    def sandbox_available(self) -> tuple[bool, str]:
        """当前环境挑不挑得出隔离后端。挑不出就不建号、不起实例（fail-closed）。"""
        res = self.run.run([str(self.cfg.sandbox_sh), "--check"], timeout=60,
                           env=self._sandbox_env())
        return res.returncode == 0, (res.stdout or res.stderr).strip()

    def isolation_backend(self) -> str:
        """选中的隔离档位: container / bwrap / uid / none / unknown。

        由 dsh-sandbox.sh 按当前环境实际拿得到的能力挑选，机器换形状（宿主 ->
        容器 -> 特权容器）时这里会跟着变，不需要改配置。
        """
        res = self.run.run([str(self.cfg.sandbox_sh), "--backend"], timeout=60,
                           env=self._sandbox_env())
        name = (res.stdout or "").strip()
        return name if res.returncode == 0 and name else "unknown"

    # ---------------- DSH_HOME 播种 ----------------
    def _seed_dsh_home(self, username: str, name: str, workspace: Path) -> None:
        dsh_home = self.cfg.users_root / username
        (dsh_home / "storages").mkdir(parents=True, exist_ok=True)
        profiles = dsh_home / "profiles"
        if not profiles.exists() and self.cfg.shared_profiles.exists():
            # 优先独立副本而非软链：landlock/bwrap 档把共享目录设为只读（防篡改
            # 他人插件），而 dsh 启动时要写自己的 profiles/web/cordis.yml，
            # 软链会把这次写引到共享目录上直接 EACCES。副本让每实例可写自己
            # 的、天然隔离；代价是共享插件更新后需对老用户重刷一次。
            try:
                shutil.copytree(self.cfg.shared_profiles, profiles, symlinks=True)
            except OSError as exc:
                # 【不要】在这里回落成软链。软链正是本次要修掉的那个形态：
                # landlock/bwrap 档把共享 profiles 设为只读，dsh 启动时写
                # profiles/web/cordis.yml 会被软链引到只读目录上直接 EACCES，
                # 表现为实例起不来、而报错指向一个跟建号无关的地方。
                # 拷不动是真异常（盘满、权限），当场说清楚，别留个坏实例。
                raise ProvisionError(
                    f"复制共享 profiles 失败: {self.cfg.shared_profiles} -> {profiles}（{exc}）\n"
                    "  这一步不能用软链代替：只读的共享目录会让 dsh 启动时写配置直接 EACCES。\n"
                    "  请检查磁盘空间与目录权限后重试。") from exc
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
    def space_consistency(self, rec: dict, actual_fb_scope: str | None = None) -> dict:
        """检查两边是否指向同一个空间。

        注意必须拿 FileBrowser 里的【实际】 scope 来比。两边都从登记表重算
        的话永远自洽，检测不出任何东西——真正会漂的是有人绕过后台、直接在
        FileBrowser 的界面或 API 上改了 scope。
        """
        dept = rec.get("department", "")
        name = rec.get("name", "")
        role = rec.get("role", ROLE_STAFF)
        space = self.space_for(dept, name, role)
        expected_scope = self.fb_scope_for(dept, name, role)
        dsh_paths = {rec.get("workspace") or ""} | {
            m["path"] for m in self.effective_mounts(rec)}
        dsh_ok = str(space) in dsh_paths
        fb_ok = actual_fb_scope is None or actual_fb_scope == expected_scope
        return {
            "space": str(space),
            "expected_scope": expected_scope,
            "actual_scope": actual_fb_scope,
            "dsh_ok": dsh_ok,
            "filebrowser_ok": fb_ok,
            "in_sync": dsh_ok and fb_ok,
        }

    def list_users(self, *, with_status: bool = True) -> list[dict]:
        reg = self.load_registry()
        auth_users = self._read_auth_users() if self.cfg.auth_users.exists() else {}
        nginx_text = self.cfg.nginx_conf.read_text(encoding="utf-8") if self.cfg.nginx_conf.exists() else ""
        fb_names: set[str] = set()
        fb_scopes: dict[str, str] = {}
        if with_status:
            try:
                for u in self._fb_users():
                    fb_names.add(u.get("username"))
                    scopes = u.get("scopes") or []
                    if scopes:
                        fb_scopes[u.get("username")] = scopes[0].get("scope", "")
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
            row["effective_mounts"] = self.effective_mounts(rec)
            row["space"] = self.space_consistency(rec, fb_scopes.get(username))
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
                f"挑不出隔离后端，拒绝建号（否则新实例将不受隔离）: {detail}\n"
                "逐项原因与处理建议: dsh-runtime/dsh-sandbox.sh --report\n"
                "验证: scripts/preflight-sandbox.sh")

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
            "port": port, "workspace": str(workspace), "mounts": [],
            "created_at": _now(), "updated_at": _now(),
        }
        reg["users"][username] = rec
        self.save_registry(reg)

        self._seed_dsh_home(username, name, workspace)
        self.sync_nginx(reg)
        self.dsh_start(username, rec)

        return {**rec, "initial_password": password}

    def set_mounts(self, username: str, mounts: list[dict]) -> dict:
        """设置该用户额外可访问的空间（本人工作区之外）。改动后重启实例生效。"""
        username = validate_username(username)
        reg = self.load_registry()
        rec = reg["users"].get(username)
        if not rec:
            raise ProvisionError(f"用户 {username} 不存在")
        if len(mounts) > 16:
            raise ProvisionError("额外挂载最多 16 条")
        validated = [validate_mount(self.cfg.files_root, m.get("path", ""), m.get("mode", "ro"))
                     for m in mounts]
        rec["mounts"] = validated
        rec["updated_at"] = _now()
        self.save_registry(reg)
        self.dsh_restart(username, rec)
        return rec

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
        # 必须在 rec.update() 之前算：之后 rec["role"] 已是新值，比出来恒为 False
        role_changed = new_role != rec["role"]

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
        elif role_changed:
            # 主管多挂一层部门目录，员工少挂——挂载集变了就得重启
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
