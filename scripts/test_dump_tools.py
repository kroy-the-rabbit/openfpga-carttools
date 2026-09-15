#!/usr/bin/env python3
"""Synthetic dump checks; no ROMs, DAT downloads, hardware or simulator needed."""
import contextlib
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
import zlib

import match_dats
import verify_dump


def gg_image(size=32768, offset=0x7FF0, code=0xC):
    data = bytearray((i * 37 + (i >> 14)) & 255 for i in range(size))
    data[offset:offset + 16] = b"TMR SEGA\x00\x00\x00\x00\x34\x12\x03\x60"
    data[offset + 15] |= code
    extent = verify_dump.GG_CHECKSUM_SIZES.get(code)
    checksum = verify_dump.gg_checksum(data, offset, extent)
    if checksum is not None:
        data[offset + 10:offset + 12] = checksum.to_bytes(2, "little")
    return data


def dat_xml(data, *, sha1=None, crc=None, size=None):
    # Deliberately shuffled: the former regular expression required name/size/crc.
    return (f'<datafile><game name="Widget Gear (World)"><rom '
            f'sha1="{sha1 or hashlib.sha1(data).hexdigest()}" '
            f'crc="{crc or "%08x" % (zlib.crc32(data) & 0xFFFFFFFF)}" '
            f'size="{len(data) if size is None else size}" '
            'name="Widget Gear &amp; Friends.gg"/></game></datafile>').encode()


class Fixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="gg-dump-tools-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def put(self, data, name="GG0000.gg"):
        path = self.root / name
        path.write_bytes(data)
        return path

    def report(self, data):
        return verify_dump.verify(self.put(data))

    def match(self, path, entries):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            missed = match_dats.report([str(path)], entries)
        return missed, output.getvalue()


class GameGearVerification(Fixture):
    def test_each_header_location_and_checksum_extent(self):
        for size, offset, code in [(8192, 0x1FF0, 0xA), (16384, 0x3FF0, 0xB),
                                   (32768, 0x7FF0, 0xC), (262144, 0x7FF0, 0)]:
            with self.subTest(offset=offset, size=size):
                rep = self.report(gg_image(size, offset, code))
                self.assertEqual(rep.failures, 0)
                text = str(rep.lines)
                self.assertIn("0x%04X" % offset, text)
                self.assertIn("01234 / 3", text)
                self.assertIn("matches; not verification", text)

    def test_checksum_excludes_header_and_honors_extent(self):
        data = gg_image(262144)
        before = verify_dump.gg_checksum(data, 0x7FF0, 32768)
        data[0x7FFA] ^= 255
        data[0x20000] ^= 255
        self.assertEqual(verify_dump.gg_checksum(data, 0x7FF0, 32768), before)
        data[0x1234] ^= 255
        self.assertNotEqual(verify_dump.gg_checksum(data, 0x7FF0, 32768), before)

    def test_underreported_extent_and_bad_checksum_are_diagnostics(self):
        data = gg_image(262144)
        data[0x1000] ^= 1
        rep = self.report(data)
        self.assertEqual(rep.failures, 0)
        self.assertIn("extent differs from file", str(rep.lines))
        self.assertIn("not a failure verdict", str(rep.lines))

    def test_unknown_region_product_and_extent_never_invent_identity(self):
        data = gg_image()
        data[0x7FFC] = 0xFA
        data[0x7FFF] = 0x39
        rep = self.report(data)
        self.assertEqual(rep.failures, 0)
        for expected in ("invalid BCD", "not a usual Game Gear", "unknown", "not evaluated"):
            self.assertIn(expected, str(rep.lines))

    def test_conflicting_headers_report_both(self):
        data = gg_image()
        second = gg_image(8192, 0x1FF0, 0xA)[-16:]
        data[0x1FF0:0x2000] = second
        rep = self.report(data)
        self.assertEqual(rep.failures, 0)
        self.assertIn("conflicting headers", str(rep.lines))
        self.assertIn("0x1FF0, 0x7FF0", str(rep.lines))

    def test_48k_bios_checksum_is_explicitly_unevaluated(self):
        rep = self.report(gg_image(49152, code=0xD))
        self.assertEqual(rep.failures, 0)
        self.assertIn("not evaluated", str(rep.lines))

    def test_missing_header_is_uncertainty_and_truncation_is_failure(self):
        self.assertEqual(self.report(bytes(32768)).failures, 0)
        self.assertIn("none complete", str(self.report(bytes(32768)).lines))
        self.assertGreater(self.report(gg_image()[:-1]).failures, 0)
        self.assertGreater(self.report(b"").failures, 0)

    def test_duplicate_banks_are_not_a_size_or_failure_verdict(self):
        rep = self.report(gg_image() * 4)
        self.assertEqual(rep.failures, 0)
        self.assertIn("repetition does not prove mapper failure or capacity", str(rep.lines))

    def test_reference_catches_corruption_outside_checksum_extent(self):
        data = gg_image(262144)
        expected = dict(sha1=hashlib.sha1(data).hexdigest(),
                        crc32="%08x" % (zlib.crc32(data) & 0xFFFFFFFF), size=len(data))
        self.assertEqual(verify_dump.verify(self.put(data), **expected).failures, 0)
        data[0x20000] ^= 1
        rep = verify_dump.verify(self.put(data), **expected)
        self.assertEqual(rep.failures, 2)
        self.assertIn("matches; not verification", str(rep.lines))

    def test_reference_can_identify_a_headerless_image(self):
        data = bytes(range(256)) * 128
        rep = verify_dump.verify(self.put(data), sha1=hashlib.sha1(data).hexdigest())
        self.assertEqual(rep.failures, 0)
        self.assertIn("reference SHA-1", str(rep.lines))

    def test_reference_cli_validates_scope_and_can_fail(self):
        path = self.put(gg_image())
        command = [sys.executable, str(Path(verify_dump.__file__)), str(path)]
        passed = subprocess.run(command + ["--expect-size", "0x8000"], capture_output=True)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        failed = subprocess.run(command + ["--expect-sha1", "0" * 40], capture_output=True)
        self.assertEqual(failed.returncode, 1, failed.stderr)
        for suffix in (["--expect-sha1", "bad"], ["--expect-size", "0"],
                       [str(path), "--expect-size", "32768"]):
            with self.subTest(suffix=suffix):
                invalid = subprocess.run(command + suffix, capture_output=True)
                self.assertEqual(invalid.returncode, 2)


class DatMatching(Fixture):
    def test_gg_is_collected_with_both_case_extensions(self):
        a = self.put(b"x")
        b = self.put(b"y", "COPY.GG")
        self.put(b"z", "SAVE.sav")
        self.assertEqual(set(match_dats.collect([str(self.root)])), {str(a), str(b)})

    def test_xml_attribute_order_and_zip_match_full_hash(self):
        data = gg_image()
        path = self.put(data)
        with zipfile.ZipFile(self.root / "Sega - Game Gear.zip", "w") as zf:
            zf.writestr("Sega - Game Gear.dat", dat_xml(data))
            zf.writestr("readme.txt", "not XML")
        entries, read = match_dats.load_dats(str(self.root))
        self.assertEqual(len(read), 1)
        missed, output = self.match(path, entries)
        self.assertEqual(missed, 0, output)
        self.assertIn("Widget Gear & Friends.gg", output)

    def test_matching_crc_and_size_with_different_sha1_is_a_miss(self):
        data = gg_image()
        self.put(dat_xml(data, sha1="0" * 40), "GG.dat")
        entries, _ = match_dats.load_dats(str(self.root))
        self.assertEqual(self.match(self.put(data), entries)[0], 1)

    def test_sha1_record_must_also_agree_on_crc_and_size(self):
        data = gg_image()
        for kwargs in ({"crc": "00000000"}, {"size": len(data) + 1}):
            with self.subTest(kwargs=kwargs):
                self.put(dat_xml(data, **kwargs), "GG.dat")
                entries, _ = match_dats.load_dats(str(self.root))
                self.assertEqual(self.match(self.put(data), entries)[0], 1)

    def test_duplicate_sha1_does_not_hide_matching_record(self):
        data = gg_image()
        self.put(dat_xml(data), "a.dat")
        self.put(dat_xml(data, size=1), "z.dat")
        entries, _ = match_dats.load_dats(str(self.root))
        self.assertEqual(len(entries[hashlib.sha1(data).hexdigest()]), 2)
        self.assertEqual(self.match(self.put(data), entries)[0], 0)

    def test_crc_only_record_cannot_authorize_a_match(self):
        data = gg_image()
        self.put(dat_xml(data).replace(b'sha1="', b'other="'), "GG.dat")
        entries, _ = match_dats.load_dats(str(self.root))
        self.assertEqual(entries, {})

    def test_header_and_extension_do_not_constrain_hash_lookup(self):
        data = bytearray(gg_image())
        data[0x7FF0] = 0
        self.put(dat_xml(data), "GG.dat")
        entries, _ = match_dats.load_dats(str(self.root))
        self.assertEqual(self.match(self.put(data, "WRONG.gba"), entries)[0], 0)

    def test_bare_and_archive_size_limits_are_enforced(self):
        self.put(dat_xml(gg_image()), "GG.dat")
        with zipfile.ZipFile(self.root / "GG.zip", "w") as zf:
            zf.writestr("GG.dat", dat_xml(gg_image()))
        with mock.patch.object(match_dats, "MAX_DAT", 128), contextlib.redirect_stderr(io.StringIO()):
            entries, read = match_dats.load_dats(str(self.root))
        self.assertEqual(entries, {})
        self.assertEqual(read, [])

    def test_malformed_and_external_entity_xml_are_rejected(self):
        self.put(b'<header/><datafile/>', "GG.dat")
        self.put(b'<!DOCTYPE datafile [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
                 b'<datafile>&x;</datafile>', "XX.dat")
        with contextlib.redirect_stderr(io.StringIO()):
            entries, read = match_dats.load_dats(str(self.root))
        self.assertEqual(entries, {})
        self.assertEqual(read, [])

    def test_missing_file_is_reported_and_offline_selftest_passes(self):
        self.assertEqual(self.match(self.root / "missing.gg", {})[0], 1)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(match_dats.selftest(), 0)


if __name__ == "__main__":
    unittest.main()
