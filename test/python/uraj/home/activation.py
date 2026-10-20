"""System activation must finish before dependent user services can start."""

import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

SOURCE = (
    Path(__file__).resolve().parents[4] / "src/python/uraj/home/activation.py"
)
SPEC = importlib.util.spec_from_file_location("home_activation", SOURCE)
ACTIVATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACTIVATION)


class Readiness(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.generation = self.home / "generation"
        self.generation.mkdir()
        (self.home / ".guix-home").symlink_to(self.generation)
        self.system = self.home / "system"
        self.system.mkdir()
        self.boot = self.home / "boot"
        self.boot.write_text("current-boot")
        for name, value in (("BOOT_ID", self.boot), ("SYSTEM", self.system)):
            patch = mock.patch.object(ACTIVATION, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.state = ACTIVATION.state_file(self.home)
        self.state.parent.mkdir(parents=True)

    def publish(self, **overrides):
        state = dict(ACTIVATION.identity(self.generation), status="ready")
        state.update(overrides)
        ACTIVATION.publish(self.state, state)

    def test_rejects_previous_boot_system_and_home(self):
        for key in ("boot", "system", "home"):
            with self.subTest(key=key):
                self.publish(**{key: "obsolete"})
                with self.assertRaises(TimeoutError):
                    ACTIVATION.wait(self.home, timeout=0)

    def test_missing_and_incomplete_state_do_not_release_waiter(self):
        for contents in (None, "{", "{}"):
            with self.subTest(contents=contents):
                if contents is not None:
                    self.state.write_text(contents)
                with self.assertRaises(TimeoutError):
                    ACTIVATION.wait(self.home, timeout=0)

    def test_success_releases_waiter(self):
        self.publish()
        ACTIVATION.wait(self.home, timeout=0)

    def test_failure_is_reported_without_waiting_for_timeout(self):
        self.publish(status="failed")
        with self.assertRaisesRegex(RuntimeError, "activation failed"):
            ACTIVATION.wait(self.home)

    def test_activation_invalidates_old_success_and_waits_for_child(self):
        self.publish()
        entered = threading.Event()
        release = threading.Event()
        results = []

        def child(*_args, **kwargs):
            self.assertEqual(
                kwargs["env"]["HOME_ENVIRONMENT"], str(self.generation)
            )
            entered.set()
            if not release.wait(5):
                raise TimeoutError("test did not release activation")
            return subprocess.CompletedProcess([], 0)

        def activate():
            results.append(ACTIVATION.activate(self.home, self.generation))

        with mock.patch.object(ACTIVATION.subprocess, "run", side_effect=child):
            thread = threading.Thread(target=activate)
            thread.start()
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(results, [])
                with self.assertRaises(TimeoutError):
                    ACTIVATION.wait(self.home, timeout=0)
            finally:
                release.set()
                thread.join(5)
        self.assertEqual(results, [0])
        ACTIVATION.wait(self.home, timeout=0)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_actual_child_failure_is_propagated(self):
        script = self.generation / "activate"
        script.write_text(f"#!{os.environ.get('SHELL', '/bin/sh')}\nexit 7\n")
        script.chmod(0o700)
        self.assertEqual(ACTIVATION.activate(self.home, self.generation), 7)
        self.assertEqual(json.loads(self.state.read_text())["status"], "failed")
        with self.assertRaises(RuntimeError):
            ACTIVATION.wait(self.home)


if __name__ == "__main__":
    unittest.main()
