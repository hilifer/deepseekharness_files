#!/usr/bin/env python3
"""Process wrapper that properly reaps its child (prevents zombies).

Usage: reap.py <command> [args...]

Becomes the direct parent of <command>. When <command> exits, reap.py
calls waitpid() to collect it — no zombie left behind.
"""
import os, sys, signal, resource

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <command> [args...]", file=sys.stderr)
        sys.exit(1)

    # Apply DSH_RLIMIT_NPROC if set (inherited from environment)
    nproc = os.environ.get("DSH_RLIMIT_NPROC")
    if nproc:
        try:
            resource.setrlimit(resource.RLIMIT_NPROC, (int(nproc), int(nproc)))
        except (ValueError, OSError):
            pass

    pid = os.fork()
    if pid == 0:
        # Child: exec the actual command
        os.execvp(sys.argv[1], sys.argv[1:])
    else:
        # Parent: wait for child and reap it
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

if __name__ == "__main__":
    main()
