"""Central credential clauses and container git defaults, with a fake guix.

Run with python3 test/python/uraj/guix/contained-agent/contained-agent-environment.py.
PATH needs Guile 3, Git and Bash.  No Guix daemon or network is needed.
"""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

SECRET = "github_pat_disposable"


class Launcher(unittest.TestCase):
    def setUp(self):
        self.tools = {name: shutil.which(name) for name in ("guile", "git")}
        self.assertTrue(all(self.tools.values()), self.tools)
        tmp = tempfile.TemporaryDirectory(prefix="contained-env-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "home"
        self.project = self.home / "src/a"
        self.project.mkdir(parents=True)
        subprocess.run(
            [self.tools["git"], "init", "-q", str(self.project)], check=True
        )
        self.secrets = self.root / "secrets"
        self.secrets.mkdir()
        self.secret = self.secrets / "token"
        self.config = self.root / "projects.scm"
        # Capture the real launcher's Guix argv and environment.
        self.record = self.root / "record.json"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        shim = bin_dir / "guix"
        shim.write_text(
            "#!" + shutil.which("python3") + "\n"
            "import json, os, sys\n"
            # `guix hash' selects the approved copy of project-local files.
            'if sys.argv[1] == "hash": print("test-approved")\n'
            "else: json.dump([sys.argv, dict(os.environ)], "
            f"open({str(self.record)!r}, 'w'))\n"
        )
        shim.chmod(0o755)
        driver = self.root / "driver.scm"
        git = json.dumps(self.tools["git"])
        driver.write_text(
            "(use-modules (uraj bin contained-agent))\n"
            f"(parameterize ((%github-secrets {json.dumps(str(self.secrets))})\n"
            "               (%secret-timeout 1))\n"
            ' (contained-agent-main (cons "contained-agent" (cdr (command-line)))\n'
            '  #:agents \'(("probe" (program . "/bin/true"))\n'
            f'             ("git" (program . {git})))\n'
            f"  #:common '() #:packages '() #:git {git}\n"
            '  #:github-secrets (and (not (getenv "TEST_NO_GITHUB"))\n'
            "                       (%github-secrets))\n"
            '  #:projects-secret (getenv "TEST_PROJECTS_SECRET")))\n'
        )
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=str(bin_dir) + ":" + os.environ["PATH"],
            CONTAINED_AGENT_PROJECTS=str(self.config),
        )
        self.env.pop("PASEO_AGENT_CWD", None)
        self.env.pop("XDG_DATA_HOME", None)
        self.command = [
            self.tools["guile"],
            "--no-auto-compile",
            "-L",
            str(Path(__file__).resolve().parents[5] / "src/guile"),
            str(driver),
        ]

    def policy(self, *clauses):
        self.config.write_text(
            f'(project "{self.project}" {" ".join(clauses)})'
        )

    def launch(self, *args, cwd=None, **env):
        self.record.unlink(missing_ok=True)
        result = subprocess.run(
            self.command + list(args or ["probe"]),
            env=dict(self.env, **env),
            cwd=cwd or self.project,
            text=True,
            capture_output=True,
            timeout=15,
        )
        if not self.record.exists():
            return result, None, None
        argv, environment = json.loads(self.record.read_text())
        return result, argv, environment


class Environment(Launcher):
    def test_value_travels_in_the_environment_only(self):
        self.policy(f'(env "GH_TOKEN" (file "{self.secret}"))')
        self.secret.write_text(SECRET + "\n")
        result, argv, environment = self.launch(GH_TOKEN="host-value")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(environment["GH_TOKEN"], SECRET)
        self.assertIn("--preserve=^GH_TOKEN$", argv)
        self.assertFalse(any(SECRET in argument for argument in argv), argv)
        self.assertFalse(any(str(self.secrets) in a for a in argv), argv)

    def test_env_overrides_preserve(self):
        # preserve passes the launcher's own value, which env has replaced.
        self.policy(
            '(preserve "GH_TOKEN")', f'(env "GH_TOKEN" (file "{self.secret}"))'
        )
        for content, expected in ((SECRET, SECRET), (None, None)):
            if content is None:
                self.secret.unlink()
            else:
                self.secret.write_text(content)
            result, _, environment = self.launch(GH_TOKEN="host-value")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(environment.get("GH_TOKEN"), expected)

    def test_missing_or_empty_file_never_falls_back_to_the_host(self):
        self.policy(f'(env "GH_TOKEN" (file "{self.secret}"))')
        for content in (None, " \n"):
            if content is not None:
                self.secret.write_text(content)
            result, argv, environment = self.launch(GH_TOKEN="host-value")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("starting without GH_TOKEN", result.stderr)
            self.assertNotIn("GH_TOKEN", environment)
            self.assertNotIn("--preserve=^GH_TOKEN$", argv)

    def test_projects_secret_is_waited_for_and_required(self):
        self.policy()
        secret = self.secrets / "projects.scm"
        self.env["TEST_PROJECTS_SECRET"] = str(secret)
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"{secret} is still missing after 1 s", result.stderr)
        self.assertIsNone(argv)
        # SOPS finishing during the wait.
        timer = threading.Timer(
            0.3,
            secret.write_text,
            [f'(project "{self.project}" (preserve "FROM_SECRET"))'],
        )
        timer.start()
        self.addCleanup(timer.cancel)
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--preserve=^FROM_SECRET$", argv)

    def test_bad_clauses_fail(self):
        self.secret.write_text(SECRET)
        for clause in (
            f'(env "GH TOKEN" (file "{self.secret}"))',
            f'(env "GH_TOKEN" "{self.secret}")',
            '(github "admin")',
            '(github "public") (github "world")',
            f'(git-credential "http://example.test" "{self.secret}")',
        ):
            self.policy(clause)
            result, argv, _ = self.launch()
            self.assertNotEqual(result.returncode, 0, clause)
            self.assertIsNone(argv, clause)

    def test_project_local_clauses_are_refused(self):
        # Even an approved project file cannot hand out a host credential.
        self.config.write_text("")
        self.secret.write_text(SECRET)
        local = self.project / ".guix"
        local.mkdir()
        approved = (
            self.home / ".local/state/contained-agent/approved/test-approved"
        )
        for clause in (
            f'(env "GH_TOKEN" (file "{self.secret}"))',
            '(github "world")',
        ):
            (local / "contained-agent.scm").write_text(clause)
            shutil.rmtree(approved, ignore_errors=True)
            shutil.copytree(local, approved)
            result, argv, _ = self.launch()
            self.assertNotEqual(result.returncode, 0, clause)
            self.assertIn("bad clause", result.stderr)
            self.assertIsNone(argv)


class GitCredentials(Launcher):
    def fill(self, environment, argv, url):
        """Ask git in the recorded environment, mounts resolved on the host."""
        mounts = dict(
            reversed(a.removeprefix("--expose=").split("=", 1))
            for a in argv
            if a.startswith("--expose=") and "git-credential-" in a
        )
        env = dict(environment)
        for target, source in mounts.items():
            env = {k: v.replace(target, source) for k, v in env.items()}
        result = subprocess.run(
            [self.tools["git"], "credential", "fill"],
            input=f"url={url}\n\n",
            env=dict(env, GIT_TERMINAL_PROMPT="0"),
            text=True,
            capture_output=True,
            timeout=15,
        )
        for line in result.stdout.splitlines():
            if line.startswith("password="):
                return line.removeprefix("password=")
        return None

    def test_tier_and_narrower_credentials(self):
        (self.secrets / "personal").write_text("tier-token\n")
        other = self.root / "other-token"
        other.write_text("other-token")
        # A host helper, as `gh auth setup-git' writes, must not answer.
        subprocess.run(
            [
                self.tools["git"],
                "config",
                "--global",
                "credential.https://github.com.helper",
                "!f() { echo username=u; echo password=host-login; }; f",
            ],
            env=self.env,
            check=True,
        )
        self.policy(
            '(github "personal")',
            f'(git-credential "https://github.com/other" "{other}")',
        )
        result, argv, environment = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"--expose={self.secrets / 'personal'}"
            "=/run/contained-agent/git-credential-1",
            argv,
        )
        self.assertFalse(any("tier-token" in a for a in argv))
        self.assertFalse(any("tier-token" in v for v in environment.values()))
        for url, token in (
            ("https://github.com/me/repo.git", "tier-token"),
            ("https://github.com/other/repo.git", "other-token"),
            ("https://example.test/repo.git", None),
        ):
            self.assertEqual(self.fill(environment, argv, url), token, url)

    def test_missing_tier_token_fails(self):
        self.policy('(github "world")')
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(
            f"{self.secrets / 'world'} is still missing after 1 s",
            result.stderr,
        )
        self.assertIsNone(argv)

    def test_host_without_tokens_starts_without(self):
        # Foreign distros run the same projects file without SOPS.
        self.policy('(github "world")')
        result, argv, _ = self.launch(TEST_NO_GITHUB="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no GitHub tokens on this host", result.stderr)
        self.assertFalse(any("git-credential-" in a for a in argv))

    def test_empty_tier_token_leaves_no_helper(self):
        self.policy('(github "world")')
        (self.secrets / "world").write_text("\n")
        result, argv, environment = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "is empty; starting without https://github.com", result.stderr
        )
        self.assertFalse(any("git-credential-" in a for a in argv))
        self.assertIsNone(
            self.fill(environment, argv, "https://github.com/me/x.git")
        )

    def test_container_gitconfig(self):
        # Run the container's entry script outside any container, in the
        # project's work tree, then ask git there for its settings.
        self.config.write_text("")
        (self.home / ".gitconfig.local").write_text("[user]\n\tname = T\n")
        query = (
            "for k in user.name push.default filter.lfs.required; do "
            'git config --get "$k"; done; git config --global --list'
        )
        result, argv, environment = self.launch("git", "--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = argv[argv.index("--") + 1 :]
        program = entry.index(self.tools["git"])
        entry[program:] = ["sh", "-c", query]
        inside = subprocess.run(
            entry,
            env=environment,
            text=True,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(inside.returncode, 0, inside.stderr)
        lines = inside.stdout.splitlines()
        # .git/config is read-only in the container, so pushes must not
        # depend on branch.*.merge.
        self.assertEqual(lines[:3], ["T", "current", "true"])
        # The global file is the session's own, starting from the identity.
        self.assertEqual(
            lines[3], f"include.path={self.home / '.gitconfig.local'}"
        )

    def test_git_hooks(self):
        # .git/hooks is read-only inside: the clause points git at the work
        # tree's hooks through the session's own ~/.gitconfig.
        hooks = self.project / "hooks"
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text("#!/bin/sh\necho checked >&2\nexit 1\n")
        hook.chmod(0o755)
        (self.project / "sub").mkdir()
        self.policy('(git-hooks "hooks")')
        result, argv, environment = self.launch("git", "--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = argv[argv.index("--") + 1 :]
        program = entry.index(self.tools["git"])
        entry[program:] = [
            "sh",
            "-c",
            "cd sub && git -c user.name=T -c user.email=t@x "
            "commit -q --allow-empty -m m",
        ]
        inside = subprocess.run(
            entry, env=environment, text=True, capture_output=True, timeout=15
        )
        self.assertNotEqual(inside.returncode, 0)
        self.assertIn("checked", inside.stderr)

        self.policy('(git-hooks "a")', '(git-hooks "b")')
        result, argv, environment = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("single (git-hooks DIR)", result.stderr)


class Direnv(Launcher):
    def setUp(self):
        super().setUp()
        self.config.write_text("")
        self.allowed = self.home / ".local/share/direnv/allow"
        (self.project / ".envrc").write_text("export A=1\n")
        self.worktree = self.root / "worktrees/w"
        for args in (
            ["add", ".envrc"],
            ["-c", "user.name=T", "-c", "user.email=t@x", "commit", "-qm", "m"],
            ["worktree", "add", "-q", str(self.worktree)],
        ):
            subprocess.run(
                [self.tools["git"], "-C", str(self.project), *args], check=True
            )

    @staticmethod
    def name(envrc, contents):
        """The approval's name as direnv computes it."""
        data = f"{envrc}\n".encode() + Path(contents).read_bytes()
        return hashlib.sha256(data).hexdigest()

    def allow(self, directory):
        envrc = directory / ".envrc"
        self.allowed.mkdir(parents=True, exist_ok=True)
        (self.allowed / self.name(envrc, envrc)).write_text(f"{envrc}\n")

    def approval(self, directory):
        """The approval written by the entry script, or None."""
        result, argv, environment = self.launch(
            "git", "--version", cwd=directory
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        # The container's home starts without the host's approvals.
        shutil.rmtree(self.allowed, ignore_errors=True)
        entry = argv[argv.index("--") + 1 :]
        program = entry.index(self.tools["git"])
        entry[program:] = ["true"]
        inside = subprocess.run(
            entry, env=environment, text=True, capture_output=True, timeout=15
        )
        self.assertEqual(inside.returncode, 0, inside.stderr)
        files = list(self.allowed.iterdir()) if self.allowed.exists() else []
        self.assertLessEqual(len(files), 1, files)
        return (files[0].name, files[0].read_text()) if files else None

    def test_host_approval_is_copied(self):
        self.assertIsNone(self.approval(self.project))
        self.allow(self.project)
        envrc = self.project / ".envrc"
        self.assertEqual(
            self.approval(self.project),
            (self.name(envrc, envrc), f"{envrc}\n"),
        )

    def test_worktree_inherits_main_approval_of_same_contents(self):
        envrc = self.worktree / ".envrc"
        self.allow(self.project)
        self.assertEqual(
            self.approval(self.worktree),
            (self.name(envrc, envrc), f"{envrc}\n"),
        )
        # Contents the main work tree never approved.
        envrc.write_text("export A=2\n")
        self.allow(self.project)
        self.assertIsNone(self.approval(self.worktree))

    def test_environment_loads_for_the_agent_and_each_command(self):
        # A direnv exporting the directory it runs in.
        direnv = self.root / "bin/direnv"
        direnv.write_text(
            "#!" + shutil.which("bash") + "\n"
            'printf "export FROM_DIRENV=%q\\n" "$PWD"\n'
        )
        direnv.chmod(0o755)
        result, argv, environment = self.launch("git", "--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = argv[argv.index("--") + 1 :]
        program = entry.index(self.tools["git"])
        # sh reads no BASH_ENV; the bash below stands for a command.
        entry[program:] = [
            "sh",
            "-c",
            'echo "$FROM_DIRENV"; cd / && bash -c \'echo "$FROM_DIRENV"\'',
        ]
        for claude, expected in ((None, "/"), ("1", str(self.project))):
            env = dict(environment, CLAUDECODE=claude or "")
            inside = subprocess.run(
                entry, env=env, text=True, capture_output=True, timeout=15
            )
            self.assertEqual(inside.returncode, 0, inside.stderr)
            self.assertEqual(
                inside.stdout.splitlines(), [str(self.project), expected]
            )
        hook = self.home / ".local/share/contained-agent/direnv.bash"
        self.assertIn("direnv export bash", hook.read_text())


if __name__ == "__main__":
    unittest.main()
