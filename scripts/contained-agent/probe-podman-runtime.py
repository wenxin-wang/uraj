#!/usr/bin/env python3
"""Probe namespace/socket plumbing; this is not a production Podman sandbox."""

import argparse
import errno
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def serve(base, podman):
    shared = base / "shared"
    checks = {
        "unshared_path_hidden": not (base / "hidden").exists(),
        "symlink_cannot_reach_unshared_path": not (shared / "escape").exists(),
        "same_uid": os.getuid() == int(os.environ["PROBE_UID"]),
    }
    try:
        (shared / "readonly" / "protected").write_text("changed")
    except OSError:
        checks["readonly_write_denied"] = True
    else:
        checks["readonly_write_denied"] = False
    # A descendant user namespace gains mount capabilities there, but must
    # still be unable to turn the inherited read-only bind into a writable one.
    remount = subprocess.run(
        [
            "unshare",
            "--user",
            "--map-root-user",
            "--mount",
            sys.executable,
            "-c",
            "import ctypes, sys; "
            "libc = ctypes.CDLL(None, use_errno=True); "
            "rc = libc.mount(None, sys.argv[1].encode(), None, "
            "4096 | 32, None); "
            "print(ctypes.get_errno() if rc else 0)",
            str(shared / "readonly"),
        ],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    checks["descendant_readonly_remount_denied"] = (
        remount.returncode == 0 and remount.stdout.strip() == str(errno.EPERM)
    )
    (shared / "output").write_text("runtime output")
    result = {"checks": checks}
    if podman:
        command = [
            podman,
            "--storage-driver=vfs",
            "--root",
            str(base / "state" / "storage"),
            "--runroot",
            str(base / "state" / "run"),
            "info",
            "--debug",
        ]
        try:
            probe = subprocess.run(
                command, capture_output=True, text=True, timeout=20, check=False
            )
            result["podman_info"] = {
                "exit_code": probe.returncode,
                "stdout": probe.stdout,
                "stderr": probe.stderr,
            }
        except subprocess.TimeoutExpired:
            result["podman_info"] = {"error": "timeout"}
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(base / "socket" / "api.sock"))
        listener.listen(1)
        listener.settimeout(15)
        connection, _ = listener.accept()
        with connection:
            connection.sendall(json.dumps(result).encode())


def client(base):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(base / "socket" / "api.sock"))
        chunks = []
        while chunk := connection.recv(65536):
            chunks.append(chunk)
    result = json.loads(b"".join(chunks))
    result["checks"]["same_path_output_visible"] = (
        base / "shared" / "output"
    ).read_text() == "runtime output"
    print(json.dumps(result, indent=2))


def sandbox(base, role, podman):
    command = [
        shutil.which("bwrap"),
        "--die-with-parent",
        "--new-session",
        "--unshare-user",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--unshare-net",
        "--cap-drop",
        "ALL",
        "--clearenv",
        "--ro-bind",
        "/gnu/store",
        "/gnu/store",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp",
        "--ro-bind",
        str(Path(__file__).resolve()),
        "/probe.py",
    ]
    for name in ("shared", "socket", "state"):
        path = str(base / name)
        mode = "--ro-bind" if role == "client" else "--bind"
        command.extend([mode, path, path])
    protected = str(base / "shared" / "readonly")
    command.extend(["--ro-bind", protected, protected])
    for key, value in {
        "HOME": str(base / "state"),
        "XDG_RUNTIME_DIR": str(base / "state"),
        "PATH": os.environ["PATH"],
        "PROBE_UID": str(os.getuid()),
    }.items():
        command.extend(["--setenv", key, value])
    command.extend(
        ["--", sys.executable, "/probe.py", "--role", role, "--base", str(base)]
    )
    if podman:
        command.extend(["--podman", podman])
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--podman", help="Absolute Guix store Podman executable"
    )
    parser.add_argument("--role", choices=("server", "client"))
    parser.add_argument("--base", type=Path)
    args = parser.parse_args()
    if args.role == "server":
        serve(args.base, args.podman)
        return
    if args.role == "client":
        client(args.base)
        return
    if not shutil.which("bwrap"):
        parser.error("bwrap is required")
    if not shutil.which("unshare"):
        parser.error("unshare is required")
    with tempfile.TemporaryDirectory(prefix="podman-runtime-probe-") as temp:
        base = Path(temp)
        for name in ("shared/readonly", "socket", "state"):
            (base / name).mkdir(parents=True, mode=0o700)
        (base / "hidden").write_text("must not be exposed")
        (base / "shared" / "escape").symlink_to(base / "hidden")
        protected = base / "shared" / "readonly" / "protected"
        protected.write_text("original")
        with tempfile.TemporaryFile(mode="w+") as log:
            server = subprocess.Popen(
                sandbox(base, "server", args.podman), stdout=log, stderr=log
            )
            try:
                deadline = time.monotonic() + 30
                while not (base / "socket" / "api.sock").exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("runtime failed: " + log.read())
                    time.sleep(0.05)
                probe = subprocess.run(
                    sandbox(base, "client", None),
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=True,
                )
                result = json.loads(probe.stdout)
                result["checks"]["host_output_visible"] = (
                    base / "shared" / "output"
                ).read_text() == "runtime output"
                result["checks"]["host_readonly_file_unchanged"] = (
                    protected.read_text() == "original"
                )
                print(json.dumps(result, indent=2))
                if not all(result["checks"].values()):
                    raise RuntimeError("namespace/socket check failed")
                server.wait(timeout=5)
                if server.returncode:
                    raise RuntimeError("runtime exited unsuccessfully")
                if args.podman and result["podman_info"].get("exit_code") != 0:
                    sys.exit(2)
            finally:
                if server.poll() is None:
                    server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    main()
