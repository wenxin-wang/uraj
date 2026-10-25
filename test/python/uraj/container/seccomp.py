"""Regression checks for the nested-engine seccomp transformation."""

import copy
import importlib.util
import unittest
from pathlib import Path

SOURCE = (
    Path(__file__).resolve().parents[4] / "src/python/uraj/container/seccomp.py"
)
SPEC = importlib.util.spec_from_file_location("container_seccomp", SOURCE)
SECCOMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SECCOMP)


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
                {
                    "names": ["chroot"],
                    "action": "SCMP_ACT_ALLOW",
                    "includes": {"caps": ["CAP_SYS_CHROOT"]},
                },
            ],
        }
        original = copy.deepcopy(profile)
        result = SECCOMP.nested_seccomp(profile)
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
        for name in ("sethostname", "chroot"):
            rules = [
                rule for rule in result["syscalls"] if name in rule["names"]
            ]
            self.assertEqual(len(rules), 1)
            self.assertEqual(rules[0]["action"], "SCMP_ACT_ALLOW")
            self.assertNotIn("includes", rules[0])

    def test_rejects_allow_by_default(self):
        with self.assertRaises(RuntimeError):
            SECCOMP.nested_seccomp(
                {"defaultAction": "SCMP_ACT_ALLOW", "syscalls": []}
            )

    def test_idempotent(self):
        profile = {"defaultAction": "SCMP_ACT_ERRNO", "syscalls": []}
        once = SECCOMP.nested_seccomp(profile)
        self.assertEqual(SECCOMP.nested_seccomp(once), once)


if __name__ == "__main__":
    unittest.main()
