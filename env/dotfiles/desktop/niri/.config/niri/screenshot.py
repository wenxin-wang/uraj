#!/usr/bin/env python3
"""Capture with niri, then edit and save the same file with Satty."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("screen", "region", "window"))
    args = parser.parse_args()
    directory = Path.home() / "tmp" / "Pictures" / "Screenshots"
    directory.mkdir(parents=True, exist_ok=True)
    path = str(directory / (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".png"))
    action = "screenshot" if args.mode == "region" else "screenshot-" + args.mode

    # Subscribe before capturing, and match our own unique path. This avoids
    # startup races, partial PNG reads, and opening another shortcut's capture.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(5)
        stream.connect(os.environ["NIRI_SOCKET"])
        stream.sendall(b'"EventStream"\n')
        with stream.makefile("rb") as events:
            reply = json.loads(events.readline())
            if reply != {"Ok": "Handled"}:
                raise RuntimeError(f"Cannot subscribe to niri: {reply}")
            subprocess.run(
                ["niri", "msg", "action", action, "--path", path], check=True
            )
            # Cancelling niri's UI emits no event. Bound the listener lifetime;
            # a later capture cannot launch an editor for this cancelled one.
            deadline = time.monotonic() + 120
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return
                stream.settimeout(remaining)
                try:
                    line = events.readline()
                except TimeoutError:
                    return
                if not line:
                    raise RuntimeError("niri closed the screenshot event stream")
                event = json.loads(line)
                if event.get("ScreenshotCaptured", {}).get("path") == path:
                    break

    subprocess.run(
        ["satty", "--filename", path, "--output-filename", path,
         "--copy-command", "wl-copy"],
        check=True,
    )


if __name__ == "__main__":
    main()
