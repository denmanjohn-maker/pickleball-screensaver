"""Pure in-memory PE scanner regressions; no packages, installs, or file writes."""

from pathlib import Path
import struct
import unittest
from unittest.mock import patch

import publish


def fixture(machine, cli_flags=None):
    data = bytearray(1024)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, machine, 1)
    struct.pack_into("<H", data, 0x94, 240)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B)
    if cli_flags is not None:
        struct.pack_into("<II", data, optional + 112 + 14 * 8, 0x2000, 72)
        struct.pack_into("<IIII", data, optional + 240 + 8, 72, 0x2000, 72, 0x300)
        struct.pack_into("<I", data, 0x310, cli_flags)
    return bytes(data)


class PeTests(unittest.TestCase):
    def test_native_architectures(self):
        for machine in (0x8664, 0xAA64):
            self.assertEqual((machine, False), publish.pe_bytes(fixture(machine)))

    def test_il_only_and_required_32bit(self):
        self.assertEqual((0x14C, True), publish.pe_bytes(fixture(0x14C, 1)))
        self.assertEqual((0x14C, False), publish.pe_bytes(fixture(0x14C, 3)))

    def test_invalid_signature_rejected(self):
        with self.assertRaises(ValueError):
            publish.pe_bytes(b"Not an executable")
        data = bytearray(fixture(0x8664))
        data[0x80] = 0
        with self.assertRaises(ValueError):
            publish.pe_bytes(data)

    def test_audit_rejects_mismatched_native_and_x86_required(self):
        for machine, il_only in ((0xAA64, False), (0x14C, False)):
            with patch.object(Path, "rglob", return_value=[Path("fixture.dll")]):
                with patch.object(publish, "pe_info", return_value=(machine, il_only)):
                    with self.assertRaises(ValueError):
                        publish.audit(Path("."), "win-x64")

    def test_audit_accepts_anycpu_il_and_matching_native(self):
        for machine, il_only in ((0x14C, True), (0x8664, False)):
            with patch.object(Path, "rglob", return_value=[Path("fixture.dll")]):
                with patch.object(publish, "pe_info", return_value=(machine, il_only)):
                    self.assertEqual(1, len(publish.audit(Path("."), "win-x64")))

    def test_empty_audit_rejected(self):
        with patch.object(Path, "rglob", return_value=[]):
            with self.assertRaises(ValueError):
                publish.audit(Path("."), "win-arm64")

    def test_apphost_cannot_be_anycpu_or_il_only(self):
        for machine, il_only in ((0x14C, True), (0x8664, True), (0xAA64, False)):
            with patch.object(Path, "rglob", return_value=[Path("PickleballScreensaver.scr")]):
                with patch.object(publish, "pe_info", return_value=(machine, il_only)):
                    with self.assertRaises(ValueError):
                        publish.audit(Path("."), "win-x64")


if __name__ == "__main__":
    unittest.main()
