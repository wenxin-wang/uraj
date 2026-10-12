"""Exercise the Codex overlay with a fake HOME and real mounts.

Needs Guile 3, Git, Bash, coreutils and recent bubblewrap on PATH.
Set CODEX_TEST_BINARY to also test the installed Codex config/batchWrite API.
The real backend must finish importing historical rollouts before shutdown.
Run: python3 test/python/uraj/guix/contained-agent/contained-agent-codex.py
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def probe():
    home = Path(os.environ["HOME"]) / ".codex"
    sqlite_home = json.loads(sys.argv[2].split("=", 1)[1])
    assert sqlite_home == str(home / "contained-sqlite")
    assert (home / "config.toml").is_symlink()
    assert (home / "config.toml").read_text() == "# host config\n"

    binary = os.environ.get("CODEX_TEST_BINARY")
    if binary:
        requests = [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "overlay-test", "version": "1"}
                },
            },
            {"method": "initialized"},
            {"id": 3, "method": "thread/list", "params": {"limit": 1}},
            {
                "id": 2,
                "method": "config/batchWrite",
                "params": {
                    "edits": [
                        {
                            "keyPath": "projects",
                            "value": {
                                str(home.parent): {"trust_level": "trusted"}
                            },
                            "mergeStrategy": "upsert",
                        }
                    ]
                },
            },
        ]
        with subprocess.Popen(
            [binary, *sys.argv[1:3], "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ) as server:
            try:
                for request in requests:
                    server.stdin.write(json.dumps(request) + "\n")
                    server.stdin.flush()
                    if "id" in request:
                        while True:
                            line = server.stdout.readline()
                            assert line, "app-server closed before replying"
                            reply = json.loads(line)
                            if reply.get("id") == request["id"]:
                                assert "error" not in reply, reply
                                break
                assert "trusted" in (home / "config.toml").read_text()
                with sqlite3.connect(
                    Path(sqlite_home) / "state_5.sqlite"
                ) as db:
                    assert db.execute(
                        "select status from backfill_state"
                    ).fetchone() == ("complete",)
                    assert (
                        db.execute("select count(*) from threads").fetchone()[0]
                        == 2
                    )
            finally:
                server.stdin.close()
                server.terminate()
                try:
                    server.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
        subprocess.run(
            [binary, "login", "--with-api-key"],
            input="sk-overlay-test-not-a-real-key\n",
            text=True,
            check=True,
            capture_output=True,
            timeout=10,
        )
    else:
        target = (home / "config.toml").resolve()
        temporary = target.with_suffix(".tmp")
        temporary.write_text("# trusted in this session\n")
        temporary.replace(target)
        (home / "auth.json").write_text('{"OPENAI_API_KEY":"test-updated"}')

    # A whole shared directory keeps WAL/SHM and concurrent connections together.
    with sqlite3.connect(Path(sqlite_home) / "probe.sqlite") as db:
        db.execute("pragma journal_mode=wal")
        db.execute("create table if not exists visits (n integer)")
        db.execute("insert into visits values (1)")
        db.commit()
        assert (Path(sqlite_home) / "probe.sqlite-wal").exists()
        with sqlite3.connect(Path(sqlite_home) / "probe.sqlite") as reader:
            assert reader.execute("select count(*) from visits").fetchone()[0]
    (home / "sessions/probe.jsonl").write_text("session retained\n")
    (home / "thread-writer-locks/probe.lock").touch()
    for name in ("history.jsonl", "session_index.jsonl"):
        with (home / name).open("a") as file:
            file.write("retained\n")
    # Codex replaces the name index when deleting a thread; a file bind
    # would fail here after the real shared rollout had already been deleted.
    index_tmp = home / "session_index.jsonl.tmp"
    index_tmp.write_text("")
    index_tmp.replace(home / "session_index.jsonl")
    (home / "AGENTS.md").write_text("session-only instructions\n")
    (home / "plugins").mkdir(exist_ok=True)
    (home / "plugins/probe").touch()


class CodexOverlay(unittest.TestCase):
    def test_overlay_and_persistence(self):
        tools = {
            name: shutil.which(name)
            for name in ("guile", "git", "bash", "bwrap")
        }
        self.assertTrue(all(tools.values()), tools)
        source = Path(__file__).resolve().parents[5] / "src/guile"
        with tempfile.TemporaryDirectory(prefix="contained-codex-") as tmp:
            root = Path(tmp)
            home = root / "home"
            state = home / ".codex"
            state.mkdir(parents=True)
            config = state / "config.toml.new-api"
            config.write_text("# host config\n")
            (state / "config.toml").symlink_to(config.name)
            (state / "auth.json").write_text('{"OPENAI_API_KEY":"test-old"}')
            # A fresh independent DB has to import the existing session files.
            # An empty HOME misses the initialization work that failed in use.
            for number, directory in enumerate(
                ("sessions", "archived_sessions"), start=1
            ):
                thread_id = f"00000000-0000-4000-8000-{number:012d}"
                timestamp = "2026-01-27T12:34:56Z"
                rollout = (
                    state
                    / directory
                    / (f"rollout-2026-01-27T12-34-56-{thread_id}.jsonl")
                )
                rollout.parent.mkdir()
                rollout.write_text(
                    json.dumps(
                        {
                            "timestamp": timestamp,
                            "type": "session_meta",
                            "payload": {
                                "id": thread_id,
                                "timestamp": timestamp,
                                "cwd": str(home),
                                "originator": "cli",
                                "cli_version": "0.155.0",
                                "source": "cli",
                                "model_provider": "openai",
                            },
                        }
                    )
                    + "\n"
                )
            auth_inode = (state / "auth.json").stat().st_ino
            capture = root / "argv.json"
            shim = root / "guix"
            shim.write_text(
                f"#!{sys.executable}\nimport json, sys\n"
                f"json.dump(sys.argv[1:], open({str(capture)!r}, 'w'))\n"
            )
            shim.chmod(0o755)
            program = root / "probe"
            program.write_text(
                f"#!{sys.executable}\nimport runpy\n"
                f"runpy.run_path({str(Path(__file__).resolve())!r}, "
                "run_name='__main__')\n"
            )
            program.chmod(0o755)
            driver = root / "driver.scm"
            driver.write_text(
                "(use-modules (uraj bin contained-agent))\n"
                '(contained-agent-main \'("contained-agent" "codex" "--probe")\n'
                ' #:agents (list (cons "codex" (codex-spec '
                + json.dumps(str(program))
                + "))) #:common '() #:packages '() #:git "
                + json.dumps(tools["git"])
                + ")\n"
            )
            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith(("CODEX_", "OPENAI_", "PASEO_"))
            }
            if "CODEX_TEST_BINARY" in os.environ:
                env["CODEX_TEST_BINARY"] = os.environ["CODEX_TEST_BINARY"]
            env.update(
                HOME=str(home),
                CONTAINED_AGENT_PROJECTS=str(root / "no-projects"),
                GUIX_ENVIRONMENT=str(Path(tools["bash"]).parent.parent),
                PATH=str(root) + ":" + os.environ["PATH"],
            )
            for iteration in range(2):
                if iteration and env.get("CODEX_TEST_BINARY"):
                    # Simulate an interrupted worker whose lease has expired.
                    # Do this only to the test fixture, never the user's DB.
                    with sqlite3.connect(
                        state / "contained-sqlite/state_5.sqlite"
                    ) as db:
                        db.execute(
                            "update backfill_state set status='running', "
                            "updated_at=0, last_watermark=null"
                        )
                subprocess.run(
                    [
                        tools["guile"],
                        "--no-auto-compile",
                        "-L",
                        str(source),
                        str(driver),
                    ],
                    cwd=home,
                    env=env,
                    check=True,
                    timeout=15,
                )
                argv = json.loads(capture.read_text())
                mounts = []
                for arg in argv[: argv.index("--")]:
                    if arg.startswith(("--share=", "--expose=")):
                        option, path = arg.split("=", 1)
                        src, _, dest = path.partition("=")
                        mounts += [
                            "--bind" if option == "--share" else "--ro-bind",
                            src,
                            dest or src,
                        ]
                subprocess.run(
                    [
                        tools["bwrap"],
                        "--dev-bind",
                        "/",
                        "/",
                        "--tmpfs",
                        "/run",
                        *mounts,
                        "--",
                        *argv[argv.index("--") + 1 :],
                    ],
                    cwd=home,
                    env=env,
                    check=True,
                    timeout=40,
                )
                self.assertEqual(config.read_text(), "# host config\n")
                self.assertFalse((state / "AGENTS.md").exists())
                self.assertFalse((state / "plugins/probe").exists())
                self.assertFalse((state / "session_index.jsonl").exists())
                self.assertEqual(
                    (state / "auth.json").stat().st_ino, auth_inode
                )
            self.assertNotIn("test-old", (state / "auth.json").read_text())
            self.assertEqual(
                (state / "history.jsonl").read_text(), "retained\n" * 2
            )
            self.assertTrue((state / "thread-writer-locks/probe.lock").exists())
            self.assertTrue((state / "sessions/probe.jsonl").exists())
            with sqlite3.connect(state / "contained-sqlite/probe.sqlite") as db:
                self.assertEqual(
                    db.execute("select count(*) from visits").fetchone(), (2,)
                )
            self.assertEqual(list(state.glob("*.sqlite*")), [])


if __name__ == "__main__":
    if "--probe" in sys.argv:
        probe()
    else:
        unittest.main()
