"""Attach or detach a host directory in a running box, without root.

Usage: nsmount.py attach OUTER_PID BOX_PID SRC DST
       nsmount.py detach OUTER_PID BOX_PID DST

OUTER_PID is a process in the rootless Podman user and mount namespaces
(the box's conmon); the host user owns that user namespace.  BOX_PID is the
box's init.  attach clones SRC with open_tree() in the outer mount namespace
(host paths are visible there), then joins the box's namespaces and attaches
the clone at DST with move_mount().  detach runs umount2(MNT_DETACH) at DST.
"""

import ctypes
import os
import sys

SYS_OPEN_TREE = 428
SYS_MOVE_MOUNT = 429
AT_FDCWD = -100
AT_RECURSIVE = 0x8000
OPEN_TREE_CLONE = 1
OPEN_TREE_CLOEXEC = os.O_CLOEXEC
MOVE_MOUNT_F_EMPTY_PATH = 0x4
MNT_DETACH = 2

libc = ctypes.CDLL(None, use_errno=True)


def check(ret, what):
    if ret < 0:
        err = ctypes.get_errno()
        sys.exit(f"{what}: {os.strerror(err)}")
    return ret


def ns_fds(pid):
    return [
        os.open(f"/proc/{pid}/ns/{ns}", os.O_RDONLY) for ns in ("user", "mnt")
    ]


def enter(fds, what):
    for fd, ns in zip(fds, ("user", "mnt")):
        check(libc.setns(fd, 0), f"setns {ns} of {what}")


def main():
    op = sys.argv[1]
    outer = ns_fds(sys.argv[2])
    box = ns_fds(sys.argv[3])
    enter(outer, "outer")
    if op == "attach":
        src, dst = sys.argv[4], sys.argv[5]
        tree = check(
            libc.syscall(
                SYS_OPEN_TREE,
                AT_FDCWD,
                src.encode(),
                OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE,
            ),
            "open_tree",
        )
        enter(box, "box")
        check(
            libc.syscall(
                SYS_MOVE_MOUNT,
                tree,
                b"",
                AT_FDCWD,
                dst.encode(),
                MOVE_MOUNT_F_EMPTY_PATH,
            ),
            "move_mount",
        )
    elif op == "detach":
        enter(box, "box")
        check(libc.umount2(sys.argv[4].encode(), MNT_DETACH), "umount2")
    else:
        sys.exit(__doc__)
    print(f"{op} ok")


if __name__ == "__main__":
    main()
