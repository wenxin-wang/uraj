"""Lifecycle tests without a real Chromium installation."""

import importlib.machinery
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "env/docker/openclaw-sandbox/browser-profile"
)
LOADER = importlib.machinery.SourceFileLoader("browser_profile", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
PROFILE = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(PROFILE)


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        patch = mock.patch.object(PROFILE, "ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)

    def invoke(self, *args):
        with mock.patch.object(sys, "argv", [str(SCRIPT), *args]):
            with mock.patch("builtins.print") as output:
                PROFILE.main()
        return json.loads(output.call_args.args[0]) if output.called else None

    def test_migrate_snapshot_and_independent_tasks(self):
        legacy = self.root / "profile"
        legacy.mkdir()
        (legacy / "Cookies").write_text("login-v1")
        (legacy / "SingletonLock").symlink_to("old-host-123")
        with mock.patch.object(PROFILE, "browser"):
            self.invoke("publish")
            first = self.invoke("create")["task"]
            second = self.invoke("create")["task"]
            one = self.root / "tasks" / first / "profile"
            two = self.root / "tasks" / second / "profile"
            self.assertFalse((one / "SingletonLock").is_symlink())
            (one / "Cookies").write_text("task-change")
            self.assertEqual((two / "Cookies").read_text(), "login-v1")
            (self.root / "identity/Cookies").write_text("login-v2")
            self.invoke("publish")
            self.assertEqual((two / "Cookies").read_text(), "login-v1")
            third = self.invoke("create")["task"]
            self.assertEqual(
                (self.root / "tasks" / third / "profile/Cookies").read_text(),
                "login-v2",
            )
            self.invoke("finish", first)
            self.assertFalse(one.exists())
            self.assertTrue(two.exists())

    def test_live_profile_refuses_migration(self):
        legacy = self.root / "profile"
        legacy.mkdir()
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import time; time.sleep(30)",
                f"--user-data-dir={legacy}",
            ]
        )
        try:
            with self.assertRaisesRegex(RuntimeError, "still uses"):
                PROFILE.identity()
            self.assertTrue(legacy.exists())
        finally:
            process.terminate()
            process.wait()

    def test_fork_only_reads_published_snapshots(self):
        host = self.root / "host"
        snapshot = host / "snapshots/v1"
        snapshot.mkdir(parents=True)
        (snapshot / "Cookies").write_text("login-v1")
        (host / "current").symlink_to("snapshots/v1")
        sandbox = self.root / "sandbox"
        hint = "Log in on the host"
        with (
            mock.patch.object(PROFILE, "ROOT", sandbox),
            mock.patch.object(PROFILE, "PUBLISHED", str(host)),
            mock.patch.object(PROFILE, "IDENTITY_HINT", hint),
            mock.patch.object(PROFILE, "browser"),
        ):
            task = self.invoke("create")["task"]
            profile = sandbox / "tasks" / task / "profile"
            self.assertEqual((profile / "Cookies").read_text(), "login-v1")
            for action in (["login", "about:blank"], ["publish"]):
                with self.assertRaisesRegex(RuntimeError, hint):
                    self.invoke(*action)
            self.assertFalse((sandbox / "identity").exists())
            self.invoke("finish", task)
            self.assertFalse(profile.exists())
        self.assertEqual((snapshot / "Cookies").read_text(), "login-v1")

    def test_invalid_task_and_profile_override(self):
        with self.assertRaises(RuntimeError):
            PROFILE.task_path("../identity")
        with self.assertRaises(RuntimeError):
            PROFILE.browser(self.root, "task", ["--profile=/tmp/other", "open"])


if __name__ == "__main__":
    unittest.main()
