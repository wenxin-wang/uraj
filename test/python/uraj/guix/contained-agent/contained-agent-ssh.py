"""Host-side SSH integration, using only disposable keys and repositories.

Run with python3 test/python/uraj/guix/contained-agent/contained-agent-ssh.py.  PATH needs Guile 3, OpenSSH
8.9+, Git, Bash, bubblewrap and sha256sum.  No Guix daemon or network is needed.
"""
import json
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ProjectSSH(unittest.TestCase):
    def test_lifecycle_and_container_arguments(self):
        tools = {name: shutil.which(name) for name in
                 ("guile", "git", "bash", "sha256sum", "ssh-agent", "ssh-add", "ssh-keygen", "ssh")}
        self.assertTrue(all(tools.values()), tools)
        source = Path(__file__).resolve().parents[5] / "src/guile"
        with tempfile.TemporaryDirectory(prefix="contained-ssh-") as tmp:
            root = Path(tmp)
            home = root / "home"
            runtime = root / "run"
            home.mkdir()
            runtime.mkdir(mode=0o700)
            projects = [home / "src" / name for name in ("a", "b")]
            for project in projects:
                project.mkdir(parents=True)
                subprocess.run([tools["git"], "init", "-q", str(project)], check=True)
            keys = [root / name for name in ("key-a", "key-b", "host-key")]
            for key in keys:
                subprocess.run([tools["ssh-keygen"], "-q", "-t", "ed25519", "-N", "",
                                "-f", str(key)], check=True)
            known = root / "known_hosts"
            host_public = keys[2].with_suffix(".pub").read_text()
            known.write_text("a.example.test,b.example.test " + host_public +
                             "@cert-authority *.example.test " + host_public)
            config = root / "projects.scm"
            private = home / ".config/contained-agent/projects.local.scm"
            private.parent.mkdir(parents=True)
            reference = root / "reference"
            reference.mkdir()
            config.write_text("\n".join(
                f'(project "{p}" (expose "{reference}") (preserve "CA_PUBLIC"))'
                for p in projects))

            def policy(dest="*.example.test", client_config=""):
                # Exercise literal multiline Scheme strings, not just escaped \n.
                config_string = json.dumps(client_config).replace("\\n", "\n")
                private.write_text("\n".join(
                    f'(project "{project}" (preserve "CA_PRIVATE") '
                    f'(ssh-agent (known-hosts "{known}") '
                    f'(client-config {config_string}) '
                    f'(identity "{key}" (destinations "{dest}" "git@a.example.test"))))'
                    for project, key in zip(projects, keys)))

            policy()
            driver = root / "driver.scm"
            driver.write_text('''(use-modules (uraj bin contained-agent))
(contained-agent-main (cons "contained-agent" (cdr (command-line)))
 #:agents '(("probe" (program . "/bin/true"))) #:common '() #:packages '()
 #:git ''' + json.dumps(tools["git"]) + " #:ssh-tools '(" + " ".join(
                f'({name} . "{tools[name]}")' for name in
                ("bash", "sha256sum", "ssh-agent", "ssh-add")) + "))\n")
            env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                       CONTAINED_AGENT_PROJECTS=str(config))
            env.pop("PASEO_AGENT_CWD", None)
            command = [tools["guile"], "--no-auto-compile", "-L", str(source), str(driver)]

            def run(*args, cwd=None, success=True):
                result = subprocess.run(command + list(map(str, args)), env=env,
                                        cwd=cwd or root, text=True, capture_output=True,
                                        timeout=15)
                if success:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                return result

            def identities(sock):
                result = subprocess.run([tools["ssh-add"], "-L"],
                                        env=dict(env, SSH_AUTH_SOCK=sock),
                                        text=True, capture_output=True, check=True)
                return result.stdout.split()[1]

            try:
                sockets = [run("ssh-start", p).stdout.strip() for p in projects]
                first_state = (Path(sockets[0]).parent / "state").read_text()
                first_inodes = {name: (Path(sockets[0]).parent / name).stat().st_ino
                                for name in ("ssh.sock", "config", "known_hosts")}
                self.assertNotEqual(*sockets)
                self.assertTrue(all(len(s.encode()) < 108 for s in sockets))
                for sock, key in zip(sockets, keys):
                    self.assertEqual(identities(sock), key.with_suffix(".pub").read_text().split()[1])
                    # Destination-constrained keys cannot perform unbound signing.
                    result = subprocess.run([tools["ssh-add"], "-T", str(key) + ".pub"],
                                            env=dict(env, SSH_AUTH_SOCK=sock), capture_output=True)
                    self.assertNotEqual(result.returncode, 0)

                # A read-only socket bind still supports the real agent protocol.
                bwrap = shutil.which("bwrap")
                self.assertIsNotNone(bwrap, "bubblewrap is required for socket mount verification")
                mounted = subprocess.run(
                    [bwrap, "--ro-bind", "/gnu/store", "/gnu/store", "--proc", "/proc",
                     "--dev", "/dev", "--ro-bind", "/etc/passwd", "/etc/passwd",
                     "--ro-bind", sockets[0], "/run/contained-agent/ssh.sock",
                     "--setenv", "SSH_AUTH_SOCK", "/run/contained-agent/ssh.sock",
                     "--", tools["ssh-add"], "-L"], text=True, capture_output=True)
                self.assertEqual(mounted.returncode, 0, mounted.stderr)
                self.assertEqual(mounted.stdout.split()[1],
                                 keys[0].with_suffix(".pub").read_text().split()[1])

                # Two identities in one policy, each with multiple destinations.
                private.write_text(
                    f'(project "{projects[0]}" (ssh-agent (known-hosts "{known}")' +
                    ''.join(f'(identity "{k}" (destinations "*.example.test" "git@a.example.test"))'
                            for k in keys[:2]) + '))')
                run("ssh-start", projects[0])
                listed = subprocess.run([tools["ssh-add"], "-L"],
                                        env=dict(env, SSH_AUTH_SOCK=sockets[0]),
                                        capture_output=True, text=True, check=True)
                self.assertEqual(len(listed.stdout.splitlines()), 2)
                policy()
                run("ssh-start", projects[0])
                self.assertEqual(first_state, (Path(sockets[0]).parent / "state").read_text())
                for name, inode in first_inodes.items():
                    self.assertEqual((Path(sockets[0]).parent / name).stat().st_ino, inode)
                # The second identity has been removed, not merely left loaded.
                listed = subprocess.run([tools["ssh-add"], "-L"],
                                        env=dict(env, SSH_AUTH_SOCK=sockets[0]),
                                        capture_output=True, text=True, check=True)
                self.assertEqual(len(listed.stdout.splitlines()), 1)

                # Linked worktrees share their main project's socket.
                subprocess.run([tools["git"], "-C", str(projects[0]), "-c", "user.name=Test",
                                "-c", "user.email=test@example.invalid", "commit", "-qm", "init",
                                "--allow-empty"], check=True)
                worktree = root / "worktree"
                subprocess.run([tools["git"], "-C", str(projects[0]), "worktree", "add", "-qb",
                                "test", str(worktree)], check=True)
                self.assertEqual(run("ssh-socket", worktree).stdout.strip(), sockets[0])

                # Capture the real launcher's Guix argv, without needing a daemon.
                bin_dir = root / "bin"
                bin_dir.mkdir()
                capture = root / "argv.json"
                import sys
                shim = bin_dir / "guix"
                shim.write_text(f'#!{sys.executable}\nimport json,sys\n'
                                'if sys.argv[1] == "hash": print("test-approved")\n'
                                f'else: json.dump(sys.argv[1:],open({str(capture)!r},"w"))\n')
                shim.chmod(0o755)
                env["PATH"] = str(bin_dir) + ":" + env["PATH"]
                run("ssh-stop", projects[0])
                run("probe", "--version", cwd=projects[0])
                self.assertFalse(Path(sockets[0]).exists())

                # First launch auto-loads; later/concurrent launches reuse it.
                self.assertEqual(run("probe", cwd=projects[0]).stdout, "")
                state = Path(sockets[0]).parent / "state"
                original = state.read_text()
                self.assertEqual(identities(sockets[0]),
                                 keys[0].with_suffix(".pub").read_text().split()[1])
                run("probe", cwd=projects[0])
                self.assertEqual(original, state.read_text())
                run("ssh-stop", projects[0])
                launches = [subprocess.Popen(command + ["probe"], env=env, cwd=projects[0],
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True) for _ in range(2)]
                for launch in launches:
                    out, err = launch.communicate(timeout=15)
                    self.assertEqual(launch.returncode, 0, err)
                    self.assertEqual(out, "")
                original = state.read_text()
                run("probe", cwd=projects[0])
                self.assertEqual(original, state.read_text())
                argv = json.loads(capture.read_text())
                self.assertIn(f"--expose={sockets[0]}=/run/contained-agent/ssh.sock", argv)
                self.assertIn("SSH_AUTH_SOCK=/run/contained-agent/ssh.sock", argv)
                self.assertIn("openssh", argv)
                self.assertIn(f"--expose={reference}", argv)
                self.assertIn("--preserve=^CA_PUBLIC$", argv)
                self.assertIn("--preserve=^CA_PRIVATE$", argv)
                self.assertFalse(any(str(private) in a for a in argv))
                self.assertFalse(any(str(keys[0]) in a for a in argv))
                self.assertFalse(any(sockets[1] in a for a in argv))

                # Inline text is private runtime data, mounted read-only for SSH.
                sentinel = root / "must-not-exist"
                client = ("Host a.example.test\n"
                          "    HostName 192.0.2.1\n"
                          "    User test-user\n"
                          "    Port 23333\n"
                          "    HostKeyAlias [a.example.test]:23333\n"
                          "Host *\n"
                          "    IdentitiesOnly no\n"
                          "    ForwardAgent no\n"
                          f"# literal $HOME $(touch {sentinel})\n")
                policy(client_config=client)
                run("probe", cwd=projects[0])
                generated = Path(sockets[0]).parent / "config"
                self.assertEqual(generated.read_text(), client)
                self.assertEqual(generated.stat().st_mode & 0o777, 0o600)
                self.assertFalse(sentinel.exists())
                self.assertIn(f"--expose={generated}={home}/.ssh/config",
                              json.loads(capture.read_text()))
                resolved = subprocess.run(
                    [bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--ro-bind", str(generated), str(generated),
                     "--", tools["ssh"], "-G", "-F", str(generated), "a.example.test"],
                    capture_output=True, text=True)
                self.assertEqual(resolved.returncode, 0, resolved.stderr)
                for setting in ("hostname 192.0.2.1", "user test-user", "port 23333",
                                "hostkeyalias [a.example.test]:23333", "identitiesonly no",
                                "forwardagent no"):
                    self.assertIn(setting, resolved.stdout.splitlines())

                # Default config discovery checks HOME, unlike explicit -F.
                # Reproduce Guix's synthetic 1777 home, then run the real
                # container bootstrap and ensure SSH accepts that same config.
                real_home = pwd.getpwuid(os.getuid()).pw_dir
                mounts = [bwrap, "--ro-bind", "/", "/", "--dev", "/dev",
                          "--tmpfs", real_home, "--ro-bind", str(generated),
                          real_home + "/.ssh/config", "--", tools["bash"], "-c",
                          'chmod 1777 -- "$1"; shift; exec "$@"', "setup", real_home]
                rejected = subprocess.run(mounts + [tools["ssh"], "-G", "a.example.test"],
                                          capture_output=True, text=True)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("bad ownership or modes for directory", rejected.stderr)
                argv = json.loads(capture.read_text())
                bootstrap = argv[argv.index("--") + 3]
                accepted = subprocess.run(
                    mounts + [tools["bash"], "-c", bootstrap, "contained-agent", real_home,
                              str(projects[0]), "0", tools["ssh"], "-G", "a.example.test"],
                    capture_output=True, text=True)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertIn("port 23333", accepted.stdout.splitlines())
                denied = subprocess.run(
                    [bwrap, "--ro-bind", "/", "/", "--ro-bind", str(generated), str(generated),
                     "--", tools["bash"], "-c", 'echo changed >> "$1"', "probe", str(generated)],
                    capture_output=True, text=True)
                self.assertNotEqual(denied.returncode, 0)
                self.assertEqual(generated.read_text(), client)
                previous = state.read_text()
                policy(client_config=client.replace("23333", "24444"))
                run("probe", cwd=projects[0])
                self.assertNotEqual(state.read_text(), previous)
                self.assertIn("Port 24444", generated.read_text())
                policy()
                run("probe", cwd=projects[0])
                self.assertEqual(generated.read_text(), "")
                original = state.read_text()

                policy("b.example.test")
                run("probe", "--version", cwd=projects[0])
                self.assertEqual(original, state.read_text())
                self.assertNotIn("SSH_AUTH_SOCK=/run/contained-agent/ssh.sock",
                                 json.loads(capture.read_text()))
                run("probe", cwd=projects[0])
                self.assertNotEqual(original, state.read_text())

                # Without tty/askpass, an encrypted key fails promptly and cleans up.
                encrypted = root / "encrypted-key"
                subprocess.run([tools["ssh-keygen"], "-q", "-t", "ed25519", "-N",
                                "test-passphrase", "-f", str(encrypted)], check=True)
                private.write_text(f'(project "{projects[0]}" (ssh-agent (known-hosts "{known}") '
                                  f'(identity "{encrypted}" (destinations "a.example.test"))))')
                env["SSH_ASKPASS_REQUIRE"] = "never"
                self.assertIn("ssh-start", run("probe", cwd=projects[0], success=False).stderr)
                self.assertFalse(Path(sockets[0]).exists())
                policy()
                run("probe", cwd=projects[0])

                # Private settings are optional and never replace public clauses.
                private.unlink()
                run("probe", cwd=projects[0])
                argv = json.loads(capture.read_text())
                self.assertIn(f"--expose={reference}", argv)
                self.assertNotIn("SSH_AUTH_SOCK=/run/contained-agent/ssh.sock", argv)
                policy()

                # Even an approved project-local file cannot request private keys.
                (projects[0] / ".guix").mkdir()
                approved = home / ".local/state/contained-agent/approved/test-approved"
                approved.mkdir(parents=True)
                (approved / "contained-agent.scm").write_text('(ssh-agent)')
                self.assertIn("bad clause", run("probe", cwd=projects[0], success=False).stderr)

                # A failed load must revoke the previous agent, not leave stale keys.
                policy("unknown.invalid")
                failure = run("ssh-start", projects[0], success=False)
                self.assertIn('No host keys found for destination "unknown.invalid"', failure.stderr)
                self.assertIn(f'Identity: "{keys[0]}"', failure.stderr)
                self.assertIn('Destinations: ("unknown.invalid"', failure.stderr)
                self.assertIn(f'Known hosts: "{known}"', failure.stderr)
                self.assertIn('[host]:port', failure.stderr)
                self.assertNotIn('Unlock keys with', failure.stderr)
                self.assertFalse(Path(sockets[0]).exists())

                # Empty destination lists fail validation before any key is loaded.
                private.write_text(f'(project "{projects[0]}" (ssh-agent '
                                  f'(identity "{keys[0]}" (destinations))))')
                run("ssh-start", projects[0], success=False)
                policy()
            finally:
                policy()
                for project in projects:
                    run("ssh-stop", project)


if __name__ == "__main__":
    unittest.main()
