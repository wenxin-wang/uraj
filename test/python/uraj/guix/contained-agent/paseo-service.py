"""Paseo activation preserves user state and confines daemon mounts."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SOURCE = (
    Path(__file__).resolve().parents[5] / "src/python/uraj/paseo/service.py"
)
SPEC = importlib.util.spec_from_file_location("paseo_service", SOURCE)
SERVICE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVICE)


class Activation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.environment = mock.patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.old_umask = os.umask(0o077)
        self.addCleanup(os.umask, self.old_umask)

    def test_fresh_home_is_idempotent_and_private(self):
        SERVICE.activate(self.home, desktop=True)
        self.assertFalse((self.home / ".paseo-password").exists())
        files = [p for p in self.home.rglob("*") if p.is_file()]
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in files}
        SERVICE.activate(self.home, desktop=True)
        self.assertEqual(
            before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in files}
        )
        self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in files))
        settings = json.loads((self.home / ".paseo/config.json").read_text())
        worktrees = self.home / ".local/share/paseo/worktrees"
        self.assertEqual(settings["worktrees"]["root"], str(worktrees))
        self.assertTrue(worktrees.is_dir())
        self.assertFalse((self.home / "Projects").exists())
        self.assertEqual(
            settings["agents"]["providers"]["codex"]["command"],
            [str(self.home / ".guix-home/profile/bin/paseo-codex")],
        )
        desktop = json.loads(
            (self.home / ".config/Paseo/desktop-settings.json").read_text()
        )
        self.assertFalse(desktop["settings"]["daemon"]["manageBuiltInDaemon"])
        self.assertTrue(desktop["migrations"]["legacyRendererSettingsImported"])

    def test_temporary_directory_is_private_and_preserves_attachments(self):
        directory = SERVICE.prepare_temporary_directory(self.home)
        attachment = directory / "image.png"
        attachment.write_bytes(b"existing attachment")
        directory.chmod(0o755)
        SERVICE.activate(self.home)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(attachment.read_bytes(), b"existing attachment")

    def test_temporary_directory_rejects_symlink(self):
        directory = self.home / ".cache/paseo-tmp"
        directory.parent.mkdir()
        target = self.home / "unrelated"
        target.mkdir(mode=0o755)
        mode = target.stat().st_mode
        directory.symlink_to(target)
        with self.assertRaises(ValueError):
            SERVICE.prepare_temporary_directory(self.home)
        self.assertEqual(target.stat().st_mode, mode)

    def test_host_and_container_launch_use_same_temporary_directory(self):
        SERVICE.activate(self.home)
        temporary = self.home / ".cache/paseo-tmp"
        for action in ("run-host", "run"):
            with (
                self.subTest(action=action),
                mock.patch.object(SERVICE.Path, "home", return_value=self.home),
                mock.patch.object(SERVICE.socket, "socket"),
                mock.patch.object(SERVICE.os, "chdir"),
                mock.patch.object(SERVICE.os, "execvp") as execute,
                mock.patch(
                    "sys.argv",
                    [
                        "paseo-service",
                        action,
                        "--guix",
                        "guix",
                        "--profile",
                        "/profile",
                    ],
                ),
                mock.patch.dict(
                    os.environ,
                    {"TMPDIR": "/unrelated", "PASEO_PASSWORD": "obsolete"},
                ),
            ):
                SERVICE.main()
                self.assertNotIn("PASEO_PASSWORD", os.environ)
                self.assertEqual(os.environ["TMPDIR"], str(temporary))
                self.assertTrue(temporary.is_dir())
                program, command = execute.call_args.args
                if action == "run-host":
                    self.assertEqual(program, "paseo")
                    self.assertEqual(command, ["paseo", "daemon", "run"])
                else:
                    self.assertEqual(program, "guix")
                    self.assertIn(f"--share={temporary}", command)
                    self.assertIn(
                        "--preserve=^(PASEO_.*|TMPDIR|LANG|LC_.*)$", command
                    )
                    self.assertNotIn("--share=/tmp", command)

    def test_upgrade_preserves_settings_password_and_backup(self):
        config = self.home / ".paseo/config.json"
        config.parent.mkdir()
        original = {
            "worktrees": {"root": "/workspace/worktrees"},
            "agents": {"providers": {"codex": {"env": {"MODEL": "keep"}}}},
        }
        config.write_text(json.dumps(original))
        (self.home / ".paseo-password").write_text("existing-password\n")
        SERVICE.activate(self.home, worktrees="/different")
        updated = json.loads(config.read_text())
        self.assertEqual(updated["worktrees"], original["worktrees"])
        self.assertEqual(
            updated["agents"]["providers"]["codex"]["env"], {"MODEL": "keep"}
        )
        self.assertEqual(
            (self.home / ".paseo-password").read_text(), "existing-password\n"
        )
        self.assertEqual(
            json.loads(
                config.with_name("config.json.before-service").read_text()
            ),
            original,
        )

    def test_previous_default_worktree_root_moves(self):
        config = self.home / ".paseo/config.json"
        config.parent.mkdir()
        old = str(self.home / "Projects/paseo-worktrees")
        config.write_text(json.dumps({"worktrees": {"root": old}}))
        SERVICE.activate(self.home)
        self.assertEqual(
            json.loads(config.read_text())["worktrees"]["root"],
            str(self.home / ".local/share/paseo/worktrees"),
        )

    def test_invalid_and_managed_config_are_not_replaced(self):
        config = self.home / ".paseo/config.json"
        config.parent.mkdir()
        config.write_text("not-json")
        with self.assertRaises(ValueError):
            SERVICE.activate(self.home)
        self.assertEqual(config.read_text(), "not-json")
        config.unlink()
        target = self.home / "managed.json"
        target.write_text("{}")
        config.symlink_to(target)
        with self.assertRaises(ValueError):
            SERVICE.activate(self.home)
        self.assertEqual(target.read_text(), "{}")

    def test_container_shares_only_connection_directory(self):
        root = self.home / "src"
        root.mkdir()
        command = SERVICE.container_command(
            "guix", "/profile", self.home, [root]
        )
        self.assertIn("--network", command)
        self.assertIn("--no-cwd", command)
        self.assertIn(f"--share={root}", command)
        runtime = self.home / ".local/state/paseo-broker"
        self.assertIn(f"--expose={runtime / 'connection'}", command)
        self.assertNotIn(f"--share={runtime}", command)
        self.assertNotIn(f"--expose={runtime}", command)
        self.assertNotIn("--nesting", command)
        self.assertNotIn(f"--share={self.home}", command)


if __name__ == "__main__":
    unittest.main()
