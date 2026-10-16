"""Tests for application-independent configuration layers and atomic updates."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SOURCE = (
    Path(__file__).resolve().parents[4]
    / "src/python/uraj/config/json_config.py"
)
SPEC = importlib.util.spec_from_file_location("json_config", SOURCE)
CONFIG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIG)


class Layers(unittest.TestCase):
    def test_recursive_merge_replaces_arrays_and_preserves_null(self):
        base = {"a": {"keep": 1, "replace": [1]}, "scalar": 3}
        patch = {"a": {"replace": [2], "null": None}, "scalar": {"x": 2}}
        result = CONFIG.merge_objects(base, patch)
        self.assertEqual(
            result,
            {
                "a": {"keep": 1, "replace": [2], "null": None},
                "scalar": {"x": 2},
            },
        )
        result["a"]["replace"].append(3)
        self.assertEqual(base["a"]["replace"], [1])
        self.assertEqual(patch["a"]["replace"], [2])

    def test_delete_then_override_can_restore_in_higher_layer(self):
        base = {"a": {"old": 1, "keep": 2}}
        lower = CONFIG.apply_layer(base, {"delete": [["a", "old"]]})
        self.assertEqual(lower, {"a": {"keep": 2}})
        higher = CONFIG.apply_layer(lower, {"overrides": {"a": {"old": None}}})
        self.assertEqual(higher, {"a": {"keep": 2, "old": None}})
        self.assertEqual(base["a"]["old"], 1)

    def test_invalid_layer_is_rejected(self):
        for layer in (
            [],
            {"unknown": 1},
            {"overrides": []},
            {"delete": [[]]},
            {"delete": [[1]]},
        ):
            with self.subTest(layer=layer), self.assertRaises(ValueError):
                CONFIG.apply_layer({}, layer)

    def test_atomic_update_backup_idempotence_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text('{"untouched": 1}')
            CONFIG.update_file(path, lambda data: data.update(managed=2))
            before = path.read_bytes(), path.stat().st_mtime_ns
            CONFIG.update_file(path, lambda data: data.update(managed=2))
            self.assertEqual(
                before, (path.read_bytes(), path.stat().st_mtime_ns)
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            backup = path.with_name("settings.json.before-activation")
            self.assertEqual(json.loads(backup.read_text()), {"untouched": 1})

            def fail(data):
                data["managed"] = 9
                raise ValueError("invalid configuration")

            with self.assertRaises(ValueError):
                CONFIG.update_file(path, fail)
            self.assertEqual(
                before, (path.read_bytes(), path.stat().st_mtime_ns)
            )


if __name__ == "__main__":
    unittest.main()
