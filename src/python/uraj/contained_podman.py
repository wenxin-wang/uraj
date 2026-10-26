#!/usr/bin/env python3
"""Manage isolated, persistent project Podman runtimes."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pwd
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


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


def remove_cgroup(group, timeout=30):
    """Remove GROUP's subtree once its processes have exited.

    conmon runs the container cleanup command from its own child group after
    the container is gone, so wait for that instead of failing at once. Never
    move or kill processes to force removal.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            events = (group / "cgroup.events").read_text().splitlines()
        except FileNotFoundError:
            return
        if "populated 0" in events:
            break
        if time.monotonic() >= deadline:
            remaining = sorted(
                {
                    pid
                    for path in group.rglob("cgroup.procs")
                    for pid in path.read_text().split()
                },
                key=int,
            )
            raise RuntimeError(
                f"Processes {' '.join(remaining)} remain in {group}; "
                "retry once they exit"
            )
        time.sleep(0.2)
    for parent, _, _ in os.walk(group, topdown=False):
        Path(parent).rmdir()


class Engine:
    """One project's outer runtime container and its inner Podman API.

    The outer engine is the shared host service: rootless Podman needs the
    host's ID helpers, unavailable inside the Paseo supervisor's single-ID
    user namespace.
    """

    def __init__(
        self,
        directory,
        run_directory,
        podman,
        outer_url,
        name,
        runtime_image,
        expected_image,
        mounts,
        storage_driver="overlay",
    ):
        self.directory = directory
        self.run_directory = run_directory
        self.name = name
        self.runtime_image = runtime_image
        self.expected_image = expected_image
        self.mounts = mounts
        self.storage_driver = storage_driver
        self.socket_directory = run_directory / "api"
        self.cgroup = None
        self.started = False
        # HOME and the runtime directory serve the Podman client.
        self.env = {
            "PATH": "/run/privileged/bin:" + os.environ["PATH"],
            "HOME": str(directory / "home"),
            "XDG_RUNTIME_DIR": str(run_directory / "run"),
        }
        self.local = [podman, "--remote", "--url", outer_url]
        self.remote = [
            podman,
            "--remote",
            "--url",
            "unix://" + str(self.socket_directory / "podman.sock"),
        ]
        self.log = (directory / "commands.log").open("a")

    def run(self, command, timeout=120, check=True):
        self.log.write("\n" + json.dumps(command) + "\n")
        self.log.flush()
        result = subprocess.run(
            command,
            env=self.env,
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
        for name in ("home", "inner"):
            (self.directory / name).mkdir(mode=0o700, exist_ok=True)
        for name in ("api", "run", "inner-run"):
            (self.run_directory / name).mkdir(mode=0o700, exist_ok=True)
        (self.directory / "inner-containers.conf").write_text(
            '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n'
            '[containers]\ncgroups="enabled"\ncgroup_parent="/tasks"\n'
        )
        # Native rootless overlay: the inner graphroot is a host bind mount,
        # not the outer container's overlay rootfs.
        (self.directory / "inner-storage.conf").write_text(
            '[storage]\ndriver="'
            + self.storage_driver
            + '"\n'
            + 'graphroot="/home/podman/.local/share/containers/storage"\n'
            'runroot="/run/user/1000/storage"\n'
        )
        # Image references in Compose files and task definitions assume
        # Docker's short names. With several search registries, enforcing
        # mode needs a TTY to choose; one leaves nothing to choose. A drop-in
        # keeps the image's short-name aliases.
        (self.directory / "inner-registries.conf").write_text(
            'unqualified-search-registries = ["docker.io"]\n'
        )

    def check_driver(self, info):
        driver = info.get("store", {}).get("graphDriverName")
        if driver != self.storage_driver:
            raise RuntimeError(
                f"Inner Podman uses storage driver {driver!r}, "
                f"not {self.storage_driver!r}"
            )

    def start(self):
        info = json.loads(
            self.run(self.local + ["info", "--format=json"]).stdout
        )
        if not info["host"]["security"]["rootless"]:
            raise RuntimeError("Outer Podman is not rootless")
        print(
            "Pulling runtime image (first run may take several minutes)...",
            flush=True,
        )
        cached = (
            self.run(
                self.local + ["image", "exists", self.expected_image],
                check=False,
            ).returncode
            == 0
        )
        if cached:
            self.runtime_image = self.expected_image
        else:
            self.run(self.local + ["pull", self.runtime_image], timeout=900)
        actual = (
            self.run(
                self.local
                + ["image", "inspect", "--format={{.Id}}", self.runtime_image]
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
        profile = self.directory / "seccomp-nested.json"
        profile.write_text(
            json.dumps(nested_seccomp(json.loads(source)), indent=2) + "\n"
        )
        root = Path("/sys/fs/cgroup")
        enabled = set((root / "cgroup.subtree_control").read_text().split())
        if not {"cpu", "memory", "pids"} <= enabled:
            raise RuntimeError(
                "Host root has not enabled cpu/memory/pids; no global changes made"
            )
        self.cgroup = root / ("contained-podman-" + self.directory.name)
        # An interrupted stop may have left the empty or draining group.
        self.cgroup.mkdir(mode=0o700, exist_ok=True)
        (self.cgroup / "cgroup.subtree_control").write_text(
            "+cpu +memory +pids"
        )
        command = self.local + [
            "run",
            "--detach",
            "--name=" + self.name,
            "--cgroups=enabled",
            "--userns=keep-id:uid=1000,gid=1000",
            "--user=0:0",
            "--security-opt=label=disable",
            "--security-opt=unmask=ALL",
            "--security-opt=seccomp=" + str(profile),
            "--device=/dev/fuse",
            "--env=HOME=/home/podman",
            "--env=XDG_RUNTIME_DIR=/run/user/1000",
            "--env=CONTAINERS_CONF=/etc/containers/probe.conf",
            "--env=CONTAINERS_STORAGE_CONF=/etc/containers/probe-storage.conf",
            "--cgroup-parent=/" + self.cgroup.name,
            "--cgroupns=private",
            # Podman's systemd mode makes the private cgroup mount writable.
            # It does not run systemd or expose the host hierarchy.
            "--systemd=always",
            "--stop-signal=SIGTERM",
        ]
        if Path("/dev/net/tun").exists():
            command.append("--device=/dev/net/tun")
        mounts = [
            # keep-id maps this host-user-owned 0700 directory to UID 1000.
            # Podman 6.1.1 rejects uid/gid options on --tmpfs.
            (self.run_directory / "inner-run", "/run/user/1000", "rw"),
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
            (
                self.directory / "inner-registries.conf",
                "/etc/containers/registries.conf.d/999-contained-agent.conf",
                "ro",
            ),
            *self.mounts,
        ]
        for source, target, mode in mounts:
            command.extend(["--volume", f"{source}:{target}:{mode}"])
        service_command = (
            'test "$(id -u)" = 1000; '
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
            "exec podman system service --time=0 unix:///run/api/podman.sock"
        )
        # crun's private cgroup mount is owned by namespace UID 0, not the
        # keep-id service UID. Delegate only its management files, then
        # permanently leave that bootstrap identity before serving.
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
                    if not info["host"]["security"]["rootless"]:
                        raise RuntimeError("Inner Podman is not rootless")
                    self.check_driver(info)
                    status = self.run(
                        self.local
                        + ["exec", self.name, "cat", "/proc/1/status"]
                    ).stdout.splitlines()
                    if ["Uid:", "1000", "1000", "1000", "1000"] not in (
                        line.split() for line in status
                    ):
                        raise RuntimeError(
                            "API service did not drop to UID 1000"
                        )
                    if ["Seccomp:", "2"] not in (
                        line.split() for line in status
                    ):
                        raise RuntimeError("Outer seccomp filter is not active")
                    return
            state = self.run(
                self.local
                + ["inspect", "--format={{.State.Running}}", self.name]
            ).stdout.strip()
            if state != "true":
                break
            time.sleep(0.5)
        raise RuntimeError("Runtime API did not become ready; see runtime.log")

    def remove_run_state(self, paths):
        """Remove PATHS, deleting subordinate-ID files in a disposable task.

        `podman unshare` needs the host ID helpers, so files the inner engine
        created under other mapped IDs are removed by namespace root in a
        container of the outer engine instead.
        """
        remaining = []
        for path in map(Path, paths):
            try:
                shutil.rmtree(path)
            except FileNotFoundError:
                pass
            except OSError:
                remaining.append(path)
        if not remaining:
            return
        command = self.local + [
            "run",
            "--rm",
            "--network=none",
            "--cgroups=disabled",
            "--userns=keep-id:uid=1000,gid=1000",
            "--user=0:0",
            "--security-opt=label=disable",
        ]
        targets = []
        for index, path in enumerate(remaining):
            targets.append(f"/cleanup/{index}")
            command.extend(["--volume", f"{path}:{targets[-1]}:rw"])
        command.extend(
            [
                "--entrypoint=/bin/sh",
                self.expected_image,
                "-ec",
                'for d; do find "$d" -mindepth 1 -delete; done',
                "sh",
                *targets,
            ]
        )
        result = self.run(command, check=False)
        try:
            for path in remaining:
                shutil.rmtree(path)
        except OSError as error:
            raise RuntimeError(
                "Runtime state cleanup failed: "
                + str(error)
                + "\n"
                + result.stderr[-4000:]
            ) from error

    def stop(self):
        """Remove the runtime container, run state and cgroup.

        Images, volumes and writable storage are always retained.
        """
        if self.started:
            logs = self.run(self.local + ["logs", self.name], check=False)
            (self.directory / "runtime.log").write_text(
                logs.stdout + logs.stderr
            )
            removed = self.run(
                self.local + ["rm", "--force", "--ignore", self.name],
                check=False,
            )
            if removed.returncode:
                raise RuntimeError(
                    "Runtime removal failed; preserving its storage\n"
                    + removed.stderr[-4000:]
                )
        self.remove_run_state(
            [
                str(self.run_directory / name)
                for name in ("inner-run", "run", "api")
            ]
        )
        if self.cgroup is not None:
            remove_cgroup(self.cgroup)


RUNTIME_ID = re.compile("[0-9a-f]{32}")
# 4: the outer engine is the shared host service, not one per runtime.
SPEC_SCHEMA = 4


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
        "schema": SPEC_SCHEMA,
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

    def __init__(self, root, run_root, spec, image_reference, outer_url):
        self.spec = spec
        self.outer_url = outer_url
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
        return Engine(
            self.directory,
            self.run_directory,
            self.spec["podman"],
            self.outer_url,
            "contained-agent-runtime-" + self.key,
            self.image_reference,
            self.spec["image"],
            mounts,
            self.spec["storage_driver"],
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
            engine.local + ["inspect", engine.name],
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
        engine.stop()
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
            # Idle collection measures its grace period from the last exit.
            (self.directory / "last-detach").touch()
            self.lease.close()
            self.lease = None

    def stop_if_idle(self, grace):
        """Stop a runtime without sessions or running tasks for GRACE seconds.

        Never waits: a startup in progress or any session lease skips it.
        """
        with (
            (self.directory / "startup.lock").open("a+") as startup,
            (self.directory / "sessions.lock").open("a+") as lease,
        ):
            try:
                fcntl.flock(startup, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            ready = self.directory / "ready.json"
            try:
                if json.loads(ready.read_text()).get("boot") != self.boot:
                    return False
            except (OSError, ValueError):
                return False
            since = max(
                path.stat().st_mtime
                for path in (ready, self.directory / "last-detach")
                if path.exists()
            )
            if time.time() - since < grace:
                return False
            engine = self.engine()
            try:
                try:
                    tasks = engine.run(
                        engine.remote + ["ps", "--quiet"],
                        check=False,
                        timeout=15,
                    )
                    # Detached tasks keep the runtime; an unresponsive API
                    # does not.
                    if tasks.returncode == 0 and tasks.stdout.strip():
                        return False
                except subprocess.TimeoutExpired:
                    pass
                engine.prepare()
                self.stop_engine(engine)
            finally:
                engine.log.close()
            return True

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


CHECK_IMAGE = "docker.io/library/busybox:1.37"


def runtime_checks(engine):
    """Exercise the inner API as an agent would, yielding (name, check).

    Each check cleans up after itself; read-only mounts are probed without
    changing their contents even if the protection were missing.
    """
    remote, image = engine.remote, CHECK_IMAGE
    suffix = str(os.getpid())
    mounts = [(Path(m[0]), m[1], m[2]) for m in engine.mounts]

    def task(shell, *options, network="none"):
        return engine.run(
            remote
            + [
                "run",
                "--rm",
                "--network=" + network,
                "--cgroups=disabled",
                *options,
                image,
                "sh",
                "-ec",
                shell,
            ],
            timeout=120,
        )

    def build():
        tag = "localhost/contained-podman-check:" + suffix
        with tempfile.TemporaryDirectory() as context:
            # The server cannot read this host path; the client uploads it.
            Path(context, "payload").write_text("uploaded context\n")
            Path(context, "Dockerfile").write_text(
                f"FROM {image}\nCOPY payload /payload\n"
                "RUN printf 'built\\n' > /built\n"
            )
            try:
                engine.run(
                    remote
                    + ["build", "--network=none", "--tag=" + tag, context],
                    timeout=600,
                )
                engine.run(
                    remote
                    + [
                        "run",
                        "--rm",
                        "--network=none",
                        "--cgroups=disabled",
                        tag,
                        "sh",
                        "-ec",
                        'test "$(cat /payload)" = "uploaded context"; '
                        'test "$(cat /built)" = built',
                    ]
                )
            finally:
                engine.run(
                    remote + ["rmi", "--force", "--ignore", tag], check=False
                )

    def same_path_write():
        writable = [m for m in mounts if m[2] == "rw" and m[0].is_dir()]
        if not writable:
            return "skipped: no writable directory mount"
        source, target, _ = writable[0]
        probe = Path(
            tempfile.mkdtemp(prefix=".contained-podman-check-", dir=source)
        )
        path = target.rstrip("/") + "/" + probe.name
        try:
            task(
                "printf 'from task\\n' > " + shlex.quote(path + "/output"),
                "--volume",
                f"{path}:{path}",
            )
            if (probe / "output").read_text() != "from task\n":
                raise RuntimeError("Task output did not reach " + str(probe))
        finally:
            shutil.rmtree(probe)
        return path

    def read_only():
        protected = [m for m in mounts if m[2] == "ro" and m[0].exists()]
        if not protected:
            return "skipped: no read-only mount"
        script, options = [], []
        for source, target, _ in protected:
            quoted = shlex.quote(target)
            if source.is_dir():
                probe = shlex.quote(
                    target + "/.contained-podman-check-" + suffix
                )
                script.append(
                    f"if mkdir {probe} 2>/dev/null; then rmdir {probe}; "
                    f"echo 'writable: '{quoted} >&2; exit 31; fi"
                )
            else:
                # Opening for append changes nothing even if it succeeds.
                script.append(
                    f"if : >> {quoted} 2>/dev/null; then "
                    f"echo 'writable: '{quoted} >&2; exit 31; fi"
                )
            script.append(
                f"if mount -o remount,bind,rw {quoted} 2>/dev/null; then "
                f"echo 'remounted: '{quoted} >&2; exit 32; fi"
            )
            options += ["--volume", f"{target}:{target}"]
        # Default privileged tasks fail at sysfs creation; test the variant
        # with the runtime's read-only sysfs as well as ordinary tasks.
        for extra in ([], ["--privileged", "--volume", "/sys:/sys:ro"]):
            task("; ".join(script), *extra, *options)
        return f"{len(protected)} mount(s), ordinary and privileged"

    def root_isolation():
        # Binding / exposes the runtime's root, never the host's.
        hidden = shlex.quote("/runtime-root" + str(engine.directory.parent))
        task(f"test ! -e {hidden}", "--volume", "/:/runtime-root:ro")

    def network():
        name = "contained-podman-check-" + suffix
        web = name + "-web"
        engine.run(remote + ["network", "create", name])
        try:
            engine.run(
                remote
                + [
                    "run",
                    "--detach",
                    "--name=" + web,
                    "--network=" + name,
                    "--cgroups=disabled",
                    image,
                    "sh",
                    "-ec",
                    "mkdir /srv; echo network works > /srv/index.html; "
                    "exec httpd -f -p 8080 -h /srv",
                ]
            )
            # Compose relies on this: service names resolve on its network.
            result = task(
                "for i in 1 2 3 4 5 6 7 8 9 10; do "
                f"if wget -T 5 -q -O - http://{web}:8080/; then exit 0; fi; "
                "sleep 1; done; exit 1",
                network=name,
            )
            if result.stdout.strip() != "network works":
                raise RuntimeError("Unexpected response: " + result.stdout)
        finally:
            engine.run(remote + ["rm", "--force", "--ignore", web], check=False)
            engine.run(remote + ["network", "rm", "--force", name], check=False)

    def short_names():
        # Docker-style references in task definitions must not need a TTY.
        info = json.loads(engine.run(remote + ["info", "--format=json"]).stdout)
        search = info.get("registries", {}).get("search")
        if search != ["docker.io"]:
            raise RuntimeError("Short-name search registries: " + repr(search))

    def limits():
        # Check the kernel files, not the requested values.
        engine.run(
            remote
            + [
                "run",
                "--rm",
                "--network=none",
                "--cgroups=enabled",
                "--cgroupns=private",
                "--memory=128m",
                "--pids-limit=32",
                "--cpus=0.5",
                image,
                "sh",
                "-ec",
                'test "$(cat /sys/fs/cgroup/memory.max)" = 134217728; '
                'test "$(cat /sys/fs/cgroup/pids.max)" = 32; '
                "awk '{ if ($1 == \"max\" || $1 / $2 != 0.5) exit 1 }' "
                "/sys/fs/cgroup/cpu.max",
            ]
        )

    engine.run(remote + ["pull", image], timeout=900)
    yield from (
        ("short_name_search", short_names),
        ("build_uploaded_context", build),
        ("same_path_write", same_path_write),
        ("read_only_mounts", read_only),
        ("root_isolation", root_isolation),
        ("network_dns", network),
        ("cgroup_limits", limits),
    )


def check_main(manager):
    """Attach to a runtime, starting it if needed, and report each check."""
    with contextlib.redirect_stdout(sys.stderr):
        manager.attach()
    print("Runtime " + manager.key + ", log " + str(manager.directory))
    engine = manager.engine()
    failures = 0
    try:
        for name, check in runtime_checks(engine):
            try:
                note = check()
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                failures += 1
                print(f"FAIL {name}: {error}", flush=True)
            else:
                print(
                    f"PASS {name}" + (f" ({note})" if note else ""), flush=True
                )
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        failures += 1
        print("FAIL setup: " + str(error), flush=True)
    finally:
        engine.log.close()
        manager.detach()
    return 1 if failures else 0


def held_locks(path):
    """Count flock holders of PATH without taking, and so racing, its lock."""
    try:
        info = path.stat()
    except FileNotFoundError:
        return 0
    identity = "{:02x}:{:02x}:{}".format(
        os.major(info.st_dev), os.minor(info.st_dev), info.st_ino
    )
    with open("/proc/locks") as table:
        return sum(
            1
            for line in table
            if "->" not in line
            and line.split()[1:2] == ["FLOCK"]
            and line.split()[5:6] == [identity]
        )


def list_main(state_root, socket, podman):
    """Print one line per runtime; runtime IDs select podman-check/stop."""
    running = None
    if socket.exists():
        names = subprocess.run(
            [podman, "--remote", "--url", "unix://" + str(socket)]
            + ["ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if names.returncode == 0:
            running = set(names.stdout.split())
    rows = []
    for directory in sorted(state_root.iterdir()):
        if not RUNTIME_ID.fullmatch(directory.name):
            continue
        try:
            spec = json.loads((directory / "spec.json").read_text())
        except (OSError, ValueError):
            continue
        project = spec.get("project", "?")
        if spec.get("schema") != SPEC_SCHEMA:
            project += " (old schema)"
        if running is None:
            state = "unknown"
        elif "contained-agent-runtime-" + directory.name in running:
            state = "running"
        else:
            state = "stopped"
        sessions = held_locks(directory / "sessions.lock")
        sessions = f"{sessions} session(s)" if sessions else "idle"
        used = [
            path.stat().st_mtime
            for path in (directory / "last-detach", directory / "ready.json")
            if path.exists()
        ]
        rows.append(
            (
                max(used, default=0),
                [
                    directory.name,
                    state,
                    sessions,
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(max(used)))
                    if used
                    else "-",
                    project,
                    " ".join(
                        item["target"]
                        for item in spec.get("mounts", [])
                        if item.get("mode") == "rw"
                    ),
                ],
            )
        )
    header = ["ID", "STATE", "SESSIONS", "LAST USED", "PROJECT", "WRITABLE"]
    lines = [header] + [row for _, row in sorted(rows, reverse=True)]
    widths = [max(len(line[i]) for line in lines) for i in range(5)]
    for line in lines:
        print(
            "  ".join(cell.ljust(width) for cell, width in zip(line, widths))
            + "  "
            + line[5]
        )
    if running is None:
        print(
            "Host Podman service unreachable at " + str(socket), file=sys.stderr
        )
    return 0


def default_runtime_root():
    # Guix System's Paseo service creates this at boot. Unlike
    # XDG_RUNTIME_DIR, it exists before login and survives logout.
    system = Path("/run/contained-podman") / str(os.getuid())
    if system.is_dir():
        return system
    return (
        Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
        / "contained-podman"
    )


def host_socket(runtime_root):
    return runtime_root / "host" / "podman.sock"


def collect_idle(state_root, runtime_root, outer_url, grace):
    for directory in sorted(state_root.iterdir()):
        if not RUNTIME_ID.fullmatch(directory.name):
            continue
        try:
            spec = json.loads((directory / "spec.json").read_text())
            if spec.get("schema") != SPEC_SCHEMA:
                continue
            manager = SharedRuntime(
                state_root, runtime_root, spec, spec["image"], outer_url
            )
            if manager.key != directory.name:
                continue
            if manager.stop_if_idle(grace):
                print("Stopped idle runtime " + manager.key, flush=True)
        except FileNotFoundError:
            continue
        except (
            RuntimeError,
            OSError,
            ValueError,
            KeyError,
            subprocess.TimeoutExpired,
        ) as error:
            print(
                "Idle check failed for " + directory.name + ": " + str(error),
                flush=True,
            )


def host_service_main(args):
    """Serve the shared outer engine and stop idle project runtimes.

    Stopping this service leaves runtimes running; each is owned by its own
    conmon, as with any detached rootless container.
    """
    state = args.state_root / "host"
    run = args.runtime_root / "host"
    for path in (state, state / "home", run, run / "xdg"):
        private_directory(path)
    # Separate configuration, storage and pause process from the user's
    # ordinary Podman: prune or reset there never reaches project runtimes.
    (state / "containers.conf").write_text(
        '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n'
        '[containers]\ncgroups="enabled"\n'
    )
    (state / "storage.conf").write_text(
        '[storage]\ndriver="overlay"\ngraphroot='
        + json.dumps(str(state / "storage"))
        + "\nrunroot="
        + json.dumps(str(run / "storage"))
        + "\n"
    )
    env = {
        "PATH": "/run/privileged/bin:" + os.environ.get("PATH", ""),
        "HOME": str(state / "home"),
        "XDG_RUNTIME_DIR": str(run / "xdg"),
        "CONTAINERS_CONF": str(state / "containers.conf"),
        "CONTAINERS_STORAGE_CONF": str(state / "storage.conf"),
    }
    socket = host_socket(args.runtime_root)
    socket.unlink(missing_ok=True)
    service = subprocess.Popen(
        [
            args.podman,
            "--remote=false",
            "system",
            "service",
            "--time=0",
            "unix://" + str(socket),
        ],
        env=env,
    )
    stopping = []

    def stop(signum, _frame):
        stopping.append(signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    print("Host Podman service: " + str(socket), flush=True)
    collect_at = time.monotonic() + args.collect_interval
    try:
        while not stopping and service.poll() is None:
            time.sleep(1)
            if time.monotonic() >= collect_at and socket.exists():
                collect_idle(
                    args.state_root,
                    args.runtime_root,
                    "unix://" + str(socket),
                    args.idle_minutes * 60,
                )
                collect_at = time.monotonic() + args.collect_interval
    finally:
        if service.poll() is None:
            service.terminate()
            try:
                service.wait(timeout=30)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()
    return 0 if stopping else 1


def session_main():
    parser = argparse.ArgumentParser(
        description="Shared project Podman runtime"
    )
    parser.add_argument("--podman", required=True)
    parser.add_argument("--project")
    parser.add_argument(
        "--runtime-image",
        # Podman 5.8.7's manifest list: a tag would move once a fresh host
        # store has to pull it, failing the image ID check below.
        default="quay.io/podman/stable@sha256:"
        "2fb39ca923dd9e0ee33f9e319c3a107a2bfde022a6a31560cbd56a862821e7d3",
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
        "--runtime-root", type=Path, default=default_runtime_root()
    )
    parser.add_argument(
        "--host-service",
        action="store_true",
        help="Serve the shared outer engine and stop idle runtimes",
    )
    parser.add_argument(
        "--idle-minutes",
        type=float,
        default=30,
        help="Stop a runtime this long after its last session exits",
    )
    parser.add_argument(
        "--collect-interval", type=float, default=60, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--stop",
        metavar="RUNTIME_ID",
        help="Stop an idle runtime, retaining images and volumes",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List runtimes with their state, project and writable mounts",
    )
    parser.add_argument(
        "--check",
        metavar="RUNTIME_ID",
        help="Start or attach a runtime and exercise its API as an agent would",
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
    if args.host_service:
        return host_service_main(args)
    socket = host_socket(args.runtime_root)
    if args.list:
        return list_main(args.state_root, socket, args.podman)
    if not socket.exists():
        parser.error(
            "Host Podman service is not running ("
            + str(socket)
            + "); start it with `contained-agent podman-service`"
        )
    outer_url = "unix://" + str(socket)
    if args.stop or args.check:
        runtime_id = args.stop or args.check
        if not RUNTIME_ID.fullmatch(runtime_id):
            parser.error("Invalid runtime ID")
        spec = json.loads(
            (args.state_root / runtime_id / "spec.json").read_text()
        )
        if runtime_key(spec) != runtime_id:
            parser.error("Stored runtime policy does not match its ID")
        manager = SharedRuntime(
            args.state_root,
            args.runtime_root,
            spec,
            args.runtime_image,
            outer_url,
        )
        if args.check:
            return check_main(manager)
        try:
            with contextlib.redirect_stdout(sys.stderr):
                manager.stop()
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            print("contained-agent runtime: " + str(error), file=sys.stderr)
            return 1
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
        args.state_root, args.runtime_root, spec, args.runtime_image, outer_url
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
    sys.exit(session_main())
