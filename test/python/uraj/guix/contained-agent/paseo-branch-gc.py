"""Real Git branch-GC tests; no network, real providers or user repositories."""

import argparse
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[5]
SPEC = importlib.util.spec_from_file_location(
    "branch_gc", ROOT / "src/python/uraj/paseo/branch_gc.py"
)
gc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gc)


class BranchGC(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "file").write_text("initial\n")
        self.git("add", "file")
        self.git("commit", "-m", "initial")
        self.git("branch", "done")
        self.registry = self.root / "workspaces.json"
        self.records = [
            {
                "workspaceId": "test",
                "kind": "worktree",
                "cwd": str(self.root / "removed"),
                "branch": "done",
                "archivedAt": "2026-10-21T00:00:00Z",
                "isPaseoOwnedWorktree": True,
                "mainRepoRoot": str(self.repo),
            }
        ]
        self.save()
        self.args = argparse.Namespace(
            path=self.repo, registry=self.registry, base="main", apply=True
        )
        patcher = mock.patch.object(gc, "merged_prs", return_value=[])
        self.prs = patcher.start()
        self.addCleanup(patcher.stop)

    def git(self, *args):
        return gc.git(self.repo, *args)

    def save(self):
        self.registry.write_text(json.dumps(self.records))

    def exists(self, name="done"):
        return bool(
            self.git(
                "for-each-ref", "--format=%(refname)", "refs/heads/" + name
            )
        )

    def test_deletes_archived_merged_branch_without_age_requirement(self):
        gc.clean(self.args)
        self.assertFalse(self.exists())
        self.assertTrue(self.exists("main"))

    def test_dry_run(self):
        self.args.apply = False
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_active_reference_even_in_another_workspace_blocks(self):
        self.records.append(
            {**self.records[0], "workspaceId": "active", "archivedAt": None}
        )
        self.save()
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_unknown_ownership_blocks(self):
        self.records[0].pop("isPaseoOwnedWorktree")
        self.save()
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_checked_out_branch_and_main_resolution(self):
        linked = self.root / "linked"
        self.git("worktree", "add", str(linked), "done")
        self.args.path = linked
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_missing_worktree_registration_still_blocks(self):
        linked = self.root / "linked"
        self.git("worktree", "add", str(linked), "done")
        (linked / "file").unlink()
        (linked / ".git").unlink()
        linked.rmdir()
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_missing_or_bad_registry_fails_closed(self):
        for content in ("{}", "[{}]", "invalid"):
            self.registry.write_text(content)
            with self.assertRaises(ValueError):
                gc.clean(self.args)
            self.assertTrue(self.exists())
        self.registry.unlink()
        with self.assertRaises(OSError):
            gc.clean(self.args)

    def make_squash(self):
        self.git("checkout", "done")
        (self.repo / "file").write_text("feature\n")
        self.git("commit", "-am", "feature")
        tip = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        self.git("merge", "--squash", "done")
        self.git("commit", "-m", "squash")
        merged = self.git("rev-parse", "HEAD")
        return {
            "headRefName": "done",
            "headRefOid": tip,
            "mergeCommit": {"oid": merged},
            "baseRefName": "main",
            "isCrossRepository": False,
        }

    def test_exact_squash_pr_proof(self):
        self.prs.return_value = [self.make_squash()]
        gc.clean(self.args)
        self.assertFalse(self.exists())

    def test_squash_without_api_proof_is_retained(self):
        self.make_squash()
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_extra_commit_after_pr_is_retained(self):
        self.prs.return_value = [self.make_squash()]
        self.git("checkout", "done")
        self.git("commit", "--allow-empty", "-m", "later work")
        self.git("checkout", "main")
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_merge_commit_not_in_main_is_retained(self):
        proof = self.make_squash()
        self.git("reset", "--hard", "HEAD~1")
        self.prs.return_value = [proof]
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_cross_repository_pr_is_not_proof(self):
        proof = self.make_squash()
        proof["isCrossRepository"] = True
        self.prs.return_value = [proof]
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_backup_branch_is_protected(self):
        self.git("branch", "-m", "done", "backup/done")
        self.records[0]["branch"] = "backup/done"
        self.save()
        gc.clean(self.args)
        self.assertTrue(self.exists("backup/done"))

    def test_another_project_cannot_authorize_deletion(self):
        self.records[0]["mainRepoRoot"] = str(self.root / "another")
        self.save()
        gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_registry_change_aborts(self):
        original = gc.ancestor

        def changed(*args):
            result = original(*args)
            self.registry.write_text("[]")
            return result

        with mock.patch.object(gc, "ancestor", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "registry changed"):
                gc.clean(self.args)
        self.assertTrue(self.exists())

    def test_tip_change_is_rejected_by_compare_and_delete(self):
        original = gc.git

        def changed(repo, *args):
            if args[0] == "update-ref":
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(repo),
                        "commit",
                        "--allow-empty",
                        "-m",
                        "concurrent",
                    ],
                    check=True,
                    capture_output=True,
                )
                original(repo, "branch", "-f", "done", "main")
            return original(repo, *args)

        with mock.patch.object(gc, "git", side_effect=changed):
            with self.assertRaises(subprocess.CalledProcessError):
                gc.clean(self.args)
        self.assertTrue(self.exists())


class BrokerGC(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "broker_gc_test", ROOT / "src/python/uraj/paseo/broker.py"
        )
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.server = self.module.BrokerServer.__new__(self.module.BrokerServer)
        self.server.args = argparse.Namespace(branch_gc="/gc")
        self.server.home = Path("/home/test")
        self.server.stopping = False
        self.server.clients = {}
        self.server.branch_gc_jobs = []
        self.server.branch_gc_pending = set()
        self.job = {
            "request": (
                "codex",
                ["run"],
                Path("/repo/linked"),
                {},
                None,
                "daily",
            )
        }

    def test_exit_queues_gc_until_other_clients_finish(self):
        self.server.clients["other"] = {}
        with mock.patch.object(self.module.subprocess, "Popen") as spawn:
            self.server.start_branch_gc(self.job)
            spawn.assert_not_called()
            self.server.clients.clear()
            self.server.poll_branch_gc()
            self.assertEqual(
                spawn.call_args.args[0], ["/gc", "--apply", "/repo/linked"]
            )
            self.assertEqual(len(self.server.branch_gc_jobs), 1)

    def test_spawn_failure_is_nonfatal(self):
        with mock.patch.object(
            self.module.subprocess, "Popen", side_effect=OSError("missing")
        ):
            self.server.start_branch_gc(self.job)
        self.assertFalse(self.server.branch_gc_jobs)

    def test_timeout_kills_and_reaps_helper(self):
        process = mock.Mock(pid=123, returncode=None)
        process.poll.return_value = None
        self.server.branch_gc_jobs = [(process, 0)]
        with mock.patch.object(self.module.os, "killpg") as kill:
            self.server.poll_branch_gc()
            kill.assert_called_once_with(123, self.module.signal.SIGKILL)
        process.wait.assert_called_once()
        self.assertFalse(self.server.branch_gc_jobs)

    def test_probe_does_not_trigger_gc(self):
        self.job["request"] = (
            "codex",
            ["--version"],
            Path("/repo"),
            {},
            None,
            "daily",
        )
        with mock.patch.object(self.module.subprocess, "Popen") as spawn:
            self.server.start_branch_gc(self.job)
            spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
