"""Test optional nesting/cache mounts without a daemon or real host cache.

Needs Guile 3, Git, Bash, coreutils and bubblewrap on PATH.
Run: python3 test/python/uraj/guix/contained-agent/contained-agent-guix.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class GuixAccess(unittest.TestCase):
    def test_opt_in_and_cache_isolation(self):
        tools = {name: shutil.which(name) for name in ("guile", "git", "bash", "bwrap")}
        self.assertTrue(all(tools.values()), tools)
        source = Path(__file__).resolve().parents[5] / "src/guile"
        with tempfile.TemporaryDirectory(prefix="contained-guix-") as tmp:
            root = Path(tmp)
            home = root / "home"
            project = home / "src/project"
            project.mkdir(parents=True)
            subprocess.run([tools["git"], "init", "-q", str(project)], check=True)
            host_cache = home / ".cache/guix"
            (host_cache / "checkouts").mkdir(parents=True)
            (host_cache / "checkouts/source").write_text("host-original")
            profiles = root / "profiles/per-user/test"
            profiles.mkdir(parents=True)
            policy = root / "projects.scm"
            policy.write_text(f'(project "{project}" (expose "{root / "profiles"}"))')
            capture = root / "argv.json"
            shim = root / "guix"
            shim.write_text(f'#!{sys.executable}\nimport json,sys\n'
                            'if sys.argv[1] == "hash": print("approved-test")\n'
                            f'else: json.dump(sys.argv[1:],open({str(capture)!r},"w"))\n')
            shim.chmod(0o755)
            driver = root / "driver.scm"
            driver.write_text('''(use-modules (uraj bin contained-agent))
(define module (resolve-module '(uraj bin contained-agent)))
(define original (module-ref module 'guix-daemon-options))
;; Keep even the GC-root fixture inside this test's temporary directory.
(module-set! module 'guix-daemon-options
 (lambda (project) (original project #:profile-directory ''' + json.dumps(str(profiles)) + ''')))
(contained-agent-main '("contained-agent" "probe")
 #:agents '(("probe" (program . "/bin/true"))) #:common '() #:packages '()
 #:git ''' + json.dumps(tools["git"]) + ''')
''')
            env = dict(os.environ, HOME=str(home), CONTAINED_AGENT_PROJECTS=str(policy),
                       PATH=str(root) + ":" + os.environ["PATH"])
            env.pop("PASEO_AGENT_CWD", None)
            env.pop("XDG_CACHE_HOME", None)

            def launch():
                subprocess.run([tools["guile"], "--no-auto-compile", "-L", str(source),
                                str(driver)], cwd=project, env=env, capture_output=True,
                               text=True, check=True, timeout=15)
                return json.loads(capture.read_text())

            self.assertNotIn("--nesting", launch())
            private = home / ".config/contained-agent/projects.local.scm"
            private.parent.mkdir(parents=True)
            private.write_text(f'(project "{project}" (guix-daemon))')
            first = launch()
            self.assertIn("--nesting", first)
            cache_option = next(a for a in first if a.endswith("=" + str(host_cache)))
            cache = Path(cache_option.split("=", 2)[1])
            self.assertNotEqual(cache, host_cache)
            self.assertEqual((cache / "checkouts/source").read_text(), "host-original")
            self.assertNotEqual((cache / "checkouts/source").stat().st_ino,
                                (host_cache / "checkouts/source").stat().st_ino)
            for name in ("profiles", "inferiors"):
                child = "--share=" + str(profiles / name)
                self.assertIn(child, first)
                self.assertGreater(first.index(child), first.index("--expose=" + str(root / "profiles")))

            # Mount order and actual write-through: only the private cache changes.
            mount_args = []
            for arg in first:
                if arg.startswith(("--share=", "--expose=")):
                    option, path = arg.split("=", 1)
                    src, sep, dst = path.partition("=")
                    mount_args += ["--bind" if option == "--share" else "--ro-bind",
                                   src, dst if sep else src]
            probe = ('printf changed > "$1/checkouts/source"; '
                     'printf root > "$2/profiles/probe"; '
                     'printf root > "$2/inferiors/probe"')
            subprocess.run([tools["bwrap"], "--ro-bind", "/", "/", *mount_args,
                            "--", tools["bash"], "-ec", probe, "probe", str(host_cache),
                            str(profiles)], check=True)
            self.assertEqual((host_cache / "checkouts/source").read_text(), "host-original")
            self.assertEqual((cache / "checkouts/source").read_text(), "changed")
            (host_cache / "checkouts/source").write_text("new-host-version")
            launch()
            self.assertEqual((cache / "checkouts/source").read_text(), "changed")

            # Custom XDG nesting location must be covered too.
            xdg = root / "xdg"
            (xdg / "guix").mkdir(parents=True)
            env["XDG_CACHE_HOME"] = str(xdg)
            custom = launch()
            self.assertIn(f"--share={cache}={xdg / 'guix'}", custom)
            self.assertIn(f"--share={cache}={host_cache}", custom)

            # The existing approval mechanism also gates project-local opt-in.
            private.unlink()
            (project / ".guix").mkdir()
            self.assertNotIn("--nesting", launch())
            approved = home / ".local/state/contained-agent/approved/approved-test"
            approved.mkdir(parents=True)
            (approved / "contained-agent.scm").write_text('(guix-daemon)')
            self.assertIn("--nesting", launch())


if __name__ == "__main__":
    unittest.main()
