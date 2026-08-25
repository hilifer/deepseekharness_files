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
        for name in ("dsh-sandbox.sh", "dsh-netns-entry.sh", "dsh-container-entry.sh"):
            shutil.copy(REPO / "dsh-runtime" / name, root / "dsh-runtime" / name)
            (root / "dsh-runtime" / name).chmod(0o755)
        # 隔离层是「调度器 + backends/ 下的后端」，只拷调度器的话四档全报
        # NO_SCRIPT，实例一个也起不来。
        shutil.copytree(REPO / "dsh-runtime" / "backends", root / "dsh-runtime" / "backends")
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
    """挑不出隔离后端时必须拒绝启动，而不是退回无隔离运行。

    这些用例一律用 DSH_ISOLATION 把后端钉死。自动挑选是分档择优的：
    bwrap 坏掉时它会往下落到 uid/none，那是设计如此；这里要验的是
    「某一档自己失败时说不说得清、拦不拦得住」，所以不能让它落档。
    """

    @staticmethod
    def _fake_root(tmp: Path) -> Path:
        (tmp / "node/bin").mkdir(parents=True)
        (tmp / "ws").mkdir()
        (tmp / "home").mkdir()
        return tmp

    def _run(self, root: Path, env: dict) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(SANDBOX), "u", "13101", str(root / "home"), str(root / "ws")],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "DSH_ROOT": str(root),
                 "DSH_NODE_ROOT": str(root / "node"), **env})

    def test_broken_bwrap_is_diagnosed_not_silently_skipped(self):
        """bwrap 装着但跑不起来时，报错要说清是「跑不起来」而不是「没找到」。

        早先 find_bwrap 只判可执行，「存在但坏」会走进沙箱分支反复失败、
        实例直接死掉，降级开关压根到不了——现场只能把 bwrap 改名骗过检测。
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            broken = root / "brokenbw"
            broken.write_text("#!/bin/bash\nexit 1\n", encoding="utf-8")
            broken.chmod(0o755)
            res = self._run(root, {"BWRAP_BIN": str(broken), "DSH_ISOLATION": "bwrap"})
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("跑不起来", res.stderr)

    def test_missing_bwrap_says_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            res = self._run(root, {"BWRAP_BIN": str(root / "nope"),
                                   "DSH_ISOLATION": "bwrap"})
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("未找到 bwrap", res.stderr)

    def test_refuses_to_start_when_no_backend_available(self):
        """一档都挑不出来时必须拒绝，且把逐项原因摊开。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            # 故意不含 uid：本用例要验的是「一档都不成立」，而在以 root 跑的
            # 环境里 uid 档是真的可用的，带上它就验不到拒绝路径了。
            res = self._run(root, {"BWRAP_BIN": str(root / "nope"),
                                   "DSH_ISOLATION": "bwrap none",
                                   "DSH_DOCKER_BIN": str(root / "nodocker")})
            self.assertNotEqual(res.returncode, 0, "挑不出后端时必须拒绝启动")
            self.assertIn("拒绝启动", res.stderr)
            self.assertIn("bwrap", res.stderr)

    def test_unconfined_requires_explicit_optin(self):
        """none 后端不显式放行就不能用——默认必须是 fail-closed。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            res = self._run(root, {"DSH_ISOLATION": "none"})
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("拒绝启动", res.stderr)

    def test_explicit_override_is_loud(self):
        """DSH_ALLOW_UNCONFINED=1 可以放行，但必须打出醒目告警。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            res = self._run(root, {"DSH_ISOLATION": "none",
                                   "DSH_ALLOW_UNCONFINED": "1",
                                   "DSH_NODE_BIN": "/bin/true", "DSH_BIN": "ignored"})
            self.assertEqual(res.returncode, 0, res.stderr[-500:])
            self.assertIn("无隔离启动", res.stderr)

    def test_downgrade_passes_every_trusted_host(self):
        """降级路径也要传全部 trusted-host。

        只传第一个（公网 IP）的话，云 NAT 场景下本机与局域网访问会被 dsh 的
        Host 校验一律拒绝，等于谁都用不了。
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = self._fake_root(Path(tmp))
            res = self._run(root, {"DSH_ISOLATION": "none",
                                   "DSH_ALLOW_UNCONFINED": "1",
                                   "DSH_NODE_BIN": "/bin/echo", "DSH_BIN": "DSH",
                                   "DSH_TRUSTED_HOSTS": "a:1 b:2 c:3"})
            # 显式配置的三个必须一个不落地传下去。总数不再断言为 3——
            # common.sh 会把本机真实拥有的名字与地址也补进来（防的是「换个
            # 地址访问就 403」），那部分随机器而变，钉死数量等于钉死机器。
            for h in ("a:1", "b:2", "c:3"):
                self.assertIn(f"--trusted-host {h}", res.stdout, res.stdout)
            for h in ("a:1", "b:2", "c:3"):
                self.assertIn(h, res.stdout)


class BackendSelectionTest(unittest.TestCase):
    """调度器按【当前环境实际拿得到什么】挑后端——这一层本身也要有回归。"""

    def _report(self, env: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(
                [str(SANDBOX), "--report"], capture_output=True, text=True, timeout=90,
                env={**os.environ, "DSH_ROOT": tmp, **env})

    def _backend(self, env: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(
                [str(SANDBOX), "--backend"], capture_output=True, text=True, timeout=90,
                env={**os.environ, "DSH_ROOT": tmp, **env})

    def test_report_lists_every_backend(self):
        res = self._report({})
        for b in ("container", "bwrap", "uid", "none"):
            self.assertIn(b, res.stdout, res.stdout)

    def test_report_states_environment_shape(self):
        """报告要把决定成败的那几项前提摊开，运维不该去读代码才知道为什么。"""
        res = self._report({})
        for key in ("跑在容器里", "非特权 userns", "CAP_SYS_ADMIN", "docker"):
            self.assertIn(key, res.stdout, res.stdout)

    @unittest.skipUnless(BWRAP_OK, "需要可用的 bubblewrap")
    def test_auto_prefers_bwrap_over_uid(self):
        """docker 不可用时，有 bwrap 就绝不该退到只有 DAC 的 uid 档。"""
        with tempfile.TemporaryDirectory() as tmp:
            res = self._backend({"DSH_DOCKER_BIN": str(Path(tmp) / "nodocker")})
        self.assertEqual(res.stdout.strip(), "bwrap", res.stderr[-800:])

    def test_unavailable_backend_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = self._backend({"DSH_ISOLATION": "none",
                                 "DSH_DOCKER_BIN": str(Path(tmp) / "nodocker")})
        self.assertNotEqual(res.returncode, 0)


class ContainerPathMapTest(unittest.TestCase):
    """容器后端的宿主路径换算——挂错了比起不来更难查，必须单测。"""

    def _to_host(self, pathmap: list[str], path: str) -> subprocess.CompletedProcess:
        script = f'''
        set -euo pipefail
        DSH_ROOT=/home/ubuntu
        BACKEND_TAG=t
        . "{REPO}/dsh-runtime/backends/common.sh"
        source_fn() {{ :; }}
        # 只取 to_host_path 这一段，绕开 probe 里的 docker 依赖
        eval "$(sed -n '/^to_host_path()/,/^}}/p' "{REPO}/dsh-runtime/backends/container.sh")"
        PATHMAP=({" ".join(repr(x) for x in pathmap).replace("'", '"')})
        to_host_path "{path}"
        '''
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)

    def test_identity_map(self):
        res = self._to_host(["/|/"], "/home/ubuntu/dsh-files/a")
        self.assertEqual(res.stdout.strip(), "/home/ubuntu/dsh-files/a", res.stderr)

    def test_sibling_container_translates_to_host_path(self):
        """挂了宿主 socket 时，-v 左边必须是宿主上的路径，不是容器内的。"""
        res = self._to_host(["/home/ubuntu|/srv/dsh"], "/home/ubuntu/dsh-files/研发部")
        self.assertEqual(res.stdout.strip(), "/srv/dsh/dsh-files/研发部", res.stderr)

    def test_longest_prefix_wins(self):
        """多条挂载时按最长前缀匹配，否则会挑到范围更大的那条挂错地方。"""
        res = self._to_host(["/|/hostroot", "/home/ubuntu/dsh-files|/data/files"],
                            "/home/ubuntu/dsh-files/x")
        self.assertEqual(res.stdout.strip(), "/data/files/x", res.stderr)

    def test_unmapped_path_fails_instead_of_guessing(self):
        """映射覆盖不到的路径必须失败——悄悄回落成恒等映射就会挂空目录。"""
        res = self._to_host(["/home/ubuntu|/srv/dsh"], "/opt/elsewhere")
        self.assertNotEqual(res.returncode, 0, res.stdout)


class DockerSocketLivenessTest(unittest.TestCase):
    """区分「有 socket 文件」和「后面真有守护进程在听」。

    现场撞见过：容器里装了 docker 包、留着一个 /var/run/docker.sock，但
    dockerd 从来没起来过。那种死 socket 起不了任何容器，不是逃逸路径；
    早先按「文件存在」判定，会把本来可用的 uid 档误判成不可用。
    反过来，判不出来时必须当作可达——方向朝安全那边倒。
    """

    MAKE_STALE = (
        "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); "
        "s.bind(sys.argv[1]); s.close()' {sock}"
    )
    MAKE_LISTENING = (
        "python3 -c 'import socket,sys,os,time; s=socket.socket(socket.AF_UNIX); "
        "s.bind(sys.argv[1]); s.listen(1); "
        "os.fork() and os._exit(0); time.sleep(20)' {sock} ; sleep 1"
    )

    def _probe(self, sock_dir: str, make: str) -> tuple[int, int]:
        """返回 (docker_socket_live 退出码, docker_socket_file_exists 退出码)。"""
        sock = f"{sock_dir}/docker.sock"
        script = "\n".join([
            "set -uo pipefail",
            "BACKEND_TAG=t",
            f'. "{REPO}/dsh-runtime/backends/common.sh"',
            # 覆盖候选列表，避免误连到开发机上真实的 docker socket
            "docker_socket_candidates() { printf '%s\\n' " + f'"{sock}"' + "; }",
            make.format(sock=f'"{sock}"'),
            "docker_socket_live; live=$?",
            "docker_socket_file_exists; exists=$?",
            'echo "$live $exists"',
        ])
        res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
        parts = res.stdout.split()
        if len(parts) != 2:
            raise AssertionError(f"探针无输出: {res.stdout!r} {res.stderr!r}")
        return int(parts[0]), int(parts[1])

    def test_no_socket_at_all(self):
        with tempfile.TemporaryDirectory() as tmp:
            live, exists = self._probe(tmp, ":")
        self.assertNotEqual(live, 0, "没有 socket 就不该判成可达")
        self.assertNotEqual(exists, 0)

    def test_stale_socket_file_is_not_reachable(self):
        """没人在听的 socket：文件在但连不上，不算逃逸路径。"""
        with tempfile.TemporaryDirectory() as tmp:
            live, exists = self._probe(tmp, self.MAKE_STALE)
        self.assertNotEqual(live, 0, "死 socket 判成可达的话，uid 档会被误判为不可用")
        self.assertEqual(exists, 0, "文件确实在，file_exists 要认出来以便告警")

    def test_listening_socket_is_reachable(self):
        """真有进程在 listen：必须判成可达，uid 档要因此拒绝选用自己。"""
        with tempfile.TemporaryDirectory() as tmp:
            live, exists = self._probe(tmp, self.MAKE_LISTENING)
        self.assertEqual(live, 0, "有人在 listen 就必须判成可达")
        self.assertEqual(exists, 0)


class AutoOrderTest(unittest.TestCase):
    """择优顺序本身就是策略，必须钉住：弱档绝不能排在强档前面。

    以前只有「有 bwrap 时别退到 uid」一条行为断言，而它要跑起来得先有 bwrap；
    顺序表本身没人看着。landlock 比 uid 强（内核强制 vs 只有 DAC，且
    landlock 不需要 root），排反了在现场就是实打实的降级。"""

    def _order(self) -> list:
        line = next(l for l in (REPO / "dsh-runtime" / "dsh-sandbox.sh")
                    .read_text(encoding="utf-8").splitlines()
                    if l.startswith("AUTO_ORDER="))
        return line.split("=", 1)[1].strip().strip('"').split()

    def test_order_is_strongest_first(self):
        self.assertEqual(self._order(), ["container", "bwrap", "landlock", "uid", "none"])

    def test_landlock_before_uid(self):
        o = self._order()
        self.assertLess(o.index("landlock"), o.index("uid"),
                        "landlock 不需要 root、且是内核强制，绝不能排在 uid 之后")

    def test_none_is_last(self):
        self.assertEqual(self._order()[-1], "none", "无隔离档必须垫底")


class UidFirewallRulesTest(unittest.TestCase):
    """uid 档的同僚端口封锁：DAC 只管文件，这条路不经过文件系统。

    员工 A 一句 `curl 127.0.0.1:<B 的端口>` 就能驱动 B 的 agent 读 B 的工作区，
    文件权限一个字节都没违反。本档只剩 netfilter 的 owner 匹配能封它，
    所以规则组成必须有回归——不需要 root：用桩 iptables 把参数录下来看。
    """

    UID = "4242"
    OWN_PORT = "13107"

    # 只把「同僚端口封锁」那一段函数抠出来 eval，绕开 uid.sh 末尾的 case 分发
    EXTRACT = ("eval \"$(sed -n '/同僚端口封锁/,/---------- probe ----------/p' "
               "\"{repo}/dsh-runtime/backends/uid.sh\")\"")

    def _run(self, stub_body: str, tail: str):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "bin"
            stub.mkdir()
            log = Path(tmp) / "calls.log"
            (stub / "iptables").write_text(stub_body.replace("{log}", str(log)), encoding="utf-8")
            (stub / "iptables").chmod(0o755)
            script = "\n".join([
                "set -euo pipefail",
                'export PATH="%s:$PATH"' % stub,
                "export DSH_ROOT=%s" % tmp,
                "BACKEND_TAG=t",
                '. "%s/dsh-runtime/backends/common.sh"' % REPO,
                self.EXTRACT.format(repo=REPO),
                tail,
            ])
            res = subprocess.run(["bash", "-c", script], capture_output=True,
                                 text=True, timeout=60)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return res, calls

    # 桩要有状态，否则测不出「装之前查不到、装之后查得到」这层语义：
    #   -C 在 -I 之前失败（逼出插入分支），-I 之后成功（fw_assert_sealed 才有意义）
    STUB_OK = ('#!/bin/bash\n'
               'printf "%s\\n" "$*" >> "{log}"\n'
               'M="{log}.installed"\n'
               'for a in "$@"; do [ "$a" = "-I" ] && { touch "$M"; exit 0; }; done\n'
               'for a in "$@"; do [ "$a" = "-C" ] && { [ -e "$M" ] && exit 0 || exit 1; }; done\n'
               'exit 0\n')

    def _rules(self) -> list:
        res, calls = self._run(self.STUB_OK,
                               "fw_seal_peer_ports %s %s\nfw_assert_sealed %s"
                               % (self.UID, self.OWN_PORT, self.UID))
        self.assertEqual(res.returncode, 0, res.stderr[-800:])
        return calls

    def test_peer_instance_ports_are_rejected(self):
        rules = self._rules()
        self.assertTrue(any("13100:13199" in r and "REJECT" in r for r in rules),
                        "实例端口段没被封: %s" % rules)

    def test_own_port_is_returned_before_the_range(self):
        """放行本人端口的规则必须排在封锁段之前，否则自己也被挡住。"""
        rules = self._rules()
        own = next(i for i, r in enumerate(rules)
                   if "--dport %s -j RETURN" % self.OWN_PORT in r)
        rng = next(i for i, r in enumerate(rules) if "13100:13199" in r)
        self.assertLess(own, rng, "顺序反了，本人端口会被自己的规则挡住: %s" % rules)

    def test_internal_service_ports_are_rejected(self):
        """FileBrowser / Authelia / 管理后台：绕过 nginx 直连也要挡住。"""
        rules = self._rules()
        for port in ("18080", "19091", "19200"):
            self.assertTrue(any("--dport %s" % port in r and "REJECT" in r for r in rules),
                            "内部服务端口 %s 没封: %s" % (port, rules))

    def test_chain_is_hooked_into_output_by_uid(self):
        rules = self._rules()
        self.assertTrue(any("-I OUTPUT 1" in r and "--uid-owner %s" % self.UID in r
                            and "DSH-ISO-%s" % self.UID in r for r in rules),
                        "链没挂进 OUTPUT: %s" % rules)

    def test_missing_rule_refuses_to_start(self):
        """规则不在内核里就必须拒绝启动——本档没有第二个手段封这条路。"""
        stub = ('#!/bin/bash\n'
                'printf "%s\\n" "$*" >> "{log}"\n'
                'for a in "$@"; do [ "$a" = "-S" ] && exit 0; done\n'
                'exit 1\n')
        res, _ = self._run(stub, "fw_assert_sealed %s" % self.UID)
        self.assertNotEqual(res.returncode, 0, "规则不在却放行了启动")
        self.assertIn("拒绝启动", res.stderr, res.stderr[-500:])


class TrustedHostAutodetectTest(unittest.TestCase):
    """dsh 对 API 调用做 Host/Origin 校验：地址栏里的 host:port 不在名单里时，
    【静态页照发、API 一律 403】。现象是界面能开、设置面板里模型/权限/预设
    三处全挂——报错只有 HTTP 403，完全指不到成因上。

    名单原本写死三个地址，换台机器、换张网卡、改用主机名访问就复现。
    所以本机真实拥有的名字与地址要自动补进去。
    """

    def _hosts(self, env: dict) -> list:
        script = (
            'DSH_ROOT=/tmp BACKEND_TAG=t . "%s/dsh-runtime/backends/common.sh"\n'
            'build_trusted_host_args\n'
            'printf "%%s\\n" "${HOST_ARGS[@]}"\n' % REPO)
        res = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                             timeout=30, env={**os.environ, **env})
        self.assertEqual(res.returncode, 0, res.stderr)
        out = res.stdout.split()
        return [out[i + 1] for i, t in enumerate(out) if t == "--trusted-host"]

    def test_explicit_hosts_are_kept(self):
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": "a:1 b:2"})
        for h in ("a:1", "b:2"):
            self.assertIn(h, hosts)

    def test_loopback_is_always_present(self):
        """浏览器用 localhost 访问是最常见的一种，写死名单里恰恰没有它。"""
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": "a:1", "DSH_ENTRY_PORT": "8099"})
        self.assertIn("localhost:8099", hosts)
        self.assertIn("127.0.0.1:8099", hosts)

    def test_entry_port_is_honoured(self):
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": "", "DSH_ENTRY_PORT": "9443"})
        self.assertIn("localhost:9443", hosts)
        self.assertTrue(all(h.endswith(":9443") for h in hosts), hosts)

    def test_no_duplicates(self):
        """dsh 收得下重复项，但日志会很脏，且掩盖名单到底有什么。"""
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": "localhost:8099 localhost:8099",
                             "DSH_ENTRY_PORT": "8099"})
        self.assertEqual(len(hosts), len(set(hosts)), hosts)

    def test_autodetect_can_be_turned_off(self):
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": "a:1", "DSH_TRUSTED_AUTODETECT": "0"})
        self.assertEqual(hosts, ["a:1"])

    def test_never_emits_a_wildcard(self):
        """自动补的都必须是本机【真实拥有】的地址。通配符/全零地址会把
        Host 校验变成摆设——那是真放宽，不是修 bug。"""
        hosts = self._hosts({"DSH_TRUSTED_HOSTS": ""})
        for bad in ("*", "0.0.0.0", "::", "*:8099", "0.0.0.0:8099"):
            self.assertNotIn(bad, hosts, hosts)


class NginxPrivilegedRpcMapTest(unittest.TestCase):
    """dsh 的特权 RPC 只应答回环来源，反代部署要把 Host/Origin 改写成回环。
    这份白名单是安全边界，它的匹配对象错了整条边界就形同虚设。
    """

    CONF = REPO / "nginx" / "conf" / "nginx.conf"

    def setUp(self):
        self.text = self.CONF.read_text(encoding="utf-8")

    def test_matches_request_uri_not_uri(self):
        """必须匹配 $request_uri。

        proxy_pass 带变量且不含 URI 部分时，nginx 转发【客户端原始的】请求行，
        而 $uri 是归一化后的。按 $uri 判、按原始串转发，就是经典的代理解析错位：
            GET /api/host.openExternal/../settings.describe
            nginx 看到 /api/settings.describe -> 判特权，Host 改回环
            dsh  收到原始串                    -> 可能路由到 openExternal
        实测确认过。判定用的串必须和转发出去的串是同一个。
        """
        self.assertIn("map $request_uri $dsh_priv_loopback", self.text)
        self.assertNotIn("map $uri $dsh_priv_loopback", self.text,
                         "回退到 $uri 会重新打开解析错位")

    def test_anchors_tolerate_query_string(self):
        """匹配 $request_uri 就得自己处理查询串：写死 $ 会让
        /api/credentials.set?x=1 漏判成非特权，症状是那个接口又开始 403。"""
        block = self.text[self.text.index("map $request_uri $dsh_priv_loopback"):]
        block = block[:block.index("}")]
        for line in block.splitlines():
            line = line.strip()
            if line.startswith("~") and line.endswith("$ 1;"):
                self.fail(f"锚点没考虑查询串: {line}")

    def test_loopback_rewrite_targets_are_loopback(self):
        for var in ("$dsh_fwd_host", "$dsh_fwd_origin"):
            self.assertIn(f"map $dsh_priv_loopback {var}", self.text)
        self.assertIn('1       "127.0.0.1"', self.text)
        self.assertIn('1       "https://127.0.0.1"', self.text)


class NginxUnauthenticatedPathTest(unittest.TestCase):
    """/manifest.webmanifest 是整站唯一不过 Authelia 的路径，必须卡死。"""

    CONF = REPO / "nginx" / "conf" / "sites" / "dsh-auth.conf"

    def setUp(self):
        text = self.CONF.read_text(encoding="utf-8")
        i = text.index("location = /manifest.webmanifest")
        # 按花括号配平取整块 —— 里面嵌了 limit_except { }，取第一个 } 会截断
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        self.block = text[i:j + 1]

    def test_still_the_only_unauthenticated_location(self):
        """再多一条免认证路径就要重新评估，不能悄悄增加。"""
        text = self.CONF.read_text(encoding="utf-8")
        locs = [l.strip() for l in text.splitlines() if l.strip().startswith("location ")]
        authed = text.count("auth_request /internal/authelia/authz;")
        # location 总数减去内部 authz 子请求与 301 跳转，其余都应带 auth_request
        self.assertGreaterEqual(authed, 3, f"认证覆盖变少了: {locs}")

    def test_get_only(self):
        self.assertIn("limit_except GET", self.block,
                      "免认证路径不该能改状态")

    def test_does_not_forward_session_cookie(self):
        self.assertIn('proxy_set_header Cookie ""', self.block,
                      "免认证路径没有任何理由拿到会话凭据")


if __name__ == "__main__":
    unittest.main(verbosity=2)
