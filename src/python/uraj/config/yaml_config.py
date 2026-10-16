"""Read host-specific YAML declarations for JSON configuration outputs."""

import math
from pathlib import Path

import yaml


def validate_json_value(value, ancestors=None):
    """Reject cycles and YAML values that cannot round-trip through JSON."""
    ancestors = set() if ancestors is None else ancestors
    if isinstance(value, (dict, list)):
        identity = id(value)
        if identity in ancestors:
            raise ValueError("recursive YAML aliases are not supported")
        ancestors.add(identity)
        try:
            if isinstance(value, dict):
                if any(not isinstance(key, str) for key in value):
                    raise ValueError("configuration keys must be strings")
                values = value.values()
            else:
                values = value
            for child in values:
                validate_json_value(child, ancestors)
        finally:
            ancestors.remove(identity)
    elif isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("configuration numbers must be finite")
    elif value is not None and not isinstance(value, (str, bool, int)):
        raise ValueError("configuration must use JSON-compatible YAML values")


def read_yaml(path):
    """Load a mapping without evaluating tags or echoing private source text."""
    try:
        document = yaml.safe_load(Path(path).read_text())
    except yaml.YAMLError:
        raise ValueError(f"invalid configuration YAML: {path}") from None
    if not isinstance(document, dict):
        raise ValueError(f"configuration must be a YAML mapping: {path}")
    validate_json_value(document)
    return document


def public_layer(path, hostname):
    """Select one explicit host from a shared YAML file with reusable anchors."""
    document = read_yaml(path)
    if set(document) - {"templates", "hosts"}:
        raise ValueError("public YAML accepts only templates and hosts")
    hosts = document.get("hosts")
    if not isinstance(hosts, dict) or hostname not in hosts:
        raise ValueError(f"public configuration has no host entry: {hostname}")
    layer = hosts[hostname]
    if not isinstance(layer, dict):
        raise ValueError("host configuration must be a YAML mapping")
    return layer


def private_layer(path, hostname):
    """Read a decrypted per-host layer, rejecting a different host's file."""
    document = read_yaml(path)
    if document.pop("hostname", None) != hostname:
        raise ValueError("private configuration hostname does not match")
    return document
