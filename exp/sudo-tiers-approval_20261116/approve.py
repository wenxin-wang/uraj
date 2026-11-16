"""Prototype: approve a command with a passkey signature relayed via ntfy.

The request travels to the phone in the URL fragment of a static page.  The
page signs SHA-256 of the exact request bytes with a passkey and posts the
WebAuthn assertion to a reply topic; this script verifies it against the keys
registered earlier.  ntfy and the page host are untrusted transport.

Run inside: guix shell python python-cryptography -- python3 approve.py ...

  approve.py register --page URL --reply TOPIC --keys FILE
  approve.py request --page URL --notify TOPIC --reply TOPIC --keys FILE \
      [--exec] [--script FILE] [--note TEXT] -- argv...
"""

import argparse
import base64
import getpass
import hashlib
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zlib

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import load_der_public_key

NTFY = "https://ntfy.sh"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def fingerprint(spki: bytes) -> str:
    return b64url(hashlib.sha256(spki).digest())[:16]


def publish(body: dict) -> None:
    req = urllib.request.Request(
        NTFY + "/",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def messages(topic: str, since: int, deadline: float):
    """Yields decoded JSON bodies posted to topic until deadline."""
    while time.time() < deadline:
        url = f"{NTFY}/{topic}/json?since={since}"
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                for line in resp:
                    event = json.loads(line)
                    if event.get("event") != "message":
                        if time.time() >= deadline:
                            return
                        continue
                    since = event["id"]
                    try:
                        yield json.loads(event["message"])
                    except (KeyError, ValueError):
                        continue
        except (OSError, ValueError) as err:
            print(f"ntfy: {err}; retrying", file=sys.stderr)
            time.sleep(3)


def page_origin(page: str) -> tuple[str, str]:
    url = urllib.parse.urlsplit(page)
    return f"{url.scheme}://{url.netloc}", url.hostname


def verify(msg: dict, raw: bytes, keys: dict, page: str) -> str | None:
    """Returns None if msg is a valid assertion over raw, else a reason."""
    spki = keys.get(msg.get("credentialId", ""))
    if spki is None:
        return "unknown credential"
    origin, rp_id = page_origin(page)
    auth_data = unb64url(msg["authenticatorData"])
    client_json = unb64url(msg["clientDataJSON"])
    client = json.loads(client_json)
    if client.get("type") != "webauthn.get":
        return "wrong clientData type"
    if client.get("origin") != origin:
        return f"wrong origin {client.get('origin')!r}"
    if client.get("challenge") != b64url(hashlib.sha256(raw).digest()):
        return "challenge does not match the request"
    if auth_data[:32] != hashlib.sha256(rp_id.encode()).digest():
        return "wrong rpId"
    if auth_data[32] & 0x05 != 0x05:
        return "user presence or verification missing"
    key = load_der_public_key(unb64url(spki))
    try:
        key.verify(
            unb64url(msg["signature"]),
            auth_data + hashlib.sha256(client_json).digest(),
            ec.ECDSA(hashes.SHA256()),
        )
    except InvalidSignature:
        return "bad signature"
    return None


def load_keys(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def cmd_register(args) -> int:
    url = f"{args.page}#register={NTFY}/{args.reply}"
    print(f"Open on the phone:\n  {url}")
    since = int(time.time())
    for msg in messages(args.reply, since, time.time() + args.timeout):
        if msg.get("type") != "register":
            continue
        spki = unb64url(msg["publicKey"])
        load_der_public_key(spki)
        print(f"Received key, fingerprint {fingerprint(spki)}")
        if input("Same as on the phone? [y/N] ").strip().lower() != "y":
            print("Ignored.")
            continue
        keys = load_keys(args.keys)
        keys[msg["credentialId"]] = msg["publicKey"]
        os.makedirs(os.path.dirname(os.path.abspath(args.keys)), exist_ok=True)
        with open(args.keys, "w") as f:
            json.dump(keys, f, indent=2)
        print(f"Saved to {args.keys}")
        return 0
    print("Timed out.", file=sys.stderr)
    return 2


def cmd_request(args) -> int:
    keys = load_keys(args.keys)
    if not keys:
        print(f"No keys in {args.keys}; run register first.", file=sys.stderr)
        return 2
    now = int(time.time())
    request = {
        "v": 1,
        "id": secrets.token_urlsafe(12),
        "title": args.title,
        "host": socket.gethostname(),
        "user": getpass.getuser(),
        "cwd": os.getcwd(),
        "argv": args.argv,
        "created": now,
        "expires": now + args.timeout,
        "reply": f"{NTFY}/{args.reply}",
    }
    if args.script:
        with open(args.script) as f:
            request["script"] = f.read()
    if args.note:
        request["note"] = args.note
    raw = json.dumps(request, ensure_ascii=False).encode()
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = b64url(deflate.compress(raw) + deflate.flush())
    url = f"{args.page}#r={packed}"
    print(
        f"Request {request['id']}, hash {b64url(hashlib.sha256(raw).digest())[:16]}"
    )
    print(f"URL ({len(url)} bytes):\n  {url}")
    publish(
        {
            "topic": args.notify,
            "title": args.title,
            "message": " ".join(args.argv),
            "click": url,
            "actions": [{"action": "view", "label": "Review", "url": url}],
        }
    )
    for msg in messages(args.reply, now, request["expires"]):
        if msg.get("id") != request["id"]:
            continue
        if msg.get("type") == "reject":
            print("Rejected.")
            return 1
        if msg.get("type") != "approve":
            continue
        reason = verify(msg, raw, keys, args.page)
        if reason:
            print(f"Ignored invalid approval: {reason}", file=sys.stderr)
            continue
        print("Approved.")
        if args.exec:
            return subprocess.call(args.argv)
        return 0
    print("Expired.", file=sys.stderr)
    return 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("register", "request"):
        p = sub.add_parser(name)
        p.add_argument("--page", required=True, help="approval page URL")
        p.add_argument("--reply", required=True, help="ntfy reply topic")
        p.add_argument("--keys", required=True, help="registered keys JSON")
        p.add_argument("--timeout", type=int, default=300, help="seconds")
    req = sub.choices["request"]
    req.add_argument("--notify", required=True, help="ntfy topic of phone")
    req.add_argument("--title", default="sudo request")
    req.add_argument("--script", help="file whose content to show")
    req.add_argument("--note", help="requester's unverified explanation")
    req.add_argument("--exec", action="store_true", help="run argv if ok")
    req.add_argument("argv", nargs="+")
    args = parser.parse_args()
    args.page = args.page.split("#")[0]
    return cmd_register(args) if args.cmd == "register" else cmd_request(args)


if __name__ == "__main__":
    sys.exit(main())
