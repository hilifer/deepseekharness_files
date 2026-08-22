#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
沙箱隔离的回归测试 —— 真跑 bubblewrap，实测「工作区以外碰不碰得到」。

这不是对配置的断言，是对行为的断言：在沙箱里真的去 cat 那些文件，
读到了就 FAIL。dsh-sandbox.sh 的任何改动（挂载项、顺序、命名空间开关）
若削弱了隔离，这里会立刻红。

没装 bubblewrap 时整体跳过，避免在没有沙箱的开发机上误报。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SANDBOX = REPO / "dsh-runtime" / "dsh-sandbox.sh"


def _bwrap_works() -> bool:
    """bwrap 存在，且非特权 user namespace 真的能用。"""
    if not shutil.which("bwrap"):
        return False
    try:
        return subprocess.run(
            ["bwrap", "--ro-bind", "/", "/", "--unshare-all", "--share-net", "true"],
            capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _pasta_works() -> bool:
    """pasta 装了不等于能用：嵌套容器里它会在 uid 映射那步失败。
    和 bwrap 一样必须真跑一次，否则测试会挂在那里空等。"""
    if not (shutil.which("pasta") and shutil.which("socat")):
        return False
    try:
        return subprocess.run(
            ["pasta", "--config-net", "--no-map-gw", "-t", "none", "-u", "none", "--", "true"],
            capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


BWRAP_OK = _bwrap_works()
NETNS_OK = BWRAP_OK and _pasta_works()

# 沙箱内执行的探针：逐项试探，输出 KEY=VALUE
PROBE = r'''
R="$P_ROOT"
seal() { cat "$1" >/dev/null 2>&1 && echo LEAK || echo SEALED; }
echo "CREDS=$(seal "$R/dsh-auth/initial-credentials.txt")"
echo "USERDB=$(seal "$R/dsh-auth/config/users_database.yml")"
echo "TLSKEY=$(seal "$R/nginx/certs/dsh.key")"
echo "FBDB=$(seal "$R/filebrowser/database.db")"
echo "ADMTOK=$(seal "$R/admin/.admin-token")"
echo "ADMSRC=$(seal "$R/admin/core.py")"
echo "REGISTRY=$(seal "$R/dsh-users/registry.json")"
echo "PEERFILE=$(seal "$R/dsh-files/departments/财务部/王五/工资表.xlsx")"
echo "SAMEDEPT=$(seal "$R/dsh-files/departments/研发部/赵六/note.txt")"
echo "PEERHOME=$(seal "$R/dsh-users/zhaoliu/state.json")"
echo "DEPTS=$(ls "$R/dsh-files/departments" 2>/dev/null | tr '\n' ',')"
echo "USERS=$(ls "$R/dsh-users" 2>/dev/null | tr '\n' ',')"
echo "MYDEPT=$(ls "$R/dsh-files/departments/研发部" 2>/dev/null | tr '\n' ',')"
echo "OWNREAD=$(cat "$P_WS/我的文档.txt" 2>/dev/null || echo FAIL)"
echo "OWNWRITE=$(touch "$P_WS/.probe" 2>/dev/null && echo OK || echo FAIL)"
echo "HOMEWRITE=$(touch "$P_HOME/.probe" 2>/dev/null && echo OK || echo FAIL)"
echo "TMPWRITE=$(touch /tmp/.probe 2>/dev/null && echo OK || echo FAIL)"
echo "PROFRO=$(touch "$R/.local/share/dsh/profiles/x" 2>/dev/null && echo WRITABLE || echo READONLY)"
echo "NODERO=$(touch "$R/node/bin/x" 2>/dev/null && echo WRITABLE || echo READONLY)"
echo "PROCS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
echo "ARGS=$*"
'''


@unittest.skipUnless(BWRAP_OK, "bubblewrap 不可用或内核禁用了非特权 user namespace")
class SandboxIsolationTest(unittest.TestCase):
    """在一棵仿真部署树上跑沙箱，逐项验收。"""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name) / "home"
        cls.root = root
        for sub in ("dsh-auth/config", "nginx/certs", "filebrowser", "admin", "node/bin",
                    "dsh-users/zhangsan/storages", "dsh-users/zhaoliu",
                    "dsh-files/departments/研发部/张三", "dsh-files/departments/研发部/赵六",
                    "dsh-files/departments/财务部/王五", ".local/share/dsh/profiles"):
            (root / sub).mkdir(parents=True, exist_ok=True)

        # 铺设「不该被看到」的高危目标
        (root / "dsh-auth/initial-credentials.txt").write_text("zhangsan 张三 Passw0rd", encoding="utf-8")
        (root / "dsh-auth/config/users_database.yml").write_text("users: {}", encoding="utf-8")
        (root / "nginx/certs/dsh.key").write_text("FAKE-TLS-KEY-FIXTURE-NOT-A-REAL-PEM", encoding="utf-8")
        (root / "filebrowser/database.db").write_text("SQLITE", encoding="utf-8")
        (root / "admin/.admin-token").write_text("deadbeef", encoding="utf-8")
        (root / "admin/core.py").write_text("# engine", encoding="utf-8")
        (root / "dsh-users/registry.json").write_text('{"users":{}}', encoding="utf-8")
        (root / "dsh-users/zhaoliu/state.json").write_text("赵六的状态", encoding="utf-8")
        (root / "dsh-files/departments/财务部/王五/工资表.xlsx").write_text("机密", encoding="utf-8")
        (root / "dsh-files/departments/研发部/赵六/note.txt").write_text("赵六的笔记", encoding="utf-8")
        (root / ".local/share/dsh/profiles/index.mjs").write_text("export default 1", encoding="utf-8")
        # 本人工作区
        cls.ws = root / "dsh-files/departments/研发部/张三"
        (cls.ws / "我的文档.txt").write_text("我的内容", encoding="utf-8")
        cls.home = root / "dsh-users/zhangsan"

        # 冒充 node + dsh
        shutil.copy("/bin/bash", root / "node/bin/node")
        probe = root / "node/bin/dsh"
        probe.write_text(PROBE, encoding="utf-8")
        probe.chmod(0o755)

        cls.out = cls._run_sandbox("zhangsan", cls.home, cls.ws)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    @classmethod
    def _run_sandbox(cls, user: str, home: Path, ws: Path) -> dict[str, str]:
        env = {
            **os.environ,
            "DSH_ROOT": str(cls.root),
            "DSH_NODE_ROOT": str(cls.root / "node"),
            "DSH_NODE_BIN": str(cls.root / "node/bin/node"),
            "DSH_BIN": str(cls.root / "node/bin/dsh"),
            "DSH_SHARED_PROFILES": str(cls.root / ".local/share/dsh/profiles"),
            "DSH_SANDBOX_PASSENV": "P_ROOT P_WS P_HOME",
            "P_ROOT": str(cls.root), "P_WS": str(ws), "P_HOME": str(home),
        }
        res = subprocess.run([str(SANDBOX), user, "13101", str(home), str(ws)],
                             capture_output=True, text=True, timeout=90, env=env)
        parsed = {}
        for line in res.stdout.splitlines():
            if "=" in line:
                key, _, val = line.partition("=")
                parsed[key.strip()] = val.strip()
        if not parsed:
            raise AssertionError(f"探针无输出。stdout={res.stdout!r} stderr={res.stderr!r}")
        return parsed

    # ---------- 不该看到的 ----------
    def test_credentials_file_sealed(self):
        """initial-credentials.txt 是全员明文初始密码，泄露等于全公司账号失守。"""
        self.assertEqual(self.out["CREDS"], "SEALED")

    def test_authelia_userdb_sealed(self):
        self.assertEqual(self.out["USERDB"], "SEALED")

    def test_tls_private_key_sealed(self):
        self.assertEqual(self.out["TLSKEY"], "SEALED")

    def test_filebrowser_db_sealed(self):
        self.assertEqual(self.out["FBDB"], "SEALED")

    def test_admin_token_sealed(self):
        """管理后台 token 若能读到，沙箱内就能直调 API 任意增删员工。"""
        self.assertEqual(self.out["ADMTOK"], "SEALED")

    def test_admin_source_sealed(self):
        self.assertEqual(self.out["ADMSRC"], "SEALED")

    def test_registry_sealed(self):
        self.assertEqual(self.out["REGISTRY"], "SEALED")

    def test_other_department_file_sealed(self):
        self.assertEqual(self.out["PEERFILE"], "SEALED")

    def test_same_department_peer_sealed(self):
        """同部门同事的目录也必须看不到——scope 是个人，不是部门。"""
        self.assertEqual(self.out["SAMEDEPT"], "SEALED")

    def test_peer_dsh_home_sealed(self):
        self.assertEqual(self.out["PEERHOME"], "SEALED")

    # ---------- 目录遍历面 ----------
    def test_only_own_department_visible(self):
        self.assertEqual(self.out["DEPTS"].strip(","), "研发部")

    def test_only_self_visible_in_own_department(self):
        self.assertEqual(self.out["MYDEPT"].strip(","), "张三")

    def test_only_own_dsh_home_visible(self):
        self.assertEqual(self.out["USERS"].strip(","), "zhangsan")

    # ---------- 该能用的 ----------
    def test_own_workspace_readable(self):
        self.assertEqual(self.out["OWNREAD"], "我的内容")

    def test_own_workspace_writable(self):
        self.assertEqual(self.out["OWNWRITE"], "OK")

    def test_own_dsh_home_writable(self):
        self.assertEqual(self.out["HOMEWRITE"], "OK")

    def test_tmp_writable(self):
        self.assertEqual(self.out["TMPWRITE"], "OK")

    # ---------- 只读面 ----------
    def test_shared_profiles_readonly(self):
        """profiles 全实例共享；可写则任何员工都能改插件影响全体。"""
        self.assertEqual(self.out["PROFRO"], "READONLY")

    def test_node_and_dsh_readonly(self):
        self.assertEqual(self.out["NODERO"], "READONLY")

    # ---------- 命名空间 ----------
    def test_pid_namespace_isolated(self):
        """ps 看不到宿主进程，顺带堵住 authelia hash 命令行短暂暴露密码。"""
        self.assertLess(int(self.out["PROCS"]), 20)

    def test_trusted_host_passed_through(self):
        self.assertIn("--trusted-host", self.out["ARGS"])
        self.assertIn("web --port 13101", self.out["ARGS"])


@unittest.skipUnless(NETNS_OK, "需要 pasta(passt) 与 socat")
class NetnsIsolationTest(unittest.TestCase):
    """DSH_NETNS=1：每实例独立网络命名空间，入站走 unix socket。

    验的是：宿主回环上不再留下 dsh 端口，因而员工之间无法互连实例；
    同时 nginx 仍能经 unix socket 连到实例，沙箱内仍能出网。
    用的是真实的 dsh-runtime/dsh-sandbox.sh，不是实验用的临时脚本。
    """

    PORT = 13411

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name) / "home"
        cls.root = root
        (root / "node/bin").mkdir(parents=True)
        (root / "dsh-runtime").mkdir(parents=True)
        for sub in ("A", "B"):
            (root / f"dsh-users/{sub}").mkdir(parents=True)
            (root / f"ws/{sub}").mkdir(parents=True)
        for name in ("dsh-sandbox.sh", "dsh-netns-entry.sh"):
            shutil.copy(REPO / "dsh-runtime" / name, root / "dsh-runtime" / name)
            (root / "dsh-runtime" / name).chmod(0o755)
        shutil.copy("/bin/bash", root / "node/bin/node")
        # 冒充 dsh：在本 netns 的 --port 上起一个 HTTP 服务
        fake = root / "node/bin/dsh"
        fake.write_text(
            'port=""\n'
            'while [ $# -gt 0 ]; do [ "$1" = "--port" ] && port=$2; shift; done\n'
            'exec python3 -c "\n'
            'import http.server, os, sys\n'
            'who = os.environ.get(\'WHOAMI\', \'?\')\n'
            'class H(http.server.BaseHTTPRequestHandler):\n'
            '    def do_GET(s):\n'
            '        s.send_response(200); s.end_headers(); s.wfile.write((\'dsh-\'+who).encode())\n'
            '    def log_message(*a): pass\n'
            'http.server.HTTPServer((\'127.0.0.1\', int(sys.argv[1])), H).serve_forever()" "$port"\n',
            encoding="utf-8")
        fake.chmod(0o755)

        cls.procs = []
        for who in ("B", "A"):
            env = {
                **os.environ,
                "DSH_ROOT": str(root), "DSH_NETNS": "1",
                "DSH_NODE_ROOT": str(root / "node"),
                "DSH_NODE_BIN": str(root / "node/bin/node"),
                "DSH_BIN": str(root / "node/bin/dsh"),
                "DSH_SANDBOX_PASSENV": "WHOAMI", "WHOAMI": who,
            }
            log = root / f"{who}.log"
            cls.logs = getattr(cls, "logs", {})
            cls.logs[who] = log
            cls.procs.append(subprocess.Popen(
                [str(root / "dsh-runtime/dsh-sandbox.sh"), who, str(cls.PORT),
                 str(root / f"dsh-users/{who}"), str(root / f"ws/{who}")],
                env=env, stdout=open(log, "wb"), stderr=subprocess.STDOUT,
                start_new_session=True))
        cls.sock_b = root / "dsh-sockets/B/dsh.sock"
        # 只等 socket 文件出现是不够的：socat 一启动就立刻创建 socket，
        # 而它背后的 dsh 可能还没开始监听，这时请求会拿到空响应。
        # 必须等到一次真实请求成功为止，否则用例会偶发地红。
        deadline = time.time() + 40
        ready = False
        while time.time() < deadline:
            if cls.sock_b.exists():
                probe = subprocess.run(
                    ["curl", "-s", "--max-time", "3", "--unix-socket",
                     str(cls.sock_b), "http://x/"],
                    capture_output=True, text=True)
                if probe.stdout.strip() == "dsh-B":
                    ready = True
                    break
            time.sleep(0.5)
        if not ready:
            for proc in cls.procs:
                proc.terminate()
            detail = "\n".join(
                f"--- {who}.log ---\n" + path.read_text(errors="replace")[-1500:]
                for who, path in sorted(cls.logs.items()) if path.exists())
            raise AssertionError(
                "netns 模式下实例未在 40 秒内就绪（socket 存在与否: "
                f"{cls.sock_b.exists()}，路径 {cls.sock_b}）\n{detail}")

    @classmethod
    def tearDownClass(cls):
        # 必须 wait 回收：只 terminate 不回收会留下僵尸子进程，
        # Python 退出时报 ResourceWarning: subprocess N is still running。
        for proc in cls.procs:
            proc.terminate()
        for proc in cls.procs:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            if proc.stdout:
                proc.stdout.close()
        cls._tmp.cleanup()

    @staticmethod
    def _curl(args: list[str]) -> tuple[str, int]:
        r = subprocess.run(["curl", "-s", "--max-time", "5", *args],
                           capture_output=True, text=True)
        return r.stdout.strip(), r.returncode

    def test_socket_created(self):
        self.assertTrue(self.sock_b.exists(), "实例应建立 unix socket 供 nginx 连接")

    def test_host_reaches_instance_via_socket(self):
        out, _ = self._curl(["--unix-socket", str(self.sock_b), "http://x/"])
        self.assertEqual(out, "dsh-B", "nginx 必须能经 unix socket 连到实例")

    def test_no_port_on_host_loopback(self):
        """宿主回环上不留端口，是实例间互不可连的根本原因。"""
        _, rc = self._curl(["-o", "/dev/null", f"http://127.0.0.1:{self.PORT}/"])
        self.assertEqual(rc, 7, f"期望 curl 退出码 7（拒绝连接），实际 {rc}")
        listening = subprocess.run(["ss", "-ltn"], capture_output=True, text=True).stdout
        self.assertNotIn(f":{self.PORT}", listening, "宿主不应有该端口的监听")

    def test_peer_cannot_reach_other_instance(self):
        """员工 A 的沙箱里去连员工 B 的实例——三条路都应不通。"""
        # 用位置参数传 URL，避免 f-string 与多层引号互相打架
        probe = ('c() { curl -s --max-time 4 -o /dev/null -w "%{http_code}" "$@" 2>/dev/null; }; '
                 'echo LOOP=$(c "$1"); echo SOCK=$(c --unix-socket "$2" http://x/)')
        r = subprocess.run(
            ["pasta", "--config-net", "--no-map-gw", "-t", "none", "-u", "none", "--",
             "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
             "--tmpfs", "/tmp", "--tmpfs", str(self.root / "dsh-sockets"),
             "--unshare-user", "--share-net", "--", "bash", "-c", probe,
             "_", f"http://127.0.0.1:{self.PORT}/", str(self.sock_b)],
            capture_output=True, text=True, timeout=60)
        out = r.stdout
        self.assertIn("LOOP=000", out, f"A 不应连到 B 的端口: {out!r}")
        self.assertIn("SOCK=000", out, f"A 不应连到 B 的 socket: {out!r}")

    def test_outbound_still_works(self):
        """dsh 要调模型 API，隔离网络后出网必须仍然可用。"""
        resolv = self.root / "dsh-sockets/B/resolv.conf"
        self.assertTrue(resolv.exists(), "netns 模式应生成指向 pasta DNS 转发器的 resolv.conf")
        self.assertIn("nameserver", resolv.read_text(encoding="utf-8"))
        r = subprocess.run(
            ["pasta", "--config-net", "--no-map-gw", "--dns-forward", "10.0.2.3", "--",
             "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
             "--ro-bind", str(resolv), "/etc/resolv.conf", "--unshare-user", "--share-net", "--",
             "bash", "-c", "getent hosts github.com >/dev/null 2>&1 && echo DNS_OK"],
            capture_output=True, text=True, timeout=60)
        self.assertIn("DNS_OK", r.stdout, f"沙箱内 DNS 应可用: {r.stdout!r} {r.stderr[-200:]!r}")


@unittest.skipUnless(BWRAP_OK, "bubblewrap 不可用")
class ExtraMountsTest(unittest.TestCase):
    """额外空间：主管的部门目录、共享资料库等。

    关键是「多挂了几个目录」不能把别的东西一起带进来——所以这里同时断言
    额外空间按 ro/rw 生效，以及没被列出来的目录依然读不到。
    """

    PROBE = (
        'r() { cat "$1"/marker 2>/dev/null || echo SEALED; }\n'
        'w() { touch "$1"/.probe 2>/dev/null && echo RW || echo RO; }\n'
        'echo "OWN_R=$(r $P_OWN)"; echo "OWN_W=$(w $P_OWN)"\n'
        'echo "RWDIR_R=$(r $P_RW)"; echo "RWDIR_W=$(w $P_RW)"\n'
        'echo "RODIR_R=$(r $P_RO)"; echo "RODIR_W=$(w $P_RO)"\n'
        'echo "SECRET=$(r $P_SECRET)"\n'
        'echo "ROOTS=$(echo "$DSH_ALLOWED_ROOTS" | tr "\\n" "|")"\n'
        'echo "UPLOAD=$DSH_UPLOAD_DIR"\n'
    )

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name) / "home"
        cls.root = root
        for sub in ("node/bin", "dsh-users/u1", "files/own", "files/shared_rw",
                    "files/shared_ro", "files/secret"):
            (root / sub).mkdir(parents=True, exist_ok=True)
        for name in ("own", "shared_rw", "shared_ro", "secret"):
            (root / "files" / name / "marker").write_text(name, encoding="utf-8")
        shutil.copy("/bin/bash", root / "node/bin/node")
        probe = root / "node/bin/dsh"
        probe.write_text(cls.PROBE, encoding="utf-8")
        probe.chmod(0o755)

        env = {
            **os.environ,
            "DSH_ROOT": str(root),
            "DSH_NODE_ROOT": str(root / "node"),
            "DSH_NODE_BIN": str(root / "node/bin/node"),
            "DSH_BIN": str(root / "node/bin/dsh"),
            "DSH_SANDBOX_PASSENV": "P_OWN P_RW P_RO P_SECRET",
            "P_OWN": str(root / "files/own"),
            "P_RW": str(root / "files/shared_rw"),
            "P_RO": str(root / "files/shared_ro"),
            "P_SECRET": str(root / "files/secret"),
            "DSH_EXTRA_MOUNTS": (
                f"rw\t{root / 'files/shared_rw'}\n"
                f"ro\t{root / 'files/shared_ro'}"
            ),
        }
        res = subprocess.run(
            [str(REPO / "dsh-runtime/dsh-sandbox.sh"), "u1", "13501",
             str(root / "dsh-users/u1"), str(root / "files/own")],
            capture_output=True, text=True, timeout=90, env=env)
        cls.out = {}
        for line in res.stdout.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                cls.out[k.strip()] = v.strip()
        if not cls.out:
            raise AssertionError(f"探针无输出: {res.stdout!r} / {res.stderr[-800:]!r}")

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_own_workspace_readwrite(self):
        self.assertEqual(self.out["OWN_R"], "own")
        self.assertEqual(self.out["OWN_W"], "RW")

    def test_rw_mount_is_writable(self):
        """主管的部门目录这类：既能读也能写。"""
        self.assertEqual(self.out["RWDIR_R"], "shared_rw")
        self.assertEqual(self.out["RWDIR_W"], "RW")

    def test_ro_mount_is_readable_but_not_writable(self):
        """只读资料库：读得到，写不了。"""
        self.assertEqual(self.out["RODIR_R"], "shared_ro")
        self.assertEqual(self.out["RODIR_W"], "RO")

    def test_unlisted_dir_still_sealed(self):
        """没列进挂载表的目录，即便是同一个父目录下的兄弟，也必须看不到。"""
        self.assertEqual(self.out["SECRET"], "SEALED")

    def test_upload_dir_defaults_inside_workspace(self):
        """上传插件的落盘目录必须在工作区内，否则传的文件在文件服务器里看不见。"""
        self.assertEqual(self.out["UPLOAD"], str(self.root / "files/own/uploads"))

    def test_allowed_roots_passed_to_picker(self):
        """选择器插件要拿到完整的允许根列表，否则能读却选不到。"""
        roots = self.out["ROOTS"]
        self.assertIn("own", roots)
        self.assertIn("shared_rw", roots)
        self.assertIn("shared_ro", roots)
        self.assertNotIn("secret", roots)


class SandboxFailClosedTest(unittest.TestCase):
    """沙箱不可用时必须拒绝启动，而不是退回无隔离运行。"""

    def test_refuses_to_start_without_bwrap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "node/bin").mkdir(parents=True)
            (root / "ws").mkdir()
            (root / "home").mkdir()
            # 复制一份去掉硬编码 bwrap 候选路径的启动器，模拟「系统里没有 bwrap」
            script = SANDBOX.read_text(encoding="utf-8") \
                .replace('"$DSH_ROOT/bwrap/usr/bin/bwrap" \\', '"/nope1" \\') \
                .replace("/usr/bin/bwrap /bin/bwrap", "/nope2 /nope3")
            fake = root / "sb.sh"
            fake.write_text(script, encoding="utf-8")
            fake.chmod(0o755)

            env = {**os.environ, "PATH": str(root / "empty"),
                   "DSH_ROOT": str(root), "DSH_NODE_ROOT": str(root / "node")}
            env.pop("BWRAP_BIN", None)
            res = subprocess.run([str(fake), "u", "13101", str(root / "home"), str(root / "ws")],
                                 capture_output=True, text=True, timeout=30, env=env)
            self.assertNotEqual(res.returncode, 0, "无沙箱时必须拒绝启动")
            self.assertIn("拒绝", res.stderr)

    def test_explicit_override_is_loud(self):
        """DSH_ALLOW_UNCONFINED=1 可以放行，但必须打出醒目告警。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "node/bin").mkdir(parents=True)
            (root / "ws").mkdir()
            (root / "home").mkdir()
            script = SANDBOX.read_text(encoding="utf-8") \
                .replace('"$DSH_ROOT/bwrap/usr/bin/bwrap" \\', '"/nope1" \\') \
                .replace("/usr/bin/bwrap /bin/bwrap", "/nope2 /nope3")
            fake = root / "sb.sh"
            fake.write_text(script, encoding="utf-8")
            fake.chmod(0o755)
            (root / "empty").mkdir()
            env = {**os.environ, "PATH": str(root / "empty"),
                   "DSH_ALLOW_UNCONFINED": "1", "DSH_ROOT": str(root),
                   "DSH_NODE_ROOT": str(root / "node"), "DSH_NODE_BIN": "/bin/true",
                   "DSH_BIN": "ignored"}
            env.pop("BWRAP_BIN", None)
            res = subprocess.run([str(fake), "u", "13101", str(root / "home"), str(root / "ws")],
                                 capture_output=True, text=True, timeout=30, env=env)
            self.assertIn("警告", res.stderr)
            self.assertIn("无隔离", res.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
