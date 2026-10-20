"""Persist the completed Depot callback emitted by maa-cli 0.7.5."""

import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def depot_items(output):
    """Extract a final snapshot, never an intermediate page of recognition."""
    decoder = json.JSONDecoder()
    items = None
    for match in re.finditer(r"\bDepot: (\{)", output):
        message, _ = decoder.raw_decode(output[match.start(1) :])
        if (
            message.get("taskchain") != "Depot"
            or message.get("what") != "DepotInfo"
        ):
            continue
        details = message["details"]
        if details.get("done") is not True:
            continue
        data = json.loads(details["data"])
        if not isinstance(data, dict) or not data:
            raise ValueError("Empty or invalid Depot inventory")
        if any(
            not item_id.isdecimal() or type(count) is not int or count < 0
            for item_id, count in data.items()
        ):
            raise ValueError("Invalid Depot item ID or quantity")
        items = data
    # MaaCore may emit done=true even when basic-item recognition failed.
    if items is None or not re.search(r"\bDepot Completed\b", output):
        raise ValueError("No successfully completed Depot snapshot")
    return items


def save_snapshot(destination, items):
    """Replace the latest snapshot atomically in its persistent directory."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    snapshot = {
        "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "items": items,
    }
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=".depot-",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            json.dump(snapshot, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    destination = Path(sys.argv[1])
    # Capture only this invocation, not the CLI's append-only historical logs.
    # Keep scheduler output live and bound memory while the game is running.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output:
        with subprocess.Popen(
            sys.argv[2:],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            env={**os.environ, "NO_COLOR": "1"},
        ) as process:
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                output.write(line)
        if process.returncode:
            return process.returncode if process.returncode > 0 else 1
        output.seek(0)
        try:
            save_snapshot(destination, depot_items(output.read()))
        except (ValueError, KeyError, TypeError, OSError) as error:
            print(f"Depot snapshot not updated: {error}", file=sys.stderr)
            return 1
    print(f"Depot snapshot updated: {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
