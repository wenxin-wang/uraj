#!/usr/bin/env python3
"""Probe a Docker-hosted rootless Podman engine for OpenClaw sandboxes.

Run on storie as a docker-group user whose UID matches the engine image's
podman user (1000).  It creates only disposable containers named
openclaw-engine-probe-*, and files below /var/tmp/openclaw-engine-*.
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "container_seccomp", ROOT / "src/python/uraj/container/seccomp.py"
)
_SECCOMP = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_SECCOMP)

SOCKET_DIRECTORY = "/run/openclaw-engine"
# Without a Docker user namespace these become real host UIDs/GIDs.  Keep
# them away from host accounts and from the main user's own subordinate IDs.
SUBORDINATE_START = 524288
SUBORDINATE_COUNT = 65536
# The arguments OpenClaw v2026.10.6 passes for a rootless Podman sandbox
# (docker.ts buildSandboxCreateArgs plus podman-runtime.ts extras).
SANDBOX_ARGS = [
    "--init",
    "--read-only",
    "--read-only-tmpfs=true",
    "--tmpfs=/tmp",
    "--tmpfs=/var/tmp",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--http-proxy=false",
]


class Probe:
    def __init__(self, args, directory):
        self.args = args
        self.directory = directory
        self.suffix = directory.name.rsplit("-", 1)[-1]
        self.engine = "openclaw-engine-probe-" + self.suffix
        self.uid = os.getuid()
        self.gid = os.getgid()
        self.results = {}
        self.log = (directory / "commands.log").open("w")

    def run(self, command, timeout=180, check=True):
        self.log.write("\n" + json.dumps(command) + "\n")
        self.log.flush()
        result = subprocess.run(
            command,
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
                f"Command failed ({result.returncode}): {json.dumps(command)}\n"
                + result.stdout[-2000:]
                + result.stderr[-2000:]
            )
        return result

    def path(self, name):
        return self.directory / name

    def prepare(self):
        for name in ("api", "run", "storage", "shared", "protected"):
            self.path(name).mkdir(mode=0o700)
        self.path("unshared-secret").write_text("not exposed\n")
        self.path("protected/sentinel").write_text("original\n")
        self.path("shared/from-host").write_text("host\n")
        self.path("shared/escape").symlink_to(self.path("unshared-secret"))
        ids = f"podman:{SUBORDINATE_START}:{SUBORDINATE_COUNT}\n"
        self.path("subuid").write_text(ids)
        self.path("subgid").write_text(ids)
        storage = self.args.storage
        options = ""
        if storage == "fuse-overlayfs":
            storage = "overlay"
            options = (
                '\n[storage.options.overlay]\nmount_program="/usr/bin/'
                'fuse-overlayfs"\n'
            )
        self.path("storage.conf").write_text(
            f'[storage]\ndriver="{storage}"\n'
            'graphroot="/home/podman/.local/share/containers/storage"\n'
            f'runroot="/run/user/{self.uid}/storage"\n' + options
        )
        # Docker mounts cgroup2 read-only; per-sandbox limits stay out of
        # scope.  The engine container's own limits apply to all sandboxes.
        self.path("containers.conf").write_text(
            '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n'
            '[containers]\ncgroups="disabled"\n'
        )

    def seccomp_option(self):
        if self.args.seccomp == "default":
            return []
        if self.args.seccomp == "unconfined":
            return ["--security-opt=seccomp=unconfined"]
        source = self.run(
            [
                "docker",
                "run",
                "--rm",
                "--network=none",
                "--entrypoint=/bin/cat",
                self.args.engine_image,
                "/usr/share/containers/seccomp.json",
            ]
        ).stdout
        self.path("seccomp-base.json").write_text(source)
        profile = _SECCOMP.nested_seccomp(json.loads(source))
        target = self.path("seccomp-nested.json")
        target.write_text(json.dumps(profile, indent=2) + "\n")
        return ["--security-opt=seccomp=" + str(target)]

    def dns_options(self):
        resolver = Path("/run/restricted-network/resolv.conf")
        if self.args.network == "none" or not resolver.exists():
            return []
        return [
            "--dns=" + line.split()[1]
            for line in resolver.read_text().splitlines()
            if line.startswith("nameserver ")
        ]

    def start_engine(self):
        if self.uid != 1000:
            raise RuntimeError("Run as UID 1000 to match the image's podman")
        self.run(["docker", "pull", self.args.engine_image], timeout=900)
        image = self.run(
            [
                "docker",
                "image",
                "inspect",
                "--format={{.Id}}",
                self.args.engine_image,
            ]
        ).stdout.strip()
        self.results["engine_image"] = image
        mounts = [
            (self.path("api"), SOCKET_DIRECTORY, "rw"),
            (self.path("run"), f"/run/user/{self.uid}", "rw"),
            (
                self.path("storage"),
                "/home/podman/.local/share/containers",
                "rw",
            ),
            (self.path("shared"), self.path("shared"), "rw"),
            (self.path("protected"), self.path("shared/readonly"), "ro"),
            (self.path("subuid"), "/etc/subuid", "ro"),
            (self.path("subgid"), "/etc/subgid", "ro"),
            (self.path("containers.conf"), "/etc/containers/probe.conf", "ro"),
            (
                self.path("storage.conf"),
                "/etc/containers/probe-storage.conf",
                "ro",
            ),
        ]
        command = [
            "docker",
            "run",
            "--detach",
            "--name=" + self.engine,
            f"--user={self.uid}:{self.gid}",
            "--cap-drop=ALL",
            *("--cap-add=" + cap for cap in self.args.cap_add),
            *self.seccomp_option(),
            *(
                ["--security-opt=systempaths=unconfined"]
                if self.args.unmask
                else []
            ),
            "--network=" + self.args.network,
            *self.dns_options(),
            "--memory=2g",
            "--pids-limit=1024",
            "--env=HOME=/home/podman",
            f"--env=XDG_RUNTIME_DIR=/run/user/{self.uid}",
            "--env=CONTAINERS_CONF=/etc/containers/probe.conf",
            "--env=CONTAINERS_STORAGE_CONF=/etc/containers/probe-storage.conf",
        ]
        for device in ("/dev/fuse", "/dev/net/tun"):
            if Path(device).exists():
                command.append("--device=" + device)
            else:
                self.results["missing_" + Path(device).name] = True
        for source, target, mode in mounts:
            command.append(f"--volume={source}:{target}:{mode}")
        command += [
            "--entrypoint=/bin/sh",
            self.args.engine_image,
            "-ec",
            f'test "$(id -u)" = {self.uid}; exec podman system service '
            f"--time=0 unix://{SOCKET_DIRECTORY}/podman.sock",
        ]
        self.run(command)
        status = self.run(
            [
                "docker",
                "exec",
                self.engine,
                "grep",
                "-E",
                "^(Cap|Seccomp|NoNew)",
                "/proc/1/status",
            ],
            check=False,
        )
        self.results["engine_process_status"] = status.stdout.strip()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if self.path("api/podman.sock").exists():
                return
            time.sleep(1)
        logs = self.run(["docker", "logs", self.engine], check=False)
        raise RuntimeError("Engine socket did not appear\n" + logs.stderr)

    def client(self, *podman_args, timeout=180, check=True):
        """Run podman like the hardened Gateway would."""
        return self.run(
            [
                "docker",
                "run",
                "--rm",
                f"--user={self.uid}:{self.gid}",
                "--read-only",
                "--tmpfs=/tmp",
                "--cap-drop=ALL",
                "--security-opt=no-new-privileges",
                "--network=none",
                "--env=HOME=/tmp",
                f"--env=CONTAINER_HOST=unix://{SOCKET_DIRECTORY}/podman.sock",
                f"--volume={self.path('api')}:{SOCKET_DIRECTORY}:rw",
                "--entrypoint=podman",
                self.args.engine_image,
                *podman_args,
            ],
            timeout=timeout,
            check=check,
        )

    def check(self, name, function):
        try:
            value = function()
            self.results[name] = "PASS" if value is None else value
        except Exception as error:  # Report every check.
            self.results[name] = "FAIL: " + str(error)[-1500:]

    def sandbox_exec(self, script, check=True):
        return self.client(
            "exec", "-i", "probe-sandbox", "/bin/sh", "-lc", script, check=check
        )

    def create_sandbox(self):
        shared = str(self.path("shared"))
        self.client(
            "create",
            "--name=probe-sandbox",
            *SANDBOX_ARGS,
            "--network=" + self.args.sandbox_network,
            f"--user={self.uid}:{self.gid}",
            f"--userns=keep-id:uid={self.uid},gid={self.gid}",
            "--workdir=" + shared,
            f"--volume={shared}:{shared}:z",
            self.args.task_image,
            "sleep",
            "infinity",
            timeout=900,
        )
        self.client("start", "probe-sandbox")
        identity = self.sandbox_exec("id -u; id -g").stdout.split()
        if identity != [str(self.uid), str(self.gid)]:
            raise RuntimeError("Unexpected sandbox identity " + str(identity))

    def same_path(self):
        shared = self.path("shared")
        self.sandbox_exec(
            f"grep -qx host {shared}/from-host; "
            f"echo sandbox > {shared}/from-sandbox"
        )
        written = shared / "from-sandbox"
        if written.read_text() != "sandbox\n":
            raise RuntimeError("Sandbox write not visible on the host")
        if written.stat().st_uid != self.uid:
            raise RuntimeError(f"Owner is {written.stat().st_uid}")

    def isolation(self):
        shared = self.path("shared")
        self.sandbox_exec(
            f"! cat {shared}/escape 2>/dev/null; "
            f"! test -e {self.path('unshared-secret')}; "
            f"grep -qx original {shared}/readonly/sentinel; "
            f"! touch {shared}/readonly/x 2>/dev/null"
        )

    def init_process(self):
        return self.sandbox_exec("cat /proc/1/comm").stdout.strip()

    def egress(self, url, expect):
        result = self.sandbox_exec(
            f"wget -q -T 8 -O /dev/null {url} && echo open || echo closed",
            check=False,
        )
        state = result.stdout.strip().splitlines()[-1:] or ["error"]
        if state[0] != expect:
            raise RuntimeError(f"{url}: {state[0]}, expected {expect}")

    def root_bind(self):
        """A Gateway may request any bind; only the engine's view exists."""
        result = self.client(
            "run",
            "--rm",
            "--network=none",
            "--volume=/:/host:ro",
            self.args.task_image,
            "sh",
            "-c",
            f"test -e /host{self.path('unshared-secret')} && echo leaked "
            "|| echo hidden",
            check=False,
        )
        return result.stdout.strip() or "FAIL: " + result.stderr[-500:]

    def same_bridge_gateway(self):
        address = self.run(
            [
                "docker",
                "inspect",
                "--format",
                "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                "openclaw-gateway-1",
            ],
            check=False,
        ).stdout.strip()
        if not address:
            return "SKIP: Gateway is not running"
        result = self.sandbox_exec(
            f"wget -q -T 5 -O /dev/null http://{address}:18789/startupz "
            "&& echo open || echo closed",
            check=False,
        )
        return result.stdout.strip()

    def cleanup(self):
        if self.args.keep:
            return
        self.run(
            [
                "docker",
                "exec",
                self.engine,
                "podman",
                "system",
                "reset",
                "--force",
            ],
            timeout=300,
            check=False,
        )
        result = self.run(["docker", "rm", "--force", self.engine], check=False)
        self.results["cleanup"] = (
            "PASS" if result.returncode == 0 else result.stderr.strip()
        )

    def execute(self):
        self.prepare()
        try:
            self.start_engine()
            info = self.client(
                "info",
                "--format={{.Host.Security.Rootless}}\t"
                "{{.Host.ServiceIsRemote}}\t{{.Version.Version}}",
            ).stdout.split()
            self.results["client_info"] = info
            if info[:2] != ["true", "true"]:
                raise RuntimeError("Engine must be rootless and remote")
            self.check("sandbox_create", self.create_sandbox)
            if self.results["sandbox_create"] != "PASS":
                return
            self.check("same_path_write", self.same_path)
            self.check("isolation", self.isolation)
            self.check("init_process", self.init_process)
            self.check("root_bind", self.root_bind)
            if self.args.sandbox_network != "none":
                self.check(
                    "egress_allowed",
                    lambda: self.egress(self.args.allowed_url, "open"),
                )
                self.check(
                    "egress_blocked",
                    lambda: self.egress(self.args.blocked_url, "closed"),
                )
                self.check("same_bridge_gateway", self.same_bridge_gateway)
        except Exception as error:  # Keep results.
            self.results["error"] = str(error)[-3000:]
        finally:
            self.cleanup()
            self.path("results.json").write_text(
                json.dumps(self.results, indent=2) + "\n"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-image", default="quay.io/podman/stable")
    parser.add_argument("--task-image", default="docker.io/library/alpine:3.21")
    parser.add_argument(
        "--seccomp",
        choices=("nested", "default", "unconfined"),
        default="nested",
    )
    parser.add_argument(
        "--cap-add",
        action="append",
        default=None,
        help="Engine capability; repeat (default: SETUID and SETGID)",
    )
    parser.add_argument(
        "--no-unmask",
        dest="unmask",
        action="store_false",
        help="Keep Docker's masked /proc paths",
    )
    parser.add_argument(
        "--storage",
        choices=("vfs", "overlay", "fuse-overlayfs"),
        default="vfs",
    )
    parser.add_argument("--network", default="static-agent")
    parser.add_argument("--sandbox-network", default="pasta")
    parser.add_argument("--allowed-url", default="https://example.com/")
    parser.add_argument("--blocked-url", default="http://172.31.0.6:2283/")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    if args.cap_add is None:
        args.cap_add = ["SETUID", "SETGID"]
    directory = Path(
        tempfile.mkdtemp(prefix="openclaw-engine-", dir="/var/tmp")
    )
    probe = Probe(args, directory)
    probe.execute()
    print(json.dumps(probe.results, indent=2))
    print("Results:", directory)
    failed = any(
        isinstance(value, str) and value.startswith("FAIL")
        for value in probe.results.values()
    )
    return 1 if failed or "error" in probe.results else 0


if __name__ == "__main__":
    sys.exit(main())
