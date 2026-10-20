"""Bridge system Home activation and dependent user Shepherd services."""

import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
SYSTEM = Path("/run/current-system")


def identity(home_environment):
    """Identify a successful activation without trusting previous boots."""
    return {
        "boot": BOOT_ID.read_text().strip(),
        "system": str(SYSTEM.resolve(strict=True)),
        "home": str(home_environment.resolve(strict=True)),
    }


def state_file(home):
    return home / ".local/state/uraj/home-activation.json"


def publish(path, state):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(state, output)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def activate(home, home_environment):
    """Publish success only after the complete Home activation exits zero."""
    path = state_file(home)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = identity(home_environment)
    publish(path, dict(state, status="activating"))
    environment = dict(os.environ, HOME_ENVIRONMENT=str(home_environment))
    try:
        result = subprocess.run(
            [str(home_environment / "activate")],
            env=environment,
            check=False,
        )
    except BaseException:
        publish(path, dict(state, status="failed"))
        raise
    publish(
        path,
        dict(state, status="ready" if result.returncode == 0 else "failed"),
    )
    return result.returncode if result.returncode >= 0 else 1


def wait(home, timeout=120):
    """Wait for this boot and the currently selected system/Home generation."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            expected = identity(home / ".guix-home")
            state = json.loads(state_file(home).read_text())
            if all(state.get(key) == value for key, value in expected.items()):
                if state.get("status") == "ready":
                    return
                if state.get("status") == "failed":
                    raise RuntimeError("System Home activation failed")
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if time.monotonic() >= deadline:
            raise TimeoutError(
                "Home activation is not ready; inspect system "
                "guix-home service, then retry the user home-ready service"
            )
        time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("activate", "wait"))
    parser.add_argument("home_environment", nargs="?", type=Path)
    args = parser.parse_args()
    if args.action == "activate":
        if args.home_environment is None:
            parser.error("activate requires a Home generation")
        raise SystemExit(activate(Path.home(), args.home_environment))
    wait(Path.home())


if __name__ == "__main__":
    main()
