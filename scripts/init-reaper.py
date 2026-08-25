#!/usr/bin/env python3
"""
Subreaper wrapper — reaps all orphaned descendants so they never become zombies.

Started via exec-self in start-all.sh:
    exec python3 init-reaper.py "$0" "$@"

Sets PR_SET_CHILD_SUBREAPER so the kernel reparents orphaned descendants to us.
Forks the real entrypoint (start-all.sh), then loops forever reaping children.
"""
import ctypes
import ctypes.util
import os
import signal
import sys
import time

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
PR_SET_CHILD_SUBREAPER = 36  # linux/prctl.h

_logfile = "/tmp/init-reaper.log"

def _log(msg):
    try:
        with open(_logfile, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except OSError:
        pass

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <command> [args...]", file=sys.stderr)
        sys.exit(1)

    _log(f"init-reaper starting: pid={os.getpid()} cmd={sys.argv[1:]}")

    # 1) Tell the kernel: when our children orphan, reparent them to US, not PID 1.
    ret = libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
    _log(f"PR_SET_CHILD_SUBREAPER returned {ret}")

    # 2) Fork the real entrypoint (e.g. start-all.sh).
    child_pid = os.fork()
    if child_pid == 0:
        # Child: exec the real command.
        os.execvp(sys.argv[1], sys.argv[1:])
        # execvp only returns on error
        _log(f"execvp FAILED for {sys.argv[1]}")
        sys.exit(127)

    _log(f"forked entrypoint child pid={child_pid}")

    # 3) Parent: reap loop.  Stay alive as subreaper even after entrypoint exits,
    #    because services keep running and their reap.py wrappers may exit.
    reaped = 0
    while True:
        try:
            pid, status = os.waitpid(-1, 0)
            reaped += 1
            _log(f"reaped pid={pid} status={status} total={reaped}")
        except ChildProcessError:
            # No children yet or all reaped — brief sleep then retry.
            # We use sleep(1) instead of signal.pause() because new children
            # may be about to spawn and we don't want to miss SIGCHLD.
            time.sleep(1)

if __name__ == "__main__":
    main()
