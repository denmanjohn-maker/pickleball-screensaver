#!/usr/bin/env python3
"""Publish complete native self-contained Windows packages; never activate the saver."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "src/Pickleball.Windows/Pickleball.Windows.csproj"
MACHINES = {"win-x64": 0x8664, "win-arm64": 0xAA64}


def pe_info(path):
    return pe_bytes(path.read_bytes(), path.name)


def pe_bytes(data, name="memory"):
    if data[:2] != b"MZ":
        raise ValueError(f"Not a PE file: {name}")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE signature: {name}")
    machine, sections = struct.unpack_from("<HH", data, pe + 4)
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directory = optional + (112 if magic == 0x20B else 96)
    cli_rva, cli_size = struct.unpack_from("<II", data, directory + 14 * 8)
    il_only = False
    if cli_rva and cli_size:
        for index in range(sections):
            header = optional + optional_size + index * 40
            virtual_size, virtual_rva, raw_size, raw_offset = struct.unpack_from("<IIII", data, header + 8)
            if virtual_rva <= cli_rva < virtual_rva + max(virtual_size, raw_size):
                flags = struct.unpack_from("<I", data, raw_offset + cli_rva - virtual_rva + 16)[0]
                il_only = bool(flags & 1) and not bool(flags & 2)
                break
    return machine, il_only


def audit(directory, rid):
    entries = []
    for path in sorted(directory.rglob("*")):
        if path.suffix.lower() not in (".exe", ".scr", ".dll"):
            continue
        machine, il_only = pe_info(path)
        if path.name in ("Pickleball.Windows.exe", "PickleballScreensaver.scr") and (
                machine != MACHINES[rid] or il_only):
            raise ValueError(f"Apphost must be native {rid}: {path.name}")
        # AnyCPU managed assemblies may have an I386 PE header. Native/R2R files may not.
        if machine != MACHINES[rid] and not (machine == 0x14C and il_only):
            raise ValueError(f"Architecture mismatch: {path.name} has machine 0x{machine:04x} for {rid}")
        entries.append({"file": str(path.relative_to(directory)), "machine": f"0x{machine:04x}", "ilOnly": il_only})
    if not entries:
        raise ValueError("No PE files found to audit.")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rid", required=True, choices=MACHINES)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--sign", action="store_true", help="Windows only; explicitly configured Authenticode identity")
    args = parser.parse_args()
    output = args.output.resolve()
    # All project commands and outputs stay in this checkout.
    if not output.is_relative_to(ROOT):
        parser.error("--output must be beneath windows/ in this worktree")
    version = subprocess.check_output(
        [args.dotnet, "msbuild", str(PROJECT), "-getProperty:Version"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", version):
        raise ValueError("Cannot determine the Windows product version.")
    name = f"PickleballScreensaver-{version}-{args.rid}"
    single = output / name
    folder = output / f"{name}-folder"
    if single.exists() or folder.exists():
        raise ValueError("Output directories already exist; use a new --output directory to avoid stale dependencies.")
    common = [args.dotnet, "publish", str(PROJECT), "-c", "Release", "-r", args.rid, "--self-contained", "true",
              "-p:PublishTrimmed=false", "-p:PublishAot=false", "-p:DebugType=None", "-p:DebugSymbols=false",
              "--nologo"]
    # An unbundled companion lets us inspect every native dependency before bundling.
    subprocess.run(common + ["-p:PublishSingleFile=false", "-o", str(folder)], cwd=ROOT, check=True)
    dependencies = audit(folder, args.rid)
    subprocess.run(common + ["-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true",
                             "-o", str(single)], cwd=ROOT, check=True)
    for directory in (folder, single):
        (directory / "Pickleball.Windows.exe").rename(directory / "PickleballScreensaver.scr")
        (directory / "README.txt").write_text(
            f"{'SIGNED' if args.sign else 'UNSIGNED DEVELOPMENT'} WINDOWS PICKLEBALL {version} ({args.rid}).\n"
            "Five appearances; singles/doubles; optional weather, tournaments and daily drills.\n"
            "No registration or system policy changes are performed. No .NET install is needed.\n"
            "No arguments or /c: configure; /p HWND: offline embedded preview; /s: fullscreen.\n"
            "Keep ALL files together. Single-file native dependencies extract to the .NET user cache.\n"
            "Windows 11 native runtime acceptance is required before distribution.\n", encoding="utf-8")
        for script in ("Maintain.ps1",):
            import shutil
            shutil.copyfile(ROOT / "packaging" / script, directory / script)
        if args.sign:
            subprocess.run(["powershell", "-NoProfile", "-File", str(ROOT / "packaging/sign.ps1"),
                            "-Path", str(directory / "PickleballScreensaver.scr")], check=True)
    bundled_audit = audit(single, args.rid)
    (single / "architecture.json").write_text(json.dumps({
        "rid": args.rid, "version": version, "signed": args.sign,
        "apphost": bundled_audit, "unbundledDependencyAudit": dependencies
    }, indent=2) + "\n", encoding="utf-8")
    # Preserve complete folders, including any SDK-emitted sidecars; never zip only an assumed apphost.
    for directory in (single, folder):
        archive = output / f"{directory.name}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for path in sorted(directory.rglob("*")):
                if path.is_file():
                    bundle.write(path, Path(directory.name) / path.relative_to(directory))
        checksum = hashlib.sha256()
        with archive.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(block)
        digest = checksum.hexdigest()
        archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
        print(f"Published {archive.name}; SHA256={digest}")


if __name__ == "__main__":
    main()
