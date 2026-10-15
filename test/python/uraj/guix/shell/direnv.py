"""Check direnv's Bash prompt hook with SSH startup files and a fake HOME.

Run: python3 test/python/uraj/guix/shell/direnv.py
Requires Bash and direnv; no SSH server, Guix daemon, or network is used.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[5] / "env/dotfiles/common/shell"


class DirenvSSH(unittest.TestCase):
    def test_hook_preserves_inherited_path_and_unloads_project(self):
        bash = shutil.which("bash")
        direnv = shutil.which("direnv")
        self.assertTrue(bash and direnv)
        with tempfile.TemporaryDirectory(prefix="uraj-direnv-") as temporary:
            home = Path(temporary)
            local_bin = home / ".local/bin"
            local_bin.mkdir(parents=True)
            wrapper = local_bin / "uraj-direnv-bash"
            shutil.copy2(SOURCE / ".local/bin/uraj-direnv-bash", wrapper)
            probe = local_bin / "uraj-probe"
            probe.write_text("#!/bin/sh\nexit 0\n")
            probe.chmod(0o755)
            project = home / "project"
            project.mkdir()
            (project / ".envrc").write_text(
                'export PATH="$PWD/bin:$PATH"\nexport PROJECT_LOADED=yes\n'
            )
            # Model Guix's SSH startup resetting PATH. This also proves the
            # test reaches remote startup rather than merely inspecting argv.
            (home / ".bashrc").write_text(
                'export PATH="$TEST_BASE_PATH"\nexport REMOTE_RC_LOADED=yes\n'
            )
            environment = {
                "HOME": str(home),
                "PATH": f"{local_bin}:{os.environ['PATH']}",
                "TEST_BASE_PATH": os.environ["PATH"],
                "SHLVL": "0",
                "SSH_CLIENT": "192.0.2.1 12345 23333",
                "SSH_CONNECTION": "192.0.2.1 12345 192.0.2.2 23333",
                "DIRENV_BASH": bash,
                "DIRENV_LOG_FORMAT": "",
            }
            subprocess.run(
                [direnv, "allow", str(project)],
                env=environment,
                check=True,
                capture_output=True,
            )
            script = """
if [ "$1" = fixed ]; then
    unset DIRENV_BASH
    . "$2"
fi
cd "$3"
eval "$("$4" export bash)"
printf '%s\\n' "$PATH" "${REMOTE_RC_LOADED-}" "$PROJECT_LOADED"
command -v uraj-probe || :
cd "$HOME"
eval "$("$4" export bash)"
printf '%s\\n' "$PATH" "${PROJECT_LOADED-}" "$SSH_CONNECTION"
"""
            for fixed in (False, True):
                with self.subTest(fixed=fixed):
                    result = subprocess.run(
                        [
                            bash,
                            "--norc",
                            "-c",
                            script,
                            "direnv-test",
                            "fixed" if fixed else "original",
                            str(SOURCE / ".profile.d/62-direnv.sh"),
                            str(project),
                            direnv,
                        ],
                        env=environment,
                        cwd=home,
                        text=True,
                        capture_output=True,
                        check=True,
                        timeout=15,
                    )
                    lines = result.stdout.splitlines()
                    base_path = (
                        environment["PATH"]
                        if fixed
                        else environment["TEST_BASE_PATH"]
                    )
                    expected = [
                        f"{project}/bin:{base_path}",
                        "" if fixed else "yes",
                        "yes",
                    ]
                    if fixed:
                        expected.append(str(probe))
                    expected.extend(
                        [environment["PATH"], "", environment["SSH_CONNECTION"]]
                    )
                    self.assertEqual(lines, expected, result.stderr)

    def test_profile_preserves_custom_interpreter(self):
        result = subprocess.check_output(
            [
                shutil.which("bash"),
                "--norc",
                "-c",
                '. "$1"; printf "%s" "$DIRENV_BASH"',
                "profile-test",
                str(SOURCE / ".profile.d/62-direnv.sh"),
            ],
            env={
                "HOME": "/nonexistent",
                "PATH": os.environ["PATH"],
                "DIRENV_BASH": "/custom/bash",
            },
            text=True,
        )
        self.assertEqual(result, "/custom/bash")


if __name__ == "__main__":
    unittest.main()
