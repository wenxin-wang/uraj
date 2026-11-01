"""Central credential clauses and container git defaults, with a fake guix.

Run with python3 test/python/uraj/guix/contained-agent/contained-agent-environment.py.
PATH needs Guile 3, Git and Bash.  No Guix daemon or network is needed.
"""

import hashlib
import json
import os
import pty
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
            '  #:projects-secret (getenv "TEST_PROJECTS_SECRET")\n'
            '  #:browser-snapshots (getenv "TEST_BROWSER_SNAPSHOTS")\n'
            '  #:render-nodes (getenv "TEST_RENDER_NODES")))\n'
        )
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=str(bin_dir) + ":" + os.environ["PATH"],
            CONTAINED_AGENT_PROJECTS=str(self.config),
        )
        self.env.pop("PASEO_AGENT_CWD", None)
        self.env.pop("PASEO_HOME", None)
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


class WorktreeMounts(Launcher):
    def git(self, *args):
        return subprocess.check_output(
            [self.tools["git"], "-C", str(self.project), *args], text=True
        ).strip()

    def test_mapped_mounts_inherit_with_worktree_relative_paths(self):
        self.git(
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@x",
            "commit",
            "--allow-empty",
            "-qm",
            "initial",
        )
        worktree = self.root / "linked tree"
        self.git("worktree", "add", "-qb", "linked", str(worktree))
        nested = worktree / "nested"
        nested.mkdir()
        source = self.project / "instances"
        source.mkdir()
        (worktree / "relative-source").write_text("reference")
        self.policy(
            '(share ("~/src/a/instances" "instances"))',
            '(expose ("relative-source" "data/reference") "nested")',
            f'(share ("{source}" "{self.root}/absolute"))',
            '(share ("missing" "skipped"))',
        )
        result, argv, _ = self.launch(cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--share={source}={worktree}/instances", argv)
        self.assertIn(
            f"--expose={worktree}/relative-source={worktree}/data/reference",
            argv,
        )
        self.assertIn(f"--expose={nested}", argv)
        self.assertIn(f"--share={source}={self.root}/absolute", argv)
        self.assertFalse(any("skipped" in arg for arg in argv))
        self.assertFalse((worktree / "instances").exists())

    def test_mapped_mounts_check_both_ends(self):
        source = self.project / "public"
        source.mkdir()
        secret = self.home / ".ssh"
        secret.mkdir()
        (self.project / "alias").symlink_to(secret, target_is_directory=True)
        for kind in ("share", "expose"):
            for src, target in (
                (str(secret), "public-copy"),
                (str(source), "~/.ssh/new"),
                (str(source), "alias/new"),
                (str(source), "../../.ssh/new"),
            ):
                with self.subTest(kind=kind, source=src, target=target):
                    self.policy(f'({kind} ("{src}" "{target}"))')
                    result, argv, _ = self.launch()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("never mounting", result.stderr)
                    self.assertFalse(
                        any(arg.startswith(f"--{kind}={src}=") for arg in argv)
                    )

    def test_mapped_mounts_reject_invalid_entries(self):
        for entry in (
            '("a")',
            '("a" "b" "c")',
            '("a" 3)',
            '("a" "")',
            '("a=b" "c")',
        ):
            with self.subTest(entry=entry):
                self.policy(f"(share {entry})")
                result, argv, _ = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(argv)
                self.assertNotIn("Backtrace", result.stderr)

    def test_browser_snapshots_without_identity(self):
        state = self.home / ".local/state/agent-browser"
        nodes = self.root / "dri"
        nodes.mkdir()
        (nodes / "renderD128").write_text("not a device")
        self.policy('(expose "~/.local/state/agent-browser")')
        result, argv, _ = self.launch(
            TEST_BROWSER_SNAPSHOTS="~/.local/state/agent-browser/published",
            TEST_RENDER_NODES=str(nodes),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("never mounting", result.stderr)
        published = state / "published"
        self.assertEqual(published.stat().st_mode & 0o777, 0o700)
        self.assertEqual(state.stat().st_mode & 0o777, 0o700)
        mounts = [arg for arg in argv if "agent-browser" in arg]
        self.assertEqual(
            mounts, [f"--expose={published}=/run/contained-agent/browser"]
        )
        self.assertFalse(any(str(nodes) in arg for arg in argv))
        self.assertNotIn("--expose=/sys/dev/char", argv)

    def test_main_worktree_is_exposed_before_writable_mounts(self):
        self.project = self.root / "main repo"
        subprocess.run(
            [self.tools["git"], "init", "-q", str(self.project)], check=True
        )
        self.git(
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@x",
            "commit",
            "--allow-empty",
            "-qm",
            "initial",
        )
        worktree = self.project / "nested worktree"
        self.git("worktree", "add", "-qb", "linked", str(worktree))
        result, argv, _ = self.launch(cwd=worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        main = argv.index(f"--expose={self.project}")
        self.assertLess(main, argv.index(f"--share={worktree}"))
        common = self.git("rev-parse", "--absolute-git-dir")
        self.assertLess(main, argv.index(f"--share={common}"))
        self.assertIn(f"--expose={common}/config", argv)
        self.assertIn(f"--expose={worktree}/.git", argv)
        self.assertNotIn(f"--share={self.project}", argv)

    def test_main_checkout_is_only_shared(self):
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--share={self.project}", argv)
        self.assertNotIn(f"--expose={self.project}", argv)

    def test_bare_repository_does_not_expose_parent(self):
        self.git(
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@x",
            "commit",
            "--allow-empty",
            "-qm",
            "initial",
        )
        bare = self.root / "bare.git"
        self.git("clone", "--bare", "-q", str(self.project), str(bare))
        worktree = self.root / "linked"
        subprocess.run(
            [
                self.tools["git"],
                "-C",
                str(bare),
                "worktree",
                "add",
                "-qb",
                "linked",
                str(worktree),
            ],
            check=True,
        )
        result, argv, _ = self.launch(cwd=worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--share={bare}", argv)
        self.assertNotIn(f"--expose={bare}", argv)
        self.assertNotIn(f"--expose={bare.parent}", argv)


class PodmanRemote(Launcher):
    def setUp(self):
        super().setUp()
        self.runtime_record = self.root / "runtime.json"
        launcher = self.root / "bin/runtime"
        launcher.write_text(
            "#!" + shutil.which("python3") + "\n"
            "import json, os, sys\n"
            f"json.dump(sys.argv[1:], open({str(self.runtime_record)!r}, 'w'))\n"
            "if sys.argv[1] in ('--stop', '--check', '--list', '--host-service'): sys.exit(0)\n"
            "command = sys.argv[sys.argv.index('--') + 1:]\n"
            "os.execvp(command[0], command)\n"
        )
        launcher.chmod(0o755)
        driver = self.root / "driver.scm"
        driver.write_text(
            driver.read_text().replace(
                "#:common '()",
                "#:podman-launcher '("
                + json.dumps(str(launcher))
                + ") #:common '()",
            )
        )

    def test_stop_dispatches_without_project_policy(self):
        runtime_id = "a" * 32
        result, _, _ = self.launch("podman-stop", runtime_id, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.runtime_record.read_text()), ["--stop", runtime_id]
        )

    def test_list_dispatches_without_project_policy(self):
        result, _, _ = self.launch("podman-list", cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.runtime_record.read_text()), ["--list"]
        )

    def test_check_dispatches_without_project_policy(self):
        runtime_id = "b" * 32
        result, _, _ = self.launch("podman-check", runtime_id, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.runtime_record.read_text()), ["--check", runtime_id]
        )

    def test_service_dispatches_without_project_policy(self):
        result, _, _ = self.launch("podman-service", cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.runtime_record.read_text()), ["--host-service"]
        )

    def test_central_opt_in_and_local_refusal(self):
        self.policy()
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("podman-remote", argv)
        self.policy("(podman-remote)")
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("podman-remote", argv)
        self.assertIn(
            "--expose=@CONTAINED_PODMAN_SOCKET@=/run/contained-agent/podman",
            argv,
        )
        self.assertNotIn("openssh", argv)
        runtime_args = json.loads(self.runtime_record.read_text())
        self.assertEqual(
            runtime_args[runtime_args.index("--project") + 1], str(self.project)
        )
        self.assertIn(
            "--mount-option=--share=" + str(self.project), runtime_args
        )
        self.assertIn(
            "--mount-option=--expose=" + str(self.project / ".git/config"),
            runtime_args,
        )
        self.assertFalse(any("client-" in arg for arg in argv))
        self.policy()
        local = self.project / ".guix"
        local.mkdir()
        (local / "contained-agent.scm").write_text("(podman-remote)")
        approved = (
            self.home
            / ".local/state/contained-agent/approved"
            / str(self.project).replace("%", "%25").replace("/", "%2F")
            / "test-approved"
        )
        shutil.copytree(local, approved)
        result, argv, _ = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bad clause", result.stderr)
        self.assertIsNone(argv)

    def test_wrapper_preserves_arguments_stdin_and_exit_status(self):
        self.policy('(podman-remote (tmpdir "~/.cache/harbor/tmp space"))')
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        script = argv[argv.index("podman-remote") - 1]
        fake = self.root / "bin/podman"
        fake.write_text(
            "#!" + shutil.which("python3") + "\n"
            "import json, os, sys\n"
            "print(json.dumps([sys.argv[1:], sys.stdin.read(), "
            "os.environ['CONTAINER_HOST'], os.environ['TMPDIR']]))\n"
            "sys.exit(23)\n"
        )
        fake.chmod(0o755)
        arguments = ["run", "--volume", "/path with spaces:/data", "$(false)"]
        result = subprocess.run(
            [
                "bash",
                "-c",
                script,
                "setup",
                argv[argv.index("podman-remote") + 1],
                "podman",
                *arguments,
            ],
            env=self.env,
            input="stdin payload",
            text=True,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 23, result.stderr)
        args, stdin, host, tmpdir = json.loads(result.stdout)
        self.assertEqual(args, ["--remote", *arguments])
        self.assertEqual(stdin, "stdin payload")
        self.assertEqual(tmpdir, str(self.home / ".cache/harbor/tmp space"))
        self.assertTrue(Path(tmpdir).is_dir())
        self.assertIn(f"--share={tmpdir}", argv)
        self.assertEqual(
            host,
            "unix:///run/contained-agent/podman/podman.sock",
        )

    def test_invalid_central_options_fail(self):
        for clauses in (
            ("(podman-remote arbitrary)",),
            ("(podman-remote)", "(podman-remote)"),
            ('(podman-remote (tmpdir "relative"))',),
            ('(podman-remote (tmpdir "~/.cache/../.ssh/new"))',),
        ):
            self.policy(*clauses)
            result, argv, _ = self.launch()
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(argv)

    def test_runtime_does_not_receive_credentials_or_common_state(self):
        private = self.root / "agent-state"
        private.mkdir()
        token = self.root / "token"
        token.write_text("private-token")
        driver = self.root / "driver.scm"
        driver.write_text(
            driver.read_text().replace(
                "#:common '()",
                "#:common '((share " + json.dumps(str(private)) + "))",
            )
        )
        self.policy("(podman-remote)", f'(env "ACCESS_TOKEN" (file "{token}"))')
        result, argv, _ = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--share=" + str(private), argv)
        runtime_args = json.loads(self.runtime_record.read_text())
        mount_args = runtime_args[: runtime_args.index("--")]
        self.assertFalse(
            any(
                str(private) in arg
                or str(token) in arg
                or "private-token" in arg
                for arg in mount_args
            )
        )

    def test_runtime_state_is_never_mounted(self):
        state = self.home / ".local/share/contained-agent/podman/host"
        state.mkdir(parents=True)
        for kind in ("share", "expose"):
            with self.subTest(kind=kind):
                self.policy(
                    "(podman-remote)",
                    f'({kind} "~/.local/share/contained-agent/podman")',
                )
                result, argv, _ = self.launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("never mounting", result.stderr)
                self.assertFalse(
                    any(
                        arg.startswith(("--share=", "--expose="))
                        and ".local/share/contained-agent" in arg
                        for arg in argv
                    )
                )

    def test_tmpdir_cannot_create_under_denied_paths(self):
        private = self.home / ".ssh"
        private.mkdir()
        alias = self.home / "alias"
        alias.symlink_to(private, target_is_directory=True)
        for path in ("~/.ssh/new", "~/alias/new"):
            self.policy(f'(podman-remote (tmpdir "{path}"))')
            result, argv, _ = self.launch()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("denied TMPDIR", result.stderr)
            self.assertIsNone(argv)
            self.assertFalse((private / "new").exists())


class VersionProbe(Launcher):
    def test_version_skips_project_and_container_preparation(self):
        # Cold-start probes must not wait for SOPS, inspect a stale session
        # directory, or ask Guix to build the agent's environment.
        self.config.write_text("not valid scheme (")
        result, argv, _ = self.launch(
            "git",
            "--version",
            TEST_PROJECTS_SECRET=str(self.secrets / "missing"),
            PASEO_AGENT_CWD=str(self.root / "missing-project"),
        )
        expected = subprocess.check_output(
            [self.tools["git"], "--version"], text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)
        self.assertIsNone(argv)

    def test_only_exact_version_probe_skips_container(self):
        for args in (("--version", "extra"), ("auth", "status"), ()):
            with self.subTest(args=args):
                result, argv, _ = self.launch("git", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--container", argv)
                self.assertEqual(
                    argv[-1 - len(args) :], [self.tools["git"], *args]
                )

    def test_unknown_provider_version_still_fails(self):
        result, argv, _ = self.launch("unknown", "--version")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown agent unknown", result.stderr)
        self.assertIsNone(argv)


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

    def test_inline_value_only_in_private_files(self):
        clause = f'(env "GH_TOKEN" (value "{SECRET}"))'
        self.policy(clause)
        result, argv, _ = self.launch(GH_TOKEN="host-value")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("belongs in a private file", result.stderr)
        self.assertIsNone(argv)

        self.config.write_text("")
        local = self.home / ".config/contained-agent/projects.local.scm"
        local.parent.mkdir(parents=True)
        secret = self.secrets / "projects.scm"
        cases = ((local, {}), (secret, {"TEST_PROJECTS_SECRET": str(secret)}))
        for private, env in cases:
            local.unlink(missing_ok=True)
            private.write_text(f'(project "{self.project}" {clause})')
            result, argv, environment = self.launch(
                GH_TOKEN="host-value", **env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(environment["GH_TOKEN"], SECRET)
            self.assertIn("--preserve=^GH_TOKEN$", argv)
            self.assertFalse(any(SECRET in a for a in argv), argv)

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
            '(env "GH_TOKEN" (value 1))',
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
            self.home
            / ".local/state/contained-agent/approved"
            / str(self.project).replace("%", "%25").replace("/", "%2F")
            / "test-approved"
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
        result, argv, environment = self.launch("git")
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
        result, argv, environment = self.launch("git")
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


class ManifestSelection(Launcher):
    def setUp(self):
        super().setUp()
        # Hash fixture contents so edits invalidate the actual approval flow.
        shim = self.root / "bin/guix"
        shim.write_text(
            "#!" + shutil.which("python3") + "\n"
            "import hashlib, json, os, pathlib, sys\n"
            'if sys.argv[1] == "hash":\n'
            " p = pathlib.Path(sys.argv[-1])\n"
            " data = (json.dumps([(str(f.relative_to(p)), "
            "f.read_bytes().hex()) for f in sorted(p.rglob('*')) "
            "if f.is_file()]).encode() if p.is_dir() else p.read_bytes())\n"
            " print(hashlib.sha256(data).hexdigest())\n"
            "else: json.dump([sys.argv, dict(os.environ)], "
            f"open({str(self.record)!r}, 'w'))\n"
        )

    def approve(self, cwd=None, **env):
        master, slave = pty.openpty()
        try:
            os.write(master, b"y\n")
            return subprocess.run(
                self.command + ["allow"],
                cwd=cwd or self.project,
                env=dict(self.env, **env),
                stdin=slave,
                capture_output=True,
                text=True,
                timeout=15,
            )
        finally:
            os.close(master)
            os.close(slave)

    def manifest_path(self, cwd=None):
        result, argv, _ = self.launch(cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = [
            arg.split("=", 1)[1]
            for arg in argv
            if arg.startswith("--manifest=")
        ]
        self.assertLessEqual(len(paths), 1)
        return Path(paths[0]) if paths else None

    def test_explicit_file_selected_by_private_policy(self):
        self.config.write_text("")
        private = self.home / ".config/contained-agent/projects.local.scm"
        private.parent.mkdir(parents=True)
        private.write_text(
            f'(project "{self.project}" (manifest "maa-manifest.scm"))'
        )
        (self.project / "maa-manifest.scm").write_text("selected\n")
        (self.project / ".guix").mkdir()
        (self.project / ".guix/manifest.scm").write_text("default\n")
        nested = self.project / "nested"
        nested.mkdir()
        self.assertIsNone(self.manifest_path(nested))
        result = self.approve(nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selected manifest: maa-manifest.scm", result.stdout)
        approved = self.manifest_path(nested)
        self.assertEqual(approved.read_text(), "selected\n")
        self.assertNotEqual(approved, self.project / "maa-manifest.scm")
        (self.project / "maa-manifest.scm").write_text("changed\n")
        self.assertIsNone(self.manifest_path())

    def test_guix_selection_approves_entire_directory(self):
        self.policy('(manifest ".guix/maa-manifest.scm")')
        local = self.project / ".guix"
        local.mkdir()
        (local / "manifest.scm").write_text("default\n")
        (local / "maa-manifest.scm").write_text("selected\n")
        (local / "helper.scm").write_text("helper\n")
        result = self.approve()
        self.assertEqual(result.returncode, 0, result.stderr)
        approved = self.manifest_path()
        self.assertEqual(approved.name, "maa-manifest.scm")
        self.assertEqual(approved.read_text(), "selected\n")
        self.assertEqual(
            (approved.parent / "helper.scm").read_text(), "helper\n"
        )
        (local / "helper.scm").write_text("changed\n")
        self.assertIsNone(self.manifest_path())

    def test_default_manifest_still_works(self):
        self.config.write_text("")
        (self.project / "manifest.scm").write_text("default\n")
        result = self.approve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.manifest_path().read_text(), "default\n")

    def test_invalid_selection_fails_without_fallback(self):
        (self.project / "manifest.scm").write_text("default\n")
        (self.project / "linked.scm").symlink_to("manifest.scm")
        (self.project / "linked-dir").symlink_to(self.project)
        for name in (
            "missing.scm",
            "../manifest.scm",
            "/tmp/manifest.scm",
            "linked.scm",
            "linked-dir/manifest.scm",
            ".",
            "",
        ):
            with self.subTest(name=name):
                self.policy(f'(manifest "{name}")')
                result, argv, _ = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Backtrace", result.stderr)
                self.assertIsNone(argv)
                result = self.approve()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Backtrace", result.stderr)
        self.policy('(manifest "manifest.scm")', '(manifest "manifest.scm")')
        result, _, _ = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("single", result.stderr)


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
        result, argv, environment = self.launch("git", cwd=directory)
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

    def test_worktree_inherits_identical_approval(self):
        envrc = self.worktree / ".envrc"
        self.assertIsNone(self.approval(self.worktree))
        self.allow(self.project)
        self.assertEqual(
            self.approval(self.worktree),
            (self.name(envrc, envrc), f"{envrc}\n"),
        )
        # Contents the main work tree never approved.
        envrc.write_text("export A=2\n")
        self.assertIsNone(self.approval(self.worktree))
        self.allow(self.worktree)
        self.assertEqual(
            self.approval(self.worktree),
            (self.name(envrc, envrc), f"{envrc}\n"),
        )

    def test_inherit_command_approves_on_the_host(self):
        inherit = self.command + ["inherit", str(self.worktree)]
        result = subprocess.run(
            inherit, env=self.env, text=True, capture_output=True, timeout=15
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("direnv allow", result.stderr)
        self.allow(self.project)
        result = subprocess.run(
            inherit, env=self.env, text=True, capture_output=True, timeout=15
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Inherited approvals of {self.project}", result.stdout)
        envrc = self.worktree / ".envrc"
        self.assertEqual(
            (self.allowed / self.name(envrc, envrc)).read_text(),
            f"{envrc}\n",
        )

    def test_worktree_policy_inherits_unless_overridden(self):
        self.secret.write_text(SECRET)
        clause = f'(env "WORKTREE_SECRET" (file "{self.secret}"))'
        self.policy(clause)
        nested = self.worktree / "nested"
        nested.mkdir()
        result, _, environment = self.launch(cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(environment["WORKTREE_SECRET"], SECRET)

        # An empty local entry overrides even managed/private main policies.
        local = self.home / ".config/contained-agent/projects.local.scm"
        local.parent.mkdir(parents=True)
        local.write_text(f'(project "{self.worktree}")')
        result, _, environment = self.launch(cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("WORKTREE_SECRET", environment)

        local.write_text(
            f'(project "{self.worktree}" (env "OWN" (file "{self.secret}")))'
        )
        result, _, environment = self.launch(cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("WORKTREE_SECRET", environment)
        self.assertEqual(environment["OWN"], SECRET)
        result, _, environment = self.launch(cwd=self.project)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(environment["WORKTREE_SECRET"], SECRET)
        self.assertNotIn("OWN", environment)

    def test_worktree_inherits_private_github_policy(self):
        (self.secrets / "personal").write_text(SECRET)
        private = self.root / "private.scm"
        private.write_text(f'(project "{self.project}" (github "personal"))')
        result, argv, environment = self.launch(
            cwd=self.worktree, TEST_PROJECTS_SECRET=str(private)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"--expose={self.secrets / 'personal'}="
            "/run/contained-agent/git-credential-0",
            argv,
        )
        self.assertEqual(environment["GIT_CONFIG_COUNT"], "2")
        self.config.write_text(f'(project "{self.worktree}")')
        result, argv, environment = self.launch(
            cwd=self.worktree, TEST_PROJECTS_SECRET=str(private)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("git-credential-" in arg for arg in argv))
        self.assertEqual(environment["GIT_CONFIG_COUNT"], "1")

    def test_local_and_direnv_approvals_are_inherited_together(self):
        for directory in (self.project, self.worktree):
            local = directory / ".guix"
            local.mkdir()
            (local / "contained-agent.scm").write_text('(preserve "LOCAL_OK")')
        # Unapproved local files keep the approved .envrc out as well.
        self.allow(self.project)
        self.assertIsNone(self.approval(self.worktree))
        approved = (
            self.home
            / ".local/state/contained-agent/approved"
            / str(self.project).replace("%", "%25").replace("/", "%2F")
            / "test-approved"
        )
        shutil.copytree(self.project / ".guix", approved)
        result, argv, _ = self.launch(cwd=self.project)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--preserve=^LOCAL_OK$", argv)
        # The main work tree's .envrc is not approved, so neither is taken.
        result, argv, _ = self.launch(cwd=self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--preserve=^LOCAL_OK$", argv)
        self.assertIsNone(self.approval(self.worktree))
        self.allow(self.project)
        result, argv, _ = self.launch(cwd=self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--preserve=^LOCAL_OK$", argv)
        self.assertIsNotNone(self.approval(self.worktree))

    def test_environment_loads_for_the_agent_and_each_command(self):
        # A direnv exporting the directory it runs in.
        direnv = self.root / "bin/direnv"
        direnv.write_text(
            "#!" + shutil.which("bash") + "\n"
            'printf "export FROM_DIRENV=%q\\n" "$PWD"\n'
        )
        direnv.chmod(0o755)
        result, argv, environment = self.launch("git")
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


class PaseoSource(Launcher):
    """Paseo worktrees inherit the checkout they were created from."""

    def setUp(self):
        super().setUp()
        self.source = self.root / "source checkout"
        self.worktree = self.root / "worktrees/w"
        for args in (
            ["-c", "user.name=T", "-c", "user.email=t@x", "commit"]
            + ["--allow-empty", "-qm", "m"],
            ["worktree", "add", "-qb", "source", str(self.source)],
            ["worktree", "add", "-qb", "w", str(self.worktree)],
        ):
            subprocess.run(
                [self.tools["git"], "-C", str(self.project), *args], check=True
            )
        self.registry = self.home / ".paseo/projects"
        self.registry.mkdir(parents=True)
        self.entries = {
            self.project: '(preserve "MAIN")',
            self.source: '(preserve "SOURCE")',
        }

    def register(self, root, worktree=None, archived=None):
        worktree = worktree or self.worktree
        (self.registry / "projects.json").write_text(
            json.dumps(
                [
                    {"projectId": "p", "rootPath": str(root)},
                    {"projectId": "q", "rootPath": str(self.project)},
                ]
            )
        )
        (self.registry / "workspaces.json").write_text(
            json.dumps(
                [
                    {
                        "projectId": "p",
                        "kind": "worktree",
                        "cwd": str(worktree),
                        "worktreeRoot": str(worktree),
                        "archivedAt": archived,
                    }
                ]
            )
        )

    def preserved(self, cwd=None):
        self.config.write_text(
            "".join(
                f'(project "{root}" {clauses})'
                for root, clauses in self.entries.items()
            )
        )
        result, argv, _ = self.launch(cwd=cwd or self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {
            name
            for name in ("MAIN", "SOURCE")
            if f"--preserve=^{name}$" in argv
        }, result.stderr

    def test_source_checkout_entries(self):
        self.assertEqual(self.preserved()[0], {"MAIN"})
        self.register(self.source)
        self.assertEqual(self.preserved()[0], {"SOURCE"})
        # Also from a subdirectory, and for the source checkout itself.
        (self.worktree / "nested").mkdir()
        self.assertEqual(
            self.preserved(self.worktree / "nested")[0], {"SOURCE"}
        )
        self.assertEqual(self.preserved(self.source)[0], {"SOURCE"})
        # Through PASEO_AGENT_CWD, as Paseo launches agents from $HOME.
        result, argv, _ = self.launch(
            cwd=self.home, PASEO_AGENT_CWD=str(self.worktree)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--preserve=^SOURCE$", argv)
        self.assertNotIn("--preserve=^MAIN$", argv)

    def test_source_without_entry_falls_back_to_main(self):
        self.register(self.source)
        del self.entries[self.source]
        self.assertEqual(self.preserved()[0], {"MAIN"})
        # An explicit empty entry suppresses inheritance as for the worktree.
        self.entries[self.source] = ""
        self.assertEqual(self.preserved()[0], set())

    def test_own_entry_wins(self):
        self.register(self.source)
        self.entries[self.worktree] = ""
        self.assertEqual(self.preserved()[0], set())

    def test_untrusted_or_stale_records_are_ignored(self):
        other = self.root / "other"
        subprocess.run(
            [self.tools["git"], "init", "-q", str(other)], check=True
        )
        self.entries[other] = '(preserve "SOURCE")'
        for root, kwargs in (
            # Another repository, even with its own entry.
            (other, {}),
            (self.root / "missing", {}),
            (self.source, {"archived": "2026-10-01T00:00:00Z"}),
            (self.source, {"worktree": self.root / "elsewhere"}),
        ):
            with self.subTest(root=root, **kwargs):
                self.register(root, **kwargs)
                self.assertEqual(self.preserved()[0], {"MAIN"})

    def test_malformed_registry_warns(self):
        (self.registry / "workspaces.json").write_text("{")
        preserved, stderr = self.preserved()
        self.assertEqual(preserved, {"MAIN"})
        self.assertIn("workspaces.json: unreadable, ignored", stderr)


if __name__ == "__main__":
    unittest.main()
