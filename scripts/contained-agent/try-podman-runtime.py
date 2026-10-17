#!/usr/bin/env python3
"""Run the disposable host-side Podman runtime experiment."""

import runpy
from pathlib import Path

MODULE = (
    Path(__file__).resolve().parents[2] / "src/python/uraj/contained_podman.py"
)
_namespace = runpy.run_path(str(MODULE))
nested_seccomp = _namespace["nested_seccomp"]
_CLEANUP_STORAGE = _namespace["_CLEANUP_STORAGE"]
if __name__ == "__main__":
    raise SystemExit(_namespace["main"]())
