"""Test daemon SSH policy and owner-death cleanup using disposable keys.

Set ARTIFACTS to the built Paseo repair/test bundle containing sandbox-helper,
supervisor and profile. No live daemon, credentials, or remote SSH are used.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


class SandboxTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="paseo-ssh-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.artifacts = Path(os.environ["ARTIFACTS"])
        self.record = self.home / "observed.json"
        self.key = self.home / "private-key"
        host = self.home / "host-key"
        for path in (self.key, host):
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "test-password" if path == self.key else "",
                    "-f",
                    str(path),
                ],
                check=True,
            )
        known = self.home / "known_hosts"
        known.write_text("example.test " + host.with_suffix(".pub").read_text())
        self.policy = self.home / ".config/paseo/sandbox.scm"
        self.policy.parent.mkdir(parents=True)
        self.shared = self.home / "shared"
        self.shared.mkdir()
        self.policy.write_text(
            f'(share "{self.shared}")\n'
            '(preserve "PASEO_TEST_VALUE")\n'
            "(ssh-agent\n"
            f'  (known-hosts "{known}")\n'
            '  (client-config "Host example.test\\n  User git\\n")\n'
            f'  (identity "{self.key}" (destinations "example.test")))\n'
        )
        self.fake_guix = self.home / "guix"
        self.fake_guix.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, subprocess, sys, time\n"
            "args = sys.argv[1:]\n"
            "socket = next(x.split('=', 2)[1] for x in args "
            "if x.endswith('=/run/paseo/ssh.sock'))\n"
            f"keys = subprocess.check_output([{shutil.which('ssh-add')!r}, '-L'], "
            "env=dict(os.environ, SSH_AUTH_SOCK=socket), text=True)\n"
            f"pathlib.Path({str(self.record)!r}).write_text(json.dumps("
            "dict(args=args, socket=socket, keys=keys, tmp=os.environ['TMPDIR'])))\n"
            "while True: time.sleep(1)\n"
        )
        self.fake_guix.chmod(0o700)
        connection = self.home / ".local/state/paseo-broker/connection"
        connection.mkdir(parents=True)
        self.broker = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.broker.bind(str(connection / "socket"))
        self.broker.listen(8)
        self.addCleanup(self.broker.close)
        askpass = self.home / "askpass"
        askpass.write_text(
            f"#!{shutil.which('bash')}\nprintf '%s\\n' test-password\n"
        )
        askpass.chmod(0o700)
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            PASEO_TEST_VALUE="test",
            SSH_ASKPASS=str(askpass),
            SSH_ASKPASS_REQUIRE="force",
        )
        subprocess.run(
            [str(self.artifacts / "service"), "activate"],
            env=self.env,
            check=True,
        )
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            process.stdout.close()
            process.stderr.close()

    def launch(self):
        process = subprocess.Popen(
            [
                str(self.artifacts / "service"),
                "run",
                "--guix",
                str(self.fake_guix),
                "--profile",
                str(self.artifacts / "profile"),
                "--supervisor",
                str(self.artifacts / "supervisor"),
                "--sandbox-helper",
                str(self.artifacts / "sandbox-helper"),
            ],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        return process

    def wait_for_record(self, process):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.record.exists():
                return json.loads(self.record.read_text())
            if process.poll() is not None:
                self.fail(process.stderr.read().decode())
            time.sleep(0.05)
        self.fail("daemon workload did not start")

    def assert_socket_dead(self, path):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with socket.socket(socket.AF_UNIX) as peer:
                try:
                    peer.connect(path)
                except (FileNotFoundError, ConnectionRefusedError):
                    return
            time.sleep(0.05)
        self.fail("SSH agent survived its owner")

    def test_policy_and_graceful_stop(self):
        process = self.launch()
        record = self.wait_for_record(process)
        self.assertIn(f"--share={self.shared}", record["args"])
        self.assertIn("--preserve=^PASEO_TEST_VALUE$", record["args"])
        self.assertIn(
            self.key.with_suffix(".pub").read_text().split()[1], record["keys"]
        )
        self.assertNotIn(str(self.key), " ".join(record["args"]))
        self.assertEqual(record["tmp"], str(self.home / ".cache/paseo-tmp"))
        self.assertLessEqual(len(os.fsencode(record["socket"])), 107)
        process.terminate()
        process.wait(timeout=15)
        self.assert_socket_dead(record["socket"])
        self.assertFalse(
            list((self.home / ".local/state/paseo-sandbox").glob("ssh-*"))
        )

    def test_owner_death_and_restart(self):
        process = self.launch()
        first = self.wait_for_record(process)
        process.kill()
        process.wait(timeout=10)
        self.assert_socket_dead(first["socket"])
        self.record.unlink()
        replacement = self.launch()
        second = self.wait_for_record(replacement)
        self.assertNotEqual(first["socket"], second["socket"])
        self.assertFalse(Path(first["socket"]).exists())

    def test_invalid_policy_never_starts_daemon(self):
        self.policy.write_text('(system "touch should-not-execute")\n')
        process = self.launch()
        process.wait(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
