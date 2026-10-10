"""End-to-end broker tests with real namespaces and a fake provider.

Run: SUPERVISOR=/path/to/compiled/paseo-agent-supervisor python3 THIS_FILE
Uses no real credentials, providers or Paseo configuration.
"""

import ctypes
import importlib.util
import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BROKER = Path(__file__).resolve().parents[5] / "src/python/uraj/paseo/broker.py"
SPEC = importlib.util.spec_from_file_location("paseo_broker_under_test", BROKER)
broker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(broker)


def wait_until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise TimeoutError("condition did not complete")
        time.sleep(0.02)


class PolicySyntax(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="broker-policy-test-")
        self.root = Path(self.tmp.name)
        self.policy = self.root / "broker-sandbox.json"

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, text, mode=0o600):
        self.policy.write_text(text)
        self.policy.chmod(mode)
        return broker.load_policy(self.policy)

    def test_missing_file_selects_nothing(self):
        self.assertEqual(broker.load_policy(self.policy), [])

    def test_preserve_names(self):
        patterns = self.load(
            '{"preserve": ["HTTP_PROXY", "HTTPS_PROXY",'
            ' "ALL_PROXY", "NO_PROXY"]}\n'
        )
        self.assertEqual(
            [p.pattern for p in patterns],
            ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"],
        )

    def test_preserve_regexp_and_escaped_quote(self):
        patterns = self.load('{"preserve": ["WANDB_.*", "A\\"B"]}\n')
        self.assertEqual([p.pattern for p in patterns], ["WANDB_.*", 'A"B'])
        self.assertEqual(
            broker.preserved_environment(patterns),
            {
                key: value
                for key, value in os.environ.items()
                if key in ("WANDB_RUN", 'A"B')
            },
        )

    def test_rejected_documents(self):
        cases = [
            '["BROKER_TEST"]\n',
            '{"preserve": "BROKER_TEST"}\n',
            '{"preserve": [42]}\n',
            '{"unknown": ["BROKER_TEST"]}\n',
            '{"preserve": ["A"], "extra": 1}\n',
            '{"preserve": ["["]}\n',
            '{"preserve": [""]}\n',
            "{not json}\n",
        ]
        for text in cases:
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    self.load(text)

    def test_rejected_permissions(self):
        with self.assertRaises(ValueError):
            self.load('{"preserve": ["BROKER_TEST"]}\n', mode=0o666)
        real = self.root / "real-policy.json"
        real.write_text('{"preserve": ["BROKER_TEST"]}\n')
        real.chmod(0o600)
        self.policy.unlink()
        self.policy.symlink_to(real)
        with self.assertRaises(ValueError):
            broker.load_policy(self.policy)

    def test_preserved_environment_matches_full_names(self):
        os.environ["POLICY_TEST_EXACT"] = "exact"
        os.environ["POLICY_TEST_PREFIXED"] = "prefixed"
        try:
            patterns = self.load(
                '{"preserve": ["POLICY_TEST_EXACT", "POLICY_TEST_.*X"]}\n'
            )
            preserved = broker.preserved_environment(patterns)
        finally:
            del os.environ["POLICY_TEST_EXACT"]
            del os.environ["POLICY_TEST_PREFIXED"]
        self.assertEqual(preserved["POLICY_TEST_EXACT"], "exact")
        self.assertNotIn("POLICY_TEST_PREFIXED", preserved)


class Broker(unittest.TestCase):
    def setUp(self):
        # Reap test-owned orphans after intentionally killing the broker.
        self.assertEqual(ctypes.CDLL(None).prctl(36, 1, 0, 0, 0), 0)
        self.tmp = tempfile.TemporaryDirectory(prefix="broker-test-")
        self.root = Path(self.tmp.name)
        self.runtime = self.root / "runtime"
        self.launcher = self.root / "launcher"
        self.launcher.write_text(
            f"#!{sys.executable}\n"
            + """
import os, sys, signal, time
from pathlib import Path
args = sys.argv[2:]
if args == ['--version']:
    print('fake-provider 1.0'); sys.exit(0)
if args == ['echo']:
    print(sys.stdin.readline().strip()); print('diagnostic', file=sys.stderr); sys.exit(7)
if args == ['signal']:
    os.kill(os.getpid(), signal.SIGTERM)
if args == ['leak']:
    if os.fork() == 0:
        os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
    sys.exit(0)
if args == ['hang']:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if os.fork() == 0:
        os.setsid()
        if os.fork(): os._exit(0)
        while True: time.sleep(1)
    print('ready', flush=True)
    while True: time.sleep(1)
if args and args[0] == 'env':
    print(os.environ.get(args[1], '<unset>')); sys.exit(0)
sys.exit(99)
"""
        )
        self.launcher.chmod(0o700)
        self.env = {
            "PATH": "/run/current-system/profile/bin",
            "LANG": "C.UTF-8",
            "BROKER_TEST_ALPHA": "host-alpha",
            "BROKER_TEST_BETA": "host-beta",
            "OPENAI_BROKER_TEST": "host",
        }
        self.prefix = [
            sys.executable,
            str(BROKER),
            "--directory",
            str(self.runtime),
        ]
        self.clients = []
        self.start_server()

    def start_server(self):
        self.server = subprocess.Popen(
            self.prefix
            + [
                "serve",
                "--supervisor",
                os.environ["SUPERVISOR"],
                "--launcher",
                str(self.launcher),
                "--root",
                str(self.root),
                "--policy",
                str(self.root / "broker-sandbox.json"),
            ],
            env=self.env,
            stderr=subprocess.PIPE,
        )

        def available():
            if self.server.poll() is not None:
                return True
            try:
                with socket.socket(
                    socket.AF_UNIX, socket.SOCK_SEQPACKET
                ) as peer:
                    peer.settimeout(0.2)
                    peer.connect(str(self.runtime / "connection/socket"))
                    peer.send(b'{"version":1,"type":"status"}')
                    return json.loads(peer.recv(65536)).get("type") == "status"
            except OSError:
                return False

        wait_until(available)
        if self.server.poll() is not None:
            self.fail(self.server.stderr.read().decode())

    def client(self, *args, agent_id=None, env_extra=None):
        env = dict(self.env)
        if agent_id:
            env["PASEO_AGENT_ID"] = agent_id
        if env_extra:
            env.update(env_extra)
        proc = subprocess.Popen(
            self.prefix + ["client", "codex", *args],
            cwd=self.root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.clients.append(proc)
        return proc

    def ready(self, client):
        readable, _, _ = select.select([client.stdout], [], [], 10)
        self.assertTrue(readable)
        self.assertEqual(client.stdout.readline(), b"ready\n")
        wait_until(
            lambda: bool(list(self.runtime.glob("execution-*/namespace.stat")))
        )
        record = next(
            self.runtime.glob("execution-*/namespace.stat")
        ).read_text()
        return os.pidfd_open(int(record.split()[0]))

    def assert_dead(self, fd):
        try:
            readable, _, _ = select.select([fd], [], [], 10)
            self.assertTrue(readable, "namespace init survived")
        finally:
            os.close(fd)

    def test_probe_and_streams(self):
        probe = self.client("--version")
        self.assertEqual(
            probe.communicate(timeout=10), (b"fake-provider 1.0\n", b"")
        )
        self.assertEqual(probe.returncode, 0)
        echo = self.client("echo")
        self.assertEqual(
            echo.communicate(b'{"stream":true}\n', timeout=10),
            (b'{"stream":true}\n', b"diagnostic\n"),
        )
        self.assertEqual(echo.returncode, 7)

    def test_previous_boot_records_do_not_match_live_pids(self):
        self.server.terminate()
        self.server.wait(timeout=10)
        self.server.stderr.close()
        old = self.runtime / "execution-previous-boot"
        old.mkdir()
        (old / "boot-id").write_text("different-boot\n")
        # A PID and start-time collision across boots must not block startup.
        (old / "namespace.stat").write_text(Path("/proc/self/stat").read_text())
        self.start_server()
        self.assertFalse(old.exists())

    def test_signal_fidelity(self):
        proc = self.client("signal")
        proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, -signal.SIGTERM)

    def test_normal_exit_cleans_detached_children(self):
        proc = self.client("leak")
        proc.communicate(timeout=10)  # inherited stdout must reach EOF
        self.assertEqual(proc.returncode, 0)
        wait_until(lambda: not list(self.runtime.glob("execution-*")))

    def test_client_sigkill(self):
        proc = self.client("hang")
        fd = self.ready(proc)
        proc.kill()
        self.assert_dead(fd)
        proc.communicate(timeout=10)
        wait_until(lambda: not list(self.runtime.glob("execution-*")))

    def test_term_ignoring_provider_and_replacement(self):
        proc = self.client("hang", agent_id="same-agent")
        fd = self.ready(proc)
        proc.terminate()
        replacement = self.client("echo", agent_id="same-agent")
        self.assert_dead(fd)
        proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, -signal.SIGKILL)
        self.assertEqual(
            replacement.communicate(b"next\n", timeout=10)[0], b"next\n"
        )
        self.assertEqual(replacement.returncode, 7)

    def test_broker_sigkill_and_restart(self):
        proc = self.client("hang")
        fd = self.ready(proc)
        self.server.kill()
        self.server.wait(timeout=10)
        self.server.stderr.close()
        self.assert_dead(fd)
        proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 125)
        self.start_server()
        probe = self.client("--version")
        probe.communicate(timeout=10)
        self.assertEqual(probe.returncode, 0)

    def test_invalid_request(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as peer:
            peer.settimeout(5)
            peer.connect(str(self.runtime / "connection/socket"))
            peer.send(
                json.dumps(
                    {"version": 1, "type": "start", "provider": "sh"}
                ).encode()
            )
            self.assertEqual(json.loads(peer.recv(65536))["type"], "error")
        self.assertIsNone(self.server.poll())

    def test_status(self):
        proc = self.client("hang")
        fd = self.ready(proc)
        result = subprocess.run(
            self.prefix + ["status"],
            env=self.env,
            capture_output=True,
            check=True,
            timeout=5,
        )
        entries = json.loads(result.stdout)["executions"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["provider"], "codex")
        self.assertEqual(entries[0]["cwd"], str(self.root))
        proc.terminate()
        self.assert_dead(fd)

    def test_policy_preserves_broker_environment(self):
        policy = self.root / "broker-sandbox.json"
        policy.write_text('{"preserve": ["BROKER_TEST_ALPHA"]}\n')
        # The client holds a conflicting value but cannot forward this name.
        probe = self.client(
            "env",
            "BROKER_TEST_ALPHA",
            env_extra={"BROKER_TEST_ALPHA": "client"},
        )
        self.assertEqual(probe.communicate(timeout=10), (b"host-alpha\n", b""))
        # The policy is read per start: a new clause needs no broker restart.
        policy.write_text('{"preserve": ["BROKER_TEST_BETA"]}\n')
        probe = self.client("env", "BROKER_TEST_BETA")
        self.assertEqual(probe.communicate(timeout=10), (b"host-beta\n", b""))
        result = subprocess.run(
            self.prefix + ["status"],
            env=self.env,
            capture_output=True,
            check=True,
            timeout=5,
        )
        self.assertEqual(json.loads(result.stdout)["policy"]["preserve"], 1)
        self.assertIsNone(json.loads(result.stdout)["policy"]["error"])

    def test_policy_does_not_override_forwarded_values(self):
        (self.root / "broker-sandbox.json").write_text(
            '{"preserve": ["OPENAI_BROKER_TEST"]}\n'
        )
        probe = self.client(
            "env",
            "OPENAI_BROKER_TEST",
            env_extra={"OPENAI_BROKER_TEST": "client"},
        )
        self.assertEqual(probe.communicate(timeout=10), (b"client\n", b""))

    def test_bad_policy_fails_starts_not_broker(self):
        policy = self.root / "broker-sandbox.json"
        policy.write_text('{"share": ["~/Projects"]}\n')
        probe = self.client("--version")
        _, stderr = probe.communicate(timeout=10)
        self.assertEqual(probe.returncode, 125)
        self.assertIn(b"unsupported policy key", stderr)
        result = subprocess.run(
            self.prefix + ["status"],
            env=self.env,
            capture_output=True,
            check=True,
            timeout=5,
        )
        self.assertEqual(
            json.loads(result.stdout)["policy"]["error"],
            "unsupported policy key 'share'",
        )
        policy.write_text('{"preserve": ["BROKER_TEST_ALPHA"]}\n')
        probe = self.client("env", "BROKER_TEST_ALPHA")
        self.assertEqual(probe.communicate(timeout=10), (b"host-alpha\n", b""))

    def test_policy_symlink_rejected(self):
        real = self.root / "real-policy.json"
        real.write_text('{"preserve": ["BROKER_TEST_ALPHA"]}\n')
        real.chmod(0o600)
        (self.root / "broker-sandbox.json").symlink_to(real)
        probe = self.client("--version")
        _, stderr = probe.communicate(timeout=10)
        self.assertEqual(probe.returncode, 125)
        self.assertIn(b"regular user-owned file", stderr)

    def test_parent_death(self):
        command = self.prefix + ["client", "codex", "hang"]
        parent = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import subprocess,sys; p=subprocess.Popen(sys.argv[1:]); p.wait()",
                *command,
            ],
            cwd=self.root,
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.clients.append(parent)
        fd = self.ready(parent)
        parent.kill()
        self.assert_dead(fd)
        parent.communicate(timeout=10)

    def test_configure_and_restore(self):
        clients = self.root / "clients"
        clients.mkdir()
        for provider in ("codex", "claude"):
            script = clients / provider
            script.write_text(
                f"#!{sys.executable}\nimport os,sys\n"
                f"os.execv(sys.executable, {self.prefix + ['client', provider]!r} + sys.argv[1:])\n"
            )
            script.chmod(0o700)
        config = self.root / "config.json"
        original = {
            "other": {"keep": True},
            "agents": {
                "providers": {
                    "codex": {
                        "command": ["/old/codex"],
                        "env": {"KEEP": "yes"},
                    },
                    "claude": {"enabled": True},
                }
            },
        }
        config.write_text(json.dumps(original))
        base = self.prefix + ["configure", "--config", str(config)]
        subprocess.run(
            base + ["--client-directory", str(clients)],
            env=self.env,
            check=True,
            stdout=subprocess.DEVNULL,
            timeout=20,
        )
        changed = json.loads(config.read_text())
        self.assertEqual(changed["other"], original["other"])
        self.assertEqual(
            changed["agents"]["providers"]["codex"]["env"], {"KEEP": "yes"}
        )
        self.assertEqual(
            changed["agents"]["providers"]["codex"]["command"],
            [str(clients / "codex")],
        )
        backup = next(self.root.glob("config.json.before-broker-*"))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        subprocess.run(
            base + ["--restore", str(backup)],
            env=self.env,
            check=True,
            stdout=subprocess.DEVNULL,
            timeout=10,
        )
        self.assertEqual(json.loads(config.read_text()), original)

    def tearDown(self):
        for proc in self.clients:
            if proc.poll() is None:
                proc.kill()
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=10)
        self.server.stderr.close()
        for proc in self.clients:
            proc.communicate(timeout=10)
        deadline = time.monotonic() + 10
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                self.assertLess(
                    time.monotonic(), deadline, "unreaped test descendant"
                )
                time.sleep(0.01)
        self.tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
