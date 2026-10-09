#!/usr/bin/env python3
"""Move the focused column up, creating a workspace at the top when needed."""

import fcntl
import json
import os
import socket
import sys


def move_up(request):
    workspaces = request("Workspaces")["Workspaces"]
    current = next((ws for ws in workspaces if ws["is_focused"]), None)
    if current is None:
        return
    if current["idx"] > 1:
        request({"Action": {"MoveColumnToWorkspaceUp": {"focus": True}}})
        return

    window = request("FocusedWindow")["FocusedWindow"]
    if window is None or window["workspace_id"] != current["id"]:
        return
    target = max(
        (ws for ws in workspaces if ws["output"] == current["output"]),
        key=lambda ws: ws["idx"],
    )
    if target["id"] == current["id"]:
        return
    windows = request("Windows")["Windows"]
    if target["name"] is not None or any(
        win["workspace_id"] == target["id"] for win in windows
    ):
        raise RuntimeError("The last workspace is no longer empty; try again")

    reference = {"Id": target["id"]}
    request(
        {
            "Action": {
                "MoveColumnToWorkspace": {
                    "reference": reference,
                    "focus": True,
                }
            }
        }
    )
    # A column action can be a no-op (or focus can change between requests).
    # Only reorder the workspace if the original window actually arrived.
    windows = request("Windows")["Windows"]
    if any(
        win["id"] == window["id"] and win["workspace_id"] == target["id"]
        for win in windows
    ):
        request(
            {
                "Action": {
                    "MoveWorkspaceToIndex": {
                        "index": 1,
                        "reference": reference,
                    }
                }
            }
        )


def main():
    socket_path = os.environ["NIRI_SOCKET"]
    # Drop overlapping invocations instead of queuing stale key presses.
    with open(socket_path + ".workspace-up.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(5)
            stream.connect(socket_path)
            with stream.makefile("rwb") as ipc:

                def request(message):
                    ipc.write(json.dumps(message).encode() + b"\n")
                    ipc.flush()
                    reply = json.loads(ipc.readline())
                    if "Err" in reply:
                        raise RuntimeError(reply["Err"])
                    return reply["Ok"]

                move_up(request)


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError) as error:
        sys.exit(f"workspace-up: {error}")
