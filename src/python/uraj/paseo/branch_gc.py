"""Conservative local branch GC; no worktree, remote, or archive deletion."""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def git(repo, *args):
    return (
        subprocess.check_output(
            ["git", "-C", str(repo), *args], stderr=subprocess.PIPE, timeout=10
        )
        .decode("utf-8", "surrogateescape")
        .strip()
    )


def ancestor(repo, tip, base):
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", tip, base],
        capture_output=True,
        timeout=10,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise ValueError("Cannot verify Git ancestry")
    return result.returncode == 0


def worktrees(repo):
    records = []
    raw = git(repo, "worktree", "list", "--porcelain", "-z")
    for block in raw.split("\0\0"):
        record = dict(
            field.split(" ", 1) if " " in field else (field, "")
            for field in block.split("\0")
            if field
        )
        if record:
            records.append(record)
    if not records or "worktree" not in records[0]:
        raise ValueError("Cannot identify main worktree")
    return records


def inventory(registry):
    raw = registry.read_bytes()
    records = json.loads(raw)
    if not isinstance(records, list):
        raise ValueError("Unsupported Paseo workspace registry")
    for record in records:
        if not isinstance(record, dict) or any(
            key not in record
            for key in ("workspaceId", "cwd", "branch", "archivedAt")
        ):
            raise ValueError("Incomplete Paseo workspace registry")
        if not isinstance(record["cwd"], str):
            raise ValueError("Invalid workspace cwd")
        if record["archivedAt"] is not None and not isinstance(
            record["archivedAt"], str
        ):
            raise ValueError("Invalid archive status")
    return raw, records


def candidates(repo, records):
    """Only branches with explicit Paseo ownership and no active references."""
    owned = set()
    active = set()
    for record in records:
        branch = record["branch"]
        if not branch:
            # Missing branch identity on an active worktree is ambiguous.
            if not record["archivedAt"] and record.get("kind") == "worktree":
                raise ValueError("Active worktree has no branch identity")
            continue
        if not isinstance(branch, str):
            raise ValueError("Invalid workspace branch")
        # Conservatively protect active branch names across projects too.
        if not record["archivedAt"]:
            active.add(branch)
        if (
            record.get("kind") == "worktree"
            and record.get("isPaseoOwnedWorktree") is True
            and record.get("mainRepoRoot")
            and Path(record["mainRepoRoot"]).resolve() == repo
        ):
            owned.add(branch)
    return owned - active


def merged_prs(repo, base):
    """Unavailable API/auth is absence of proof, not permission to delete."""
    try:
        origin = git(repo, "remote", "get-url", "origin")
        match = re.fullmatch(
            r"(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?",
            origin,
        )
        if not match:
            return []
        raw = subprocess.check_output(
            [
                "gh",
                "pr",
                "list",
                "--repo",
                match[1],
                "--state",
                "merged",
                "--base",
                base,
                "--limit",
                "1000",
                "--json",
                "headRefName,headRefOid,mergeCommit,baseRefName,isCrossRepository",
            ],
            cwd=repo,
            stderr=subprocess.PIPE,
            timeout=20,
        )
        records = json.loads(raw)
        if not isinstance(records, list):
            return []
        return records
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


def clean(args):
    tree_list = worktrees(args.path)
    repo = Path(tree_list[0]["worktree"]).resolve()
    if "bare" in tree_list[0] or not repo.is_dir():
        raise ValueError("Main worktree unavailable")
    common = Path(
        git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    )
    # Serialize manual and broker GC invocations for the same repository.
    with (common / "paseo-branch-gc.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        raw, records = inventory(args.registry)
        names = candidates(repo, records)
        base_ref = "refs/heads/" + args.base
        base_oid = git(repo, "rev-parse", "--verify", base_ref + "^{commit}")
        branches = dict(
            line.split(" ", 1)
            for line in git(
                repo,
                "for-each-ref",
                "--format=%(refname:short) %(objectname)",
                "refs/heads",
            ).splitlines()
        )
        prs = None
        for name in sorted(names & branches.keys()):
            if name == args.base or name.startswith("backup/"):
                continue
            ref = "refs/heads/" + name
            if any(w.get("branch") == ref for w in worktrees(repo)):
                continue
            tip = branches[name]
            reason = "ancestor"
            if not ancestor(repo, tip, base_oid):
                if prs is None:
                    prs = merged_prs(repo, args.base)
                proof = next(
                    (
                        p
                        for p in prs
                        if isinstance(p, dict)
                        and p.get("headRefName") == name
                        and p.get("headRefOid") == tip
                        and p.get("baseRefName") == args.base
                        and p.get("isCrossRepository") is False
                        and isinstance(p.get("mergeCommit"), dict)
                        and p["mergeCommit"].get("oid")
                        and ancestor(repo, p["mergeCommit"]["oid"], base_oid)
                    ),
                    None,
                )
                if proof is None:
                    continue
                reason = "merged-pr"
            if args.apply:
                # Abort on any changed registry snapshot. CAS below also rejects
                # a moved branch; never delete a ref whose tip was not verified.
                if args.registry.read_bytes() != raw:
                    raise ValueError("Workspace registry changed; stopping GC")
                if git(repo, "rev-parse", base_ref) != base_oid:
                    raise ValueError("Integration branch changed; stopping GC")
                if any(w.get("branch") == ref for w in worktrees(repo)):
                    continue
                git(repo, "update-ref", "--no-deref", "-d", ref, tip)
            print(
                json.dumps(
                    {
                        "repository": str(repo),
                        "branch": name,
                        "tip": tip,
                        "reason": reason,
                        "action": "deleted" if args.apply else "candidate",
                    }
                )
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path, default=Path.cwd())
    parser.add_argument("--base", default="main")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--registry",
        type=Path,
        default=Path(os.environ.get("PASEO_HOME", str(Path.home() / ".paseo")))
        / "projects/workspaces.json",
    )
    args = parser.parse_args()
    try:
        clean(args)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"paseo-branch-gc: skipped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
