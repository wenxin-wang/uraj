"""Test shared SSH preparation with real namespaces and disposable keys.

Requires SUPERVISOR, Guix/Guile, Git, and OpenSSH. Guix shell is replaced by a
probe; no Guix daemon, network, user keys, or live broker are used.
"""

import ctypes
import json
import os
import pathlib
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[5]


def wait_until(predicate):
    deadline = time.monotonic() + 15
    while not predicate():
        if time.monotonic() > deadline:
            raise TimeoutError("test condition did not complete")
        time.sleep(0.02)


class SharedSSHTest(unittest.TestCase):
    def setUp(self):
        self.assertEqual(ctypes.CDLL(None).prctl(36, 1, 0, 0, 0), 0)
        self.temporary = tempfile.TemporaryDirectory(prefix="ssh-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.project = self.home / "src" / "project"
        self.project.mkdir(parents=True)
        self.runtime = self.root / "run"
        self.runtime.mkdir(mode=0o700)
        # Reproduce persistent Home paths: the previous execution-ssh-/keys
        # layout exceeded Linux's socket path limit with this base length.
        self.broker_directory = self.runtime / "broker"
        padding = max(0, 40 - len(os.fsencode(self.broker_directory)))
        self.broker_directory = self.runtime / ("broker" + "x" * padding)
        self.tools = {
            name: shutil.which(name)
            for name in (
                "guix",
                "git",
                "bash",
                "sha256sum",
                "ssh-agent",
                "ssh-add",
                "ssh-keygen",
            )
        }
        self.assertTrue(all(self.tools.values()), self.tools)
        subprocess.run(
            [self.tools["git"], "init", "-q", str(self.project)], check=True
        )
        self.key = self.root / "key"
        host_key = self.root / "host-key"
        for path, password in ((self.key, "test-password"), (host_key, "")):
            subprocess.run(
                [
                    self.tools["ssh-keygen"],
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    password,
                    "-f",
                    str(path),
                ],
                check=True,
            )
        self.known = self.root / "known_hosts"
        self.known.write_text(
            "example.test " + host_key.with_suffix(".pub").read_text()
        )
        self.policy = self.root / "policy.scm"
        self.write_policy()
        self.prompts = self.root / "prompts"
        askpass = self.root / "askpass"
        askpass.write_text(
            f"#!{sys.executable}\n"
            + f"with open({str(self.prompts)!r}, 'a') as log: log.write('prompt\\n')\n"
            "print('test-password')\n"
        )
        askpass.chmod(0o700)
        driver = self.root / "driver.scm"
        tool_names = ("ssh-agent", "ssh-add", "bash", "sha256sum")
        driver.write_text(
            "(use-modules (uraj bin contained-agent))\n"
            f'(setenv "HOME" {json.dumps(str(self.home))})\n'
            '(contained-agent-main (cons "contained-agent" (cdr (command-line)))\n'
            ' #:agents \'(("codex" (program . "/bin/true")))\n'
            " #:common '() #:packages '()\n"
            f" #:projects-file {json.dumps(str(self.policy))}\n"
            f" #:git {json.dumps(self.tools['git'])}\n"
            " #:ssh-tools '("
            + " ".join(
                f"({name} . {json.dumps(self.tools[name])})"
                for name in tool_names
            )
            + "))\n"
        )
        launcher = self.root / "launcher"
        launcher.write_text(
            "#!/bin/sh\nexec "
            + shlex.join(
                [
                    self.tools["guix"],
                    "repl",
                    "-L",
                    str(SOURCE / "src/guile"),
                    "--",
                    str(driver),
                ]
            )
            + ' "$@"\n'
        )
        launcher.chmod(0o700)
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        probe = binary_dir / "guix"
        probe.write_text(
            f"#!{sys.executable}\n"
            + """
import os, subprocess, sys, time
mounts = [arg for arg in sys.argv if arg.startswith('--expose=') and '/ssh.sock=' in arg]
if not mounts:
    print('no-ssh'); sys.exit(0)
sock = mounts[0].split('=', 2)[1]
result = subprocess.run([SSH_ADD, '-L'], env=dict(os.environ, SSH_AUTH_SOCK=sock),
                        capture_output=True, check=True)
print(sock, flush=True)
if 'hold' in sys.argv:
    while True: time.sleep(1)
""".replace("SSH_ADD", repr(self.tools["ssh-add"]))
        )
        probe.chmod(0o700)
        self.env = dict(
            os.environ,
            PATH=str(binary_dir) + ":" + os.environ["PATH"],
            XDG_RUNTIME_DIR=str(self.runtime),
            SSH_ASKPASS=str(askpass),
            SSH_ASKPASS_REQUIRE="force",
        )
        self.prefix = [
            sys.executable,
            str(SOURCE / "src/python/uraj/paseo/broker.py"),
            "--directory",
            str(self.broker_directory),
        ]
        self.command = self.prefix + [
            "serve",
            "--shared-ssh",
            "--supervisor",
            os.environ["SUPERVISOR"],
            "--launcher",
            str(launcher),
            "--root",
            str(self.home / "src"),
        ]
        self.clients = []
        self.server = subprocess.Popen(
            self.command, env=self.env, stderr=subprocess.PIPE
        )
        self.addCleanup(self.stop_processes)
        wait_until(
            lambda: (self.broker_directory / "connection/socket").exists()
            or self.server.poll() is not None
        )
        self.assertIsNone(self.server.poll())

    def write_policy(self, destination="example.test"):
        self.policy.write_text(
            f'(project "{self.project}" (ssh-agent (known-hosts "{self.known}") '
            f'(identity "{self.key}" (destinations "{destination}"))))\n'
        )

    def stop_processes(self):
        if self.server.poll() is None:
            self.server.terminate()
        try:
            self.server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait(timeout=5)
        self.server.stderr.close()
        for process in self.clients:
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)
        # Subreaper collects the deliberately orphaned supervised namespace.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                time.sleep(0.02)

    def client(self, *args, cwd=None):
        env = dict(self.env)
        env.pop("PASEO_AGENT_ID", None)
        env.pop("PASEO_AGENT_CWD", None)
        process = subprocess.Popen(
            self.prefix + ["client", "codex", *args],
            cwd=cwd or self.project,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.clients.append(process)
        return process

    def result(self, process):
        output, error = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, error.decode())
        return output.decode().strip()

    def test_concurrent_and_later_sessions_reuse_one_unlock(self):
        self.assertEqual(self.result(self.client("--version")), "no-ssh")
        self.assertEqual(self.result(self.client("auth", "status")), "no-ssh")
        self.assertFalse(self.prompts.exists())
        self.assertFalse(list(self.broker_directory.glob("ssh-*")))
        first, second = self.client(), self.client()
        sock = self.result(first)
        self.assertLessEqual(len(os.fsencode(sock)), 107)
        self.assertEqual(self.result(second), sock)
        self.assertEqual(self.result(self.client()), sock)
        self.assertEqual(self.prompts.read_text().splitlines(), ["prompt"])
        self.assertEqual(self.result(self.client("--version")), "no-ssh")
        self.assertEqual(self.result(self.client("auth", "status")), "no-ssh")
        # A still-running session must retain its socket when another starts.
        held = self.client("hold")
        ready, _, _ = select.select([held.stdout], [], [], 15)
        self.assertTrue(ready)
        self.assertEqual(held.stdout.readline().decode().strip(), sock)
        self.assertEqual(self.result(self.client()), sock)
        held.terminate()
        held.communicate(timeout=10)
        self.assertEqual(self.result(self.client()), sock)
        self.assertEqual(len(self.prompts.read_text().splitlines()), 1)
        self.write_policy("git@example.test")
        self.assertEqual(self.result(self.client()), sock)
        self.assertEqual(len(self.prompts.read_text().splitlines()), 2)

    def test_worktree_shares_keys_but_other_project_is_separate(self):
        subprocess.run(
            [
                self.tools["git"],
                "-C",
                str(self.project),
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.test",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "fixture",
            ],
            check=True,
        )
        worktree = self.home / "src/worktree"
        subprocess.run(
            [
                self.tools["git"],
                "-C",
                str(self.project),
                "worktree",
                "add",
                "-q",
                "-b",
                "other",
                str(worktree),
            ],
            check=True,
        )
        sock = self.result(self.client())
        self.assertEqual(self.result(self.client(cwd=worktree)), sock)
        self.assertEqual(len(self.prompts.read_text().splitlines()), 1)
        other = self.home / "src/other"
        other.mkdir()
        subprocess.run(
            [self.tools["git"], "init", "-q", str(other)], check=True
        )
        with self.policy.open("a") as policy:
            policy.write(
                self.policy.read_text().replace(str(self.project), str(other))
            )
        self.assertNotEqual(self.result(self.client(cwd=other)), sock)
        self.assertEqual(self.result(self.client()), sock)
        self.assertEqual(len(self.prompts.read_text().splitlines()), 2)

    def test_broker_death_cleans_shared_namespace_and_restart(self):
        self.result(self.client())
        record = next(self.broker_directory.glob("ssh-*/namespace.stat"))
        fd = os.pidfd_open(int(record.read_text().split()[0]))
        self.server.kill()
        self.server.wait(timeout=10)
        self.server.stderr.close()
        try:
            self.assertTrue(select.select([fd], [], [], 10)[0])
        finally:
            os.close(fd)
        self.server = subprocess.Popen(
            self.command, env=self.env, stderr=subprocess.PIPE
        )

        def ready():
            try:
                with socket.socket(
                    socket.AF_UNIX, socket.SOCK_SEQPACKET
                ) as peer:
                    peer.settimeout(0.2)
                    peer.connect(
                        str(self.broker_directory / "connection/socket")
                    )
                    peer.send(b'{"version":1,"type":"status"}')
                    return bool(peer.recv(65536))
            except OSError:
                return False

        wait_until(ready)
        self.result(self.client())
        self.assertEqual(len(self.prompts.read_text().splitlines()), 2)

    def test_failed_unlock_can_retry_without_restarting_broker(self):
        askpass = self.root / "askpass"
        original = askpass.read_text()
        askpass.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
        failed = self.client()
        _, error = failed.communicate(timeout=15)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"ssh-add failed", error)
        self.assertIsNone(self.server.poll())
        askpass.write_text(original)
        self.result(self.client())
        self.assertEqual(len(self.prompts.read_text().splitlines()), 1)

    def test_cancel_during_shared_unlock_does_not_launch_workload(self):
        askpass = self.root / "askpass"
        gate = self.root / "unlock"
        askpass.write_text(
            f"#!{sys.executable}\nimport pathlib, time\n"
            f"pathlib.Path({str(self.prompts)!r}).write_text('prompt\\n')\n"
            f"while not pathlib.Path({str(gate)!r}).exists(): time.sleep(0.02)\n"
            "print('test-password')\n"
        )
        canceled = self.client()
        wait_until(self.prompts.exists)
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as peer:
            peer.settimeout(1)
            peer.connect(str(self.broker_directory / "connection/socket"))
            peer.send(b'{"version":1,"type":"status"}')
            self.assertEqual(
                json.loads(peer.recv(65536))["ssh_preparation"], "unlocking"
            )
        canceled.terminate()
        canceled.communicate(timeout=5)
        gate.touch()
        self.result(self.client())
        self.assertEqual(len(self.prompts.read_text().splitlines()), 1)
        self.server.terminate()
        self.server.wait(timeout=10)
        self.assertEqual(
            list(self.broker_directory.glob("execution-*"))
            + list(self.broker_directory.glob("ssh-*")),
            [],
        )


if __name__ == "__main__":
    unittest.main()
