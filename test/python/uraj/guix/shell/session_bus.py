"""Exercise SSH bus discovery with private sockets and process environments.

Run: python3 test/python/uraj/guix/shell/session_bus.py
No host desktop, keyring, or network is accessed.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROFILE = (
    Path(__file__).resolve().parents[5]
    / "env/dotfiles/desktop/shell/.profile.d/65-session-bus.sh"
)


class SessionBus(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="uraj-session-bus-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {
            "HOME": str(self.root),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "XDG_RUNTIME_DIR": str(self.root),
            "SSH_CONNECTION": "192.0.2.1 12345 192.0.2.2 23333",
        }
        # Restrict discovery to fixture processes even on a real desktop.
        pgrep = self.bin / "pgrep"
        pgrep.write_text(
            '#!/bin/sh\n[ "$1" = -u ] && [ "$2" = "$(id -u)" ] && '
            '[ "$3" = -x ] && [ "$4" = niri ] || exit 1\n'
            'printf "%s\\n" "${TEST_SESSION_PID:-}"\n'
        )
        pgrep.chmod(0o755)

    def make_socket(self, name):
        path = self.root / name
        server = socket.socket(socket.AF_UNIX)
        self.addCleanup(server.close)
        server.bind(str(path))
        return f"unix:path={path}"

    def desktop(self, address):
        process = subprocess.Popen(
            [sys.executable, "-c", "import sys; sys.stdin.read()"],
            env={
                **self.environment,
                "DBUS_SESSION_BUS_ADDRESS": address,
                "UNRELATED_DESKTOP_VALUE": "must-not-be-imported",
            },
            stdin=subprocess.PIPE,
        )
        self.addCleanup(process.stdin.close)
        self.addCleanup(process.wait, 5)
        self.addCleanup(process.terminate)
        self.environment["TEST_SESSION_PID"] = str(process.pid)

    def discover(self, **overrides):
        result = subprocess.run(
            [
                shutil.which("sh"),
                "-eu",
                "-c",
                '. "$1"; printf "%s\\n%s\\n" '
                '"${DBUS_SESSION_BUS_ADDRESS-}" '
                '"${UNRELATED_DESKTOP_VALUE-}"',
                "session-bus-test",
                str(PROFILE),
            ],
            env={**self.environment, **overrides},
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        self.assertEqual(result.stderr, "")
        address, unrelated = result.stdout.splitlines()
        self.assertEqual(unrelated, "")
        return address

    def test_discovers_live_desktop_socket_with_guid(self):
        address = self.make_socket("desktop") + ",guid=fixture"
        self.desktop(address)
        self.assertEqual(self.discover(), address)

    def test_preserves_existing_bus_and_local_sessions(self):
        self.desktop(self.make_socket("desktop"))
        existing = "unix:path=/explicit/session"
        self.assertEqual(
            self.discover(DBUS_SESSION_BUS_ADDRESS=existing), existing
        )
        self.assertEqual(self.discover(SSH_CONNECTION=""), "")

    def test_prefers_standard_user_bus(self):
        self.desktop(self.make_socket("desktop"))
        standard = self.make_socket("bus")
        self.assertEqual(self.discover(), standard)

    def test_absent_desktop_and_stale_socket(self):
        self.assertEqual(self.discover(), "")
        self.desktop(f"unix:path={self.root}/gone")
        self.assertEqual(self.discover(), "")
        (self.root / "gone").touch()
        self.assertEqual(self.discover(), "")


if __name__ == "__main__":
    unittest.main()
