"""Activate writable Paseo settings and run its Guix application container."""

import argparse
import fcntl
import os
import select
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

# Also support invoking this source file directly, outside an installed package.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from uraj.config import json_config
from uraj.config import yaml_config

# Authorized like a project root, but not among agents' common mounts.
WORKTREES = ".local/share/paseo/worktrees"
OLD_WORKTREES = "Projects/paseo-worktrees"
ROOTS = ("src", "Projects", WORKTREES)
# Seconds to wait for a policy SOPS decrypts: at boot the daemon may start
# before SOPS is done.
SECRET_TIMEOUT = 10


def prepare_temporary_directory(home):
    """Create the stable directory also exposed read-only to contained agents."""
    directory = home / ".cache/paseo-tmp"
    if directory.is_symlink():
        raise ValueError(f"Refusing managed symlink: {directory}")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    return directory


def validate_provider_settings(settings):
    """Validate launch settings before publishing an activation result."""
    agents = settings.get("agents", {})
    if not isinstance(agents, dict):
        raise ValueError("agents must be an object")
    providers = agents.get("providers", {})
    if not isinstance(providers, dict):
        raise ValueError("agents.providers must be an object")
    for name, provider in providers.items():
        if not isinstance(provider, dict):
            raise ValueError(f"provider {name} must be an object")
        if "command" in provider:
            command = provider["command"]
            if (
                not isinstance(command, list)
                or not command
                or any(not isinstance(arg, str) or not arg for arg in command)
            ):
                raise ValueError(
                    f"provider {name} command must be nonempty argv"
                )
        for field in ("label", "extends"):
            if field in provider and not isinstance(provider[field], str):
                raise ValueError(f"provider {name} {field} must be a string")
    return providers


def resolve_home_paths(settings, home):
    """Expand only known path fields against the activation target's Home."""

    def expand(value):
        if value == "~":
            return str(home)
        if isinstance(value, str) and value.startswith("~/"):
            return str(home / value[2:])
        return value

    worktrees = settings.get("worktrees", {})
    if not isinstance(worktrees, dict):
        raise ValueError("worktrees must be an object")
    if "root" in worktrees:
        if not isinstance(worktrees["root"], str):
            raise ValueError("worktrees.root must be a string")
        worktrees["root"] = expand(worktrees["root"])
    for provider in validate_provider_settings(settings).values():
        if "command" in provider:
            provider["command"][0] = expand(provider["command"][0])


def activate(
    home, desktop=False, worktrees=None, public_config=None, private_config=None
):
    """Prepare configuration without contacting or restarting any daemon."""
    hostname = socket.gethostname()
    layers = []
    if public_config is not None:
        layers.append(yaml_config.public_layer(public_config, hostname))
    if private_config is not None:
        private = Path(private_config)
        deadline = time.monotonic() + SECRET_TIMEOUT
        while not private.exists():
            if time.monotonic() >= deadline:
                raise FileNotFoundError("Paseo private YAML is still missing")
            time.sleep(0.1)
        layers.append(yaml_config.private_layer(private, hostname))
    os.umask(0o077)
    prepare_temporary_directory(home)
    default_worktrees = worktrees is None
    if default_worktrees:
        worktrees = str(home / WORKTREES)

    def configure(settings):
        validate_provider_settings(settings)
        settings.setdefault("version", 1)
        providers = settings.setdefault("agents", {}).setdefault(
            "providers", {}
        )
        for provider in ("codex", "claude"):
            for tier, label in (
                ("daily", "日常沙箱"),
                ("system", "系统沙箱"),
                ("host", "宿主"),
            ):
                name = provider if tier == "daily" else f"{provider}-{tier}"
                entry = providers.setdefault(name, {})
                entry.update(
                    {
                        "label": f"{label} {provider}",
                        "command": [
                            str(
                                home
                                / ".guix-home/profile/bin"
                                / f"paseo-{provider}-{tier}"
                            )
                        ],
                    }
                )
                if tier != "daily":
                    entry["extends"] = provider
        if worktrees:
            section = settings.setdefault("worktrees", {})
            # Move the previous default out of ~/Projects; custom roots stay.
            if section.get("root") == str(home / OLD_WORKTREES):
                del section["root"]
            section.setdefault("root", worktrees)

        for layer in layers:
            merged = json_config.apply_layer(settings, layer)
            settings.clear()
            settings.update(merged)
        resolve_home_paths(settings, home)
        configured = validate_provider_settings(settings)
        for provider in ("codex", "claude"):
            expected = [
                str(home / ".guix-home/profile/bin" / f"paseo-{provider}-daily")
            ]
            if configured.get(provider, {}).get("command") != expected:
                print(
                    f"paseo: default {provider} no longer uses daily",
                    file=sys.stderr,
                )

    json_config.update_file(
        home / ".paseo/config.json", configure, backup_suffix=".before-service"
    )
    if default_worktrees:
        # Paseo's upstream default is inside .paseo, which agents deliberately
        # cannot mount. Keep agent worktrees apart from human project roots.
        (home / WORKTREES).mkdir(parents=True, exist_ok=True)
    if desktop:

        def configure_desktop(document):
            document.setdefault("version", 1)
            document.setdefault("settings", {}).setdefault("daemon", {})[
                "manageBuiltInDaemon"
            ] = False
            document.setdefault("migrations", {})[
                "legacyRendererSettingsImported"
            ] = True

        config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
        user_data = Path(
            os.environ.get(
                "PASEO_ELECTRON_USER_DATA_DIR", config_home / "Paseo"
            )
        )
        json_config.update_file(
            user_data / "desktop-settings.json",
            configure_desktop,
            backup_suffix=".before-service",
        )


def container_command(
    guix,
    profile,
    home,
    roots,
    extra_options=(),
    ssh_directory=None,
    gh_config=None,
):
    """Keep host paths and UID; expose only the broker connection directory.

    GH_CONFIG, the daemon's own read-only GitHub CLI configuration, stands in
    for the host's ~/.config/gh, which is never mounted.
    """
    runtime = home / ".local/state/paseo-broker"
    command = [
        guix,
        "shell",
        "--container",
        "--network",
        "--no-cwd",
        f"--profile={profile}",
        "--expose=/gnu/store",
        f"--share={home / '.paseo'}",
        f"--share={home / '.cache/paseo-tmp'}",
        f"--expose={runtime / 'connection'}",
        # Keep stable command paths in config; restart after Home upgrades to
        # select the new profile generation for this mount.
        f"--expose={home / '.guix-home'}={home / '.guix-home'}",
        "--preserve=^(PASEO_.*|TMPDIR|LANG|LC_.*)$",
    ]
    for root in roots:
        path = Path(root).expanduser()
        if path.exists():
            command.append(f"--share={path}")
    # Paseo itself replays Claude transcripts to rebuild a session's timeline
    # after a daemon restart, and rewinds a conversation by forking its
    # transcript; Codex history comes back through its provider.
    transcripts = home / ".claude/projects"
    if transcripts.exists():
        command.append(f"--share={transcripts}")
    # Of the host's Git configuration, only the identity serves the daemon:
    # the rest is preferences, and applications write ~/.gitconfig.
    identity = home / ".gitconfig.local"
    if identity.exists():
        command.append(f"--expose={identity}={home / '.gitconfig'}")
    if gh_config:
        command.append(f"--expose={gh_config}={home / '.config/gh'}")
    command.extend(extra_options)
    if ssh_directory:
        for source, target in (
            ("ssh.sock", "/run/paseo/ssh.sock"),
            ("known_hosts", str(home / ".ssh/known_hosts")),
            ("config", str(home / ".ssh/config")),
        ):
            command.append(f"--expose={ssh_directory}/{source}={target}")
        return command + [
            "--",
            "bash",
            "-c",
            'export HOME="$1"; shift; chmod 700 "$HOME" || exit; '
            "export SSH_AUTH_SOCK=/run/paseo/ssh.sock; "
            'unset SSH_AGENT_PID; exec "$@"',
            "paseo-container",
            str(home),
            "paseo",
            "daemon",
            "run",
        ]
    return command + ["--", "paseo", "daemon", "run"]


def write_all(fd, data):
    """Write data to fd, waiting when Shepherd's non-blocking pipe is full."""
    view = memoryview(data)
    while view:
        try:
            view = view[os.write(fd, view) :]
        except BlockingIOError:
            select.select([], [fd], [])


def sandbox_policy(args, home):
    """Return the daemon's sandbox policy file, or None for the defaults.

    A host-private policy that SOPS decrypts is waited for and required, and
    excludes the unmanaged one.
    """
    local = Path(args.sandbox_config or home / ".config/paseo/sandbox.scm")
    if not args.sandbox_secret:
        return local if local.exists() else None
    secret = Path(args.sandbox_secret)
    if local.exists():
        raise ValueError(f"{local} conflicts with this host's policy {secret}")
    deadline = time.monotonic() + SECRET_TIMEOUT
    while not secret.exists():
        if time.monotonic() >= deadline:
            raise FileNotFoundError(
                f"{secret} is still missing after {SECRET_TIMEOUT} s; "
                "check `sudo herd status sops-secrets'"
            )
        time.sleep(0.2)
    return secret


def run_configured_container(args, home, roots, policy):
    """Own one namespace containing both daemon and its private SSH agents."""
    # Reuse the broker's boot/PID identity checks; never remove live sockets.
    from uraj.paseo import broker

    if not args.supervisor or not args.sandbox_helper:
        raise ValueError(
            "Sandbox policy requires the packaged service launcher"
        )
    base = home / ".local/state/paseo-sandbox"
    if base.is_symlink():
        raise ValueError("Paseo sandbox state must not be a symlink")
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = base.stat()
    if st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise ValueError("Paseo sandbox state must be private and user-owned")
    with (base / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for previous in base.glob("ssh-*"):
            broker.wait_for_old_execution_and_remove_directory(previous)
        directory = broker.execution_directory(base, "ssh-")
        env = dict(
            os.environ,
            TMPDIR=str(directory),
            PASEO_DAEMON_TMPDIR=os.environ["TMPDIR"],
            CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY=str(directory),
        )
        env.pop("SSH_AUTH_SOCK", None)
        env.pop("SSH_AGENT_PID", None)
        owner = os.pidfd_open(os.getpid())
        process = None

        def interrupted(signum, _frame):
            raise InterruptedError(f"Paseo service received signal {signum}")

        handlers = {
            sig: signal.signal(sig, interrupted)
            for sig in (signal.SIGTERM, signal.SIGINT)
        }
        try:
            process = subprocess.Popen(
                [
                    args.supervisor,
                    "--owner-fd",
                    str(owner),
                    "--",
                    args.sandbox_helper,
                    str(policy),
                ],
                env=env,
                pass_fds=(owner,),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
            )
            response = bytearray()
            deadline = time.monotonic() + 120
            while not response.endswith(b"\0\0"):
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        "Paseo sandbox/SSH preparation timed out"
                    )
                if not select.select([process.stdout], [], [], 0.2)[0]:
                    continue
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError(
                        "Paseo sandbox preparation failed; see stderr"
                    )
                response.extend(data)
                if len(response) > 1024 * 1024:
                    raise ValueError("Paseo sandbox policy response too large")
            parts = os.fsdecode(bytes(response[:-2])).split("\0")
            ssh_directory, *options = parts
            command = container_command(
                args.guix,
                args.profile,
                home,
                roots,
                options,
                ssh_directory,
                args.gh_config,
            )
            process.stdin.write(os.fsencode("\0".join(command) + "\0\0"))
            process.stdin.flush()
            process.stdin.close()
            # Stream daemon output instead of accumulating an unbounded log.
            while data := os.read(process.stdout.fileno(), 65536):
                write_all(sys.stdout.fileno(), data)
            return process.wait()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                process.stdin.close()
                process.stdout.close()
            os.close(owner)
            broker.wait_for_old_execution_and_remove_directory(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("activate", "run", "run-host"))
    parser.add_argument("--desktop", action="store_true")
    parser.add_argument("--public-config")
    parser.add_argument("--private-config")
    parser.add_argument("--worktrees")
    parser.add_argument("--guix")
    parser.add_argument("--profile")
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--sandbox-helper")
    parser.add_argument("--supervisor")
    parser.add_argument("--sandbox-config")
    parser.add_argument("--sandbox-secret")
    parser.add_argument("--gh-config")
    args = parser.parse_args()
    home = Path.home()
    if args.action == "activate":
        activate(
            home,
            args.desktop,
            args.worktrees,
            args.public_config,
            args.private_config,
        )
        return
    os.environ["TMPDIR"] = str(prepare_temporary_directory(home))
    # Shepherd starting the broker does not mean its socket (or first Home
    # activation) is ready yet. Probe without requesting an agent execution.
    socket_path = home / ".local/state/paseo-broker/connection/socket"
    deadline = time.monotonic() + 60
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as peer:
                peer.settimeout(1)
                peer.connect(str(socket_path))
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    "Paseo broker did not become ready"
                ) from None
            time.sleep(0.1)
    os.environ["PASEO_HOME"] = str(home / ".paseo")
    os.environ["PASEO_BROKER_DIRECTORY"] = str(
        home / ".local/state/paseo-broker"
    )
    # Relay pairing supplies authentication; do not add a daemon password.
    os.environ.pop("PASEO_PASSWORD", None)
    roots = args.root or [str(home / root) for root in ROOTS]
    os.chdir(home)
    policy = sandbox_policy(args, home)
    if policy:
        if args.action == "run-host":
            raise ValueError("Sandbox policy requires container mode")
        raise SystemExit(run_configured_container(args, home, roots, policy))
    command = (
        ["paseo", "daemon", "run"]
        if args.action == "run-host"
        else container_command(
            args.guix, args.profile, home, roots, gh_config=args.gh_config
        )
    )
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
