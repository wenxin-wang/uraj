"""Ensure the engine probe cannot hide failed isolation checks."""

import argparse
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SOURCE = (
    Path(__file__).resolve().parents[4]
    / "scripts/openclaw/check-docker-engine.py"
)
SPEC = importlib.util.spec_from_file_location("engine_probe", SOURCE)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ProbeChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.probe = PROBE.Probe(
            argparse.Namespace(task_image="test-image"),
            Path(self.directory.name),
        )
        self.addCleanup(self.probe.log.close)
        shared = self.probe.path("shared")
        shared.mkdir()
        (shared / "readonly").mkdir()
        (shared / "readonly/sentinel").write_text("original\n")

        def shell(script, check=True):
            return subprocess.run(
                ["/bin/sh", "-lc", script],
                capture_output=True,
                text=True,
                check=check,
            )

        self.probe.sandbox_exec = shell

    def test_wrong_host_content_is_not_hidden_by_successful_write(self):
        self.probe.path("shared/from-host").write_text("wrong\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.probe.same_path()

    def test_each_isolation_failure_is_reported(self):
        secret = self.probe.path("unshared-secret")
        escape = self.probe.path("shared/escape")
        sentinel = self.probe.path("shared/readonly/sentinel")
        original = self.probe.sandbox_exec
        for failure in ("none", "escape", "unshared", "sentinel"):
            with self.subTest(failure=failure):
                secret.unlink(missing_ok=True)
                escape.unlink(missing_ok=True)
                sentinel.write_text("original\n")
                if failure == "escape":
                    escape.write_text("leaked\n")
                elif failure == "unshared":
                    secret.write_text("leaked\n")
                elif failure == "sentinel":
                    sentinel.write_text("wrong\n")
                # The final negated touch succeeds, as on a read-only mount.

                def readonly_shell(script, check=True):
                    script = script.replace(
                        f"touch {self.probe.path('shared/readonly/x')}",
                        "false",
                    )
                    return original(script, check=check)

                with mock.patch.object(
                    self.probe, "sandbox_exec", side_effect=readonly_shell
                ):
                    if failure == "none":
                        self.probe.isolation()
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            self.probe.isolation()

    def test_root_bind_leak_and_command_failure_are_errors(self):
        for code, output in ((0, "leaked\n"), (125, "hidden\n")):
            with self.subTest(code=code, output=output):
                self.probe.client = mock.Mock(
                    return_value=subprocess.CompletedProcess(
                        [], code, output, "runtime error"
                    )
                )
                with self.assertRaises(RuntimeError):
                    self.probe.root_bind()

    def test_init_must_be_an_init_process(self):
        self.probe.sandbox_exec = mock.Mock(
            return_value=subprocess.CompletedProcess([], 0, "sleep\n", "")
        )
        with self.assertRaises(RuntimeError):
            self.probe.init_process()


if __name__ == "__main__":
    unittest.main()
