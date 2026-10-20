"""Exercise the scheduled wrapper without connecting to the game."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "env/maa/run-daily.py"


def callback(items, done=True):
    return "[INFO] Depot: " + json.dumps(
        {
            "taskchain": "Depot",
            "what": "DepotInfo",
            "details": {"done": done, "data": json.dumps(items)},
        },
        indent=2,
    )


class DepotTest(unittest.TestCase):
    def run_wrapper(self, destination, output, status=0):
        return subprocess.run(
            [
                sys.executable,
                str(WRAPPER),
                str(destination),
                sys.executable,
                "-c",
                f"import sys; print({output!r}); sys.exit({status})",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_success_replaces_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "state/depot.json"
            for items in ({"4001": 123, "3003": 5}, {"4001": 456}):
                output = (
                    callback({"4001": 1}, done=False)
                    + "\n"
                    + callback(items)
                    + "\n[INFO] Depot Completed\n[INFO] CloseDown Completed"
                )
                result = self.run_wrapper(destination, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = json.loads(destination.read_text())
                self.assertEqual(snapshot["items"], items)
                self.assertTrue(snapshot["updated_at"].endswith("+00:00"))
                self.assertIn("CloseDown Completed", result.stdout)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_failure_preserves_previous_snapshot(self):
        good = callback({"4001": 123}) + "\n[INFO] Depot Completed"
        cases = [
            ("API update failed", 1),
            (good, 1),
            (callback({"4001": 123}), 0),
            (callback({"4001": 123}, done=False), 0),
            ('[INFO] Depot: {"details":', 0),
            (callback({}) + "\n[INFO] Depot Completed", 0),
            (callback({"4001": -1}) + "\n[INFO] Depot Completed", 0),
            (callback({"4001": True}) + "\n[INFO] Depot Completed", 0),
        ]
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "depot.json"
            destination.write_text("previous snapshot\n")
            for output, status in cases:
                with self.subTest(output=output, status=status):
                    result = self.run_wrapper(destination, output, status)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(
                        destination.read_text(), "previous snapshot\n"
                    )


if __name__ == "__main__":
    unittest.main()
