"""Check real CAB file inventories (not renamed ZIPs), without a decompressor."""
from pathlib import Path
import struct
import sys


def cabinet_files(path):
    data = path.read_bytes()
    if len(data) < 36 or data[:4] != b"MSCF":
        raise ValueError("Desktop theme pack must be a CAB")
    declared_size = struct.unpack_from("<I", data, 8)[0]
    if declared_size != len(data):
        raise ValueError("Truncated CAB")
    cursor = struct.unpack_from("<I", data, 16)[0]
    count = struct.unpack_from("<H", data, 28)[0]
    files = []
    for _ in range(count):
        size = struct.unpack_from("<I", data, cursor)[0]
        attributes = struct.unpack_from("<H", data, cursor + 14)[0]
        cursor += 16
        end = data.index(b"\0", cursor)
        name = data[cursor:end].decode("utf-8" if attributes & 0x80 else "ascii").replace("\\", "/")
        if not size or name.startswith("/") or ".." in name.split("/"):
            raise ValueError("Unsafe or empty CAB entry")
        files.append(name)
        cursor = end + 1
    return files


def audit(directory):
    for label in ("Classic", "BlackLight"):
        path = directory / f"Pickleball-{label}.deskthemepack"
        expected = {f"Pickleball-{label}.theme",
                    f"DesktopBackground/{label}-3840x2160.png",
                    f"DesktopBackground/{label}-5120x2160.png"}
        names = cabinet_files(path)
        if len(names) != 3 or set(names) != expected:
            raise ValueError(f"Unexpected theme pack contents: {names}")
        print(f"PASS: {path.name}, real CAB, exactly one theme and two high-resolution wallpapers")


if __name__ == "__main__":
    audit(Path(sys.argv[1]))
