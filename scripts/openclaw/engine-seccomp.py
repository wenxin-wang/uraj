#!/usr/bin/env python3
"""Write the OpenClaw engine's seccomp profile from its image's base profile.

Usage: engine-seccomp.py [IMAGE] > env/docker/openclaw-sandbox-engine/seccomp.json

With IMAGE, read /usr/share/containers/seccomp.json from that local Docker
image; otherwise read the base profile from standard input.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "container_seccomp", ROOT / "src/python/uraj/container/seccomp.py"
)
_SECCOMP = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_SECCOMP)


def main(argv):
    if len(argv) > 2:
        sys.exit(__doc__)
    if len(argv) == 2:
        source = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--network=none",
                "--entrypoint=/bin/cat",
                argv[1],
                "/usr/share/containers/seccomp.json",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    else:
        source = sys.stdin.read()
    profile = _SECCOMP.nested_seccomp(json.loads(source))
    sys.stdout.write(json.dumps(profile, indent=2) + "\n")


if __name__ == "__main__":
    main(sys.argv)
