"""Validate shared product versions and stage the exact public release inventory."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import xml.etree.ElementTree as ET
import zipfile

from audit_themes import audit as audit_themes
from publish import MACHINES, digest, write_checksum

ROOT = Path(__file__).resolve().parents[2]
RIDS = tuple(MACHINES)
THEMES = ("Pickleball-Classic.deskthemepack", "Pickleball-BlackLight.deskthemepack")
MSI_LIMITS = (255, 255, 65535)


def msi_version(version):
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError(f"Windows version must be a numeric major.minor.patch: {version}")
    parts = tuple(map(int, version.split(".")))
    if any(part > limit for part, limit in zip(parts, MSI_LIMITS)):
        raise ValueError(f"Version exceeds Windows Installer limits: {version}")
    return parts


def next_version(version):
    parts = list(msi_version(version))
    for index in range(2, -1, -1):
        if parts[index] < MSI_LIMITS[index]:
            parts[index] += 1
            parts[index + 1:] = [0] * (2 - index)
            return ".".join(map(str, parts))
    raise ValueError("No higher version available for the synthetic MSI upgrade test")


def versions(root=ROOT, tag=""):
    mac = plistlib.loads((root / "PickleballScreensaver/Info.plist").read_bytes())["CFBundleShortVersionString"]
    windows = ET.parse(root / "windows/Directory.Build.props").findtext("./PropertyGroup/Version")
    if not windows:
        raise ValueError("Missing Windows product version")
    msi_version(windows)
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", mac):
        raise ValueError(f"Invalid macOS product version: {mac}")
    expected = mac + ".0" if len(mac.split(".")) == 2 else mac
    if windows != expected:
        raise ValueError(f"Windows version {windows} must match macOS {expected}")
    if tag and tag != f"v{mac}":
        raise ValueError(f"Tag {tag} must match macOS v{mac} and Windows {windows}")
    return {"mac_version": mac, "version": windows, "upgrade_version": next_version(windows)}


def verify_checksum(path, checksum):
    expected = f"{digest(path)}  {path.name}"
    if checksum.read_text(encoding="ascii").strip() != expected:
        raise ValueError(f"Invalid SHA-256 or checksum filename for {path.name}")


def windows_packages(version):
    return [
        f"PickleballScreensaver-{version}-{rid}{suffix}"
        for rid in RIDS for suffix in (".msi", ".zip", "-folder.zip")
    ] + list(THEMES)


def mac_packages(version):
    return [
        f"PickleballScreensaver{label}{suffix}"
        for label in (f"-{version}", "") for suffix in (".dmg", ".zip")
    ]


def audit_archive(path, version, rid, folder=False):
    prefix = f"PickleballScreensaver-{version}-{rid}" + ("-folder" if folder else "")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(
                not name.startswith(prefix + "/") or "\\" in name or ".." in name.split("/")
                for name in names):
            raise ValueError(f"Unexpected portable archive paths: {path.name}")
        if f"{prefix}/PickleballScreensaver.scr" not in names:
            raise ValueError(f"Missing screensaver in {path.name}")
        if not folder:
            metadata = json.loads(archive.read(f"{prefix}/architecture.json"))
            if metadata.get("rid") != rid or metadata.get("version") != version or metadata.get("signed") is not False:
                raise ValueError(f"Release requires correctly labeled unsigned packages: {path.name}")


def stage(source, output, product):
    mac, version = product["mac_version"], product["version"]
    packages = windows_packages(version)
    expected = set(mac_packages(mac) + packages + [name + ".sha256" for name in packages])
    files = {}
    for path in source.rglob("*"):
        if path.is_file():
            if path.is_symlink() or path.name in files:
                raise ValueError(f"Duplicate or symlink release asset: {path.name}")
            files[path.name] = path
    if set(files) != expected:
        raise ValueError(f"Release inventory mismatch; missing={sorted(expected - files.keys())}, "
                         f"unexpected={sorted(files.keys() - expected)}")
    for name in packages:
        verify_checksum(files[name], files[name + ".sha256"])
    for suffix in (".dmg", ".zip"):
        if digest(files[f"PickleballScreensaver-{mac}{suffix}"]) != digest(files[f"PickleballScreensaver{suffix}"]):
            raise ValueError(f"macOS versionless {suffix} differs from its versioned asset")
    for rid in RIDS:
        for folder in (False, True):
            name = f"PickleballScreensaver-{version}-{rid}" + ("-folder.zip" if folder else ".zip")
            audit_archive(files[name], version, rid, folder)
    # Theme artifacts are uploaded together, independently from the two native jobs.
    if files[THEMES[0]].parent != files[THEMES[1]].parent:
        raise ValueError("Shared theme packs must be in the same artifact")
    audit_themes(files[THEMES[0]].parent)
    output.mkdir(parents=True, exist_ok=False)
    for name, path in sorted(files.items()):
        shutil.copyfile(path, output / name)
    for rid in RIDS:
        for suffix in (".msi", ".zip", "-folder.zip"):
            alias = output / f"PickleballScreensaver-{rid}{suffix}"
            shutil.copyfile(output / f"PickleballScreensaver-{version}-{rid}{suffix}", alias)
            write_checksum(alias)
    return sorted(path.as_posix() for path in output.iterdir())


def check_new_release(pages, tag):
    if any(item["tag_name"] == tag for page in pages for item in page):
        raise ValueError(f"Release {tag} already exists; refusing to overwrite public assets or an existing draft. "
                         "For a failed upload, remove its draft explicitly before retrying.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("version", "stage", "check-new"):
        sub = commands.add_parser(command)
        sub.add_argument("--tag", default="")
        sub.add_argument("--github-output", type=Path)
        if command == "stage":
            sub.add_argument("--input", type=Path, required=True)
            sub.add_argument("--output", type=Path, required=True)
        elif command == "check-new":
            sub.add_argument("--releases", type=Path, required=True)
    args = parser.parse_args()
    product = versions(tag=args.tag)
    if args.command == "version":
        results = "".join(f"{key}={value}\n" for key, value in product.items())
    elif args.command == "stage":
        if not args.tag:
            parser.error("stage requires a version tag")
        assets = stage(args.input, args.output, product)
        results = "files<<RELEASE_FILES\n" + "\n".join(assets) + "\nRELEASE_FILES\n"
    else:
        if not args.tag:
            parser.error("check-new requires a version tag")
        check_new_release(json.loads(args.releases.read_text(encoding="utf-8")), args.tag)
        results = f"Release {args.tag} does not exist; new publication allowed\n"
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(results)
    print(results, end="")


if __name__ == "__main__":
    main()
