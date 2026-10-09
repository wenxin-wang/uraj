"""Test askpass against a disposable GNOME Keyring, without a desktop.

Put the built ksshaskpass, gnome-keyring, libsecret, dbus and openssh on PATH.
All credentials, sockets and D-Bus services belong to a temporary directory.
"""

import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest


class KeyringAskpassTest(unittest.TestCase):
    """Exercise actual Secret Service lookup and constrained key loading."""

    login_start = False

    def setUp(self):
        names = (
            "ksshaskpass",
            "gnome-keyring-daemon",
            "secret-tool",
            "dbus-daemon",
            "ssh-agent",
            "ssh-add",
            "ssh-keygen",
        )
        self.tools = {name: shutil.which(name) for name in names}
        if not all(self.tools.values()):
            self.skipTest("Required test tools are not on PATH")
        temporary = tempfile.TemporaryDirectory(prefix="uraj-keyring-")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "XDG_RUNTIME_DIR": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_DIRS": str(self.root / "empty"),
            "XDG_CURRENT_DESKTOP": "niri",
            "QT_QPA_PLATFORM": "offscreen",
            "LC_ALL": "C",
        }
        self.log = (self.root / "services.log").open("w+")
        self.addCleanup(self.log.close)
        bus = self.start(
            "dbus-daemon", "--session", "--nofork", "--print-address"
        )
        self.env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
        keyring = self.start(
            "gnome-keyring-daemon",
            "--foreground",
            "--components=secrets",
            "--control-directory=" + str(self.root / "keyring"),
            "--login" if self.login_start else "--unlock",
        )
        keyring.stdin.write("disposable-keyring-password")
        keyring.stdin.close()
        self.key = self.root / "identity"
        self.password = "disposable-ssh-password"
        # Wait for initialization of the control socket before storing secrets.
        deadline = time.monotonic() + 10
        while not (self.root / "keyring/control").exists():
            if keyring.poll() is not None or time.monotonic() > deadline:
                self.fail("Disposable keyring did not start")
            time.sleep(0.05)
        if self.login_start:
            self.run_tool(
                "gnome-keyring-daemon",
                "--start",
                "--components=secrets",
                "--control-directory=" + str(self.root / "keyring"),
            )
        self.run_tool(
            "secret-tool",
            "store",
            "--label=Disposable SSH test",
            "user",
            str(self.key),
            "server",
            "ksshaskpass",
            "type",
            "plaintext",
            input_text=self.password,
        )

    def start(self, tool, *args):
        """Start and register cleanup for an isolated fixture process."""
        process = subprocess.Popen(
            [self.tools[tool], *args],
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
        )

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()

        self.addCleanup(stop)
        return process

    def run_tool(self, tool, *args, input_text=None, check=True):
        """Run a fixture tool without displaying credentials in test output."""
        result = subprocess.run(
            [self.tools[tool], *map(str, args)],
            env=self.env,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_lookup_and_destination_constrained_load(self):
        result = self.run_tool(
            "ksshaskpass", f"Enter passphrase for {self.key}: "
        )
        self.assertTrue(result.stdout.rstrip("\n") == self.password)
        self.run_tool(
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            self.password,
            "-f",
            self.key,
        )
        host = self.root / "host"
        self.run_tool("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", host)
        known_hosts = self.root / "known_hosts"
        known_hosts.write_text(
            "allowed.test " + host.with_suffix(".pub").read_text()
        )
        socket = self.root / "ssh.sock"
        self.start("ssh-agent", "-D", "-a", str(socket))
        deadline = time.monotonic() + 10
        while not socket.exists():
            if time.monotonic() > deadline:
                self.fail("Fixture SSH agent did not start")
            time.sleep(0.05)
        self.env.update(
            SSH_AUTH_SOCK=str(socket),
            SSH_ASKPASS=self.tools["ksshaskpass"],
            SSH_ASKPASS_REQUIRE="force",
        )
        self.run_tool(
            "ssh-add", "-H", known_hosts, "-h", "git@allowed.test", self.key
        )
        identities = self.run_tool("ssh-add", "-L").stdout
        self.assertEqual(
            identities.strip(), self.key.with_suffix(".pub").read_text().strip()
        )
        # ssh-add -T requests an arbitrary signature without a destination
        # binding. A constrained identity must refuse it even after unlock.
        result = self.run_tool(
            "ssh-add", "-T", self.key.with_suffix(".pub"), check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "keyring/ssh").exists())


class KeyringLoginStartupTest(KeyringAskpassTest):
    """Simulate PAM's --login followed by the graphical session's --start."""

    login_start = True


if __name__ == "__main__":
    unittest.main()
