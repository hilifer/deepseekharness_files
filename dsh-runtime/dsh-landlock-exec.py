#!/usr/bin/env python3
# =====================================================================
# Landlock 上锁器 —— 给自己套上文件系统/网络限制，然后 exec 目标程序。
#
# 用法:
#   dsh-landlock-exec.py --selftest
#   dsh-landlock-exec.py [--ro PATH]... [--rw PATH]... [--rwio PATH]...
#                        [--bind-port N]... [--connect-port N]... -- CMD [ARG]...
#
#   --ro    只读（可执行、可读文件、可列目录）
#   --rw    完全读写（含创建/删除/改名）
#   --rwio  读写已有文件但不能创建/删除——给 /dev 和 /proc 用
#
# 为什么需要它：这个项目要能跑在【拿不到 root、也拿不到 user namespace】的
# 容器里。那种环境下 docker、bubblewrap、独立 OS 用户三条路全断，而 Landlock
# 恰恰是内核为「非特权自我沙箱」设计的机制——普通用户进程可以给自己上锁，
# 上锁后【不可撤销】、【子进程继承】，正好对上 dsh 那个能执行任意命令的
# bash 工具：dsh 起 bash、bash 起 cat，全都带着这把锁。
#
# 纯 ctypes 直调系统调用，不需要编译、不需要装任何包——那种环境里多半也
# 装不了东西。
#
# 与挂载命名空间的差别（如实写出来，别让人以为等价）：
#   · 越界访问返回 EACCES「拒绝访问」，不是 ENOENT「不存在」。路径本身的
#     存在性仍会泄露一点点（能判断出某个路径在不在）。
#   · 没有 pid namespace：`ps` 仍能看到全机进程和它们的命令行。
#   · 没有 cgroup 限额。
# 换来的是：不需要 root、不需要 userns、不需要任何人配合。
#
# 参考: Documentation/userspace-api/landlock.rst
# =====================================================================
from __future__ import annotations

import ctypes
import os
import struct
import sys

# ---- 系统调用号（x86_64 与 arm64 的通用表里是同一组）----
NR_CREATE_RULESET = 444
NR_ADD_RULE = 445
NR_RESTRICT_SELF = 446

PR_SET_NO_NEW_PRIVS = 38
LANDLOCK_CREATE_RULESET_VERSION = 1 << 0
LANDLOCK_RULE_PATH_BENEATH = 1
LANDLOCK_RULE_NET_PORT = 2

# ---- 文件系统访问位 ----
FS = {
    "execute":     1 << 0,
    "write_file":  1 << 1,
    "read_file":   1 << 2,
    "read_dir":    1 << 3,
    "remove_dir":  1 << 4,
    "remove_file": 1 << 5,
    "make_char":   1 << 6,
    "make_dir":    1 << 7,
    "make_reg":    1 << 8,
    "make_sock":   1 << 9,
    "make_fifo":   1 << 10,
    "make_block":  1 << 11,
    "make_sym":    1 << 12,
    "refer":       1 << 13,   # ABI 2
    "truncate":    1 << 14,   # ABI 3
    "ioctl_dev":   1 << 15,   # ABI 5
}
# 每个 ABI 版本【认得】哪些位。传了它不认得的位，create_ruleset 会直接 EINVAL，
# 所以必须按实际 ABI 裁剪，不能一股脑全传。
FS_MASK_BY_ABI = {
    1: 0x1fff,   # execute..make_sym
    2: 0x3fff,   # +refer
    3: 0x7fff,   # +truncate
    4: 0x7fff,   # ABI4 加的是网络，文件位没变
    5: 0xffff,   # +ioctl_dev
}

NET_BIND_TCP = 1 << 0
NET_CONNECT_TCP = 1 << 1

SCOPE_ABSTRACT_UNIX_SOCKET = 1 << 0   # ABI 6
SCOPE_SIGNAL = 1 << 1                 # ABI 6

_libc = ctypes.CDLL(None, use_errno=True)
_libc.syscall.restype = ctypes.c_long


def _syscall(nr: int, *args) -> int:
    """裸系统调用。ctypes 对变参默认按 c_int 传，指针会被截断，所以每个参数
    都必须显式包成 ctypes 类型。"""
    ctypes.set_errno(0)
    return _libc.syscall(ctypes.c_long(nr), *args)


def abi_version() -> int:
    """内核支持的 Landlock ABI 版本；不支持返回 -1。"""
    return _syscall(NR_CREATE_RULESET, None, ctypes.c_size_t(0),
                    ctypes.c_uint32(LANDLOCK_CREATE_RULESET_VERSION))


def fs_mask(abi: int) -> int:
    return FS_MASK_BY_ABI.get(min(abi, 5), FS_MASK_BY_ABI[5]) if abi >= 1 else 0


def ro_access(abi: int) -> int:
    a = FS["execute"] | FS["read_file"] | FS["read_dir"]
    if abi >= 5:
        a |= FS["ioctl_dev"]
    return a


def rw_access(abi: int) -> int:
    return fs_mask(abi)


def rwio_access(abi: int) -> int:
    """读写已有文件，但不能创建/删除。给 /dev 和 /proc 用：
    /dev/null 要能写、/proc/self/* 要能读，但没必要允许在那里造文件。"""
    a = FS["execute"] | FS["read_file"] | FS["write_file"] | FS["read_dir"]
    if abi >= 3:
        a |= FS["truncate"]
    if abi >= 5:
        a |= FS["ioctl_dev"]
    return a


def _create_ruleset(abi: int, handled_fs: int, handled_net: int, scoped: int) -> int:
    """结构体布局随 ABI 增长；传的 size 必须和我们填的字段数一致。"""
    if abi >= 6:
        attr = struct.pack("<QQQ", handled_fs, handled_net, scoped)
    elif abi >= 4:
        attr = struct.pack("<QQ", handled_fs, handled_net)
    else:
        attr = struct.pack("<Q", handled_fs)
    buf = ctypes.create_string_buffer(attr, len(attr))
    return _syscall(NR_CREATE_RULESET, ctypes.byref(buf),
                    ctypes.c_size_t(len(attr)), ctypes.c_uint32(0))


def _add_path(ruleset_fd: int, path: str, access: int) -> None:
    try:
        fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    except OSError as exc:
        raise RuntimeError(f"打不开 {path}: {exc}") from exc
    try:
        # struct landlock_path_beneath_attr 是 packed 的：u64 + s32 = 12 字节。
        # '<' 前缀关掉对齐填充，正好对上。
        attr = struct.pack("<Qi", access, fd)
        buf = ctypes.create_string_buffer(attr, len(attr))
        rc = _syscall(NR_ADD_RULE, ctypes.c_int(ruleset_fd),
                      ctypes.c_uint32(LANDLOCK_RULE_PATH_BENEATH),
                      ctypes.byref(buf), ctypes.c_uint32(0))
        if rc != 0:
            err = ctypes.get_errno()
            raise RuntimeError(f"add_rule({path}) 失败: {os.strerror(err)}")
    finally:
        os.close(fd)


def _add_port(ruleset_fd: int, port: int, access: int) -> None:
    attr = struct.pack("<QQ", access, port)
    buf = ctypes.create_string_buffer(attr, len(attr))
    rc = _syscall(NR_ADD_RULE, ctypes.c_int(ruleset_fd),
                  ctypes.c_uint32(LANDLOCK_RULE_NET_PORT),
                  ctypes.byref(buf), ctypes.c_uint32(0))
    if rc != 0:
        err = ctypes.get_errno()
        raise RuntimeError(f"add_rule(port {port}) 失败: {os.strerror(err)}")


def apply_landlock(ro: list[str], rw: list[str],
                   bind_ports: list[int], connect_ports: list[int],
                   rwio: list[str] | None = None) -> dict:
    """给【当前进程】上锁。返回一份说明这次到底锁住了什么的报告。

    上锁后不可撤销，且 exec 之后仍然有效——这正是我们要的：dsh 换成 bash、
    bash 换成 cat，锁一路跟着走。
    """
    abi = abi_version()
    if abi < 1:
        raise RuntimeError(f"内核不支持 Landlock（abi={abi}）")

    # no_new_privs 是 restrict_self 的硬前提，顺带也堵死 setuid 提权
    if _libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise RuntimeError("prctl(PR_SET_NO_NEW_PRIVS) 失败")

    handled_fs = fs_mask(abi)
    handled_net = (NET_BIND_TCP | NET_CONNECT_TCP) if abi >= 4 else 0
    # ABI6 的 scope：挡住给沙箱外进程发信号、以及连沙箱外的抽象 unix socket。
    # 前者让员工 kill 不掉别人的实例，后者堵住一条常被忽略的旁路。
    scoped = (SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL) if abi >= 6 else 0

    fd = _create_ruleset(abi, handled_fs, handled_net, scoped)
    if fd < 0:
        err = ctypes.get_errno()
        raise RuntimeError(f"create_ruleset 失败: {os.strerror(err)}")

    report = {"abi": abi, "ro": [], "rw": [], "rwio": [], "bind": [], "connect": [],
              "net": bool(handled_net), "scoped": bool(scoped)}
    try:
        for p in ro:
            if os.path.exists(p):
                _add_path(fd, p, ro_access(abi) & handled_fs)
                report["ro"].append(p)
        for p in (rwio or []):
            if os.path.exists(p):
                _add_path(fd, p, rwio_access(abi) & handled_fs)
                report["rwio"].append(p)
        for p in rw:
            if os.path.exists(p):
                _add_path(fd, p, rw_access(abi))
                report["rw"].append(p)
        if handled_net:
            for port in bind_ports:
                _add_port(fd, port, NET_BIND_TCP)
                report["bind"].append(port)
            for port in connect_ports:
                _add_port(fd, port, NET_CONNECT_TCP)
                report["connect"].append(port)
        rc = _syscall(NR_RESTRICT_SELF, ctypes.c_int(fd), ctypes.c_uint32(0))
        if rc != 0:
            err = ctypes.get_errno()
            raise RuntimeError(f"restrict_self 失败: {os.strerror(err)}")
    finally:
        os.close(fd)
    return report


def selftest() -> int:
    """不看返回码，真上一次锁再去读一个不该读的文件——「装了但不生效」和
    「没装」必须一视同仁，这是这个项目一以贯之的判据。"""
    abi = abi_version()
    print(f"Landlock ABI: {abi}")
    if abi < 1:
        print("不可用：内核没有 Landlock（需要 5.13+ 且在 lsm= 列表里）")
        return 1

    victim = "/etc/hostname"
    if not os.path.exists(victim):
        victim = "/etc/passwd"
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            apply_landlock(ro=["/usr", "/lib", "/lib64", "/bin"], rw=[],
                           bind_ports=[], connect_ports=[])
            try:
                with open(victim, "rb"):
                    os.write(w, b"LEAK")
            except OSError:
                os.write(w, b"SEALED")
        except Exception as exc:  # noqa: BLE001
            os.write(w, f"ERROR {exc}".encode())
        os._exit(0)
    os.close(w)
    out = os.read(r, 256).decode()
    os.close(r)
    os.waitpid(pid, 0)

    if out == "SEALED":
        print(f"实测: 上锁后读 {victim} 被拒 ✅ Landlock 真的生效")
        return 0
    print(f"实测: {out} ❌ 上锁没有生效")
    return 1


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()

    ro: list[str] = []
    rw: list[str] = []
    rwio: list[str] = []
    bind_ports: list[int] = []
    connect_ports: list[int] = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if i + 1 >= len(argv):
            print(f"选项 {a} 缺参数", file=sys.stderr)
            return 2
        val = argv[i + 1]
        if a == "--ro":
            ro.append(val)
        elif a == "--rw":
            rw.append(val)
        elif a == "--rwio":
            rwio.append(val)
        elif a == "--bind-port":
            bind_ports.append(int(val))
        elif a == "--connect-port":
            connect_ports.append(int(val))
        else:
            print(f"未知选项 {a}", file=sys.stderr)
            return 2
        i += 2

    cmd = argv[i:]
    if not cmd:
        print("缺少要执行的命令（-- 之后）", file=sys.stderr)
        return 2

    try:
        rep = apply_landlock(ro, rw, bind_ports, connect_ports, rwio=rwio)
    except Exception as exc:  # noqa: BLE001
        # 上不了锁就【不要执行】——宁可实例起不来，也不裸跑
        print(f"[landlock] 上锁失败，拒绝启动: {exc}", file=sys.stderr)
        return 1

    print(f"[landlock] 已上锁 abi=v{rep['abi']} "
          f"ro={len(rep['ro'])} rwio={len(rep['rwio'])} rw={len(rep['rw'])} "
          f"net={'on' if rep['net'] else 'off'} "
          f"scope={'on' if rep['scoped'] else 'off'}", file=sys.stderr)
    sys.stderr.flush()
    os.execv(cmd[0], cmd)
    return 127  # execv 不返回；走到这里说明失败了


if __name__ == "__main__":
    sys.exit(main(sys.argv))
