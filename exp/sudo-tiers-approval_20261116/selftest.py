"""Offline check of approve.verify with a software authenticator."""

import hashlib
import json

import approve
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric import ed25519

PAGE = "https://arbiter.example/"


def assertion(
    key,
    raw,
    origin="https://arbiter.example",
    rp_id="arbiter.example",
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
    ed_spki = (
        ed25519.Ed25519PrivateKey.generate()
        .public_key()
        .public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    )
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
        "missing fields": ({"credentialId": "c1"}, raw, "malformed"),
        "clientData not JSON": (
            dict(assertion(key, raw), clientDataJSON=approve.b64url(b"x")),
            raw,
            "malformed",
        ),
        "short authenticatorData": (
            dict(assertion(key, raw), authenticatorData=approve.b64url(b"x")),
            raw,
            "too short",
        ),
        "bad base64": (
            dict(assertion(key, raw), signature="!!!"),
            raw,
            "signature",
        ),
        "non-P-256 key": (
            assertion(key, raw),
            raw,
            "malformed",
            {"c1": approve.b64url(ed_spki)},
        ),
    }
    for name, (msg, data, want, *case_keys) in cases.items():
        got = approve.verify(msg, data, (case_keys or [keys])[0], PAGE)
        ok = got is None if want is None else (got and want in got)
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
        assert ok


if __name__ == "__main__":
    main()
