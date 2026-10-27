#!/usr/bin/python3
"""Expose restricted config and agent identity commands in tool sandboxes."""

import http.client
import json
import socket
import sys
from pathlib import Path

CAPABILITY_PATH = "/workspace/.openclaw-cli-capability"
SOCKET_PATH = "/run/openclaw-config/config.sock"


class ProxyConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCKET_PATH)


def main():
    connection = ProxyConnection("localhost", timeout=190)
    try:
        headers = {}
        if sys.argv[1:2] == ["agents"]:
            try:
                with Path(CAPABILITY_PATH).open() as capability_file:
                    capability = capability_file.read(65).strip()
                if len(capability) == 64 and all(
                    char in "0123456789abcdef" for char in capability
                ):
                    headers["X-OpenClaw-Agent-Capability"] = capability
            except OSError:
                pass
        connection.request(
            "POST", "/config", json.dumps(sys.argv[1:]), headers=headers
        )
        response = connection.getresponse()
        result = json.loads(response.read(1024 * 1024))
        if response.status != 200:
            raise ValueError("Unexpected response")
        sys.stdout.write(result.get("stdout", ""))
        sys.stderr.write(result.get("stderr", ""))
        return 0 if result.get("ok") is True else 1
    except (OSError, ValueError, http.client.HTTPException):
        print(
            "OpenClaw config proxy unavailable; retry after Gateway startup.",
            file=sys.stderr,
        )
        return 1
    finally:
        connection.close()


if __name__ == "__main__":
    sys.exit(main())
