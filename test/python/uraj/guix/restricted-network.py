#!/usr/bin/env python3
"""Exercise generated nft rules in disposable user/network namespaces.

Run with nft, ip, unshare, nsenter and guix on PATH. No Docker daemon or
Internet connection is used. All addresses and interfaces exist only inside
the test namespaces. A sandbox may require permission to use netlink there.
"""

import argparse
import contextlib
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.run(
        args, check=True, text=True, capture_output=True, **kwargs
    )


def serve():
    """Echo peer addresses, so tests can distinguish routing from NAT."""
    selector = selectors.DefaultSelector()
    with contextlib.ExitStack() as stack:
        for family, kind, ports in (
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                (53, 80, 443, 3000, 8000, 8001, 8080, 9090),
            ),
            (socket.AF_INET, socket.SOCK_DGRAM, (53, 8443)),
            (socket.AF_INET6, socket.SOCK_STREAM, (80,)),
        ):
            for port in ports:
                sock = stack.enter_context(socket.socket(family, kind))
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if kind == socket.SOCK_DGRAM:
                    # Linux IP_PKTINFO: preserve the destination address when
                    # replying from a wildcard socket on a multi-address peer.
                    sock.setsockopt(socket.IPPROTO_IP, 8, 1)
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind(
                    ("::" if family == socket.AF_INET6 else "0.0.0.0", port)
                )
                if kind == socket.SOCK_STREAM:
                    sock.listen()
                selector.register(sock, selectors.EVENT_READ, kind)
        print("ready", flush=True)
        while True:
            for key, _ in selector.select():
                if key.data == socket.SOCK_STREAM:
                    conn, peer = key.fileobj.accept()
                    with conn:
                        conn.sendall(peer[0].encode())
                else:
                    _, control, _, peer = key.fileobj.recvmsg(1024, 128)
                    key.fileobj.sendmsg([peer[0].encode()], control, 0, peer)


def probe(address, port, udp=False):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
    with socket.socket(family, kind) as sock:
        sock.settimeout(0.4)
        try:
            sock.connect((address, port))
            if udp:
                sock.send(b"probe")
            print(sock.recv(128).decode())
        except OSError:
            return 1
    return 0


class NetworkTest:
    def __init__(self):
        self.processes = []
        self.holders = []
        self.passed = 0

    def close(self):
        for process in reversed(self.processes + self.holders):
            process.terminate()
        for process in self.processes + self.holders:
            process.wait(timeout=5)

    def namespace(self):
        process = subprocess.Popen(
            [
                "unshare",
                "--net",
                sys.executable,
                "-c",
                "import time; print('ready', flush=True); time.sleep(600)",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        self.holders.append(process)
        assert process.stdout.readline().strip() == "ready"
        return process.pid

    def command(self, pid, *args):
        prefix = ["nsenter", f"--net=/proc/{pid}/ns/net", "--"] if pid else []
        return prefix + list(args)

    def ip(self, pid, *args):
        return run(*self.command(pid, "ip", *args))

    def link(self, name, pid, address, gateway, bridge=None):
        self.ip(
            None, "link", "add", name, "type", "veth", "peer", "name", "peer"
        )
        self.ip(None, "link", "set", "peer", "netns", str(pid))
        self.ip(pid, "link", "set", "peer", "name", "eth0")
        if bridge:
            self.ip(None, "link", "add", bridge, "type", "bridge")
            self.ip(None, "link", "set", name, "master", bridge)
            self.ip(None, "link", "set", bridge, "up")
        self.ip(None, "addr", "add", gateway, "dev", bridge or name)
        self.ip(None, "link", "set", name, "up")
        self.ip(pid, "addr", "add", address, "dev", "eth0")
        self.ip(pid, "link", "set", "eth0", "up")
        self.ip(pid, "link", "set", "lo", "up")
        if bridge:
            self.ip(
                pid, "route", "add", "default", "via", gateway.split("/")[0]
            )

    def server(self, pid):
        process = subprocess.Popen(
            self.command(pid, sys.executable, __file__, "--serve"),
            stdout=subprocess.PIPE,
            text=True,
        )
        self.processes.append(process)
        assert process.stdout.readline().strip() == "ready"

    def check(self, name, pid, address, port, allowed, udp=False, source=None):
        command = self.command(
            pid, sys.executable, __file__, "--probe", address, str(port)
        )
        if udp:
            command.append("--udp")
        result = subprocess.run(
            command, text=True, capture_output=True, check=False
        )
        assert result.returncode in (0, 1), result.stderr
        assert (result.returncode == 0) == allowed, (
            name,
            result.stdout,
            result.stderr,
        )
        if source:
            assert result.stdout.strip() == source, (name, result.stdout)
        self.passed += 1
        print(f"PASS: {name}", flush=True)

    def exercise(self, rules):
        # Failure here is confined to the outer disposable network namespace.
        run("sysctl", "-qw", "net.ipv4.ip_forward=1")
        self.ip(None, "link", "set", "lo", "up")
        agents, code, outside = (self.namespace() for _ in range(3))
        # Install before interfaces exist; repeated application is intentional.
        run("nft", "add", "table", "inet", "unrelated_test")
        for _ in range(2):
            run("nft", "-f", str(rules))
        run("nft", "list", "table", "inet", "unrelated_test")
        self.link(
            "agent-veth", agents, "10.204.0.2/24", "10.204.0.1/24", "br-agents"
        )
        self.link(
            "code-veth", code, "10.205.0.2/24", "10.205.0.1/24", "br-code"
        )
        self.link("uplink", outside, "8.0.0.2/24", "8.0.0.1/24")
        self.ip(None, "route", "add", "default", "via", "8.0.0.2")
        for address in (
            "9.9.9.9",
            "9.9.9.10",
            "172.31.0.9",
            "172.31.0.10",
            "100.64.0.2",
        ):
            self.ip(outside, "addr", "add", address + "/32", "dev", "eth0")
        self.ip(None, "-6", "addr", "add", "fd00:1::1/64", "dev", "br-agents")
        self.ip(
            agents, "-6", "addr", "add", "fd00:1::2/64", "dev", "eth0", "nodad"
        )
        for pid in (None, agents, code, outside):
            self.server(pid)
        self.check(
            "public HTTP uses NAT",
            agents,
            "8.0.0.2",
            80,
            True,
            source="8.0.0.1",
        )
        self.check("public HTTPS", agents, "8.0.0.2", 443, True)
        self.check("other public port blocked", agents, "8.0.0.2", 8000, False)
        self.check(
            "LAN blocked on allowed HTTP port", agents, "172.31.0.10", 80, False
        )
        self.check("CGN/VPN range blocked", agents, "100.64.0.2", 443, False)
        self.check("internal model endpoint", agents, "172.31.0.9", 3000, True)
        self.check(
            "same endpoint other port blocked", agents, "172.31.0.9", 80, False
        )
        self.check("specified UDP DNS", agents, "9.9.9.9", 53, True, udp=True)
        self.check("specified TCP DNS", agents, "9.9.9.9", 53, True)
        self.check("other DNS blocked", agents, "9.9.9.10", 53, False, udp=True)
        self.check("host exception", agents, "10.204.0.1", 8080, True)
        self.check(
            "other host service blocked", agents, "10.204.0.1", 9090, False
        )
        self.check(
            "host uplink address blocked", agents, "8.0.0.1", 8080, False
        )
        self.check("IPv6 host access blocked", agents, "fd00:1::1", 80, False)
        self.check(
            "host-initiated ADB-like connection replies",
            None,
            "10.204.0.2",
            8000,
            True,
        )
        self.ip(outside, "route", "add", "10.204.0.0/24", "via", "8.0.0.1")
        self.check(
            "unsolicited inbound blocked", outside, "10.204.0.2", 8000, False
        )
        self.check(
            "source grant cannot bypass destination",
            agents,
            "10.205.0.2",
            8000,
            False,
        )
        run("nft", "-f", str(rules) + ".ingress")
        self.check(
            "both source and destination grant",
            agents,
            "10.205.0.2",
            8000,
            True,
            source="10.204.0.2",
        )
        self.check(
            "neighbor port still blocked", agents, "10.205.0.2", 8001, False
        )
        self.check(
            "reverse initiation still blocked", code, "10.204.0.2", 8000, False
        )
        # A deliberately invalid transaction must not flush the old rules.
        failed = subprocess.run(
            ["nft", "-f", "-"],
            input="flush table inet restricted_network\ninvalid statement\n",
            text=True,
            capture_output=True,
            check=False,
        )
        assert failed.returncode != 0
        self.check(
            "failed reload keeps LAN blocked", agents, "172.31.0.10", 80, False
        )
        run("nft", "-f", str(rules) + ".redroid")
        self.check(
            "redroid arbitrary public TCP", agents, "8.0.0.2", 8001, True
        )
        self.check(
            "redroid public UDP", agents, "8.0.0.2", 8443, True, udp=True
        )
        self.check("redroid LAN blocked", agents, "172.31.0.9", 3000, False)
        self.check("redroid host blocked", agents, "10.204.0.1", 8080, False)
        self.check(
            "redroid explicit DNS", agents, "9.9.9.9", 53, True, udp=True
        )
        self.check(
            "redroid other DNS blocked", agents, "9.9.9.10", 53, False, udp=True
        )
        self.check(
            "redroid host-initiated ADB replies", None, "10.204.0.2", 8000, True
        )
        run("nft", "list", "table", "inet", "unrelated_test")
        print(
            f"{self.passed} packet checks passed; reload and unrelated-table checks passed."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--probe", nargs=2)
    parser.add_argument("--udp", action="store_true")
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--rules", type=Path)
    args = parser.parse_args()
    if args.serve:
        serve()
        return 0
    if args.probe:
        return probe(args.probe[0], int(args.probe[1]), args.udp)
    if args.inside:
        # The launcher records the parent's namespace to guard accidental
        # direct --inside invocation from modifying the host network.
        original = os.environ.get("RESTRICTED_TEST_PARENT_NETNS")
        assert original and original != os.readlink("/proc/self/ns/net")
        test = NetworkTest()
        try:
            test.exercise(args.rules)
        finally:
            test.close()
        return 0
    for tool in ("ip", "nft", "unshare", "nsenter", "sysctl", "guix"):
        if not shutil.which(tool):
            parser.error(f"Missing tool: {tool}")
    root = Path(__file__).resolve().parents[4]
    with tempfile.TemporaryDirectory(
        prefix="restricted-network-test-"
    ) as directory:
        rules = Path(directory) / "rules.nft"
        subprocess.run(
            [
                "guix",
                "repl",
                "-L",
                "src/guix",
                "test/guix/uraj/network-policy.scm",
                str(rules),
            ],
            cwd=root,
            check=True,
        )
        env = dict(
            os.environ,
            RESTRICTED_TEST_PARENT_NETNS=os.readlink("/proc/self/ns/net"),
        )
        return subprocess.run(
            [
                "unshare",
                "--user",
                "--map-root-user",
                "--net",
                sys.executable,
                __file__,
                "--inside",
                "--rules",
                str(rules),
            ],
            env=env,
            check=False,
        ).returncode


if __name__ == "__main__":
    sys.exit(main())
