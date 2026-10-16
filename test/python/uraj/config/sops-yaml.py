"""SOPS structured YAML extraction and per-host recipient separation."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[4]


class SopsYaml(unittest.TestCase):
    def test_repository_files_use_only_their_host_and_administrators(self):
        policy = yaml.safe_load((ROOT / ".sops.yaml").read_text())
        recipients = {}
        for rule in policy["creation_rules"][:3]:
            hostname = rule["path_regex"].split("/")[2]
            recipients[hostname] = rule
        for hostname in ("lappie", "hypie", "storie"):
            path = ROOT / "secrets/hosts" / hostname / "paseo-config.yaml"
            document = yaml.safe_load(path.read_text())
            metadata = document["sops"]
            self.assertEqual(
                [key["recipient"] for key in metadata["age"]],
                [recipients[hostname]["age"]],
            )
            expected = {
                key.strip().rstrip("!")
                for key in recipients[hostname]["pgp"].split(",")
            }
            self.assertEqual(
                {key["fp"].rstrip("!") for key in metadata["pgp"]}, expected
            )
            self.assertTrue(
                document["paseo"]["config.yaml"]["hostname"].startswith("ENC[")
            )

    @unittest.skipUnless(
        shutil.which("age-keygen") and shutil.which("sops"),
        "requires age-keygen and sops",
    )
    def test_extract_structured_yaml_with_disposable_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / "age.txt"
            subprocess.run(
                ["age-keygen", "-o", str(identity)],
                check=True,
                capture_output=True,
            )
            recipient = subprocess.check_output(
                ["age-keygen", "-y", str(identity)], text=True
            ).strip()
            policy = root / "sops.yaml"
            policy.write_text(f"creation_rules:\n  - age: {recipient}\n")
            plaintext = {
                "hostname": "test-host",
                "overrides": {
                    "agents": {
                        "providers": {"codex": {"env": {"TEST": "secret"}}}
                    }
                },
            }
            encrypted = root / "config.yaml"
            encryption = subprocess.run(
                [
                    "sops",
                    "--config",
                    str(policy),
                    "encrypt",
                    "--filename-override",
                    str(encrypted),
                    "--input-type",
                    "json",
                    "--output-type",
                    "yaml",
                    "--output",
                    str(encrypted),
                    "/dev/stdin",
                ],
                input=json.dumps({"paseo": {"config.yaml": plaintext}}),
                text=True,
                check=False,
                capture_output=True,
            )
            self.assertEqual(encryption.returncode, 0, encryption.stderr)
            environment = dict(os.environ, SOPS_AGE_KEY_FILE=str(identity))
            decrypted = subprocess.check_output(
                [
                    "sops",
                    "decrypt",
                    "--extract",
                    '["paseo"]["config.yaml"]',
                    "--output-type",
                    "yaml",
                    str(encrypted),
                ],
                env=environment,
                text=True,
            )
            self.assertEqual(yaml.safe_load(decrypted), plaintext)


if __name__ == "__main__":
    unittest.main()
