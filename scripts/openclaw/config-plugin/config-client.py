#!/usr/bin/python3
"""Expose the limited Gateway config capability inside tool sandboxes."""

import http.client
import json
import socket
import sys

SOCKET_PATH = "/run/openclaw-config/config.sock"


class ProxyConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCKET_PATH)


def main():
    connection = ProxyConnection("localhost", timeout=190)
    try:
        connection.request("POST", "/config", json.dumps(sys.argv[1:]))
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
