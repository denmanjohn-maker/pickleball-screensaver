import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


def theme_fixture(label):
    header = bytearray(36)
    header[:4] = b"MSCF"
    entries = b"".join(
        struct.pack("<IHHHHHH", 123, 0, 0, 0, 0, 0, 0) + name.encode("ascii") + b"\0"
        for name in (f"Pickleball-{label}.theme", f"DesktopBackground/{label}-3840x2160.png",
                     f"DesktopBackground/{label}-5120x2160.png")
    )
    struct.pack_into("<I", header, 8, len(header) + len(entries))
    struct.pack_into("<I", header, 16, 36)
    struct.pack_into("<H", header, 28, 3)
    return header + entries


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "PickleballScreensaver").mkdir()
        (self.root / "windows").mkdir()

    def product(self, mac="2.3", windows="2.3.0", tag=""):
        (self.root / "PickleballScreensaver/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleShortVersionString": mac}))
        (self.root / "windows/Directory.Build.props").write_text(
            f"<Project><PropertyGroup><Version>{windows}</Version></PropertyGroup></Project>")
        return release.versions(self.root, tag)

    def test_normalized_two_and_three_component_versions(self):
        self.assertEqual(
            {"mac_version": "2.3", "version": "2.3.0", "upgrade_version": "2.3.1"},
            self.product(tag="v2.3"))
        self.assertEqual("2.3.5", self.product("2.3.4", "2.3.4", "v2.3.4")["upgrade_version"])

    def test_mismatched_versions_and_tags_fail(self):
        for mac, windows, tag in (("2.3", "2.4.0", ""), ("2.3", "2.3.0", "v2.3.0"),
                                  ("2.3", "2.3.0", "v2.2"), ("bad", "2.3.0", ""),
                                  ("2.3", "", "")):
            with self.subTest(mac=mac, windows=windows, tag=tag), self.assertRaises(ValueError):
                self.product(mac, windows, tag)

    def test_msi_limits_and_upgrade_rollover(self):
        self.assertEqual("1.3.0", release.next_version("1.2.65535"))
        self.assertEqual("2.0.0", release.next_version("1.255.65535"))
        for version in ("1.2", "1.2.3-beta", "1.2.3+build", "-1.2.3", "01.2.3",
                        "256.0.0", "1.256.0", "1.0.65536", "255.255.65535"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.next_version(version)

    def test_existing_public_releases_and_drafts_rejected(self):
        for draft in (False, True):
            pages = [[{"tag_name": "v2.2", "draft": False}], [{"tag_name": "v2.3", "draft": draft}]]
            with self.subTest(draft=draft), self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                release.check_new_release(pages, "v2.3")
        release.check_new_release(pages, "v2.4")
        release.check_new_release([[]], "v2.4")


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = root / "downloads"
        self.source.mkdir()
        self.output = root / "release"
        self.product = {"mac_version": "2.3", "version": "2.3.0"}
        for name in release.mac_packages("2.3"):
            (self.source / name).write_bytes(b"macOS " + Path(name).suffix.encode("ascii"))
        for name in release.windows_packages("2.3.0"):
            path = self.source / name
            if name.endswith(".zip"):
                rid = next(rid for rid in release.RIDS if rid in name)
                prefix = path.stem
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(f"{prefix}/PickleballScreensaver.scr", b"native apphost")
                    archive.writestr(f"{prefix}/architecture.json", json.dumps(
                        {"version": "2.3.0", "rid": rid, "signed": False}))
                    archive.writestr(f"{prefix}/sidecar.dll", b"SDK sidecar")
            elif name.endswith(".deskthemepack"):
                label = name.removeprefix("Pickleball-").removesuffix(".deskthemepack")
                path.write_bytes(theme_fixture(label))
            else:
                path.write_bytes(b"MSI fixture")
            release.write_checksum(path)

    def test_complete_inventory_and_alias_checksums(self):
        assets = release.stage(self.source, self.output, self.product)
        self.assertEqual(32, len(assets))
        for rid in release.RIDS:
            for suffix in (".msi", ".zip", "-folder.zip"):
                alias = self.output / f"PickleballScreensaver-{rid}{suffix}"
                versioned = self.output / f"PickleballScreensaver-2.3.0-{rid}{suffix}"
                self.assertEqual(versioned.read_bytes(), alias.read_bytes())
                release.verify_checksum(alias, alias.with_name(alias.name + ".sha256"))
        self.assertEqual({Path(asset).name for asset in assets}, {path.name for path in self.output.iterdir()})

    def test_nested_downloaded_artifacts_flatten_to_exact_inventory(self):
        for path in list(self.source.iterdir()):
            artifact = next((rid for rid in release.RIDS if rid in path.name),
                            "themes" if ".deskthemepack" in path.name else "macos")
            directory = self.source / artifact
            if ".msi" in path.name:
                directory /= "installers"
            directory.mkdir(parents=True, exist_ok=True)
            path.rename(directory / path.name)
        assets = release.stage(self.source, self.output, self.product)
        self.assertEqual(32, len(assets))
        self.assertTrue(all(Path(asset).parent == self.output for asset in assets))

    def test_stage_cli_writes_exact_multiline_github_output(self):
        github_output = self.output.parent / "github-output"
        argv = ["release.py", "stage", "--tag", "v2.3", "--input", str(self.source),
                "--output", str(self.output), "--github-output", str(github_output)]
        with patch("sys.argv", argv), patch.object(release, "versions", return_value=self.product):
            with redirect_stdout(io.StringIO()):
                release.main()
        lines = github_output.read_text().splitlines()
        self.assertEqual("files<<RELEASE_FILES", lines[0])
        self.assertEqual("RELEASE_FILES", lines[-1])
        self.assertEqual(32, len(lines[1:-1]))
        self.assertEqual(set(lines[1:-1]), {path.as_posix() for path in self.output.iterdir()})

    def test_missing_architecture_fails_before_staging(self):
        (self.source / "PickleballScreensaver-2.3.0-win-arm64.msi").unlink()
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            release.stage(self.source, self.output, self.product)
        self.assertFalse(self.output.exists())

    def test_diagnostics_and_synthetic_upgrade_never_promoted(self):
        for name in ("fixture.png", "install.log", "PickleballScreensaver-2.3.1-win-x64.msi"):
            extra = self.source / name
            extra.write_bytes(b"test-only")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unexpected"):
                release.stage(self.source, self.output, self.product)
            extra.unlink()

    def test_corrupt_checksum_or_wrong_checksum_filename_fails(self):
        path = self.source / "PickleballScreensaver-2.3.0-win-x64.msi"
        checksum = path.with_name(path.name + ".sha256")
        for text in (f"{'0' * 64}  {path.name}\n", f"{release.digest(path)}  wrong.msi\n"):
            checksum.write_text(text)
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "Invalid SHA-256"):
                release.stage(self.source, self.output, self.product)

    def test_duplicate_asset_names_rejected(self):
        nested = self.source / "diagnostics"
        nested.mkdir()
        (nested / "PickleballScreensaver.dmg").write_bytes(b"duplicate")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            release.stage(self.source, self.output, self.product)

    def test_mac_aliases_must_match(self):
        (self.source / "PickleballScreensaver.dmg").write_bytes(b"wrong release")
        with self.assertRaisesRegex(ValueError, "macOS versionless"):
            release.stage(self.source, self.output, self.product)

    def test_archive_metadata_and_path_checks(self):
        path = self.source / "PickleballScreensaver-2.3.0-win-x64.zip"
        prefix = path.stem
        for metadata in ({"version": "2.3.0", "rid": "win-arm64", "signed": False},
                         {"version": "2.2.0", "rid": "win-x64", "signed": False},
                         {"version": "2.3.0", "rid": "win-x64", "signed": True}):
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(f"{prefix}/PickleballScreensaver.scr", b"apphost")
                archive.writestr(f"{prefix}/architecture.json", json.dumps(metadata))
            release.write_checksum(path)
            with self.subTest(metadata=metadata), self.assertRaisesRegex(ValueError, "unsigned packages"):
                release.stage(self.source, self.output, self.product)
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr(f"{prefix}/../test.scr", b"wrong path")
        release.write_checksum(path)
        with self.assertRaisesRegex(ValueError, "archive paths"):
            release.stage(self.source, self.output, self.product)

    def test_invalid_theme_rejected_even_with_valid_checksum(self):
        path = self.source / release.THEMES[0]
        path.write_bytes(b"PK" + bytes(40))
        release.write_checksum(path)
        with self.assertRaisesRegex(ValueError, "must be a CAB"):
            release.stage(self.source, self.output, self.product)

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("untouched")
        with self.assertRaises(FileExistsError):
            release.stage(self.source, self.output, self.product)
        self.assertEqual("untouched", sentinel.read_text())


if __name__ == "__main__":
    unittest.main()
from contextlib import redirect_stdout
import io
