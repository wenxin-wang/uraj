"""Check target-based environment selection without running Guix or sudo.

Run: python3 test/python/uraj/guix/shell/targets.py
Requires Bash and direnv.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[5] / "env/dotfiles/common/shell"
COMMANDS = ("deploy", "home-reconfigure", "system-reconfigure")


class TargetEnvironment(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="uraj-targets-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.bin = self.home / ".local/bin"
        shutil.copytree(SOURCE / ".local", self.home / ".local")
        self.environment = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "DIRENV_BASH": shutil.which("bash"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
        }
        maak = self.bin / "maak"
        maak.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "print(json.dumps([os.environ.get('TARGET_PROJECT'), "
            "os.getcwd(), sys.argv[1:]]))\n"
        )
        maak.chmod(0o755)
        sudo = self.bin / "sudo"
        sudo.write_text(
            '#!/bin/sh\n[ "$1" = -E ] || exit 1\nshift\nexec "$@"\n'
        )
        sudo.chmod(0o755)
        self.default = self.project("src/uraj")
        self.other = self.project("other worktree")

    def project(self, name):
        project = self.home / name
        (project / "env/guix/os/deploy").mkdir(parents=True)
        (project / ".envrc").write_text('export TARGET_PROJECT="$PWD"\n')
        (project / "env/guix/os/deploy/host.scm").touch()
        subprocess.run(
            ["direnv", "allow", str(project)],
            env=self.environment,
            capture_output=True,
            check=True,
        )
        return project

    def run_command(self, command, *arguments):
        return subprocess.run(
            [str(self.bin / f"uraj-{command}"), *map(str, arguments)],
            cwd=self.home,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def assert_command(self, result, project, command, *arguments):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [
                str(project),
                str(self.home),
                [
                    "-f",
                    str(project / "env/guix/os/maak.scm"),
                    command,
                    *map(str, arguments),
                ],
            ],
        )

    def test_explicit_targets(self):
        target = self.other / "env/guix/os/deploy/host.scm"
        link = self.home / "linked.scm"
        link.symlink_to(target)
        for command in COMMANDS:
            for argument in (target, target.relative_to(self.home), link):
                with self.subTest(command=command, argument=argument):
                    self.assert_command(
                        self.run_command(command, argument),
                        self.other,
                        command,
                        target,
                    )

    def test_defaults(self):
        self.assert_command(
            self.run_command("deploy", "host"),
            self.default,
            "deploy",
            self.default / "env/guix/os/deploy/host.scm",
        )
        for command in COMMANDS[1:]:
            with self.subTest(command=command):
                self.assert_command(
                    self.run_command(command), self.default, command
                )

    def test_invalid_targets_and_unapproved_environment(self):
        orphan = self.home / "orphan.scm"
        orphan.touch()
        target = self.other / "env/guix/os/deploy/host.scm"
        (self.other / ".envrc").write_text("export TARGET_PROJECT=changed\n")
        for command in COMMANDS:
            for argument in ("missing.scm", orphan, target):
                with self.subTest(command=command, argument=argument):
                    result = self.run_command(command, argument)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
