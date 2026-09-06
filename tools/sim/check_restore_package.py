#!/usr/bin/env python3
"""Restore preparation boundaries, using only synthetic data."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_restore", REPO / "scripts/prepare_restore.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def checksums(rom):
    rom[0x14D] = (-sum(rom[0x134:0x14D]) - 25) & 0xFF
    checksum = (sum(rom[:0x14E]) + sum(rom[0x150:])) & 0xFFFF
    rom[0x14E:0x150] = checksum.to_bytes(2, "big")
    return rom


def fixture():
    # No extracted ROM data, logo, or real save contents are test fixtures.
    rom = bytearray(524288)
    rom[0x134:0x144] = b"TEST RESTORE\0\0\0\0"
    rom[0x147:0x14A] = bytes((0x03, 0x04, 0x02))
    return bytes(checksums(rom)), bytes((i * 17 + 3) & 255 for i in range(8192))


class RestorePackageTests(unittest.TestCase):
    def test_binary_contract_and_payload_binding(self):
        rom, save = fixture()
        meta = PREPARE.make_manifest(rom, save)
        self.assertEqual(len(meta), 64)
        self.assertEqual(meta[:4], b"CTRS")
        words = struct.unpack("<16I", meta)
        self.assertEqual(words[1:3], (1, 8192))
        self.assertEqual(words[3:6], (zlib.crc32(save), 524288, zlib.crc32(rom)))
        self.assertEqual(words[6], 0x00040203)
        self.assertEqual(words[7], rom[0x14D])
        self.assertEqual(meta[32:48], b"TEST RESTORE\0\0\0\0")
        self.assertEqual(meta[48:60], bytes(12))
        self.assertEqual(words[15], zlib.crc32(meta[:60]))
        changed = bytearray(save)
        changed[4000] ^= 1
        changed_meta = PREPARE.make_manifest(rom, changed)
        self.assertNotEqual(meta[12:16], changed_meta[12:16])
        self.assertNotEqual(meta[60:64], changed_meta[60:64])

    def test_crc_standard_vector(self):
        self.assertEqual(PREPARE.crc32(b"123456789"), 0xCBF43926)

    def test_refuses_different_size_mapper_or_color(self):
        rom, save = fixture()
        for offset, value in ((0x147, 0x1B), (0x149, 0x03),
                              (0x143, 0x80), (0x148, 0x03)):
            with self.subTest(offset=offset):
                changed = bytearray(rom)
                changed[offset] = value
                with self.assertRaises(ValueError):
                    PREPARE.make_manifest(checksums(changed), save)
        for changed in (rom[:100], rom[:-1], rom + b"\0"):
            with self.assertRaises(ValueError):
                PREPARE.make_manifest(changed, save)
        oversized = bytearray(rom + rom)
        oversized[0x148] = 5
        with self.assertRaises(ValueError):
            PREPARE.make_manifest(checksums(oversized), save)
        for changed in (b"", save[:-1], save + b"\0", save * 4):
            with self.assertRaises(ValueError):
                PREPARE.make_manifest(rom, changed)

    def test_refuses_header_and_body_corruption(self):
        rom, save = fixture()
        for offset in (0x140, 0x14D, 0x14E, 20000):
            with self.subTest(offset=offset):
                changed = bytearray(rom)
                changed[offset] ^= 1
                with self.assertRaises(ValueError):
                    PREPARE.make_manifest(changed, save)

    def test_outputs_are_raw_and_sources_unchanged(self):
        rom, save = fixture()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rom_path, save_path = root / "input.gb", root / "input.sav"
            rom_path.write_bytes(rom)
            save_path.write_bytes(save)
            output = root / "out"
            PREPARE.prepare(rom_path, save_path, output)
            self.assertEqual(sorted(p.name for p in output.iterdir()),
                             ["RESTORE.meta", "RESTORE.sav"])
            self.assertEqual((output / "RESTORE.sav").read_bytes(), save)
            self.assertEqual(rom_path.read_bytes(), rom)
            self.assertEqual(save_path.read_bytes(), save)
            with self.assertRaises(FileExistsError):
                PREPARE.prepare(rom_path, save_path, output)
            self.assertEqual((output / "RESTORE.sav").read_bytes(), save)

    def test_existing_or_dangling_target_is_never_overwritten(self):
        rom, save = fixture()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rom_path, save_path = root / "input.gb", root / "input.sav"
            rom_path.write_bytes(rom)
            save_path.write_bytes(save)
            for target in ("RESTORE.sav", "RESTORE.meta"):
                with self.subTest(target=target):
                    output = root / target
                    output.mkdir()
                    (output / target).symlink_to(root / "missing")
                    with self.assertRaises(FileExistsError):
                        PREPARE.prepare(rom_path, save_path, output)
                    self.assertTrue((output / target).is_symlink())
                    self.assertEqual(len(list(output.iterdir())), 1)

    def test_invalid_input_creates_no_output(self):
        rom, save = fixture()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rom_path, save_path = root / "input.gb", root / "input.sav"
            rom_path.write_bytes(rom)
            save_path.write_bytes(save[:-1])
            with self.assertRaises(ValueError):
                PREPARE.prepare(rom_path, save_path, root / "out")
            self.assertFalse((root / "out").exists())


if __name__ == "__main__":
    unittest.main()
