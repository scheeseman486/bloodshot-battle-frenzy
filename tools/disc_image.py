#!/usr/bin/env python3
"""Read the original CD image into memory without extracting its contents.

Development bridge for Godot: JSON on stdout, read-only libchdr access. The
supported format is deliberately narrow: standalone CHD v5, track 1 MODE1_RAW
or MODE1, and single-extent ISO9660 files. Unsupported formats fail explicitly.
"""
from __future__ import annotations

import argparse
from collections import OrderedDict
import ctypes as C
import ctypes.util
import json
from pathlib import Path
import re
import struct
import sys

SECTOR_BYTES = 2048
MAX_READ = 16 * 1024 * 1024


class ChdImage:
    """Read only the first data track; cache at most eight decompressed hunks."""

    def __init__(self, path: Path):
        self.handle = C.c_void_p()
        with path.open("rb") as source:
            header = source.read(124)
        if len(header) != 124 or header[:8] != b"MComprHD" or struct.unpack_from(">I", header, 12)[0] != 5:
            raise ValueError("Expected a standalone CHD v5 image")
        if any(header[104:124]):
            raise ValueError("Parent/differential CHDs are not supported")
        self.logical_bytes = struct.unpack_from(">Q", header, 32)[0]
        self.hunk_bytes, self.unit_bytes = struct.unpack_from(">II", header, 56)
        if self.unit_bytes != 2448 or not 2448 <= self.hunk_bytes <= 512 * 1024:
            raise ValueError("Unsupported CD hunk/unit geometry")
        library = ctypes.util.find_library("chdr")
        if not library:
            raise RuntimeError("libchdr is required to read the original disc")
        self.lib = C.CDLL(library)
        self.lib.chd_open.argtypes = [C.c_char_p, C.c_int, C.c_void_p, C.POINTER(C.c_void_p)]
        self.lib.chd_open.restype = C.c_int
        self.lib.chd_close.argtypes = [C.c_void_p]
        self.lib.chd_read.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p]
        self.lib.chd_read.restype = C.c_int
        self.lib.chd_get_metadata.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p,
                                            C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32), C.POINTER(C.c_uint8)]
        self.lib.chd_get_metadata.restype = C.c_int
        self.lib.chd_error_string.argtypes = [C.c_int]
        self.lib.chd_error_string.restype = C.c_char_p
        self.cache: OrderedDict[int, bytes] = OrderedDict()
        self._check(self.lib.chd_open(str(path.resolve()).encode(), 1, None, C.byref(self.handle)))
        try:
            meta = C.create_string_buffer(1024)
            length, tag, flags = C.c_uint32(), C.c_uint32(), C.c_uint8()
            self._check(self.lib.chd_get_metadata(self.handle, int.from_bytes(b"CHT2", "big"), 0,
                                                 meta, len(meta), C.byref(length), C.byref(tag), C.byref(flags)))
            self.track_metadata = meta.value.decode("ascii")
            fields = dict(re.findall(r"(\w+):([^ ]+)", self.track_metadata))
            if fields.get("TRACK") != "1" or fields.get("TYPE") not in ("MODE1_RAW", "MODE1"):
                raise ValueError("Track 1 must be MODE1_RAW or MODE1")
            if int(fields.get("PREGAP", "0")) != 0:
                raise ValueError("Track 1 pregaps require an explicit mapping")
            self.sector_count = int(fields["FRAMES"])
            self.payload_offset = 16 if fields["TYPE"] == "MODE1_RAW" else 0
            self.chd_sha1 = header[84:104].hex()
        except Exception:
            self.close()
            raise

    def _check(self, result: int) -> None:
        if result:
            raise ValueError(self.lib.chd_error_string(result).decode())

    def _read(self, offset: int, count: int) -> bytes:
        if offset < 0 or count < 0 or offset + count > self.logical_bytes:
            raise ValueError("Read outside CHD logical range")
        result = bytearray()
        while count:
            hunk, inside = divmod(offset, self.hunk_bytes)
            if hunk not in self.cache:
                data = C.create_string_buffer(self.hunk_bytes)
                self._check(self.lib.chd_read(self.handle, hunk, data))
                self.cache[hunk] = data.raw
                if len(self.cache) > 8:
                    self.cache.popitem(last=False)
            self.cache.move_to_end(hunk)
            take = min(count, self.hunk_bytes - inside)
            result.extend(self.cache[hunk][inside:inside + take])
            count -= take
            offset += take
        return bytes(result)

    def read_sector(self, lba: int) -> bytes:
        if not 0 <= lba < self.sector_count:
            raise ValueError("Read outside the first data track")
        return self._read(lba * self.unit_bytes + self.payload_offset, SECTOR_BYTES)

    def close(self) -> None:
        if self.handle.value:
            self.lib.chd_close(self.handle)
            self.handle = C.c_void_p()

    def __enter__(self) -> ChdImage:
        return self

    def __exit__(self, *_args) -> None:
        self.close()


def dual_u32(data: bytes, offset: int) -> int:
    """ISO9660 stores little- and big-endian copies; reject disagreement."""
    little = struct.unpack_from("<I", data, offset)[0]
    if little != struct.unpack_from(">I", data, offset + 4)[0]:
        raise ValueError("Inconsistent ISO9660 extent or length")
    return little


class Iso9660:
    """Small bounded ISO9660 reader; no filesystem writes and no host paths."""

    def __init__(self, source):
        self.source = source
        pvd = source.read_sector(16)
        if pvd[:7] != b"\x01CD001\x01":
            raise ValueError("Missing ISO9660 primary volume descriptor")
        if pvd[128:132] != b"\x00\x08\x08\x00":
            raise ValueError("Only 2048-byte ISO logical blocks are supported")
        self.volume = pvd[40:72].decode("ascii").strip()
        self.volume_sectors = dual_u32(pvd, 80)
        if self.volume_sectors > source.sector_count:
            raise ValueError("ISO volume exceeds data track")
        self.files: dict[str, dict] = {}
        self._visited: set[tuple[int, int]] = set()
        self._walk(dual_u32(pvd, 158), dual_u32(pvd, 166), "", 0)

    def _extent(self, lba: int, size: int) -> bytes:
        if size < 0 or size > MAX_READ or lba < 0 or lba + (size + 2047) // 2048 > self.volume_sectors:
            raise ValueError("Invalid or oversized ISO extent")
        return b"".join(self.source.read_sector(i) for i in range(lba, lba + (size + 2047) // 2048))[:size]

    def _walk(self, lba: int, size: int, prefix: str, depth: int) -> None:
        if depth > 16 or (lba, size) in self._visited:
            raise ValueError("Cyclic or deeply nested ISO directory")
        self._visited.add((lba, size))
        data = self._extent(lba, size)
        offset = 0
        while offset < len(data):
            length = data[offset]
            if not length:
                offset = (offset // 2048 + 1) * 2048
                continue
            if length < 34 or offset + length > len(data) or offset % 2048 + length > 2048:
                raise ValueError("Truncated ISO directory record")
            record = data[offset:offset + length]
            offset += length
            name_length = record[32]
            if 33 + name_length > length:
                raise ValueError("Truncated ISO filename")
            name_bytes = record[33:33 + name_length]
            if name_bytes in (b"\0", b"\1"):
                continue
            name = name_bytes.decode("ascii").split(";")[0]
            if not name or name in (".", "..") or any(c in name for c in "/\\\0"):
                raise ValueError("Unsafe ISO filename")
            if record[1] or record[26] or record[27] or record[25] & 0x80:
                raise ValueError("Extended/interleaved/multi-extent files are unsupported")
            start, count = dual_u32(record, 2), dual_u32(record, 10)
            if start + (count + 2047) // 2048 > self.volume_sectors:
                raise ValueError("File exceeds ISO volume")
            path = f"{prefix}/{name}"
            if record[25] & 2:
                self._walk(start, count, path, depth + 1)
            else:
                if path in self.files or len(self.files) >= 10000:
                    raise ValueError("Duplicate path or too many ISO entries")
                self.files[path] = {"path": path, "lba": start, "size": count}

    def read_file(self, name: str, offset: int = 0, count: int | None = None) -> bytes:
        entry = self.files[name]
        count = entry["size"] - offset if count is None else count
        if offset < 0 or count < 0 or offset + count > entry["size"] or count > MAX_READ:
            raise ValueError("Read outside file bounds")
        first, inside = divmod(offset, SECTOR_BYTES)
        return self._extent(entry["lba"] + first, inside + count)[inside:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("catalog")
    read = commands.add_parser("read")
    read.add_argument("path")
    read.add_argument("--offset", type=int, default=0)
    read.add_argument("--count", type=int)
    args = parser.parse_args()
    try:
        with ChdImage(args.image) as image:
            disc = Iso9660(image)
            if args.command == "catalog":
                result = {"volume": disc.volume, "chd_sha1": image.chd_sha1,
                          "track": image.track_metadata, "files": list(disc.files.values())}
            else:
                data = disc.read_file(args.path, args.offset, args.count)
                result = {"path": args.path, "offset": args.offset, "size": len(data), "hex": data.hex()}
        print(json.dumps({"ok": True, **result}))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, UnicodeError, struct.error) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
