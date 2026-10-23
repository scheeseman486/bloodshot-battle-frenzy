#!/usr/bin/env python3
"""Install a supplied verified Godot executable and build the native extension."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENGINE_SHA256 = "32f8d7596c4b41185512b1c49d69f2da3be018fd784a53e349fa92a98a97bcde"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=os.environ.get("GODOT_BIN"))
    parser.add_argument("--engine-only", action="store_true", help="Install the engine without building the extension")
    args = parser.parse_args()
    target = ROOT / "tools/bin/godot-4.7.1"
    source = args.godot.expanduser().resolve() if args.godot else target
    if not source.is_file():
        parser.error("Supply the official Godot 4.7.1 Linux x86_64 executable with --godot or GODOT_BIN")
    with source.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != ENGINE_SHA256:
        parser.error("Engine checksum differs from the verified Godot 4.7.1 Linux x86_64 executable")
    target.parent.mkdir(parents=True, exist_ok=True)
    if source != target.resolve():
        temporary = target.with_suffix(".tmp")
        shutil.copyfile(source, temporary)
        temporary.chmod(0o755)
        os.replace(temporary, target)
    if not args.engine_only:
        subprocess.run([sys.executable, str(ROOT / "tools/build_audio.py")], check=True)
    print("Ready: tools/play launches the game; tools/editor opens the project and disc dock.")


if __name__ == "__main__":
    main()
