"""Regression checks for the experimental seccomp profile transformation."""

import copy
import runpy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
NESTED_SECCOMP = runpy.run_path(
    str(ROOT / "src/python/uraj/contained_podman.py")
)["nested_seccomp"]


class Profile(unittest.TestCase):
    def test_preserves_unrelated_filters_and_architectures(self):
        profile = {
            "defaultAction": "SCMP_ACT_ERRNO",
            "defaultErrnoRet": 1,
            "archMap": [{"architecture": "SCMP_ARCH_X86_64"}],
            "syscalls": [
                {"names": ["read", "write"], "action": "SCMP_ACT_ALLOW"},
                {
                    "names": ["clone3"],
                    "action": "SCMP_ACT_ERRNO",
                    "errnoRet": 38,
                },
                {
                    "names": ["mount", "bpf"],
                    "action": "SCMP_ACT_ALLOW",
                    "includes": {"caps": ["CAP_SYS_ADMIN"]},
                },
                {"names": ["sethostname"], "action": "SCMP_ACT_ERRNO"},
            ],
        }
        original = copy.deepcopy(profile)
        result = NESTED_SECCOMP(profile)
        self.assertEqual(profile, original)
        for key in ("defaultAction", "defaultErrnoRet", "archMap"):
            self.assertEqual(result[key], profile[key])
        self.assertIn(profile["syscalls"][0], result["syscalls"])
        self.assertIn(profile["syscalls"][1], result["syscalls"])
        self.assertIn(
            {
                "names": ["bpf"],
                "action": "SCMP_ACT_ALLOW",
                "includes": {"caps": ["CAP_SYS_ADMIN"]},
            },
            result["syscalls"],
        )
        hostname_rules = [
            rule
            for rule in result["syscalls"]
            if "sethostname" in rule["names"]
        ]
        self.assertEqual(len(hostname_rules), 1)
        self.assertEqual(hostname_rules[0]["action"], "SCMP_ACT_ALLOW")
        self.assertNotIn("includes", hostname_rules[0])

    def test_rejects_allow_by_default(self):
        with self.assertRaises(RuntimeError):
            NESTED_SECCOMP({"defaultAction": "SCMP_ACT_ALLOW", "syscalls": []})

    def test_idempotent(self):
        profile = {"defaultAction": "SCMP_ACT_ERRNO", "syscalls": []}
        once = NESTED_SECCOMP(profile)
        self.assertEqual(NESTED_SECCOMP(once), once)


if __name__ == "__main__":
    unittest.main()
