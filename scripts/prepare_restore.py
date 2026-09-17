#!/usr/bin/env python3
"""Prepare the single raw save and identity manifest used by CartTools restore.

The supplied ROM asserts which cartridge the save belongs to. Raw save data
does not independently establish that association. The manifest binds those
exact save bytes to the supplied ROM so the core can check both before writing.
"""

import argparse
import hashlib
import os
from pathlib import Path
import struct
import sys
import tempfile
import zlib


MAGIC = b"CTRS"
FORMAT_VERSION = 1
META_BYTES = 64

# Supported geometries: (cartridge type, RAM code) -> (save bytes, CGB flags, max ROM code).
GEOMETRIES = {
    (0x03, 0x02): (8192, (0x00,), 4),
    (0x10, 0x03): (32768, (0x00, 0x80), 6),
    (0x13, 0x03): (32768, (0x00, 0x80), 6),
    (0x1B, 0x03): (32768, (0x00, 0x80, 0xC0), 7),
}


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def save_bytes_for(rom):
    """Save length the core expects for this ROM's header geometry."""
    return GEOMETRIES[(rom[0x147], rom[0x149])][0]


def validate_rom(rom):
    """Limit preparation to MBC1 8 KiB, MBC3 32 KiB or MBC5 32 KiB battery cartridges."""
    if len(rom) < 0x150:
        raise ValueError("ROM is too short to contain a complete GB header")
    geometry = GEOMETRIES.get((rom[0x147], rom[0x149]))
    if geometry is None:
        raise ValueError("restore requires MBC1+RAM+BAT type 03 with RAM code 02, "
                         "MBC3 type 10/13 with RAM code 03, "
                         "or MBC5+RAM+BAT type 1B with RAM code 03")
    _, cgb_flags, max_code = geometry
    if rom[0x143] not in cgb_flags:
        raise ValueError("CGB flag {:02X} is not supported for this mapper".format(rom[0x143]))
    code = rom[0x148]
    if code > max_code or len(rom) != (32768 << code):
        raise ValueError("ROM length does not match a supported header size")
    complement = 0
    for byte in rom[0x134:0x14D]:
        complement = (complement - byte - 1) & 0xFF
    if complement != rom[0x14D]:
        raise ValueError("ROM header checksum does not match")
    global_sum = (sum(rom[:0x14E]) + sum(rom[0x150:])) & 0xFFFF
    if global_sum != int.from_bytes(rom[0x14E:0x150], "big"):
        raise ValueError("ROM global checksum does not match")


def make_manifest(rom, save):
    validate_rom(rom)
    expected = save_bytes_for(rom)
    if len(save) != expected:
        raise ValueError("restore save must be exactly {} bytes for this cartridge".format(expected))
    header_flags = (rom[0x147] | (rom[0x149] << 8)
                    | (rom[0x148] << 16) | (rom[0x143] << 24))
    revision = rom[0x14D] | (rom[0x14C] << 8)
    body = struct.pack("<4s7I16s3I", MAGIC, FORMAT_VERSION,
                       len(save), crc32(save), len(rom), crc32(rom),
                       header_flags, revision, rom[0x134:0x144], 0, 0, 0)
    return body + struct.pack("<I", crc32(body))


def prepare(rom_path, save_path, output_dir):
    """Preserve both sources and refuse to replace either output file."""
    rom = Path(rom_path).read_bytes()
    save = Path(save_path).read_bytes()
    manifest = make_manifest(rom, save)
    output_dir = Path(output_dir)
    outputs = (output_dir / "RESTORE.sav", output_dir / "RESTORE.meta")
    for path in outputs:
        if path.exists() or path.is_symlink():
            raise FileExistsError("refusing to replace existing output: {}".format(path))
    output_dir.mkdir(parents=True, exist_ok=True)
    # Publish only fully written files. Hard linking fails if another process
    # creates a target meanwhile, unlike replace/rename overwriting it.
    with tempfile.TemporaryDirectory(prefix=".prepare-restore-", dir=output_dir) as tmp:
        stages = (Path(tmp) / "save", Path(tmp) / "meta")
        for stage, payload in zip(stages, (save, manifest)):
            with stage.open("xb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        published = []
        try:
            for stage, output in zip(stages, outputs):
                os.link(stage, output)
                published.append(output)
        except OSError:
            for output in published:
                output.unlink()
            raise
    return rom, save, manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rom", type=Path, help="verified original GB ROM")
    parser.add_argument("save", type=Path, help="raw save associated with that ROM, 8192 or 32768 bytes")
    parser.add_argument("output", type=Path, help="directory for RESTORE.sav and RESTORE.meta")
    args = parser.parse_args(argv)
    try:
        rom, save, manifest = prepare(args.rom, args.save, args.output)
    except (OSError, ValueError) as error:
        print("prepare_restore: {}".format(error), file=sys.stderr)
        return 1
    for label, data in (("ROM", rom), ("Save", save)):
        print("{}: {} bytes, CRC32 {:08X}, SHA-256 {}".format(
            label, len(data), crc32(data), hashlib.sha256(data).hexdigest()))
    print("Manifest: {} bytes, payload CRC32 {:08X}".format(
        len(manifest), crc32(manifest[:60])))
    print("Prepared: {}".format(args.output / "RESTORE.sav"))
    print("Prepared: {}".format(args.output / "RESTORE.meta"))
    print("Association comes from the supplied ROM; raw save provenance is not proven.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
