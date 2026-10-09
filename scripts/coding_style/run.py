#!/usr/bin/env python3
"""Check coding style, format files, or explicitly apply safe Ruff fixes."""

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

C_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh"}
CONFIGS = (".clang-format", "ruff.toml", "CPPLINT.cfg")


def git(root, *args):
    """Return raw Git output, preserving arbitrary filenames."""
    return subprocess.check_output(["git", "-C", str(root), *args])


def supported(name):
    """Select owned C/C++ and Python sources."""
    path = Path(name)
    return path.parts[0] != "vendor" and path.suffix in C_SUFFIXES | {".py"}


def run_tools(root, names, action):
    """Run requested tools; only the explicit fix action applies lint fixes."""
    failed = False
    for name in names:
        filename = "./" + name
        commands = []
        if Path(name).suffix == ".py":
            if action not in ("lint", "fix"):
                commands.append(
                    [
                        "ruff",
                        "format",
                        "--config",
                        str(root / "ruff.toml"),
                        "--no-cache",
                        *([] if action == "format" else ["--check"]),
                        filename,
                    ]
                )
            if action != "format":
                commands.append(
                    [
                        "ruff",
                        "check",
                        "--config",
                        str(root / "ruff.toml"),
                        "--fix" if action == "fix" else "--no-fix",
                        "--no-unsafe-fixes",
                        "--no-cache",
                        filename,
                    ]
                )
        else:
            if action != "lint":
                commands.append(
                    [
                        "clang-format",
                        "--style=file",
                        *(
                            ["-i"]
                            if action == "format"
                            else ["--dry-run", "--Werror"]
                        ),
                        filename,
                    ]
                )
            if action != "format":
                commands.append(["cpplint", filename])
        for command in commands:
            print("+ " + shlex.join(command), flush=True)
            if not shutil.which(command[0]):
                print(
                    f"Missing tool: {command[0]}.\n"
                    "Reconfigure basic-dev, or run:\n"
                    "  guix shell python clang cpplint ruff",
                    file=sys.stderr,
                )
                failed = True
                continue
            result = subprocess.run(command, cwd=root, check=False)
            failed = bool(result.returncode) or failed
    return failed


def main():
    """Check tracked files, explicit paths, or a read-only index snapshot."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "lint", "format", "fix"))
    parser.add_argument(
        "--staged",
        action="store_true",
        help="check changed index versions in a temporary tree",
    )
    parser.add_argument(
        "files", nargs="*", help="paths relative to current directory"
    )
    args = parser.parse_args()
    if args.staged and (args.action in ("format", "fix") or args.files):
        parser.error("--staged supports only check/lint without explicit paths")
    root = Path(
        os.fsdecode(git(Path.cwd(), "rev-parse", "--show-toplevel")).strip()
    )
    if args.files:
        names = []
        for filename in args.files:
            path = Path(filename).absolute()
            if path.is_symlink() or not path.is_file():
                parser.error(f"expected a regular source file: {filename}")
            try:
                name = str(path.resolve().relative_to(root))
            except ValueError:
                parser.error(f"file outside repository: {filename}")
            if not supported(name):
                parser.error(f"unsupported or vendor file: {filename}")
            if args.action == "fix" and path.suffix != ".py":
                parser.error(
                    f"Ruff fixes only support Python files: {filename}"
                )
            names.append(name)
    else:
        command = (
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=ACMR",
            "-z",
        )
        if not args.staged:
            command = ("ls-files", "-z")
        names = [
            os.fsdecode(name)
            for name in git(root, *command).split(b"\0")
            if name and supported(os.fsdecode(name))
        ]
    if args.action == "fix":
        names = [name for name in names if Path(name).suffix == ".py"]
    if not names:
        return 0
    if args.staged:
        with tempfile.TemporaryDirectory(prefix="uraj-style-") as directory:
            snapshot = Path(directory)
            git(root, "checkout-index", "--all", "--prefix=" + directory + "/")
            # Bootstrap newly added style configuration before its first commit.
            for config in CONFIGS:
                if not (snapshot / config).exists():
                    shutil.copyfile(root / config, snapshot / config)
            names = [
                name
                for name in names
                if (snapshot / name).is_file()
                and not (snapshot / name).is_symlink()
            ]
            failed = run_tools(snapshot, names, args.action)
    else:
        names = [
            name
            for name in names
            if (root / name).is_file() and not (root / name).is_symlink()
        ]
        failed = run_tools(root, names, args.action)
    if failed:
        if args.action == "fix":
            print(
                "\nSome Ruff fixes may have been applied. Review git diff; "
                "remaining diagnostics need manual fixes. No git add was run.",
                file=sys.stderr,
            )
        else:
            print(
                "\nCoding style failed. No lint fixes or git add were run.",
                file=sys.stderr,
            )
        print(
            "From the repository root:\n"
            "  scripts/coding_style/fix <file.py> ... # safe Ruff fixes\n"
            "  scripts/coding_style/format <file> ...  # explicitly format\n"
            "  scripts/coding_style/lint <file> ...    # fix manually\n"
            "  git add -p                            # review and restage\n"
            "  scripts/coding_style/check --staged\n"
            "For partially staged files, review unstaged edits "
            "before formatting or fixing.",
            file=sys.stderr,
        )
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Coding style check failed: {error}", file=sys.stderr)
        sys.exit(1)
