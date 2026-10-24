"""Seccomp profiles for engines that run nested rootless containers."""

# Calls that a nested rootless engine needs without CAP_SYS_ADMIN in the
# outer container.  Kernel namespace and capability checks still apply.
NESTED_SYSCALLS = frozenset(
    {
        "clone",
        "mount",
        "umount",
        "umount2",
        "pivot_root",
        "setns",
        "unshare",
        "sethostname",
        "setdomainname",
    }
)


def nested_seccomp(profile):
    """Allow namespace setup while retaining the base syscall allowlist."""
    if profile.get("defaultAction") != "SCMP_ACT_ERRNO":
        raise RuntimeError(
            "Unexpected seccomp default action; refusing to weaken it"
        )
    # Remove conditional/denial rules for these calls before adding the
    # unconditional allow.
    rules = []
    for rule in profile["syscalls"]:
        names = [name for name in rule["names"] if name not in NESTED_SYSCALLS]
        if names:
            rules.append({**rule, "names": names})
    rules.append({"names": sorted(NESTED_SYSCALLS), "action": "SCMP_ACT_ALLOW"})
    return {**profile, "syscalls": rules}
