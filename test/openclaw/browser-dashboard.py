"""Exercise dashboard forwarding with real streams, without Docker or SSH."""

import importlib.util
import shlex
import socket
import socketserver
import sys
import threading
import unittest
from pathlib import Path

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

    def test_ssh_preserves_remote_arguments(self):
        arguments = [
            "exec",
            "sandbox",
            "python3",
            "-c",
            DASHBOARD.RELAY,
            "4848",
        ]
        command = DASHBOARD.engine_command("storie", arguments)
        self.assertEqual(
            command[:-1],
            ["ssh", "-T", "-o", "BatchMode=yes", "--", "storie"],
        )
        self.assertEqual(
            shlex.split(command[-1]), DASHBOARD.engine_command(None, arguments)
        )


if __name__ == "__main__":
    unittest.main()
