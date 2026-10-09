"""Real Guix container/broker smoke test using disposable state and providers.

Set PROFILE to the built paseo-daemon-profile and SUPERVISOR to its helper.
Requires Guix daemon access and unprivileged user namespaces.
"""

import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[5] / "src/python/uraj/paseo"
SPEC = importlib.util.spec_from_file_location(
    "paseo_service", SOURCE / "service.py"
)
SERVICE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVICE)


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def main():
    profile = os.environ["PROFILE"]
    guix = os.environ.get("GUIX", "guix")
    with tempfile.TemporaryDirectory(prefix="paseo-container-") as directory:
        home = Path(directory)
        root = home / "src"
        root.mkdir()
        (home / ".guix-home").mkdir()
        (home / ".guix-home/profile").symlink_to(profile)
        SERVICE.activate(home)
        launcher = home / "fake-provider"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            "if sys.argv[2:] == ['--version']:\n"
            "    print('fake-provider 1.0'); sys.exit(0)\n"
            "sys.exit(1)\n"
        )
        launcher.chmod(0o700)
        runtime = home / ".local/state/paseo-broker"
        env = {
            k: v for k, v in os.environ.items() if not k.startswith("PASEO_")
        }
        env.update(HOME=str(home), PASEO_BROKER_DIRECTORY=str(runtime))
        broker = subprocess.Popen(
            [
                sys.executable,
                str(SOURCE / "broker.py"),
                "serve",
                "--supervisor",
                os.environ["SUPERVISOR"],
                "--launcher",
                str(launcher),
                "--root",
                str(home),
            ],
            env=env,
            start_new_session=True,
        )
        daemon = None
        try:
            deadline = time.monotonic() + 10
            while not (runtime / "connection/socket").exists():
                if broker.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Broker failed to start")
                time.sleep(0.05)
            (runtime / "private-test-marker").write_text("not exposed")
            command = SERVICE.container_command(guix, profile, home, [root])
            probe = subprocess.run(
                command[:-3]
                + [
                    "bash",
                    "-c",
                    'test ! -e "$PASEO_BROKER_DIRECTORY/private-test-marker" '
                    "|| exit 1; "
                    "test ! -e /var/guix/daemon-socket/socket || exit 1; "
                    # Exercise the same child lookup used by daemon cleanup.
                    "sleep 30 & child=$!; "
                    "children=$(ps -o pid --no-headers --ppid $$); status=$?; "
                    'kill "$child"; wait "$child" 2>/dev/null; '
                    'test "$status" = 0 || exit 1; '
                    "[[ $children =~ (^|[[:space:]])$child($|[[:space:]]) ]] "
                    ' || exit 1; paseo-codex --version; result=$?; exit "$result"',
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert probe.returncode == 0, probe.stderr
            assert probe.stdout.strip() == "fake-provider 1.0", probe.stdout
            print(
                "PASS: container client reaches host broker; private files hidden"
            )
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            env.update(
                PASEO_LISTEN=f"127.0.0.1:{port}",
                PASEO_RELAY_ENABLED="false",
                PASEO_WEB_UI_ENABLED="true",
            )
            sandbox_arguments = []
            if helper := os.environ.get("SANDBOX_HELPER"):
                policy = home / ".config/paseo/sandbox.scm"
                policy.parent.mkdir(parents=True)
                known = home / "known_hosts"
                known.write_text("")
                policy.write_text(f'(ssh-agent (known-hosts "{known}"))\n')
                sandbox_arguments = [
                    "--sandbox-helper",
                    helper,
                    "--supervisor",
                    os.environ["SUPERVISOR"],
                ]
            with (home / "daemon.log").open("w+") as log:
                daemon = subprocess.Popen(
                    [
                        sys.executable,
                        str(SOURCE / "service.py"),
                        "run",
                        "--guix",
                        guix,
                        "--profile",
                        profile,
                        "--root",
                        str(root),
                    ]
                    + sandbox_arguments,
                    env=env,
                    stdout=log,
                    stderr=log,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 60
                while True:
                    if daemon.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError(log.read()[-6000:])
                    try:
                        with urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/api/health", timeout=1
                        ) as response:
                            assert response.status == 200
                            break
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.2)
                print("PASS: real Paseo daemon healthy over host network")
                if sandbox_arguments:
                    socket_path = next(
                        (home / ".local/state/paseo-sandbox").glob(
                            "ssh-*/ssh.sock"
                        )
                    )
                    ssh_command = SERVICE.container_command(
                        guix,
                        profile,
                        home,
                        [root],
                        ssh_directory=str(socket_path.parent),
                    )
                    ssh_probe = subprocess.run(
                        ssh_command[: ssh_command.index("--") + 1]
                        + [
                            "env",
                            "SSH_AUTH_SOCK=/run/paseo/ssh.sock",
                            "ssh-add",
                            "-l",
                        ],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    assert ssh_probe.returncode == 1, ssh_probe.stderr
                    assert "no identities" in ssh_probe.stdout.lower(), (
                        ssh_probe
                    )
                    print("PASS: real container reaches independent SSH agent")
            settings = json.loads((home / ".paseo/config.json").read_text())
            assert settings["agents"]["providers"]["codex"]["command"] == [
                str(home / ".guix-home/profile/bin/paseo-codex")
            ]
        finally:
            if daemon is not None:
                stop(daemon)
            stop(broker)


if __name__ == "__main__":
    main()
