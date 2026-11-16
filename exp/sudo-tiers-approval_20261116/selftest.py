"""Offline check of approve.verify with a software authenticator."""

import hashlib
import json

import approve
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

PAGE = "https://example.github.io/uraj/"


def assertion(
    key,
    raw,
    origin="https://example.github.io",
    rp_id="example.github.io",
    flags=0x05,
):
    client = json.dumps(
        {
            "type": "webauthn.get",
            "challenge": approve.b64url(hashlib.sha256(raw).digest()),
            "origin": origin,
        }
    ).encode()
    auth = hashlib.sha256(rp_id.encode()).digest() + bytes([flags]) + b"\0" * 4
    sig = key.sign(
        auth + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256())
    )
    return {
        "credentialId": "c1",
        "authenticatorData": approve.b64url(auth),
        "clientDataJSON": approve.b64url(client),
        "signature": approve.b64url(sig),
    }


def main():
    key = ec.generate_private_key(ec.SECP256R1())
    spki = key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    keys = {"c1": approve.b64url(spki)}
    raw = b'{"id":"x","argv":["true"]}'
    cases = {
        "valid": (assertion(key, raw), raw, None),
        "other request": (assertion(key, raw), b"{}", "challenge"),
        "other origin": (
            assertion(key, raw, origin="https://evil.example"),
            raw,
            "origin",
        ),
        "other rpId": (assertion(key, raw, rp_id="evil.example"), raw, "rpId"),
        "no UV": (assertion(key, raw, flags=0x01), raw, "verification"),
        "other key": (
            assertion(ec.generate_private_key(ec.SECP256R1()), raw),
            raw,
            "signature",
        ),
    }
    for name, (msg, data, want) in cases.items():
        got = approve.verify(msg, data, keys, PAGE)
        ok = got is None if want is None else (got and want in got)
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
        assert ok


if __name__ == "__main__":
    main()
