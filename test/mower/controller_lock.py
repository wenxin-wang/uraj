"""Exercise the real entrypoint against a competing host controller lock."""

import fcntl
import os
import pathlib
import subprocess
import tempfile
import time


def main():
    entrypoint = (
        pathlib.Path(__file__).resolve().parents[2] / "env/mower/entrypoint"
    )
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        marker = root / "started"
        # Substitute only the final worker, retaining the entrypoint and flock.
        worker = root / "python"
        worker.write_text('#!/bin/sh\ntouch "$START_MARKER"\nexec sleep 30\n')
        worker.chmod(0o700)
        env = dict(
            os.environ,
            PATH=f"{root}:{os.environ['PATH']}",
            MOWER_DATA_DIR=str(root / "data"),
            MOWER_CONTROLLER_LOCK=str(root / "controller.lock"),
            START_MARKER=str(marker),
        )
        with open(env["MOWER_CONTROLLER_LOCK"], "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(
                ["sh", str(entrypoint)], env=env, check=False, timeout=5
            )
            assert result.returncode == 75
            assert not marker.exists(), "Busy device must not start a worker"
            fcntl.flock(lock, fcntl.LOCK_UN)
            process = subprocess.Popen(["sh", str(entrypoint)], env=env)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    assert process.poll() is None
                    time.sleep(0.01)
                assert marker.exists(), "Worker did not start"
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("Worker lost its lock across exec")
            finally:
                process.terminate()
                process.wait(timeout=5)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("Controller exclusion and release passed")


if __name__ == "__main__":
    main()
