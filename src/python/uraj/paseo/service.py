"""Activate writable Paseo settings and run its Guix application container."""

import argparse
import fcntl
import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Authorized like a project root, but not among agents' common mounts.
WORKTREES = ".local/share/paseo/worktrees"
OLD_WORKTREES = "Projects/paseo-worktrees"
ROOTS = ("src", "Projects", WORKTREES)


def prepare_temporary_directory(home):
    """Create the stable directory also exposed read-only to contained agents."""
    directory = home / ".cache/paseo-tmp"
    if directory.is_symlink():
        raise ValueError(f"Refusing managed symlink: {directory}")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    return directory


def merge_settings(path, update):
    """Merge owned fields, preserving other settings and unchanged files."""
    if path.is_symlink():
        raise ValueError(f"Refusing managed symlink: {path}")
    original = path.read_bytes() if path.exists() else None
    settings = json.loads(original) if original is not None else {}
    update(settings)
    if original is not None and settings == json.loads(original):
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if original is not None:
        backup = path.with_name(path.name + ".before-service")
        if not backup.exists():
            with backup.open("xb") as output:
                output.write(original)
            backup.chmod(0o600)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def activate(home, desktop=False, worktrees=None):
    """Prepare configuration without contacting or restarting any daemon."""
    os.umask(0o077)
    prepare_temporary_directory(home)
    default_worktrees = worktrees is None
    if default_worktrees:
        worktrees = str(home / WORKTREES)

    def configure(settings):
        settings.setdefault("version", 1)
        providers = settings.setdefault("agents", {}).setdefault(
            "providers", {}
        )
        for provider in ("codex", "claude"):
            providers.setdefault(provider, {})["command"] = [
                str(home / ".guix-home/profile/bin" / f"paseo-{provider}")
            ]
        if worktrees:
            section = settings.setdefault("worktrees", {})
            # Move the previous default out of ~/Projects; custom roots stay.
            if section.get("root") == str(home / OLD_WORKTREES):
                del section["root"]
            section.setdefault("root", worktrees)

    merge_settings(home / ".paseo/config.json", configure)
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
        merge_settings(user_data / "desktop-settings.json", configure_desktop)


def container_command(
    guix, profile, home, roots, extra_options=(), ssh_directory=None
):
    """Keep host paths and UID; expose only the broker connection directory."""
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
    for name in (".gitconfig", ".gitconfig.local"):
        path = home / name
        if path.exists():
            command.append(f"--expose={path}")
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


def run_configured_container(args, home, roots, policy):
    """Own one namespace containing both daemon and its private SSH agents."""
    # Reuse the broker's boot/PID identity checks; never remove live sockets.
    import broker

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
                args.guix, args.profile, home, roots, options, ssh_directory
            )
            process.stdin.write(os.fsencode("\0".join(command) + "\0\0"))
            process.stdin.flush()
            process.stdin.close()
            # Stream daemon output instead of accumulating an unbounded log.
            while data := os.read(process.stdout.fileno(), 65536):
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
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
    parser.add_argument("--worktrees")
    parser.add_argument("--guix")
    parser.add_argument("--profile")
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--sandbox-helper")
    parser.add_argument("--supervisor")
    parser.add_argument("--sandbox-config")
    args = parser.parse_args()
    home = Path.home()
    if args.action == "activate":
        activate(home, args.desktop, args.worktrees)
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
    policy = Path(args.sandbox_config or home / ".config/paseo/sandbox.scm")
    if policy.exists():
        if args.action == "run-host":
            raise ValueError("Sandbox policy requires container mode")
        raise SystemExit(run_configured_container(args, home, roots, policy))
    command = (
        ["paseo", "daemon", "run"]
        if args.action == "run-host"
        else container_command(args.guix, args.profile, home, roots)
    )
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
