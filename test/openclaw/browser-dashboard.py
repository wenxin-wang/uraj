"""Exercise dashboard forwarding with real streams, without Docker or SSH."""

import argparse
import importlib.util
import json
import os
import pty
import select
import shlex
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "scripts/openclaw/browser-dashboard.py"
)
SPEC = importlib.util.spec_from_file_location("browser_dashboard", SCRIPT)
DASHBOARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DASHBOARD)


class EchoRequest(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)


class EchoServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


class DashboardTest(unittest.TestCase):
    def serve(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.addCleanup(stop)
        return server.server_address

    def forward(self):
        upstream = self.serve(EchoServer(("127.0.0.1", 0), EchoRequest))
        server = DASHBOARD.ForwardServer(
            0, [sys.executable, "-c", DASHBOARD.RELAY, str(upstream[1])]
        )
        return server, self.serve(server)

    def test_binary_streams_and_half_close(self):
        _, address = self.forward()
        payload = bytes(range(256)) * 1024
        with (
            socket.create_connection(address, timeout=5) as first,
            socket.create_connection(address, timeout=5) as second,
        ):
            first.sendall(payload)
            first.shutdown(socket.SHUT_WR)
            # A long-lived stream must not block another connection.
            second.sendall(b"second session")
            self.assertEqual(second.recv(1024), b"second session")
            received = bytearray()
            while data := first.recv(65536):
                received.extend(data)
            self.assertEqual(received, payload)

    def test_close_terminates_active_forwarders(self):
        server, address = self.forward()
        with socket.create_connection(address, timeout=5) as client:
            client.sendall(b"connected")
            self.assertEqual(client.recv(1024), b"connected")
            with server.process_lock:
                processes = list(server.processes)
            self.assertEqual(len(processes), 1)
            server.server_close()
            self.assertIsNotNone(processes[0].poll())
            self.assertEqual(client.recv(1024), b"")

    def test_hangup_cleans_up_a_running_helper(self):
        upstream = self.serve(EchoServer(("127.0.0.1", 0), EchoRequest))
        source = f"""
import importlib.util
import signal
import sys
spec = importlib.util.spec_from_file_location("dashboard", {str(SCRIPT)!r})
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)
signal.signal(signal.SIGHUP, dashboard.stop_forwarding)
try:
    with dashboard.ForwardServer(
        0, [sys.executable, "-c", dashboard.RELAY, {str(upstream[1])!r}]
    ) as server:
        print(server.server_address[1], flush=True)
        server.serve_forever()
except KeyboardInterrupt:
    pass
"""
        with subprocess.Popen(
            [sys.executable, "-c", source], stdout=subprocess.PIPE
        ) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                port = int(process.stdout.readline())
                with socket.create_connection(
                    ("127.0.0.1", port), timeout=5
                ) as client:
                    client.sendall(b"connected")
                    self.assertEqual(client.recv(1024), b"connected")
                    process.send_signal(signal.SIGHUP)
                    self.assertEqual(process.wait(timeout=5), 0)
                    self.assertEqual(client.recv(1024), b"")
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)

    def ssh_args(self, **overrides):
        return argparse.Namespace(
            **(
                {
                    "ssh": "storie",
                    "list": False,
                    "container": "sandbox",
                    "port": 4850,
                    "dashboard_port": 4848,
                }
                | overrides
            )
        )

    def test_ssh_keeps_tty_separate_from_forwarded_bytes(self):
        command = DASHBOARD.ssh_command(self.ssh_args())
        self.assertEqual(
            command[:-1],
            [
                "ssh",
                "-tt",
                "-o",
                "ExitOnForwardFailure=yes",
                "-o",
                "ControlPath=none",
                "-L",
                "127.0.0.1:4850:127.0.0.1:4850",
                "--",
                "storie",
            ],
        )

    def test_ssh_list_prompts_without_starting_a_tunnel(self):
        command = DASHBOARD.ssh_command(self.ssh_args(list=True))
        self.assertNotIn("-L", command)
        self.assertIn("-tt", command)
        remote = shlex.split(command[-1])
        self.assertEqual(remote[:3], ["sudo", "--", "/etc/openclaw/compose"])
        self.assertEqual(
            remote[-3:], ["ps", "--format", "{{.Names}}\t{{.Status}}"]
        )

    def test_privileged_helper_does_not_repeat_sudo(self):
        with mock.patch.object(DASHBOARD.os, "geteuid", return_value=0):
            command = DASHBOARD.engine_command(["exec", "sandbox", "python3"])
        self.assertEqual(command[0], "/etc/openclaw/compose")
        self.assertNotIn("sudo", command)

    def test_dashboard_start_drops_launch_defaults_keeps_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "environment.json"
            executable = root / "agent-browser"
            executable.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                f"Path({str(output)!r}).write_text(json.dumps(\n"
                "    [sys.argv[1:], dict(os.environ)]))\n"
            )
            executable.chmod(0o700)
            with (
                mock.patch.object(sys, "argv", [str(SCRIPT), "sandbox"]),
                mock.patch.dict(
                    os.environ,
                    {
                        "PATH": directory + os.pathsep + os.environ["PATH"],
                        "AGENT_BROWSER_SOCKET_DIR": "/tmp/role-daemons",
                        "AGENT_BROWSER_HEADED": "1",
                        "AGENT_BROWSER_EXECUTABLE_PATH": "/bin/chromium",
                        "AGENT_BROWSER_ARGS": "--enable-gpu",
                    },
                    clear=True,
                ),
                mock.patch.object(
                    DASHBOARD, "engine_command", side_effect=lambda a: a[2:]
                ),
                mock.patch.object(DASHBOARD, "ForwardServer"),
                mock.patch("builtins.print"),
            ):
                DASHBOARD.main()
            arguments, environment = json.loads(output.read_text())
            self.assertEqual(
                arguments, ["dashboard", "start", "--port", "4848"]
            )
            self.assertEqual(
                environment["AGENT_BROWSER_SOCKET_DIR"], "/tmp/role-daemons"
            )
            for key in (
                "AGENT_BROWSER_HEADED",
                "AGENT_BROWSER_EXECUTABLE_PATH",
                "AGENT_BROWSER_ARGS",
            ):
                self.assertNotIn(key, environment)

    def test_remote_shell_prompts_and_preserves_helper_arguments(self):
        # Exercise the exact remote shell command on a real PTY. This fake
        # sudo only asks for a disposable test password; it never elevates.
        source = "import json, sys; print('helper:' + json.dumps(sys.argv[1:]))"
        container = "sandbox ' ; $(exit 42)"
        with mock.patch.object(Path, "read_text", return_value=source):
            remote = DASHBOARD.ssh_command(self.ssh_args(container=container))[
                -1
            ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "python3").symlink_to(sys.executable)
            sudo = root / "sudo"
            sudo.write_text(
                f"#!{sys.executable}\n"
                "import getpass, os, sys\n"
                "assert sys.argv[1] == '--'\n"
                "assert getpass.getpass('sudo password: ') == 'test-only'\n"
                "os.execv(sys.argv[2], sys.argv[2:])\n"
            )
            sudo.chmod(0o700)
            pid, terminal = pty.fork()
            if pid == 0:
                os.execve(
                    "/bin/sh",
                    ["sh", "-c", remote],
                    os.environ | {"PATH": directory},
                )
            output = bytearray()
            prompted = False
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if not select.select([terminal], [], [], 0.1)[0]:
                        continue
                    try:
                        data = os.read(terminal, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output.extend(data)
                    if b"sudo password: " in output and not prompted:
                        os.write(terminal, b"test-only\n")
                        prompted = True
                self.assertTrue(prompted, output)
                self.assertNotIn(b"test-only", output)
                self.assertIn(
                    b"helper:"
                    + json.dumps(
                        [
                            "--port",
                            "4850",
                            "--dashboard-port",
                            "4848",
                            "--",
                            container,
                        ]
                    ).encode(),
                    output,
                )
            finally:
                os.close(terminal)
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main()
