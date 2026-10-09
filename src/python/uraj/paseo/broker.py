"""Local Paseo provider execution broker. Linux, Python 3.9+, no dependencies.

Only the server CLI chooses the launcher and roots. Requests select a provider,
not a host executable or sandbox flags. Pair with paseo-agent-supervisor.
"""

import argparse
import array
import fcntl
import json
import os
import pathlib
import pwd
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

MAX_MESSAGE = 65536
# Trusted broker environment for host-side SSH unlocking.  Do not add these
# to ENV: a client must not choose a host executable through SSH_ASKPASS.
HOST_SETUP_ENVIRONMENT = frozenset(
    {
        "PATH",
        "USER",
        "LOGNAME",
        "LANG",
        "GUIX_LOCPATH",
        "SSL_CERT_FILE",
        "SSH_ASKPASS",
        "SSH_ASKPASS_REQUIRE",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XAUTHORITY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
    }
)
ENV = re.compile(
    r"(?:OPENAI_.*|ANTHROPIC_.*|CODEX_.*|CLAUDE_.*|PASEO_AGENT_ID|"
    r"PASEO_AGENT_CWD|TERM|COLORTERM|LANG|LC_.*|NO_COLOR|RUST_LOG)\Z"
)


def encode_control_message(message):
    """Encode one JSON packet within the protocol size limit."""
    data = json.dumps(message, separators=(",", ":")).encode()
    if len(data) > MAX_MESSAGE:
        raise ValueError("control message too large")
    return data


def send_control_reply(connection, message):
    """Send a reply if the client can still receive it."""
    try:
        connection.send(encode_control_message(message))
    except (BrokenPipeError, ConnectionError, BlockingIOError):
        pass


def default_runtime_directory():
    """Return the per-user broker runtime directory."""
    if directory := os.environ.get("PASEO_BROKER_DIRECTORY"):
        return pathlib.Path(directory)
    return pathlib.Path.home() / ".local/state/paseo-broker"


def launcher_environment(home, forwarded):
    """Build host setup environment from broker settings and validated input.

    Desktop and askpass settings come only from the broker.  The contained-agent
    launcher applies its separate environment policy when entering the sandbox.
    """
    env = {
        k: v
        for k, v in os.environ.items()
        if k in HOST_SETUP_ENVIRONMENT or ENV.fullmatch(k)
    }
    env.update(forwarded)
    env["HOME"] = str(home)
    env.setdefault("PATH", "/run/current-system/profile/bin")
    return env


def namespace_has_exited(path, timeout=0):
    """Check the exact namespace init, including after its helper was killed."""
    path = pathlib.Path(path)
    boot = path / "boot-id"
    if (
        boot.exists()
        and boot.read_text()
        != pathlib.Path("/proc/sys/kernel/random/boot_id").read_text()
    ):
        return True
    identity = path / "namespace.stat"
    if identity.exists():
        original = identity.read_text()
        pid = int(original.split(" ", 1)[0])
        started = original.rsplit(")", 1)[1].split()[19]
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            fd = None
        if fd is not None:
            try:
                try:
                    current = pathlib.Path(f"/proc/{pid}/stat").read_text()
                except FileNotFoundError:
                    current = ""
                if current and current.rsplit(")", 1)[1].split()[19] == started:
                    ready, _, _ = select.select([fd], [], [], timeout)
                    return bool(ready)
            finally:
                os.close(fd)
    return True


def execution_directory(parent, prefix="execution-"):
    """Record the boot before any process can run in persistent runtime state."""
    path = pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=parent))
    (path / "boot-id").write_text(
        pathlib.Path("/proc/sys/kernel/random/boot_id").read_text()
    )
    return path


def wait_for_old_execution_and_remove_directory(path):
    """On broker restart, wait for old processes before deleting their runtime files.

    Refuse startup if teardown is still pending; never discard its identity record.
    """
    if not namespace_has_exited(path, timeout=10):
        raise ValueError(
            "old execution has not finished teardown; refusing startup"
        )
    # No record means the init launch gate could not have released a workload.
    shutil.rmtree(path)


def receive_control_message_and_fds(connection):
    """Receive a control packet and take ownership of its descriptors."""
    data, ancillary, flags, _ = connection.recvmsg(
        MAX_MESSAGE, socket.CMSG_SPACE(16 * 4), socket.MSG_CMSG_CLOEXEC
    )
    fds = []
    try:
        for level, kind, value in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                items = array.array("i")
                items.frombytes(
                    value[: len(value) - len(value) % items.itemsize]
                )
                fds.extend(items)
        if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
            raise ValueError("truncated request")
        if not data:
            raise EOFError()
        message = json.loads(data)
        if not isinstance(message, dict):
            raise ValueError("expected object")
        return message, fds
    except BaseException:
        for fd in fds:
            os.close(fd)
        raise


def validate_start_request(message, roots, home):
    """Validate provider, arguments, environment, and authorized working directory."""
    if message.get("version") != 1 or message.get("type") != "start":
        raise ValueError("unsupported request")
    provider = message.get("provider")
    if provider not in ("codex", "claude"):
        raise ValueError("unknown provider")
    argv = message.get("argv")
    if (
        not isinstance(argv, list)
        or len(argv) > 1024
        or any(not isinstance(a, str) or "\0" in a for a in argv)
    ):
        raise ValueError("invalid argv")
    env = message.get("env", {})
    if not isinstance(env, dict) or any(
        not isinstance(k, str)
        or not ENV.fullmatch(k)
        or not isinstance(v, str)
        or "\0" in v
        for k, v in env.items()
    ):
        raise ValueError("invalid environment")
    cwd = message.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        raise ValueError("absolute cwd required")
    cwd = pathlib.Path(cwd).resolve(strict=True)
    if not cwd.is_dir():
        raise ValueError("cwd is not a directory")
    if cwd == pathlib.Path("/"):
        cwd = home
    if cwd != home and not any(cwd == r or r in cwd.parents for r in roots):
        raise ValueError("cwd outside authorized roots")
    env["PASEO_AGENT_CWD"] = str(cwd)
    agent_id = env.get("PASEO_AGENT_ID", "")
    if len(agent_id) > 256:
        raise ValueError("invalid agent id")
    probe = argv == ["--version"] or argv == ["auth", "status"]
    key = (provider, agent_id) if agent_id and not probe else None
    return provider, argv, cwd, env, key


class SharedSSHPreparation:
    """Serialize SSH preparation in a namespace owned by the broker, not a job.

    The service keeps per-project SSH agents alive between executions.  Its
    supervisor's parent-death link cleans all agents if the broker dies.
    """

    def __init__(self, args, home, owner):
        """Start the trusted launcher in shared SSH service mode."""
        # Keep project sockets below sun_path's 107-byte limit with the
        # persistent ~/.local/state/paseo-broker base directory. This private
        # tree also holds the supervisor identity used for safe cleanup.
        self.directory = execution_directory(args.directory, "ssh-")
        self.runtime = self.directory
        env = launcher_environment(home, {})
        env["TMPDIR"] = str(self.directory)
        env["CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY"] = str(self.runtime)
        self.process = subprocess.Popen(
            [
                args.supervisor,
                "--owner-fd",
                str(owner),
                "--",
                args.launcher,
                "ssh-service",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env,
            pass_fds=(owner,),
        )
        os.set_blocking(self.process.stdout.fileno(), False)
        self.pending = None
        self.buffer = bytearray()

    def prepare(self, job):
        """Submit one validated working directory when the service is idle."""
        if self.pending is not None:
            return
        self.process.stdin.write(os.fsencode(job["request"][2]) + b"\0")
        self.process.stdin.flush()
        self.pending = job

    def poll(self):
        """Collect a completed preparation without blocking the broker loop."""
        if self.process.poll() is not None:
            raise ValueError(
                "shared SSH service exited; restart broker when safe"
            )
        try:
            data = os.read(self.process.stdout.fileno(), MAX_MESSAGE)
        except BlockingIOError:
            return
        if not data:
            raise ValueError("shared SSH service disconnected")
        self.buffer.extend(data)
        if len(self.buffer) > MAX_MESSAGE:
            raise ValueError("shared SSH service reply too large")
        if self.buffer.count(0) < 2:
            return
        status, message, remaining = bytes(self.buffer).split(b"\0", 2)
        if remaining or self.pending is None or status not in (b"ok", b"error"):
            raise ValueError("invalid shared SSH service reply")
        self.pending["ssh_ready"] = status == b"ok"
        if status == b"error":
            self.pending["ssh_error"] = message.decode(errors="replace")
        self.pending = None
        self.buffer.clear()

    def close(self):
        """Stop shared agents after session cleanup, retaining pending records."""
        self.process.kill()
        self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        if namespace_has_exited(self.directory, timeout=10):
            shutil.rmtree(self.directory)


class BrokerServer:
    """Own provider execution lifetimes and their control connections."""

    def __init__(self, args):
        """Recover old executions and open the private broker listener."""
        self.args = args
        self.home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        self.roots = [pathlib.Path(r).expanduser().resolve() for r in args.root]
        self.directory = pathlib.Path(args.directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        st = self.directory.lstat()
        if (
            self.directory.is_symlink()
            or st.st_uid != os.getuid()
            or st.st_mode & 0o077
        ):
            raise ValueError(
                "runtime directory must be owned by this user and mode 0700"
            )
        self.lock = open(self.directory / "lock", "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Restart cleans host-side setup artifacts after kernel process teardown.
        for pattern in ("execution-*", "ssh-*"):
            for path in self.directory.glob(pattern):
                wait_for_old_execution_and_remove_directory(path)
        # Only this directory is exposed to the Paseo container. Execution
        # records and shared SSH material stay outside its mount namespace.
        socket_directory = self.directory / "connection"
        socket_directory.mkdir(mode=0o700, exist_ok=True)
        socket_stat = socket_directory.lstat()
        if (
            socket_directory.is_symlink()
            or socket_stat.st_uid != os.getuid()
            or socket_stat.st_mode & 0o077
        ):
            raise ValueError("socket directory must be private and user-owned")
        self.path = socket_directory / "socket"
        self.path.unlink(missing_ok=True)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.listener.bind(str(self.path))
        os.chmod(self.path, 0o600)
        self.listener.listen(32)
        self.listener.setblocking(False)
        self.owner = os.pidfd_open(os.getpid())
        self.clients = {}
        self.stopping = False
        self.ssh_preparation = None

    def request_execution_stop(self, job):
        """Request graceful termination and set a forced-stop deadline."""
        if job.get("process") and not job.get("deadline"):
            try:
                job["process"].terminate()
            except ProcessLookupError:
                pass
            job["deadline"] = time.monotonic() + 5

    def launch_execution(self, connection, job):
        """Start the supervised launcher with the received standard streams."""
        provider, argv, cwd, forwarded, _ = job["request"]
        env = launcher_environment(self.home, forwarded)
        if self.ssh_preparation is not None:
            env["CONTAINED_AGENT_SSH_PREPARED"] = "1"
            env["CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY"] = str(
                self.ssh_preparation.runtime
            )
        temporary = str(execution_directory(self.directory))
        env["TMPDIR"] = temporary
        job["temporary"] = temporary
        fds = job.pop("fds")
        try:
            job["process"] = subprocess.Popen(
                [
                    self.args.supervisor,
                    "--owner-fd",
                    str(self.owner),
                    "--",
                    self.args.launcher,
                    provider,
                    *argv,
                ],
                cwd=cwd,
                env=env,
                stdin=fds[0],
                stdout=fds[1],
                stderr=fds[2],
                pass_fds=(self.owner,),
            )
        finally:
            for fd in fds:
                os.close(fd)
        job["id"] = uuid.uuid4().hex
        send_control_reply(connection, {"type": "started", "id": job["id"]})

    def close_client_and_release_resources(self, connection):
        """Release the connection and FDs; preserve files if teardown is pending."""
        job = self.clients.pop(connection)
        for fd in job.get("fds", []):
            os.close(fd)
        if job.get("temporary") and namespace_has_exited(job["temporary"]):
            shutil.rmtree(job["temporary"])
        connection.close()

    def run_event_loop(self):
        """Serve clients until shutdown and owned execution cleanup complete."""

        def request_shutdown(_sig, _frame):
            self.stopping = True

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, request_shutdown)
        try:
            while not self.stopping or self.clients:
                if self.ssh_preparation is not None:
                    self.ssh_preparation.poll()
                for connection, job in list(self.clients.items()):
                    process = job.get("process")
                    if process and process.poll() is not None:
                        if not namespace_has_exited(job["temporary"]):
                            since = job.setdefault(
                                "cleanup_pending", time.monotonic()
                            )
                            if time.monotonic() - since > 10 and not job.get(
                                "cleanup_failed"
                            ):
                                job["cleanup_failed"] = True
                                send_control_reply(
                                    connection,
                                    {
                                        "type": "error",
                                        "message": "namespace teardown incomplete; execution retained",
                                    },
                                )
                            continue
                        send_control_reply(
                            connection,
                            {
                                "type": "exited",
                                "returncode": process.returncode,
                            },
                        )
                        self.close_client_and_release_resources(connection)
                        continue
                    if self.stopping:
                        if process:
                            self.request_execution_stop(job)
                        else:
                            self.close_client_and_release_resources(connection)
                            continue
                    if (
                        job.get("deadline")
                        and time.monotonic() > job["deadline"]
                    ):
                        # Killing the helper activates init's own parent-death link.
                        process.kill()
                    if (
                        not process
                        and not job.get("ssh_waiting")
                        and time.monotonic() - job["accepted"] > 30
                    ):
                        send_control_reply(
                            connection,
                            {
                                "type": "error",
                                "message": "launch/cleanup wait timed out",
                            },
                        )
                        self.close_client_and_release_resources(connection)
                active = {
                    j["request"][4]
                    for j in self.clients.values()
                    if j.get("process") and j["request"][4]
                }
                for connection, job in list(self.clients.items()):
                    if "request" in job and not job.get("process"):
                        key = job["request"][4]
                        if not key or key not in active:
                            try:
                                if self.args.shared_ssh:
                                    _, argv, cwd, _, _ = job["request"]
                                    needs_ssh = (
                                        cwd != self.home
                                        and argv
                                        not in (
                                            ["--version"],
                                            ["auth", "status"],
                                        )
                                    )
                                    if needs_ssh and not job.get("ssh_ready"):
                                        if job.get("ssh_error"):
                                            raise ValueError(job["ssh_error"])
                                        job["ssh_waiting"] = True
                                        if self.ssh_preparation is None:
                                            self.ssh_preparation = (
                                                SharedSSHPreparation(
                                                    self.args,
                                                    self.home,
                                                    self.owner,
                                                )
                                            )
                                        self.ssh_preparation.prepare(job)
                                        continue
                                    if job.pop("ssh_waiting", False):
                                        job["accepted"] = time.monotonic()
                                self.launch_execution(connection, job)
                                if key:
                                    active.add(key)
                            except (OSError, ValueError) as error:
                                send_control_reply(
                                    connection,
                                    {"type": "error", "message": str(error)},
                                )
                                self.close_client_and_release_resources(
                                    connection
                                )
                watches = [
                    c
                    for c, j in self.clients.items()
                    if not j.get("disconnected")
                ]
                if not self.stopping:
                    watches.append(self.listener)
                ready, _, _ = select.select(watches, [], [], 0.05)
                for connection in ready:
                    if connection is self.listener:
                        peer, _ = self.listener.accept()
                        _, uid, _ = struct.unpack(
                            "3i",
                            peer.getsockopt(
                                socket.SOL_SOCKET, socket.SO_PEERCRED, 12
                            ),
                        )
                        if uid != os.getuid() or len(self.clients) >= 64:
                            peer.close()
                        else:
                            peer.setblocking(False)
                            self.clients[peer] = {"accepted": time.monotonic()}
                        continue
                    job = self.clients[connection]
                    try:
                        message, fds = receive_control_message_and_fds(
                            connection
                        )
                        try:
                            if "request" in job:
                                if fds or message != {"type": "terminate"}:
                                    raise ValueError("expected terminate")
                                if job.get("process"):
                                    self.request_execution_stop(job)
                                else:
                                    self.close_client_and_release_resources(
                                        connection
                                    )
                            else:
                                if (
                                    message == {"version": 1, "type": "status"}
                                    and not fds
                                ):
                                    send_control_reply(
                                        connection,
                                        {
                                            "type": "status",
                                            "ssh_preparation": (
                                                "unlocking"
                                                if self.ssh_preparation.pending
                                                is not None
                                                else "ready"
                                            )
                                            if self.ssh_preparation is not None
                                            else "not-started",
                                            "executions": [
                                                {
                                                    "id": j.get("id"),
                                                    "provider": j["request"][0],
                                                    "cwd": str(j["request"][2]),
                                                    "pid": j["process"].pid
                                                    if j.get("process")
                                                    else None,
                                                    "cleanup_failed": bool(
                                                        j.get("cleanup_failed")
                                                    ),
                                                    "stopping": bool(
                                                        j.get("deadline")
                                                    ),
                                                }
                                                for j in self.clients.values()
                                                if "request" in j
                                            ],
                                        },
                                    )
                                    self.close_client_and_release_resources(
                                        connection
                                    )
                                    continue
                                if len(fds) != 3:
                                    raise ValueError(
                                        "exactly three standard descriptors required"
                                    )
                                job["request"] = validate_start_request(
                                    message, self.roots, self.home
                                )
                                job["fds"] = fds
                                fds = []
                        finally:
                            for fd in fds:
                                os.close(fd)
                    except (EOFError, OSError, ValueError) as error:
                        send_control_reply(
                            connection, {"type": "error", "message": str(error)}
                        )
                        if job.get("process"):
                            self.request_execution_stop(job)
                            # Avoid repeatedly polling a disconnected socket.
                            job["disconnected"] = True
                        else:
                            self.close_client_and_release_resources(connection)
        finally:
            # On an internal exception do not orphan the owned namespaces.
            for job in self.clients.values():
                if job.get("process"):
                    job["process"].kill()
            for job in self.clients.values():
                if job.get("process"):
                    job["process"].wait()
            for connection in list(self.clients):
                self.close_client_and_release_resources(connection)
            if self.ssh_preparation is not None:
                self.ssh_preparation.close()
            self.listener.close()
            self.path.unlink(missing_ok=True)
            os.close(self.owner)


def run_provider_client(args):
    """Pass standard streams to the broker and await execution cleanup."""
    parent = os.getppid()
    if parent <= 1:
        raise ValueError("provider client has no live parent")
    parent_fd = os.pidfd_open(parent)
    if os.getppid() != parent:
        raise ValueError("provider client parent changed during startup")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    connection.settimeout(5)
    connection.connect(str(pathlib.Path(args.directory) / "connection/socket"))
    forwarded = {k: v for k, v in os.environ.items() if ENV.fullmatch(k)}
    message = {
        "version": 1,
        "type": "start",
        "provider": args.provider,
        "argv": args.arguments,
        "env": forwarded,
        "cwd": forwarded.get("PASEO_AGENT_CWD") or os.getcwd(),
    }
    connection.sendmsg(
        [encode_control_message(message)],
        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [0, 1, 2]))],
    )
    stopping = False

    def request_shutdown(_sig, _frame):
        nonlocal stopping
        stopping = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, request_shutdown)
    sent = False
    while True:
        ready, _, _ = select.select([connection, parent_fd], [], [], 0.1)
        if parent_fd in ready:
            stopping = True
        if stopping and not sent:
            connection.send(encode_control_message({"type": "terminate"}))
            sent = True
        if connection not in ready:
            continue
        data = connection.recv(MAX_MESSAGE)
        if not data:
            raise ValueError(
                "broker disconnected before execution cleanup acknowledgement"
            )
        result = json.loads(data)
        if result["type"] == "error":
            raise ValueError(result["message"])
        if result["type"] == "exited":
            code = result["returncode"]
            connection.close()
            os.close(parent_fd)
            if code < 0:
                if -code not in (signal.SIGKILL, signal.SIGSTOP):
                    signal.signal(-code, signal.SIG_DFL)
                os.kill(os.getpid(), -code)
            return code


def configure_paseo_provider_commands(args):
    """Explicit host-side switch; preserve settings and keep a private backup."""
    config = pathlib.Path(args.config).expanduser()
    if config.is_symlink():
        raise ValueError(
            "Paseo config is a symlink; edit its managed source instead"
        )
    original = (
        config.read_bytes()
    )  # Missing configuration is not a new installation.
    settings = json.loads(original)
    providers = settings.setdefault("agents", {}).setdefault("providers", {})
    if args.restore:
        saved = json.loads(pathlib.Path(args.restore).expanduser().read_bytes())
        old = saved.get("agents", {}).get("providers", {})
        for provider in ("codex", "claude"):
            current = providers.setdefault(provider, {})
            if "command" in old.get(provider, {}):
                current["command"] = old[provider]["command"]
            else:
                current.pop("command", None)
    else:
        commands = {
            p: str(pathlib.Path(args.client_directory).expanduser() / p)
            for p in ("codex", "claude")
        }
        # Each installed client must successfully reach the broker and provider.
        # Keep provider output off the control protocol and out of config logs.
        probe_env = dict(os.environ)
        probe_env.pop("PASEO_AGENT_CWD", None)
        probe_env.pop("PASEO_AGENT_ID", None)
        for provider, command in commands.items():
            subprocess.run(
                [command, "--version"],
                cwd=pathlib.Path.home(),
                env=probe_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                check=True,
                timeout=120,
            )
            providers.setdefault(provider, {})["command"] = [command]
    if config.read_bytes() != original:
        raise ValueError("Paseo configuration changed during probes; retry")
    backup = config.with_name(
        config.name + ".before-broker-" + uuid.uuid4().hex
    )
    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(original)
    fd, temporary = tempfile.mkstemp(
        prefix=config.name + ".", dir=config.parent
    )
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, config)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)
    print(f"Updated Claude/Codex provider commands. Backup: {backup}")
    print("Restart the Paseo daemon when existing sessions can be interrupted.")
    return 0


def print_broker_status(args):
    """Query the running broker and print execution metadata."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as connection:
        connection.settimeout(5)
        connection.connect(
            str(pathlib.Path(args.directory) / "connection/socket")
        )
        connection.send(
            encode_control_message({"version": 1, "type": "status"})
        )
        result = json.loads(connection.recv(MAX_MESSAGE))
        if result.get("type") != "status":
            raise ValueError("unexpected status response")
        print(json.dumps(result, indent=2))
    return 0


def main():
    """Dispatch the broker, provider client, and configuration commands."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default=str(default_runtime_directory()))
    sub = parser.add_subparsers(dest="action", required=True)
    server = sub.add_parser("serve")
    server.add_argument("--supervisor", required=True)
    server.add_argument("--launcher", required=True)
    server.add_argument(
        "--shared-ssh",
        action="store_true",
        help="prepare project SSH outside session namespaces",
    )
    server.add_argument("--root", action="append", default=[])
    provider = sub.add_parser("client")
    provider.add_argument("provider", choices=["codex", "claude"])
    provider.add_argument("arguments", nargs=argparse.REMAINDER)
    change = sub.add_parser("configure")
    change.add_argument(
        "--config", default=str(pathlib.Path.home() / ".paseo/config.json")
    )
    change.add_argument(
        "--client-directory",
        default=str(pathlib.Path.home() / ".local/libexec/paseo-broker"),
    )
    change.add_argument(
        "--restore", help="restore only provider commands from a backup"
    )
    sub.add_parser("status")
    args = parser.parse_args()
    try:
        if args.action == "serve":
            if not args.root:
                args.root = ["~/src", "~/Projects"]
            BrokerServer(args).run_event_loop()
            return 0
        if args.action == "configure":
            return configure_paseo_provider_commands(args)
        if args.action == "status":
            return print_broker_status(args)
        return run_provider_client(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"paseo-broker: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
