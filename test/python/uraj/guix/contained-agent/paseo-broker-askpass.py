"""Exercise host-only askpass settings with a disposable encrypted SSH key."""

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

BROKER_PATH = (
    pathlib.Path(__file__).resolve().parents[5]
    / "src/python/uraj/paseo/broker.py"
)
SPEC = importlib.util.spec_from_file_location("paseo_broker", BROKER_PATH)
broker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(broker)


class AskpassEnvironmentTest(unittest.TestCase):
    def test_host_desktop_settings_are_preserved(self):
        desktop = {
            "SSH_ASKPASS": "/trusted/askpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":7",
            "WAYLAND_DISPLAY": "wayland-7",
            "XAUTHORITY": "/trusted/authority",
            "XDG_RUNTIME_DIR": "/run/user/1234",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/trusted/bus",
        }
        with mock.patch.dict(os.environ, desktop, clear=True):
            env = broker.launcher_environment("/trusted/home", {}, {})
        for name, value in desktop.items():
            self.assertEqual(env[name], value)

    def test_client_cannot_select_host_askpass_or_desktop(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            for name in (
                "SSH_ASKPASS",
                "SSH_ASKPASS_REQUIRE",
                "DISPLAY",
                "WAYLAND_DISPLAY",
                "XAUTHORITY",
                "XDG_RUNTIME_DIR",
                "DBUS_SESSION_BUS_ADDRESS",
            ):
                with self.subTest(name=name):
                    request = {
                        "version": 1,
                        "type": "start",
                        "provider": "codex",
                        "argv": [],
                        "cwd": directory,
                        "env": {name: "untrusted"},
                    }
                    with self.assertRaisesRegex(
                        ValueError, "invalid environment"
                    ):
                        broker.validate_start_request(request, [home], home)

    def test_encrypted_key_unlock_without_terminal(self):
        tools = {
            name: shutil.which(name)
            for name in ("ssh-add", "ssh-agent", "ssh-keygen")
        }
        self.assertTrue(all(tools.values()), "OpenSSH test tools are required")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            key = root / "key"
            subprocess.run(
                [
                    tools["ssh-keygen"],
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "test-only-passphrase",
                    "-f",
                    str(key),
                ],
                check=True,
                capture_output=True,
                timeout=10,
            )
            askpass = root / "askpass"
            askpass.write_text(
                f"#!{sys.executable}\n"
                "import os\n"
                "assert os.environ['DISPLAY'] == ':7'\n"
                "print('test-only-passphrase')\n"
            )
            askpass.chmod(0o700)
            sock = root / "ssh.sock"
            agent = subprocess.Popen(
                [tools["ssh-agent"], "-D", "-a", str(sock)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 5
                while not sock.exists():
                    self.assertIsNone(agent.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                with mock.patch.dict(
                    os.environ,
                    {
                        "SSH_ASKPASS": str(askpass),
                        "SSH_ASKPASS_REQUIRE": "force",
                        "DISPLAY": ":7",
                    },
                    clear=True,
                ):
                    env = broker.launcher_environment(root, {}, {})
                # contained-ssh supplies the project socket after env filtering.
                env["SSH_AUTH_SOCK"] = str(sock)
                result = subprocess.run(
                    [tools["ssh-add"], str(key)],
                    env=env,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    start_new_session=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                listed = subprocess.run(
                    [tools["ssh-add"], "-L"],
                    env=env,
                    check=True,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(
                    listed.stdout.decode().strip(),
                    key.with_suffix(".pub").read_text().strip(),
                )
            finally:
                agent.terminate()
                try:
                    agent.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    agent.kill()
                    agent.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
