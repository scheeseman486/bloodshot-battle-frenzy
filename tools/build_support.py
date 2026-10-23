"""Small shared helpers for checksum-pinned build dependencies."""
import hashlib
import os
from pathlib import Path
import urllib.request


def download(url: str, destination: Path, sha256: str) -> Path:
    """Never execute or extract a cached/downloaded file before verifying it."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        temporary = destination.with_name(destination.name + '.download')
        try:
            urllib.request.urlretrieve(url, temporary)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != sha256:
                raise ValueError('Download checksum mismatch: ' + destination.name)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(destination.read_bytes()).hexdigest() != sha256:
        raise ValueError('Cached dependency checksum mismatch: ' + destination.name)
    return destination
