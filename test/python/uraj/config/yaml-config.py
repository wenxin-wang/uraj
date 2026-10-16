"""Host selection, YAML reuse and safe conversion into JSON values."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SOURCE = (
    Path(__file__).resolve().parents[4]
    / "src/python/uraj/config/yaml_config.py"
)
SPEC = importlib.util.spec_from_file_location("yaml_config", SOURCE)
CONFIG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIG)


class HostLayers(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "config.yaml"

    def test_anchors_and_merge_keys_select_only_requested_host(self):
        self.path.write_text("""templates:
  base: &base
    overrides: {nested: {common: 1}}
    delete: []
hosts:
  one: *base
  two:
    <<: *base
    delete: [[obsolete]]
""")
        one = CONFIG.public_layer(self.path, "one")
        two = CONFIG.public_layer(self.path, "two")
        self.assertEqual(one["overrides"], two["overrides"])
        self.assertEqual(one["delete"], [])
        self.assertEqual(two["delete"], [["obsolete"]])
        with self.assertRaisesRegex(ValueError, "no host entry"):
            CONFIG.public_layer(self.path, "unknown")

    def test_private_hostname_is_required_and_not_part_of_override(self):
        self.path.write_text("hostname: one\noverrides: {value: null}\n")
        self.assertEqual(
            CONFIG.private_layer(self.path, "one"),
            {"overrides": {"value": None}},
        )
        with self.assertRaises(ValueError):
            CONFIG.private_layer(self.path, "two")

    def test_rejects_executable_tags_cycles_and_non_json_values(self):
        for text in (
            "x: !!python/object/apply:os.system ['false']",
            "x: &recursive {again: *recursive}",
            "x: 2026-10-15",
            "x: .nan",
            "1: value",
            "[]",
        ):
            with self.subTest(text=text):
                self.path.write_text(text)
                with self.assertRaises(ValueError):
                    CONFIG.read_yaml(self.path)

    def test_parse_errors_do_not_echo_private_values(self):
        self.path.write_text("x: [very-private-value")
        with self.assertRaises(ValueError) as result:
            CONFIG.read_yaml(self.path)
        self.assertNotIn("very-private-value", str(result.exception))


if __name__ == "__main__":
    unittest.main()
