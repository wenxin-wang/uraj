"""Linux lifecycle experiment, NOT the production broker/supervisor.

Run with Python 3.9+ and Guix on PATH (or GUIX=/absolute/path/to/guix).
Needs unprivileged user/PID namespaces and pidfds; does not use the Guix daemon.
Runs actual Guix call-with-container inside an outer supervised PID namespace.
Only temporary files and processes created by this test are modified.
The single-threaded fork/ctypes code here is deliberately a test harness.
"""

import argparse
import ctypes
import json
import os
import select
import shutil
import signal
import sys
import tempfile
import time
import traceback
from pathlib import Path

LIBC = ctypes.CDLL(None, use_errno=True)
PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
CLONE_NEWUSER = 0x10000000
CLONE_NEWPID = 0x20000000
CLONE_NEWNS = 0x00020000
SCRIPT = str(Path(__file__).resolve())
TIMEOUT = 10


def checked(result):
    if result < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))


def prctl(option, value):
    checked(LIBC.prctl(option, value, 0, 0, 0))


def wait_until(predicate):
    end = time.monotonic() + TIMEOUT
    while not predicate():
        if time.monotonic() > end:
            raise TimeoutError("lifecycle condition did not complete")
        time.sleep(0.01)


def record(root, name, value):
    path = root / name
    temporary = root / (name + ".tmp")
    temporary.write_text(str(value))
    temporary.replace(path)


def outer_pid(root):
    # A saved proc mount is only a test observation channel, not agent policy.
    return int((root / "observer-proc/self/stat").read_text().split()[0])


def wait_file(root, name):
    wait_until(lambda: (root / name).exists())


def pidfd_dead(fd):
    poll = select.poll()
    poll.register(fd, select.POLLIN)
    return bool(poll.poll(0))


def detached_worker(root, name):
    first = os.fork()
    if first == 0:
        os.setsid()
        if os.fork():
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        record(root, name, outer_pid(root))
        while True:
            time.sleep(1)
    os.waitpid(first, 0)
    wait_file(root, name)


def payload(root, mode):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    detached_worker(root, "inner-background.pid")
    record(root, "payload.pid", outer_pid(root))
    if mode.startswith("exit-"):
        wait_file(root, "finish")
        os._exit(int(mode.split("-")[1]))
    if mode == "signal-exit":
        wait_file(root, "finish")
        os.kill(os.getpid(), signal.SIGKILL)
    while True:
        time.sleep(1)


def supervisor(root, mode, parent_fd, guix):
    # Enter a private mount namespace and retain the driver's proc view for
    # assertions; Guix itself needs /proc to match the outer execution namespace.
    original_pid = int(Path("/proc/self/stat").read_text().split()[0])
    record(root, "init.pid", original_pid)
    record(root, "init-ppid", os.getppid())
    if mode == "before-arm":
        wait_file(root, "arm")
    prctl(PR_SET_PDEATHSIG, signal.SIGKILL)
    if pidfd_dead(parent_fd):
        record(root, "parent-already-dead", "yes")
        os._exit(125)
    os.close(parent_fd)
    record(root, "armed", "yes")
    if mode == "after-arm":
        wait_file(root, "never-release")

    checked(LIBC.unshare(CLONE_NEWNS))
    checked(LIBC.mount(None, b"/", None, (1 << 18) | (1 << 14), None))
    observer = root / "observer-proc"
    observer.mkdir()
    checked(LIBC.mount(b"/proc", os.fsencode(observer), None, 4096, None))
    checked(LIBC.mount(b"proc", b"/proc", b"proc", 0, None))

    # This detached process models helpers before Guix creates its container.
    detached_worker(root, "pre-container.pid")
    if mode == "pre-container":
        wait_file(root, "never-release")

    launcher = os.fork()
    if launcher == 0:
        os.execv(
            guix,
            [
                guix,
                "repl",
                "-q",
                "--",
                str(root / "container.scm"),
                sys.executable,
                SCRIPT,
                str(root),
                mode,
            ],
        )
    record(
        root, "launcher.pid", launcher
    )  # PID in the outer execution namespace
    stopping = False

    def terminate(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, terminate)
    record(root, "supervisor-ready", "yes")
    deadline = None
    while True:
        if stopping and deadline is None:
            os.kill(launcher, signal.SIGTERM)
            deadline = time.monotonic() + 0.25
        if deadline is not None and time.monotonic() >= deadline:
            # PID 1 exiting tears down even detached and TERM-ignoring children.
            os._exit(124)
        child, status = os.waitpid(-1, os.WNOHANG)
        if child == launcher:
            if os.WIFSIGNALED(status):
                record(root, "leader-signal", os.WTERMSIG(status))
                os._exit(128 + os.WTERMSIG(status))
            os._exit(os.WEXITSTATUS(status))
        time.sleep(0.01)


def broker(root, mode, guix):
    uid, gid = os.getuid(), os.getgid()
    parent_fd = os.pidfd_open(os.getpid())
    checked(LIBC.unshare(CLONE_NEWUSER))
    Path("/proc/self/uid_map").write_text(f"0 {uid} 1\n")
    Path("/proc/self/setgroups").write_text("deny\n")
    Path("/proc/self/gid_map").write_text(f"0 {gid} 1\n")
    checked(LIBC.unshare(CLONE_NEWPID))
    child = os.fork()
    if child == 0:
        supervisor(root, mode, parent_fd, guix)
        os._exit(99)
    os.close(parent_fd)
    _, status = os.waitpid(child, 0)
    record(root, "supervisor-status", status)
    os._exit(0)


CONTAINER = """(use-modules (gnu build linux-container))
(let* ((a (cdr (command-line)))
       (python (list-ref a 0)) (script (list-ref a 1))
       (root (list-ref a 2)) (mode (list-ref a 3))
       (status
        (call-with-container '()
         (lambda () (execl python python script "--payload" root mode))
         #:namespaces '(user pid) #:child-is-pid1? #f
         #:process-spawned-hook (lambda (pid) #t))))
 (exit (or (status:exit-val status) (+ 128 (status:term-sig status)))))
"""


def run_case(mode, guix):
    with tempfile.TemporaryDirectory(prefix="paseo-pdeath-") as directory:
        root = Path(directory)
        (root / "container.scm").write_text(CONTAINER)
        child = os.fork()
        if child == 0:
            try:
                broker(root, mode, guix)
            except BaseException:
                traceback.print_exc()
                os._exit(98)
        broker_fd = os.pidfd_open(child)
        init_fd = None
        identities = []
        try:
            wait_file(root, "init.pid")
            init_fd = os.pidfd_open(int((root / "init.pid").read_text()))
            assert (root / "init-ppid").read_text() == "0"
            if mode == "before-arm":
                signal.pidfd_send_signal(broker_fd, signal.SIGKILL)
                wait_until(lambda: pidfd_dead(broker_fd))
                (root / "arm").touch()
            elif mode == "after-arm":
                wait_file(root, "armed")
                signal.pidfd_send_signal(broker_fd, signal.SIGKILL)
            else:
                wait_file(root, "pre-container.pid")
                names = ["pre-container.pid"]
                if mode != "pre-container":
                    wait_file(root, "payload.pid")
                    wait_file(root, "supervisor-ready")
                    names += ["inner-background.pid", "payload.pid"]
                identities = [
                    os.pidfd_open(int((root / n).read_text())) for n in names
                ]
                if mode.startswith("exit-") or mode == "signal-exit":
                    (root / "finish").touch()
                elif mode == "cancel":
                    signal.pidfd_send_signal(init_fd, signal.SIGTERM)
                else:
                    signal.pidfd_send_signal(broker_fd, signal.SIGKILL)
            wait_until(lambda: pidfd_dead(init_fd))
            wait_until(lambda: all(pidfd_dead(fd) for fd in identities))
            wait_until(lambda: pidfd_dead(broker_fd))
            if mode == "before-arm":
                assert (root / "parent-already-dead").exists()
                assert not (root / "pre-container.pid").exists()
            if mode == "after-arm":
                assert not (root / "pre-container.pid").exists()
            expected = {
                "exit-0": 0,
                "exit-7": 7,
                "signal-exit": 137,
                "cancel": 124,
            }
            if mode in expected:
                status = int((root / "supervisor-status").read_text())
                assert os.waitstatus_to_exitcode(status) == expected[mode], (
                    status
                )
            return {
                "case": mode,
                "passed": True,
                "observed_descendants_exited": len(identities),
            }
        finally:
            # Stable pidfds target only test-owned processes, never recycled PIDs.
            for fd in [init_fd, broker_fd] + identities:
                if fd is not None:
                    if not pidfd_dead(fd):
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    os.close(fd)
            # As a subreaper, own and reap descendants orphaned by the fake broker.
            end = time.monotonic() + TIMEOUT
            while True:
                try:
                    pid, _ = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if not pid:
                    if time.monotonic() > end:
                        raise TimeoutError(
                            "test children were not completely reaped"
                        )
                    time.sleep(0.01)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=1)
    options = parser.parse_args()
    if options.repeat < 1:
        parser.error("--repeat must be positive")
    guix = os.environ.get("GUIX") or shutil.which("guix")
    if not guix:
        raise SystemExit("Set GUIX to the installed guix executable")
    prctl(PR_SET_CHILD_SUBREAPER, 1)
    modes = (
        "before-arm",
        "after-arm",
        "pre-container",
        "running",
        "exit-0",
        "exit-7",
        "signal-exit",
        "cancel",
    )
    initial_fds = len(list(Path("/proc/self/fd").iterdir()))
    for cycle in range(options.repeat):
        for mode in modes:
            result = run_case(mode, guix)
            assert len(list(Path("/proc/self/fd").iterdir())) == initial_fds
            print(json.dumps(dict(result, cycle=cycle + 1)), flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--payload":
        payload(Path(sys.argv[2]), sys.argv[3])
    else:
        main()
