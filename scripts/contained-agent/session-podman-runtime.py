#!/usr/bin/env python3
"""Run a contained-agent session with its project's shared Podman runtime."""

import runpy
from pathlib import Path

MODULE = (
    Path(__file__).resolve().parents[2] / "src/python/uraj/contained_podman.py"
)
if __name__ == "__main__":
    raise SystemExit(runpy.run_path(str(MODULE))["session_main"]())
