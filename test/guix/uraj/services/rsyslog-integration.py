"""Run with python3 FILE /gnu/store/...-rsyslog-.../sbin/rsyslogd.

Exercise the production rules with a private socket and temporary destinations.
Use the caller's UID/groups so the test needs no root privileges.
"""
import grp
import os
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import sys
import tempfile
import time


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for rsyslog")


binary = sys.argv[1]
source = Path("src/guix/uraj/services/rsyslog.conf").read_text()
gid = next((g for g in os.getgroups() if g != os.getgid()), os.getgid())
with tempfile.TemporaryDirectory(prefix="uraj-rsyslog-") as temp:
    directory = Path(temp)
    sockpath = directory / "socket"
    config = source.replace(
        'module(load="imuxsock")',
        f'module(load="imuxsock" SysSock.Name="{sockpath}")',
    )
    config = config.replace('fileOwner="root"', f'fileOwner="{pwd.getpwuid(os.getuid()).pw_name}"')
    config = config.replace('fileGroup="root"', f'fileGroup="{grp.getgrgid(os.getgid()).gr_name}"')
    config = config.replace('fileGroup="log-readers"', f'fileGroup="{grp.getgrgid(gid).gr_name}"')
    config = config.replace("/var/log/", f"{directory}/")
    config = config.replace("/dev/tty12", f"{directory}/tty12")
    config = config.replace("/dev/console", f"{directory}/console")
    conf = directory / "rsyslog.conf"
    conf.write_text(config)
    subprocess.run([binary, "-N1", "-f", str(conf)], check=True)
    # Validate the kernel module above, but never consume host kernel logs.
    conf.write_text(config.replace('module(load="imklog")', ""))
    errors = directory / "stderr"
    with errors.open("w") as stderr:
        process = subprocess.Popen(
            [binary, "-n", "-i", str(directory / "pid"), "-f", str(conf)],
            stdout=subprocess.DEVNULL, stderr=stderr,
        )
        try:
            wait_for(sockpath.exists)

            def send(priority, message):
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
                    sock.sendto(f"<{priority}>uraj-test: {message}".encode(), str(sockpath))

            def contains(name, text):
                file = directory / name
                return file.exists() and text in file.read_text()

            for priority, text, target in (
                (14, "ordinary-message", "messages"),
                (15, "debug-message", "debug"),
                (38, "auth-message", "secure"),
                (86, "private-message", "secure"),
                (22, "mail-message", "maillog"),
            ):
                send(priority, text)
                wait_for(lambda: contains(target, text))
            send(14, "end-of-routing-check")
            wait_for(lambda: contains("messages", "end-of-routing-check"))
            messages = directory / "messages"
            text = messages.read_text()
            assert "debug-message" in text
            assert not any(s in text for s in ("auth-message", "private-message", "mail-message"))
            assert messages.stat().st_gid == gid
            assert messages.stat().st_mode & 0o777 == 0o640
            for name in ("secure", "debug", "maillog"):
                assert (directory / name).stat().st_gid == os.getgid()
                assert (directory / name).stat().st_mode & 0o777 == 0o640

            # Exercise precisely the copy/truncate primitives used by Shepherd.
            inode = messages.stat().st_ino
            subprocess.run([
                "guile", "--no-auto-compile", "-c",
                '(let ((file (cadr (command-line)))) '
                '(copy-file file (string-append file ".1")) (truncate-file file 0))',
                str(messages),
            ], check=True)
            send(14, "after-rotation")
            wait_for(lambda: contains("messages", "after-rotation"))
            assert messages.stat().st_ino == inode
            assert messages.stat().st_gid == gid
            assert "ordinary-message" in (directory / "messages.1").read_text()

            # A missing live log is recreated with the configured group.
            messages.unlink()
            process.send_signal(signal.SIGHUP)
            time.sleep(0.2)
            send(14, "after-reopen")
            wait_for(lambda: contains("messages", "after-reopen"))
            assert messages.stat().st_gid == gid
            assert messages.stat().st_mode & 0o777 == 0o640
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    assert process.returncode == 0, errors.read_text()
    assert not errors.read_text(), errors.read_text()
print("PASS: routing, private logs, group permissions, copy/truncate, recreation")
