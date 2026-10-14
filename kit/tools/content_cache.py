"""Validate private generated trees by input identity and complete output hashes."""
import hashlib
import json
from pathlib import Path

MANIFEST = ".content-cache.json"


def files(root):
    root = Path(root)
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("Generated cache contains a symlink: %s" % path)
        if path.is_file() and path not in (root / MANIFEST, root / (MANIFEST + ".new")):
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def fingerprint(paths, settings=()):
    digest = hashlib.sha256(json.dumps(settings, sort_keys=True).encode())
    for path in sorted(map(Path, paths)):
        digest.update(str(path).encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def valid(root, key):
    try:
        saved = json.loads((Path(root) / MANIFEST).read_text())
        return (saved.get("schema") == 1 and saved.get("key") == key and
                bool(saved.get("files")) and saved["files"] == files(root))
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def stamp(root, key):
    root = Path(root)
    contents = files(root)
    if not contents:
        raise ValueError("Cannot cache an empty generated tree")
    temporary = root / (MANIFEST + ".new")
    temporary.write_text(json.dumps({"schema": 1, "key": key, "files": contents},
                                    sort_keys=True) + "\n")
    temporary.replace(root / MANIFEST)
