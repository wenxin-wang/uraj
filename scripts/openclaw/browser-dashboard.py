#!/usr/bin/env python3
"""Forward an OpenClaw sandbox's browser dashboard to a local URL."""

import argparse
import os
import shlex
import signal
import socketserver
import subprocess
import sys
import threading
from pathlib import Path

# Executed inside the selected sandbox. Forward bytes, including WebSocket
# upgrades, without publishing ports on either of the two container layers.
RELAY = """
import os
import select
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10) as peer:
    peer.settimeout(None)
    readers = [0, peer]
    try:
        while readers:
            ready, _, _ = select.select(readers, [], [])
            if 0 in ready:
                data = os.read(0, 65536)
                if data:
                    peer.sendall(data)
                else:
                    peer.shutdown(socket.SHUT_WR)
                    readers.remove(0)
            if peer in ready:
                data = peer.recv(65536)
                if not data:
                    break
                data = memoryview(data)
                while data:
                    data = data[os.write(1, data):]
    except (BrokenPipeError, ConnectionResetError):
        pass
"""


def engine_command(arguments):
    command = ["/etc/openclaw/compose", "exec", "-T", "engine", "podman"]
    # SSH mode runs one privileged helper for the whole connection. Local
    # non-root use still needs cached/NOPASSWD sudo; stdin carries HTTP bytes.
    if os.geteuid() != 0:
        command = ["sudo", "-n", *command]
    return [*command, *arguments]


def ssh_command(args):
    """Prompt on a PTY; carry browser bytes on an independent SSH channel."""
    command = [
        "ssh",
        "-tt",
        "-o",
        "ExitOnForwardFailure=yes",
        # A shared ControlMaster can retain -L listeners after this exits.
        "-o",
        "ControlPath=none",
    ]
    if args.list:
        remote = shlex.join(
            [
                "sudo",
                "--",
                "/etc/openclaw/compose",
                "exec",
                "-T",
                "engine",
                "podman",
                "ps",
                "--format",
                "{{.Names}}\t{{.Status}}",
            ]
        )
    else:
        command.extend(["-L", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}"])
        # Resolve Python before sudo resets PATH (notably on Guix). Pass this
        # checkout's helper as an argument; stdin stays available for sudo's
        # own password prompt, and no remote checkout or temporary file is used.
        remote = (
            "python=$(command -v python3) || { "
            "echo 'browser-dashboard: python3 is required on the SSH host' >&2; "
            "exit 1; }; "
            'exec sudo -- "$python" '
            + shlex.join(
                [
                    "-c",
                    Path(__file__).read_text(),
                    "--port",
                    str(args.port),
                    "--dashboard-port",
                    str(args.dashboard_port),
                    "--",
                    args.container,
                ]
            )
        )
    return [*command, "--", args.ssh, remote]


class ForwardRequest(socketserver.BaseRequestHandler):
    def handle(self):
        server = self.server
        with server.process_lock:
            if server.closing:
                return
            process = subprocess.Popen(
                server.command, stdin=self.request, stdout=self.request
            )
            server.processes.add(process)
        try:
            process.wait()
        finally:
            with server.process_lock:
                server.processes.discard(process)


class ForwardServer(socketserver.ThreadingTCPServer):
    """Keep forwarding processes scoped to the foreground listener."""

    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port, command):
        self.command = command
        self.processes = set()
        self.process_lock = threading.Lock()
        self.closing = False
        super().__init__(("127.0.0.1", port), ForwardRequest)

    def server_close(self):
        with self.process_lock:
            self.closing = True
            processes = list(self.processes)
        super().server_close()
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def port_number(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return number


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=(
            "SSH mode prompts for sudo in your terminal; Python 3 must be "
            "on the remote user's PATH. For local use with a sudo password, "
            "run this script with sudo. Ctrl-C stops forwarding; the "
            "dashboard and browser sessions keep running."
        ),
    )
    parser.add_argument("container", nargs="?", help="sandbox name or ID")
    parser.add_argument(
        "--ssh", metavar="HOST", help="SSH to the OpenClaw host"
    )
    parser.add_argument("--list", action="store_true", help="list sandboxes")
    parser.add_argument(
        "--port",
        type=port_number,
        default=4848,
        help="local and SSH host listener port",
    )
    parser.add_argument(
        "--dashboard-port", type=port_number, default=4848, help="sandbox port"
    )
    args = parser.parse_args()
    if not args.list and (not args.container or args.container.startswith("-")):
        parser.error("choose a sandbox name or ID (use --list)")
    if args.ssh:
        subprocess.run(ssh_command(args), check=True)
        return
    if args.list:
        subprocess.run(
            engine_command(["ps", "--format", "{{.Names}}\t{{.Status}}"]),
            check=True,
        )
        return
    command = engine_command(
        [
            "exec",
            "-i",
            args.container,
            "python3",
            "-c",
            RELAY,
            str(args.dashboard_port),
        ],
    )
    # Bind first so a local port conflict doesn't start a remote dashboard.
    with ForwardServer(args.port, command) as server:
        subprocess.run(
            engine_command(
                [
                    "exec",
                    args.container,
                    # Existing images may predate browser-profile dashboard.
                    # Avoid launch defaults that reopen sessions sans profile.
                    "env",
                    "-u",
                    "AGENT_BROWSER_HEADED",
                    "-u",
                    "AGENT_BROWSER_EXECUTABLE_PATH",
                    "-u",
                    "AGENT_BROWSER_ARGS",
                    "agent-browser",
                    "dashboard",
                    "start",
                    "--port",
                    str(args.dashboard_port),
                ],
            ),
            stdout=sys.stderr,
            check=True,
        )
        print(
            f"Open http://127.0.0.1:{args.port} (Ctrl-C to stop forwarding)",
            flush=True,
        )
        server.serve_forever()


def stop_forwarding(_signum, _frame):
    # SSH disconnects send SIGHUP; unwind the server context to reap execs.
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGHUP, stop_forwarding)
    signal.signal(signal.SIGTERM, stop_forwarding)
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
