"""Writable JSON configuration with ordered, recursive overrides.

Objects merge recursively; arrays and scalars replace; null remains a value.
Unlike RFC 7396, deletion is explicit, using arrays of object keys. Inputs are
copied. Application-specific policy belongs to the caller.
"""

import copy
import json
import os
import tempfile
from pathlib import Path


def merge_objects(base, override):
    """Return a deep copy of BASE with OVERRIDE applied recursively."""
    if not isinstance(base, dict) or not isinstance(override, dict):
        raise ValueError("configuration layers must be JSON objects")
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict):
            previous = result.get(key)
            result[key] = merge_objects(
                previous if isinstance(previous, dict) else {}, value
            )
        else:
            result[key] = copy.deepcopy(value)
    return result


def read_object(path):
    """Read a required JSON object; missing or malformed layers fail closed."""
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError(f"configuration must be a JSON object: {path}")
    return value


def apply_layer(base, layer):
    """Apply a declaration containing overrides and optional delete paths."""
    if not isinstance(layer, dict) or set(layer) - {"overrides", "delete"}:
        raise ValueError("layer must contain only overrides and delete")
    paths = layer.get("delete", [])
    if not isinstance(paths, list):
        raise ValueError("delete must be an array of key paths")
    result = copy.deepcopy(base)
    for path in paths:
        if (
            not isinstance(path, list)
            or not path
            or any(not isinstance(key, str) for key in path)
        ):
            raise ValueError("delete paths must be nonempty arrays of strings")
        parent = result
        for key in path[:-1]:
            parent = parent.get(key) if isinstance(parent, dict) else None
        if isinstance(parent, dict):
            parent.pop(path[-1], None)
    return merge_objects(result, layer.get("overrides", {}))


def update_file(path, update, backup_suffix=".before-activation"):
    """Merge owned fields, preserving other settings and unchanged files."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f"Refusing managed symlink: {path}")
    original = path.read_bytes() if path.exists() else None
    settings = json.loads(original) if original is not None else {}
    if not isinstance(settings, dict):
        raise ValueError("configuration must be a JSON object")
    update(settings)
    if original is not None and settings == json.loads(original):
        path.chmod(0o600)
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if original is not None:
        backup = path.with_name(path.name + backup_suffix)
        if backup.is_symlink():
            raise ValueError(f"Refusing backup symlink: {backup}")
        if not backup.exists():
            descriptor = os.open(
                backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
            )
            with os.fdopen(descriptor, "wb") as output:
                output.write(original)
        backup.chmod(0o600)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
