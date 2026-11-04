#!/usr/bin/env python3
"""Forward an OpenClaw sandbox's browser dashboard to a local URL."""

import argparse
import shlex
import socketserver
import subprocess
import sys
import threading

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


def engine_command(host, arguments):
    command = ["/etc/openclaw/compose", "exec", "-T", "engine", "podman"]
    # Remote sudo must be noninteractive: its stdin carries HTTP/WS bytes.
    command = ["sudo", "-n", *command, *arguments]
    if host:
        return [
            "ssh",
            "-T",
            "-o",
            "BatchMode=yes",
            "--",
            host,
            shlex.join(command),
        ]
    return command


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
            "Requires Python 3 locally, and noninteractive sudo access to "
            "/etc/openclaw/compose on the OpenClaw host. Ctrl-C stops the "
            "forwarder; the dashboard and browser sessions keep running."
        ),
    )
    parser.add_argument("container", nargs="?", help="sandbox name or ID")
    parser.add_argument(
        "--ssh", metavar="HOST", help="SSH to the OpenClaw host"
    )
    parser.add_argument("--list", action="store_true", help="list sandboxes")
    parser.add_argument(
        "--port", type=port_number, default=4848, help="local port"
    )
    parser.add_argument(
        "--dashboard-port", type=port_number, default=4848, help="sandbox port"
    )
    args = parser.parse_args()
    if args.list:
        subprocess.run(
            engine_command(
                args.ssh, ["ps", "--format", "{{.Names}}\t{{.Status}}"]
            ),
            check=True,
        )
        return
    if not args.container or args.container.startswith("-"):
        parser.error("choose a sandbox name or ID (use --list)")
    command = engine_command(
        args.ssh,
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
                args.ssh,
                [
                    "exec",
                    args.container,
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


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
