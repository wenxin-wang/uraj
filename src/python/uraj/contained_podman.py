#!/usr/bin/env python3
"""Manage isolated project runtimes and run host-side Podman validation."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pwd
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Run only inside the disposable engine's user/mount namespace. Podman's
# rootless network setup can leave run/netns mounted after its last container
# exits, and the overlay driver bind-mounts its graphroot/overlay home onto
# itself. Removing either without unmounting it fails with EBUSY.
_CLEANUP_STORAGE = """
import ctypes
import errno
import os
import re
import shutil
import sys

roots = [os.path.realpath(path) for path in sys.argv[1:]]
libc = ctypes.CDLL(None, use_errno=True)


def mounted():
    # ismount misses same-filesystem bind mounts; mountinfo lists them all.
    with open("/proc/self/mountinfo") as table:
        points = {
            re.sub(r"\\\\([0-7]{3})", lambda m: chr(int(m[1], 8)),
                   line.split()[4])
            for line in table
        }
    return sorted(
        (
            point
            for point in points
            for root in roots
            if point == root or point.startswith(root.rstrip("/") + "/")
        ),
        key=len,
        reverse=True,
    )


# Deepest first; repeat for stacked mounts.
for _ in range(32):
    points = mounted()
    if not points:
        break
    for point in points:
        if libc.umount2(os.fsencode(point), 2):  # MNT_DETACH
            error = ctypes.get_errno()
            if error not in (errno.EINVAL, errno.ENOENT):
                raise OSError(error, os.strerror(error), point)
else:
    raise RuntimeError("Too many stacked mounts under " + ", ".join(roots))
for path in sys.argv[2:]:
    if os.path.lexists(path):
        shutil.rmtree(path)
"""


def nested_seccomp(profile):
    """Allow namespace setup while retaining the base syscall allowlist."""
    allowed = {
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
    if profile.get("defaultAction") != "SCMP_ACT_ERRNO":
        raise RuntimeError(
            "Unexpected seccomp default action; refusing to weaken it"
        )
    # Remove conditional/denial rules for these calls before adding the
    # unconditional allow. Kernel namespace/capability checks still apply.
    rules = []
    for rule in profile["syscalls"]:
        names = [name for name in rule["names"] if name not in allowed]
        if names:
            rules.append({**rule, "names": names})
    rules.append({"names": sorted(allowed), "action": "SCMP_ACT_ALLOW"})
    return {**profile, "syscalls": rules}


def host_cgroup_info():
    """Read delegation prerequisites without creating or modifying cgroups."""
    root = Path("/sys/fs/cgroup")
    result = {
        "uid": os.getuid(),
        "user": pwd.getpwuid(os.getuid()).pw_name,
        "gid": os.getgid(),
        "groups": os.getgroups(),
    }
    membership = Path("/proc/self/cgroup").read_text()
    result["membership"] = membership
    result["mounts"] = [
        line
        for line in Path("/proc/self/mountinfo").read_text().splitlines()
        if " - cgroup2 " in line
    ]
    directories = [root]
    for line in membership.splitlines():
        if line.startswith("0::"):
            relative = line[3:].lstrip("/")
            # A cgroup namespace may show a path outside its visible root.
            # Report it above but never follow '..' for this diagnostic.
            if ".." not in Path(relative).parts:
                current = root / relative
                if current != root:
                    directories.append(current)
    snapshots = {}
    for directory in directories:
        snapshot = {}
        for name in (
            ".",
            "cgroup.controllers",
            "cgroup.subtree_control",
            "cgroup.type",
            "cgroup.procs",
            "memory.max",
            "pids.max",
            "cpu.max",
        ):
            path = directory / name
            try:
                stat = path.stat()
                entry = {
                    "uid": stat.st_uid,
                    "gid": stat.st_gid,
                    "mode": oct(stat.st_mode & 0o7777),
                    "writable": os.access(path, os.W_OK),
                }
                if name == "cgroup.procs":
                    entry["process_count"] = len(path.read_text().splitlines())
                elif name != ".":
                    entry["value"] = path.read_text().strip()
                snapshot[name] = entry
            except OSError as error:
                snapshot[name] = {"error": str(error)}
        snapshots[str(directory)] = snapshot
    result["directories"] = snapshots
    print(json.dumps(result, indent=2))


class Experiment:
    def __init__(
        self,
        directory,
        podman,
        runtime_image,
        task_image,
        seccomp,
        extended=False,
        delegate_cgroup=False,
        mounts=None,
        expected_image=None,
        run_directory=None,
        persistent=False,
        storage_driver="overlay",
    ):
        self.directory = directory
        self.storage_driver = storage_driver
        self.run_directory = run_directory or directory
        self.persistent = persistent
        self.socket_directory = self.run_directory / "api"
        self.runtime_image = runtime_image
        self.task_image = task_image
        self.seccomp = seccomp
        self.extended = extended
        self.delegate_cgroup = delegate_cgroup
        self.cgroup = None
        self.mounts = mounts
        self.expected_image = expected_image
        self.env = {
            "PATH": "/run/privileged/bin:" + os.environ["PATH"],
            "HOME": str(directory / "home"),
            "XDG_RUNTIME_DIR": str(self.run_directory / "run"),
            "CONTAINERS_CONF": str(directory / "containers.conf"),
            "CONTAINERS_STORAGE_CONF": str(directory / "storage.conf"),
        }
        self.local = [podman, "--remote=false"]
        self.remote = [
            podman,
            "--remote",
            "--url",
            "unix://" + str(self.socket_directory / "podman.sock"),
        ]
        self.started = False
        self.results = {}
        self.log = (directory / "commands.log").open("a" if persistent else "w")

    def run(self, command, timeout=120, check=True, env=None):
        self.log.write("\n" + json.dumps(command) + "\n")
        self.log.flush()
        result = subprocess.run(
            command,
            env=self.env if env is None else env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        self.log.write(result.stdout + result.stderr)
        self.log.write(f"\nexit={result.returncode}\n")
        self.log.flush()
        if check and result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): "
                + json.dumps(command)
                + "\n"
                + result.stdout[-4000:]
                + result.stderr[-4000:]
            )
        return result

    def prepare(self):
        for name in (
            "home",
            "run",
            "shared",
            "protected",
            "api",
            "inner",
            "inner-run",
        ):
            (self.directory / name).mkdir(mode=0o700, exist_ok=self.persistent)
        for name in ("api", "run", "inner-run"):
            (self.run_directory / name).mkdir(mode=0o700, exist_ok=True)
        (self.directory / "unshared-secret").write_text("not exposed\n")
        (self.directory / "protected" / "sentinel").write_text("original\n")
        escape = self.directory / "shared" / "escape"
        if not os.path.lexists(escape):
            escape.symlink_to(self.directory / "unshared-secret")
        (self.directory / "containers.conf").write_text(
            '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n'
            '[containers]\ncgroups="'
            + ("enabled" if self.delegate_cgroup else "disabled")
            + '"\n'
        )
        inner_config = (
            '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n'
            '[containers]\ncgroups="enabled"\ncgroup_parent="/tasks"\n'
            if self.delegate_cgroup
            else (self.directory / "containers.conf").read_text()
        )
        (self.directory / "inner-containers.conf").write_text(inner_config)
        # Native rootless overlay in both engines; the inner graphroot is a
        # host bind mount, not the outer engine's overlay rootfs. VFS remains
        # selectable for comparison.
        driver = 'driver="' + self.storage_driver + '"\n'
        (self.directory / "storage.conf").write_text(
            "[storage]\n"
            + driver
            + "graphroot="
            + json.dumps(str(self.directory / "outer-storage"))
            + "\nrunroot="
            + json.dumps(str(self.run_directory / "outer-run"))
            + "\n"
        )
        (self.directory / "inner-storage.conf").write_text(
            "[storage]\n"
            + driver
            + 'graphroot="/home/podman/.local/share/containers/storage"\n'
            'runroot="/run/user/1000/storage"\n'
        )

    def check_driver(self, engine, info):
        driver = info.get("store", {}).get("graphDriverName")
        self.results[engine + "_storage_driver"] = driver
        if driver != self.storage_driver:
            raise RuntimeError(
                f"{engine.capitalize()} Podman uses storage driver "
                f"{driver!r}, not {self.storage_driver!r}"
            )

    def start(self):
        info = json.loads(
            self.run(self.local + ["info", "--format=json"]).stdout
        )
        if not info["host"]["security"]["rootless"]:
            raise RuntimeError("Outer Podman is not rootless")
        self.check_driver("outer", info)
        print(
            "Pulling runtime image (first run may take several minutes)...",
            flush=True,
        )
        cached = (
            self.expected_image
            and self.run(
                self.local + ["image", "exists", self.expected_image],
                check=False,
            ).returncode
            == 0
        )
        if cached:
            self.runtime_image = self.expected_image
        else:
            self.run(self.local + ["pull", self.runtime_image], timeout=900)
        if self.expected_image:
            actual = (
                self.run(
                    self.local
                    + [
                        "image",
                        "inspect",
                        "--format={{.Id}}",
                        self.runtime_image,
                    ]
                )
                .stdout.strip()
                .removeprefix("sha256:")
            )
            if actual != self.expected_image:
                raise RuntimeError(
                    "Runtime image changed; expected "
                    + self.expected_image
                    + ", got "
                    + actual
                )
            self.runtime_image = actual
        seccomp_option = []
        if self.seccomp == "nested":
            source = self.run(
                self.local
                + [
                    "run",
                    "--rm",
                    "--cgroups=disabled",
                    "--network=none",
                    "--entrypoint=/bin/cat",
                    self.runtime_image,
                    "/usr/share/containers/seccomp.json",
                ]
            ).stdout
            (self.directory / "seccomp-base.json").write_text(source)
            profile = nested_seccomp(json.loads(source))
            target = self.directory / "seccomp-nested.json"
            target.write_text(json.dumps(profile, indent=2) + "\n")
            seccomp_option = ["--security-opt=seccomp=" + str(target)]
        elif self.seccomp == "unconfined":
            seccomp_option = ["--security-opt=seccomp=unconfined"]
        (self.directory / "configuration.json").write_text(
            json.dumps(
                {
                    "outer_seccomp": self.seccomp,
                    "runtime_image": self.runtime_image,
                    "task_image": self.task_image,
                    "delegate_cgroup": self.delegate_cgroup,
                },
                indent=2,
            )
            + "\n"
        )
        command = self.local + [
            "run",
            "--detach",
            "--name=contained-agent-runtime-probe",
            "--cgroups=enabled"
            if self.delegate_cgroup
            else "--cgroups=disabled",
            "--userns=keep-id:uid=1000,gid=1000",
            "--user=0:0" if self.delegate_cgroup else "--user=1000:1000",
            "--security-opt=label=disable",
            "--security-opt=unmask=ALL",
            *seccomp_option,
            "--device=/dev/fuse",
            "--env=HOME=/home/podman",
            "--env=XDG_RUNTIME_DIR=/run/user/1000",
            "--env=CONTAINERS_CONF=/etc/containers/probe.conf",
            "--env=CONTAINERS_STORAGE_CONF=/etc/containers/probe-storage.conf",
        ]
        bootstrap = 'test "$(id -u)" = 1000; '
        if self.delegate_cgroup:
            root = Path("/sys/fs/cgroup")
            required = {"cpu", "memory", "pids"}
            enabled = set((root / "cgroup.subtree_control").read_text().split())
            if not required <= enabled:
                raise RuntimeError(
                    "Host root has not enabled cpu/memory/pids; no global changes made"
                )
            candidate = root / (
                ("contained-podman-" if self.persistent else "")
                + self.directory.name
            )
            candidate.mkdir(mode=0o700)
            self.cgroup = candidate
            (candidate / "cgroup.subtree_control").write_text(
                "+cpu +memory +pids"
            )
            command.extend(
                [
                    "--cgroup-parent=/" + candidate.name,
                    "--cgroupns=private",
                    # Podman's systemd mode makes the private cgroup mount writable.
                    # It does not run systemd or expose the host hierarchy.
                    "--systemd=always",
                    "--stop-signal=SIGTERM",
                ]
            )
            bootstrap += (
                "grep '^0::/$' /proc/self/cgroup; "
                "if ! test -w /sys/fs/cgroup/cgroup.subtree_control; then "
                "echo 'Private cgroup subtree is not writable' >&2; "
                "id >&2; "
                "ls -ld /sys/fs/cgroup /sys/fs/cgroup/cgroup.subtree_control >&2; "
                "grep ' - cgroup2 ' /proc/self/mountinfo >&2; exit 1; fi; "
                "mkdir /sys/fs/cgroup/service /sys/fs/cgroup/tasks; "
                "echo $$ > /sys/fs/cgroup/service/cgroup.procs; "
                "echo '+cpu +memory +pids' > /sys/fs/cgroup/cgroup.subtree_control; "
                "echo '+cpu +memory +pids' > /sys/fs/cgroup/tasks/cgroup.subtree_control; "
            )
        if self.extended and Path("/dev/net/tun").exists():
            command.append("--device=/dev/net/tun")
        mounts = [
            # keep-id maps this host-user-owned 0700 directory to UID 1000.
            # Podman 6.1.1 rejects uid/gid options on --tmpfs.
            (self.run_directory / "inner-run", "/run/user/1000", "rw"),
            (self.directory / "shared", str(self.directory / "shared"), "rw"),
            (
                self.directory / "protected",
                str(self.directory / "shared" / "readonly"),
                "ro",
            ),
            (self.socket_directory, "/run/api", "rw"),
            (
                self.directory / "inner",
                "/home/podman/.local/share/containers",
                "rw",
            ),
            (
                self.directory / "inner-containers.conf",
                "/etc/containers/probe.conf",
                "ro",
            ),
            (
                self.directory / "inner-storage.conf",
                "/etc/containers/probe-storage.conf",
                "ro",
            ),
        ]
        if self.mounts is not None:
            # Replace only synthetic test-project mounts; retain isolated
            # engine state/configuration and the private socket directory.
            mounts = [
                entry
                for entry in mounts
                if entry[0]
                not in (self.directory / "shared", self.directory / "protected")
            ]
            mounts.extend(self.mounts)
        for source, target, mode in mounts:
            command.extend(["--volume", f"{source}:{target}:{mode}"])
        service_command = (
            bootstrap
            + "exec podman system service --time=0 unix:///run/api/podman.sock"
        )
        if self.delegate_cgroup:
            # crun's private cgroup mount is owned by namespace UID 0, not
            # the keep-id service UID. Delegate only its management files,
            # then permanently leave that bootstrap identity before serving.
            service_command = (
                'test "$(id -u)" = 0; '
                "grep '^0::/$' /proc/self/cgroup; "
                "chown 1000:1000 /sys/fs/cgroup "
                "/sys/fs/cgroup/cgroup.procs "
                "/sys/fs/cgroup/cgroup.threads "
                "/sys/fs/cgroup/cgroup.subtree_control; "
                "exec setpriv --reuid=1000 --regid=1000 --clear-groups "
                "/bin/sh -ec " + shlex.quote(service_command)
            )
        command.extend(
            [
                "--entrypoint=/bin/sh",
                self.runtime_image,
                "-ec",
                service_command,
            ]
        )
        self.started = True
        self.run(command)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if (self.socket_directory / "podman.sock").exists():
                probe = self.run(
                    self.remote + ["info", "--format=json"], check=False
                )
                if probe.returncode == 0:
                    info = json.loads(probe.stdout)
                    self.results["inner_rootless"] = info["host"]["security"][
                        "rootless"
                    ]
                    (self.directory / "inner-info.json").write_text(
                        probe.stdout
                    )
                    if not self.results["inner_rootless"]:
                        raise RuntimeError("Inner Podman is not rootless")
                    self.check_driver("inner", info)
                    status = self.run(
                        self.local
                        + [
                            "exec",
                            "contained-agent-runtime-probe",
                            "cat",
                            "/proc/1/status",
                        ]
                    ).stdout
                    (self.directory / "runtime-process-status.txt").write_text(
                        status
                    )
                    self.results["runtime_service_uid_1000"] = any(
                        line.split() == ["Uid:", "1000", "1000", "1000", "1000"]
                        for line in status.splitlines()
                    )
                    if not self.results["runtime_service_uid_1000"]:
                        raise RuntimeError(
                            "API service did not drop to UID 1000"
                        )
                    if self.seccomp != "unconfined":
                        self.results["outer_seccomp_filter_active"] = any(
                            line.split() == ["Seccomp:", "2"]
                            for line in status.splitlines()
                        )
                        if not self.results["outer_seccomp_filter_active"]:
                            raise RuntimeError(
                                "Outer seccomp filter is not active"
                            )
                    return
            state = self.run(
                self.local
                + [
                    "inspect",
                    "--format={{.State.Running}}",
                    "contained-agent-runtime-probe",
                ]
            ).stdout.strip()
            if state != "true":
                break
            time.sleep(0.5)
        raise RuntimeError("Runtime API did not become ready; see runtime.log")

    def task(self, shell, extra=()):
        return self.run(
            self.remote
            + [
                "run",
                "--rm",
                "--cgroups=disabled",
                "--network=none",
                *extra,
                self.task_image,
                "sh",
                "-ec",
                shell,
            ]
        )

    def test(self):
        print(
            "API connected; pulling task image and testing mounts...",
            flush=True,
        )
        self.run(self.remote + ["pull", self.task_image], timeout=900)
        shared = str(self.directory / "shared")
        self.task(
            'printf "from task\\n" > /work/output; '
            "test ! -e /work/escape; "
            'test "$(cat /work/readonly/sentinel)" = original; '
            "if echo changed > /work/readonly/sentinel; then exit 31; fi",
            ["--volume", shared + ":/work"],
        )
        self.results["same_path_write"] = (
            self.directory / "shared" / "output"
        ).read_text() == "from task\n"
        self.results["symlink_and_readonly"] = True
        # Binding '/' must expose only the runtime root. Test ordinary and
        # privileged inner tasks; neither may see the unshared host sentinel.
        hidden = str(self.directory / "unshared-secret")
        for privileged in (False, True):
            # Default privileged + network=none failed at sysfs creation on
            # the host. Test a distinct variant using the runtime's read-only
            # sysfs instead; this does not establish default-mode support.
            flags = (
                ["--privileged", "--volume", "/sys:/sys:ro"]
                if privileged
                else []
            )
            self.task(
                'test ! -e "/runtime-root' + hidden + '"; '
                'test "$(cat /work/readonly/sentinel)" = original; '
                "if mount -o remount,bind,rw /work/readonly; then "
                'echo "UNEXPECTED: writable remount" >&2; exit 32; fi; '
                "if echo changed > /work/readonly/sentinel; then exit 33; fi",
                flags
                + [
                    "--volume",
                    "/:/runtime-root:ro",
                    "--volume",
                    shared + ":/work",
                ],
            )
            mode = "privileged_with_readonly_sys" if privileged else "ordinary"
            self.results[f"root_bind_and_readonly_{mode}"] = True
        self.results["host_sentinel_unchanged"] = (
            self.directory / "protected" / "sentinel"
        ).read_text() == "original\n"
        if not all(self.results.values()):
            raise RuntimeError("One or more checks failed")

    def test_build(self):
        # Deliberately outside shared/: the server cannot read this path.
        context = self.directory / "client-build-context"
        context.mkdir()
        (context / "payload").write_text("uploaded context\n")
        (context / "Dockerfile").write_text(
            "FROM " + self.task_image + "\n"
            "COPY payload /payload\nRUN printf 'built\\n' > /built\n"
        )
        self.run(
            self.remote
            + [
                "build",
                "--network=none",
                "--tag=localhost/runtime-probe:latest",
                str(context),
            ],
            timeout=600,
        )
        self.run(
            self.remote
            + [
                "run",
                "--rm",
                "--network=none",
                "--cgroups=disabled",
                "localhost/runtime-probe:latest",
                "sh",
                "-ec",
                'test "$(cat /payload)" = "uploaded context"; '
                'test "$(cat /built)" = built',
            ]
        )

    def test_compose(self):
        web_image = "docker.io/library/busybox:1.37"
        self.run(self.remote + ["pull", web_image], timeout=900)
        # Check the actual applet before involving Compose/networking.
        self.run(
            self.remote
            + [
                "run",
                "--rm",
                "--network=none",
                "--cgroups=disabled",
                web_image,
                "sh",
                "-ec",
                "busybox --list | grep -x httpd",
            ]
        )
        directory = self.directory / "shared" / "compose"
        directory.mkdir()
        (directory / "www").mkdir()
        (directory / "out").mkdir()
        (directory / "www" / "index.html").write_text("compose works\n")
        compose_file = directory / "compose.json"
        compose_file.write_text(
            json.dumps(
                {
                    "services": {
                        "web": {
                            "image": web_image,
                            "command": [
                                "busybox",
                                "httpd",
                                "-f",
                                "-p",
                                "8080",
                                "-h",
                                "/srv",
                            ],
                            "volumes": ["./www:/srv:ro"],
                        },
                        "client": {
                            "image": self.task_image,
                            "volumes": ["./out:/out"],
                            "command": [
                                "sh",
                                "-ec",
                                "for i in 1 2 3 4 5; do "
                                "if wget -T 5 -q -O /out/result http://web:8080; then "
                                "exit 0; fi; sleep 1; done; exit 1",
                            ],
                        },
                    }
                },
                indent=2,
            )
        )
        env = {
            **self.env,
            "CONTAINER_HOST": "unix://"
            + str(self.directory / "api" / "podman.sock"),
            "DOCKER_HOST": "unix://"
            + str(self.directory / "api" / "podman.sock"),
        }
        compose = [
            shutil.which("podman-compose"),
            "--podman-path",
            self.local[0],
            "--project-name",
            "runtime-probe",
            "--file",
            str(compose_file),
        ]
        try:
            self.run(compose + ["up", "--detach", "web"], env=env)
            self.run(compose + ["run", "--rm", "client"], env=env)
            if (directory / "out" / "result").read_text() != "compose works\n":
                raise RuntimeError(
                    "Compose output did not reach the shared path"
                )
        finally:
            self.run(compose + ["down", "--volumes"], env=env)

    def test_limits(self):
        # Request actual enforcement, and check kernel files, not inspect's
        # requested values. Failure exposes missing delegation; never retry
        # without limits and report success.
        self.run(
            self.local
            + [
                "exec",
                "contained-agent-runtime-probe",
                "sh",
                "-c",
                "cat /proc/self/cgroup; ls -ld /sys/fs/cgroup; "
                "cat /sys/fs/cgroup/cgroup.controllers; "
                "cat /sys/fs/cgroup/cgroup.subtree_control",
            ],
            check=False,
        )
        result = self.run(
            self.remote
            + [
                "run",
                "--name=runtime-probe-limits",
                "--network=none",
                "--cgroups=enabled",
                "--cgroupns=private",
                "--memory=128m",
                "--pids-limit=32",
                "--cpus=0.5",
                self.task_image,
                "sh",
                "-ec",
                "cat /proc/self/cgroup; "
                "grep ' - cgroup2 ' /proc/self/mountinfo; "
                "for f in memory.max pids.max cpu.max; do "
                'printf "%s=" "$f"; cat "/sys/fs/cgroup/$f"; done; '
                'test "$(cat /sys/fs/cgroup/memory.max)" = 134217728; '
                'test "$(cat /sys/fs/cgroup/pids.max)" = 32; '
                "awk '{ if ($1 == \"max\" || $1 / $2 != 0.5) exit 1 }' "
                "/sys/fs/cgroup/cpu.max",
            ],
            check=False,
        )
        inspection = self.run(
            self.remote + ["inspect", "runtime-probe-limits"], check=False
        )
        (self.directory / "limits-inspect.json").write_text(inspection.stdout)
        (self.directory / "limits-output.txt").write_text(
            result.stdout + result.stderr
        )
        self.run(
            self.remote + ["rm", "--force", "--ignore", "runtime-probe-limits"]
        )
        if result.returncode:
            raise RuntimeError(
                f"Cgroup enforcement check exited {result.returncode}:\n"
                + result.stdout
                + result.stderr
            )

    def extended_tests(self):
        failures = []
        for name, test in (
            ("remote_build_context", self.test_build),
            ("compose_network_and_relative_mounts", self.test_compose),
            ("cgroup_limits_enforced", self.test_limits),
        ):
            print("Testing " + name + "...", flush=True)
            try:
                test()
                self.results[name] = True
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                self.results[name] = False
                self.results[name + "_error"] = str(error)
                failures.append(name)
        if failures:
            raise RuntimeError("Extended checks failed: " + ", ".join(failures))

    def cleanup(self, preserve_storage=False):
        if self.started:
            logs = self.run(
                self.local + ["logs", "contained-agent-runtime-probe"],
                check=False,
            )
            (self.directory / "runtime.log").write_text(
                logs.stdout + logs.stderr
            )
            removed = self.run(
                self.local
                + [
                    "rm",
                    "--force",
                    "--ignore",
                    "contained-agent-runtime-probe",
                ],
                check=False,
            )
            if removed.returncode:
                self.log.close()
                raise RuntimeError(
                    "Runtime removal failed; preserving its storage\n"
                    + removed.stderr[-4000:]
                )
        # unshare supplies the same subordinate IDs used by the disposable
        # engines. Never reset or prune the user's normal Podman database.
        paths = [
            str(self.run_directory / name)
            for name in ("inner-run", "outer-run", "run", "api")
        ]
        if not preserve_storage:
            paths.extend(
                str(self.directory / name)
                for name in ("inner", "outer-storage", "home")
            )
        removal = self.run(
            self.local
            + [
                "unshare",
                sys.executable,
                "-c",
                _CLEANUP_STORAGE,
                str(self.run_directory / "run" / "netns"),
                *paths,
            ],
            check=False,
        )
        if removal.returncode:
            self.log.close()
            raise RuntimeError(
                "Storage cleanup failed; retained under "
                + str(self.directory)
                + "\n"
                + removal.stdout[-2000:]
                + removal.stderr[-4000:]
            )
        if self.cgroup is not None:
            # Remove only our newly created subtree, after runtime termination.
            # Never move or kill unrelated host processes to force cleanup.
            for attempt in range(10):
                try:
                    for parent, _, _ in os.walk(self.cgroup, topdown=False):
                        Path(parent).rmdir()
                    break
                except OSError:
                    if attempt == 9:
                        raise
                    time.sleep(0.2)
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime-image", default="quay.io/podman/stable:latest"
    )
    parser.add_argument("--task-image", default="docker.io/library/alpine:3.21")
    parser.add_argument(
        "--outer-seccomp",
        choices=("nested", "default", "unconfined"),
        default="nested",
    )
    parser.add_argument(
        "--extended",
        action="store_true",
        help="Also test build, Compose and cgroup limits",
    )
    parser.add_argument(
        "--host-cgroup-info",
        action="store_true",
        help="Print read-only host cgroup diagnostics; do not run containers",
    )
    parser.add_argument(
        "--storage-driver", choices=("overlay", "vfs"), default="overlay"
    )
    parser.add_argument(
        "--delegate-cgroup",
        action="store_true",
        help="Create and clean up a private host cgroup subtree for this runtime",
    )
    args = parser.parse_args()
    if args.host_cgroup_info:
        host_cgroup_info()
        return 0
    if os.getuid() == 0:
        parser.error("Run as your normal user, without sudo")
    podman = shutil.which("podman")
    if not podman:
        parser.error("podman is missing from PATH")
    if args.extended and not shutil.which("podman-compose"):
        parser.error("--extended requires podman-compose in PATH")
    for path in (
        "/sys/fs/cgroup/cgroup.controllers",
        "/dev/fuse",
        "/etc/subuid",
        "/etc/subgid",
    ):
        if not Path(path).exists():
            parser.error("Missing host prerequisite: " + path)
    for helper in ("newuidmap", "newgidmap"):
        if not shutil.which(
            helper, path="/run/privileged/bin:" + os.environ["PATH"]
        ):
            parser.error("Missing mapping helper in PATH: " + helper)
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix="agent-podman-", dir="/var/tmp"))
    print("Logs and results: " + str(directory), flush=True)
    experiment = Experiment(
        directory,
        podman,
        args.runtime_image,
        args.task_image,
        args.outer_seccomp,
        args.extended,
        args.delegate_cgroup,
        storage_driver=args.storage_driver,
    )
    status = 1
    try:
        experiment.prepare()
        experiment.start()
        experiment.test()
        if args.extended:
            experiment.extended_tests()
        status = 0
    except (
        RuntimeError,
        OSError,
        subprocess.TimeoutExpired,
        KeyboardInterrupt,
    ) as error:
        experiment.results["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        try:
            experiment.cleanup()
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            experiment.results["cleanup_error"] = str(error)
            print("Cleanup incomplete: " + str(error), file=sys.stderr)
            status = 1
        experiment.results["passed"] = status == 0
        (directory / "results.json").write_text(
            json.dumps(experiment.results, indent=2) + "\n"
        )
    print("PASS" if status == 0 else "FAIL", flush=True)
    print("Results retained: " + str(directory), flush=True)
    return status


def session_mounts(options):
    """Translate the launcher's ordered Guix project mounts, failing closed."""
    mounts = []
    reserved = (
        "/etc",
        "/usr",
        "/bin",
        "/sbin",
        "/lib",
        "/lib64",
        "/proc",
        "/sys",
        "/dev",
        "/run",
        "/home/podman",
    )
    for option in options:
        if option.startswith("--share="):
            source, mode = option[len("--share=") :], "rw"
        elif option.startswith("--expose="):
            source, mode = option[len("--expose=") :], "ro"
        else:
            raise ValueError("Not a project mount: " + option)
        # Guix's SOURCE=TARGET form; the agent addresses TARGET.
        source, _, target = source.partition("=")
        target = target or source
        for end in (source, target):
            if (
                not Path(end).is_absolute()
                or end == "/"
                or ".." in Path(end).parts
                or any(char in end for char in ("=", ":", ",", "\n"))
            ):
                raise ValueError("Unsupported runtime mount: " + option)
        if any(
            end == root
            or end.startswith(root + "/")
            or root.startswith(end.rstrip("/") + "/")
            for end in (source, target)
            for root in reserved
        ):
            raise ValueError("Mount overlaps runtime infrastructure: " + option)
        path = Path(source)
        if not path.exists():
            raise ValueError("Project mount disappeared: " + source)
        mounts.append((path, target, mode))
    return mounts


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        raise RuntimeError(
            "Runtime directory must be owned by you and mode 0700: " + str(path)
        )


def runtime_spec(project, mounts, image, podman, storage_driver="overlay"):
    user = pwd.getpwuid(os.getuid()).pw_name
    subids = {}
    for name in ("subuid", "subgid"):
        path = Path("/etc") / name
        subids[name] = (
            [
                line
                for line in path.read_text().splitlines()
                if line.split(":", 1)[0] in (user, str(os.getuid()))
            ]
            if path.exists()
            else []
        )
    return {
        "schema": 3,
        "uid": os.getuid(),
        "gid": os.getgid(),
        "project": str(Path(project).resolve(strict=True)),
        "image": image,
        "podman": str(Path(podman).resolve()),
        "storage_driver": storage_driver,
        "subids": subids,
        "mounts": [
            {
                "source": str(source),
                "resolved": str(source.resolve()),
                "target": target,
                "mode": mode,
                "device": source.stat().st_dev,
                "inode": source.stat().st_ino,
            }
            for source, target, mode in mounts
        ],
    }


def runtime_key(spec):
    return hashlib.sha256(
        json.dumps(spec, sort_keys=True).encode()
    ).hexdigest()[:32]


def atomic_json(path, value):
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


class SharedRuntime:
    """Serialize engine mutations; keep a shared lease while an agent runs."""

    def __init__(self, root, run_root, spec, image_reference):
        self.spec = spec
        self.key = runtime_key(spec)
        self.directory = root / self.key
        self.run_directory = run_root / self.key
        private_directory(self.directory)
        private_directory(self.run_directory)
        self.image_reference = image_reference
        self.boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        self.lease = None

    def engine(self):
        mounts = [
            (Path(item["source"]), item["target"], item["mode"])
            for item in self.spec["mounts"]
        ]
        return Experiment(
            self.directory,
            self.spec["podman"],
            self.image_reference,
            "",
            "nested",
            extended=True,
            delegate_cgroup=True,
            mounts=mounts,
            expected_image=self.spec["image"],
            run_directory=self.run_directory,
            persistent=True,
            storage_driver=self.spec["storage_driver"],
        )

    @contextlib.contextmanager
    def mutation_lock(self):
        with (self.directory / "startup.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = self.directory / "spec.json"
            if path.exists() and json.loads(path.read_text()) != self.spec:
                raise RuntimeError(
                    "Runtime identity collision or changed stored policy"
                )
            atomic_json(path, self.spec)
            yield

    def healthy(self, engine):
        ready = self.directory / "ready.json"
        if (
            not ready.exists()
            or json.loads(ready.read_text()).get("boot") != self.boot
        ):
            return False
        status = engine.run(
            engine.local + ["inspect", "contained-agent-runtime-probe"],
            check=False,
        )
        if status.returncode:
            return False
        data = json.loads(status.stdout)[0]
        if (
            not data["State"]["Running"]
            or data["Image"].removeprefix("sha256:") != self.spec["image"]
        ):
            return False
        probe = engine.run(
            engine.remote + ["info", "--format=json"], check=False, timeout=15
        )
        return (
            probe.returncode == 0
            and json.loads(probe.stdout)["host"]["security"]["rootless"]
        )

    def stop_engine(self, engine):
        engine.started = True  # rm --ignore also handles an interrupted start.
        engine.cgroup = Path("/sys/fs/cgroup") / (
            "contained-podman-" + self.key
        )
        engine.cleanup(preserve_storage=True)
        (self.directory / "ready.json").unlink(missing_ok=True)

    def attach(self):
        with self.mutation_lock():
            engine = self.engine()
            lease = (self.directory / "sessions.lock").open("a+")
            try:
                try:
                    healthy = self.healthy(engine)
                except (
                    subprocess.TimeoutExpired,
                    ValueError,
                    KeyError,
                    IndexError,
                    TypeError,
                ):
                    # Incomplete readiness files and unresponsive APIs need
                    # recovery, but only when no other session holds a lease.
                    healthy = False
                if not healthy:
                    try:
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError as error:
                        raise RuntimeError(
                            "Runtime is unavailable but other sessions are active; refusing to restart it"
                        ) from error
                    # Prepare deterministic config before inspecting/removing
                    # stale engine state. Never delete graphroot or volumes.
                    engine.prepare()
                    self.stop_engine(engine)
                    engine.log.close()
                    engine = self.engine()
                    try:
                        engine.prepare()
                        engine.start()
                        atomic_json(
                            self.directory / "ready.json", {"boot": self.boot}
                        )
                    except BaseException:
                        self.stop_engine(engine)
                        raise
                fcntl.flock(lease, fcntl.LOCK_SH)
                self.lease = lease
            except BaseException:
                lease.close()
                raise
            finally:
                engine.log.close()
        return self.run_directory / "api"

    def detach(self):
        if self.lease:
            self.lease.close()
            self.lease = None

    def stop(self):
        with (
            self.mutation_lock(),
            (self.directory / "sessions.lock").open("a+") as lease,
        ):
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError(
                    "Runtime still has active sessions; refusing to stop"
                ) from error
            engine = self.engine()
            try:
                engine.prepare()
                self.stop_engine(engine)
            finally:
                engine.log.close()


def session_main():
    parser = argparse.ArgumentParser(
        description="Shared project Podman runtime"
    )
    parser.add_argument("--podman", required=True)
    parser.add_argument("--project")
    parser.add_argument(
        "--runtime-image", default="quay.io/podman/stable:latest"
    )
    parser.add_argument(
        "--expected-image",
        default="0e1abc5572ecd4dbc4574f60669bdbbafe804af7f6709b257cc93b8a797106ea",
    )
    parser.add_argument(
        "--state-root",
        type=Path,
        default=Path.home() / ".local/share/contained-agent/podman",
    )
    parser.add_argument(
        "--runtime-root",
        type=Path,
        default=Path(
            os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        )
        / "contained-podman",
    )
    parser.add_argument(
        "--stop",
        metavar="RUNTIME_ID",
        help="Stop an idle runtime, retaining images and volumes",
    )
    parser.add_argument(
        "--storage-driver", choices=("overlay", "vfs"), default="overlay"
    )
    parser.add_argument("--mount-option", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if os.getuid() == 0:
        parser.error("Run as your normal host user")
    os.umask(0o077)
    private_directory(args.state_root)
    private_directory(args.runtime_root)
    if args.stop:
        if len(args.stop) != 32 or any(
            c not in "0123456789abcdef" for c in args.stop
        ):
            parser.error("Invalid runtime ID")
        spec = json.loads(
            (args.state_root / args.stop / "spec.json").read_text()
        )
        if runtime_key(spec) != args.stop:
            parser.error("Stored runtime policy does not match its ID")
        manager = SharedRuntime(
            args.state_root, args.runtime_root, spec, args.runtime_image
        )
        with contextlib.redirect_stdout(sys.stderr):
            manager.stop()
        return 0
    if not command or not args.project or not args.mount_option:
        parser.error(
            "A project, project mounts and session command are required"
        )
    if len(args.expected_image) != 64 or any(
        c not in "0123456789abcdef" for c in args.expected_image
    ):
        parser.error(
            "--expected-image must be a complete lowercase image SHA256"
        )
    mounts = session_mounts(args.mount_option)
    for source, _, _ in mounts:
        for root in (args.state_root.resolve(), args.runtime_root.resolve()):
            if root.is_relative_to(
                source.resolve()
            ) or source.resolve().is_relative_to(root):
                parser.error("Project mount overlaps private runtime state")
    for name in (
        "/dev/fuse",
        "/dev/net/tun",
        "/sys/fs/cgroup/cgroup.controllers",
    ):
        if not Path(name).exists():
            parser.error("Missing host runtime prerequisite: " + name)
    placeholder = (
        "--expose=@CONTAINED_PODMAN_SOCKET@=/run/contained-agent/podman"
    )
    if command.count(placeholder) != 1:
        parser.error(
            "Session command must mount exactly one runtime socket directory"
        )
    spec = runtime_spec(
        args.project,
        mounts,
        args.expected_image,
        args.podman,
        args.storage_driver,
    )
    manager = SharedRuntime(
        args.state_root, args.runtime_root, spec, args.runtime_image
    )
    if len(os.fsencode(manager.run_directory / "api/podman.sock")) > 107:
        parser.error(
            "Runtime socket path is too long; choose a shorter --runtime-root"
        )
    print(
        "contained-agent runtime: "
        + manager.key
        + " (logs: "
        + str(manager.directory)
        + ")",
        file=sys.stderr,
    )
    child = None
    exit_code = 1

    def interrupted(signum, _frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)
        else:
            raise InterruptedError("Runtime startup interrupted")

    previous = {
        sig: signal.signal(sig, interrupted)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
    }
    try:
        with contextlib.redirect_stdout(sys.stderr):
            socket_directory = manager.attach()
        command = [
            "--expose=" + str(socket_directory) + "=/run/contained-agent/podman"
            if arg == placeholder
            else arg
            for arg in command
        ]
        child = subprocess.Popen(command)
        result = child.wait()
        exit_code = result if result >= 0 else 128 - result
    except (
        RuntimeError,
        OSError,
        ValueError,
        subprocess.TimeoutExpired,
    ) as error:
        print("contained-agent runtime: " + str(error), file=sys.stderr)
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        manager.detach()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return exit_code


if __name__ == "__main__":
    if sys.argv[1:2] == ["--session"]:
        del sys.argv[1]
        sys.exit(session_main())
    sys.exit(main())
