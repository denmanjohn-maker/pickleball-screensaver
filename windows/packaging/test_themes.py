import struct
import unittest
from pathlib import Path
from unittest.mock import Mock
from audit_themes import cabinet_files


class CabinetTests(unittest.TestCase):
    def test_zip_renaming_is_rejected(self):
        with self.assertRaises(ValueError):
            cabinet_files(Mock(read_bytes=lambda: b"PK" + bytes(40)))

    def test_cab_inventory_and_truncation_are_verified(self):
        header = bytearray(36)
        header[:4] = b"MSCF"
        entry = struct.pack("<IHHHHHH", 123, 0, 0, 0, 0, 0, 0) + b"Pickleball.theme\0"
        data = header + entry
        struct.pack_into("<I", data, 8, len(data))
        struct.pack_into("<I", data, 16, 36)
        struct.pack_into("<H", data, 28, 1)
        self.assertEqual(["Pickleball.theme"], cabinet_files(Mock(read_bytes=lambda: bytes(data))))
        with self.assertRaises(ValueError):
            cabinet_files(Mock(read_bytes=lambda: bytes(data[:-1])))
