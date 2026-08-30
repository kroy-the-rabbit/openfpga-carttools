#!/usr/bin/env python3
"""Check what CartTools wrote to the card.

    scripts/verify_dump.py FILE...            verify each file
    scripts/verify_dump.py --compare A B      two reads of the same thing
    scripts/verify_dump.py --selftest         prove the checks can fail

ROM dumps carry their own evidence and this mostly reads it back: the Nintendo
logo, the header checksum, the global checksum, and the size the header claims
against the size of the file. The core checks most of that on the device; the
value here is a second opinion computed by different code, and a CRC32 to
compare against published records.

**None of this can prove a save is correct.** A save carries no logo, no
checksum, no length and nothing that describes itself, so every check that
makes a ROM dump trustworthy is missing. The only proof is loading it in an
emulator beside its ROM and seeing the game's own state come back:

    tools/podman/play-dump.sh ZELDA.gbc ZELDA.sav

That is the end of the chain and this script is not a substitute for it. A
size check and a "looks like real data" check both passed on the first save
this project ever took, and neither would have caught a subtly wrong read.

What is left here is structural, necessary rather than sufficient, and two of
them are worth having:

  - **Identical banks.** A 32 KB save is four 8 KB banks. If the bank select
    did not take - or on MBC1, if the mode register was not switched - the
    reader gets bank 0 four times and writes a file that is the right length,
    the right shape, and wrong. Nothing on the device can see this. Comparing
    the banks to each other can.

  - **Two reads.** The core reads a save once. docs/GB-SAVE-PLAN.md argues
    that is not good enough and the double read is still not built, so until
    it is, dumping twice and running --compare is the whole of the check.
    A save is the one thing in a cartridge that cannot be fetched from
    anywhere else if it comes back wrong.

Also cross-checks a .sav against its own ROM dump when one sits beside it: the
ROM's byte at 0x0149 says how large the save should be, which is the only
external fact about a save file that exists.
"""

import argparse
import os
import sys
import zlib

# The 48 bytes at 0x104. Every Game Boy cartridge carries it and the boot ROM
# refuses to run without it, so a mismatch means the read was wrong rather
# than that the cartridge is unusual.
GB_LOGO = bytes.fromhex(
    "CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6DDDDD999"
    "BBBB67636E0EECCCDDDC999FBBB9333E")

# 156 bytes at 0x04, and no checksum anywhere in a GBA cartridge covers them,
# which is what makes this an independent check rather than a circular one.
GBA_LOGO_SHA1 = "17daa0fec02fc33c0f6abb549a8b80b6613b48ee"

MAPPERS = {
    0x00: "ROM only", 0x01: "MBC1", 0x02: "MBC1+RAM", 0x03: "MBC1+RAM+BAT",
    0x05: "MBC2", 0x06: "MBC2+BAT", 0x08: "ROM+RAM", 0x09: "ROM+RAM+BAT",
    0x0F: "MBC3+TIMER+BAT", 0x10: "MBC3+TIMER+RAM+BAT", 0x11: "MBC3",
    0x12: "MBC3+RAM", 0x13: "MBC3+RAM+BAT", 0x19: "MBC5", 0x1A: "MBC5+RAM",
    0x1B: "MBC5+RAM+BAT", 0x1C: "MBC5+RUMBLE", 0x1D: "MBC5+RUMBLE+RAM",
    0x1E: "MBC5+RUMBLE+RAM+BAT",
}

# Size code at 0x0149 -> bytes. Not monotonic: 04 is larger than 05, which is
# exactly the kind of thing that gets transcribed wrong.
RAM_SIZES = {0x00: 0, 0x01: 2048, 0x02: 8192, 0x03: 32768,
             0x04: 131072, 0x05: 65536}

BANK = 8192


class Report:
    """Lines plus a verdict. Anything added through bad() fails the file."""

    def __init__(self, name):
        self.name = name
        self.lines = []
        self.failures = 0

    def ok(self, label, value=""):
        self.lines.append(("ok  ", label, value))

    def bad(self, label, value=""):
        self.lines.append(("FAIL", label, value))
        self.failures += 1

    def note(self, label, value=""):
        self.lines.append(("    ", label, value))

    def warn(self, label, value=""):
        self.lines.append(("??  ", label, value))

    def render(self):
        print("== {}".format(self.name))
        for status, label, value in self.lines:
            print("   {} {:<34} {}".format(status, label, value))
        print()


def gb_header_sum(data):
    total = 0
    for byte in data[0x134:0x14D]:
        total = (total - byte - 1) & 0xFF
    return total


def gb_global_sum(data):
    return (sum(data[:0x14E]) + sum(data[0x150:])) & 0xFFFF


def verify_gb(path, data, rep):
    if len(data) < 0x150:
        rep.bad("too short to hold a header", "{} bytes".format(len(data)))
        return

    title = data[0x134:0x143].rstrip(b"\0").decode("ascii", "replace")
    rep.note("title", repr(title))
    rep.note("CGB flag", "{:02X}".format(data[0x143]))

    if data[0x104:0x134] == GB_LOGO:
        rep.ok("Nintendo logo")
    else:
        differing = sum(1 for a, b in zip(data[0x104:0x134], GB_LOGO) if a != b)
        rep.bad("Nintendo logo", "{} of 48 bytes differ".format(differing))

    want = gb_header_sum(data)
    if want == data[0x14D]:
        rep.ok("header checksum", "{:02X}".format(want))
    else:
        rep.bad("header checksum",
                "file {:02X}, computed {:02X}".format(data[0x14D], want))

    stored = (data[0x14E] << 8) | data[0x14F]
    got = gb_global_sum(data)
    if stored == got:
        rep.ok("global checksum", "{:04X}".format(got))
    else:
        # The one check that covers the whole image rather than the header.
        rep.bad("global checksum",
                "file {:04X}, computed {:04X}".format(stored, got))

    code = data[0x148]
    expect = (32 << code) * 1024 if code <= 8 else None
    if expect == len(data):
        rep.ok("size matches header", "{} KB".format(len(data) // 1024))
    else:
        rep.bad("size matches header",
                "header says {}, file is {} KB"
                .format("{} KB".format(expect // 1024) if expect else "?",
                        len(data) // 1024))

    cart_type = data[0x147]
    rep.note("cartridge type",
             "{:02X}  {}".format(cart_type, MAPPERS.get(cart_type, "unknown")))
    ram_code = data[0x149]
    rep.note("save RAM", "{:02X}  {}".format(
        ram_code, describe_ram(cart_type, ram_code)))
    rep.note("crc32", "{:08X}".format(zlib.crc32(data) & 0xFFFFFFFF))


def describe_ram(cart_type, ram_code):
    if cart_type in (0x05, 0x06):
        # MBC2 keeps 512 nibbles inside the mapper and reports 0x00 here, so
        # the size byte cannot be believed for it.
        return "512 nibbles, inside the MBC2 (0x0149 always reads 00)"
    size = RAM_SIZES.get(ram_code)
    if size is None:
        return "unrecognised code"
    if size == 0:
        return "none"
    banks = max(1, size // BANK)
    return "{} bytes, {} bank{}".format(size, banks, "" if banks == 1 else "s")


def verify_gba(path, data, rep):
    import hashlib

    if len(data) < 0xC0:
        rep.bad("too short to hold a header", "{} bytes".format(len(data)))
        return

    title = data[0xA0:0xAC].rstrip(b"\0").decode("ascii", "replace")
    rep.note("title", repr(title))
    rep.note("game code", data[0xAC:0xB0].decode("ascii", "replace"))

    logo_sha = hashlib.sha1(data[0x04:0xA0]).hexdigest()
    if logo_sha == GBA_LOGO_SHA1:
        # No checksum in a GBA cartridge covers these 156 bytes, so this is a
        # genuinely independent check rather than a circular one.
        rep.ok("Nintendo logo", "156 bytes, sha1 matches")
    else:
        rep.bad("Nintendo logo", "sha1 {}".format(logo_sha))

    if data[0xB2] == 0x96:
        rep.ok("fixed byte 0xB2", "96")
    else:
        rep.bad("fixed byte 0xB2", "{:02X}".format(data[0xB2]))

    chk = 0
    for byte in data[0xA0:0xBD]:
        chk = (chk - byte) & 0xFF
    chk = (chk - 0x19) & 0xFF
    if chk == data[0xBD]:
        rep.ok("header complement", "{:02X}".format(chk))
    else:
        rep.bad("header complement",
                "file {:02X}, computed {:02X}".format(data[0xBD], chk))

    size = len(data)
    if size and (size & (size - 1)) == 0:
        rep.ok("size is a power of two", "{} MB".format(size // (1024 * 1024)))
    else:
        rep.bad("size is a power of two", "{} bytes".format(size))

    rep.note("crc32", "{:08X}".format(zlib.crc32(data) & 0xFFFFFFFF))
    rep.note("no checksum covers the data",
             "a GBA cartridge carries none; compare two dumps instead")


def find_rom_beside(path):
    """A ROM dump of the same cartridge, if one is filed next to the save."""
    stem = os.path.splitext(path)[0]
    for ext in (".gbc", ".gb", ".gba"):
        candidate = stem + ext
        if os.path.exists(candidate):
            return candidate
    return None


def verify_sav(path, data, rep):
    size = len(data)
    rep.note("size", "{} bytes".format(size))

    legal = {512: "MBC2, 512 nibbles", 2048: "2 KB", 8192: "8 KB, one bank",
             32768: "32 KB, four banks", 65536: "64 KB, eight banks",
             131072: "128 KB, sixteen banks"}
    if size in legal:
        rep.ok("a legal save size", legal[size])
    else:
        rep.bad("a legal save size", "{} bytes is not one".format(size))

    rep.note("crc32", "{:08X}".format(zlib.crc32(data) & 0xFFFFFFFF))

    # A save has nothing that describes itself. The ROM dump beside it does.
    rom = find_rom_beside(path)
    if rom:
        rom_data = open(rom, "rb").read()
        if len(rom_data) >= 0x150:
            cart_type, ram_code = rom_data[0x147], rom_data[0x149]
            expect = RAM_SIZES.get(ram_code, None)
            if cart_type in (0x05, 0x06):
                expect = 512
            rep.note("ROM beside it", os.path.basename(rom))
            if expect is None:
                rep.warn("expected size from 0x0149",
                         "unrecognised code {:02X}".format(ram_code))
            elif expect == size:
                rep.ok("size matches the cartridge header",
                       "0x0149 = {:02X}".format(ram_code))
            else:
                rep.bad("size matches the cartridge header",
                        "0x0149 = {:02X} wants {} bytes, file is {}"
                        .format(ram_code, expect, size))
    else:
        rep.warn("no ROM dump beside it",
                 "nothing external says how large this should be")

    if all(b == 0xFF for b in data):
        rep.warn("every byte is FF",
                 "a flat battery reads this way, and so does a failed enable")
    elif all(b == 0x00 for b in data):
        rep.warn("every byte is 00", "a blank save, or a read that returned 00")
    else:
        rep.ok("not blank", "{} distinct byte values".format(len(set(data))))

    # The check nothing on the device can do.
    if size > BANK:
        banks = [data[i:i + BANK] for i in range(0, size, BANK)]
        distinct = len({bytes(b) for b in banks})
        if distinct == 1:
            rep.bad("banks differ from each other",
                    "all {} banks identical - the bank select did not take, "
                    "and this file is bank 0 repeated".format(len(banks)))
        else:
            rep.ok("banks differ from each other",
                   "{} distinct of {}".format(distinct, len(banks)))
        for i, bank in enumerate(banks):
            fill = "FF" if all(b == 0xFF for b in bank) else \
                   "00" if all(b == 0 for b in bank) else "data"
            rep.note("  bank {}".format(i),
                     "{:08X}  {}".format(zlib.crc32(bank) & 0xFFFFFFFF, fill))

    rep.note("nothing here proves this is correct",
             "load it beside its ROM: tools/podman/play-dump.sh")
    rep.note("read once", "the core does not double read; --compare two dumps")


def verify(path):
    rep = Report(os.path.basename(path))
    try:
        data = open(path, "rb").read()
    except OSError as exc:
        rep.bad("unreadable", str(exc))
        return rep

    ext = os.path.splitext(path)[1].lower()
    if ext in (".gb", ".gbc"):
        verify_gb(path, data, rep)
    elif ext == ".gba":
        verify_gba(path, data, rep)
    elif ext == ".sav":
        verify_sav(path, data, rep)
    else:
        rep.warn("unrecognised extension", ext or "(none)")
        rep.note("size", "{} bytes".format(len(data)))
        rep.note("crc32", "{:08X}".format(zlib.crc32(data) & 0xFFFFFFFF))
    return rep


def compare(path_a, path_b):
    """Two reads of the same thing. This is the double read, done off device."""
    rep = Report("{} vs {}".format(os.path.basename(path_a),
                                   os.path.basename(path_b)))
    a = open(path_a, "rb").read()
    b = open(path_b, "rb").read()

    if len(a) != len(b):
        rep.bad("same length", "{} and {} bytes".format(len(a), len(b)))
        rep.render()
        return rep

    if a == b:
        rep.ok("identical", "{} bytes, crc32 {:08X}"
               .format(len(a), zlib.crc32(a) & 0xFFFFFFFF))
        rep.note("what this proves",
                 "the read reproduces; it does not prove either is correct")
        rep.note("for a save", "only play-dump.sh can tell you that")
        rep.render()
        return rep

    diff = [i for i in range(len(a)) if a[i] != b[i]]
    rep.bad("identical", "{} of {} bytes differ".format(len(diff), len(a)))
    rep.note("first difference", "0x{:X}".format(diff[0]))
    rep.note("last difference", "0x{:X}".format(diff[-1]))

    # A single stuck data line shows up as one bit differing everywhere, which
    # is how MARIOLAND2's bad dump was diagnosed. Worth naming.
    bits = 0
    for i in diff:
        bits |= a[i] ^ b[i]
    single = bits and (bits & (bits - 1)) == 0
    if single:
        rep.note("every difference is one bit",
                 "bit {} - one data line reading unreliably"
                 .format(bits.bit_length() - 1))
    else:
        rep.note("differing bits", "{:08b}".format(bits))

    for i in diff[:8]:
        rep.note("  0x{:X}".format(i), "{:02X} vs {:02X}".format(a[i], b[i]))
    rep.note("keep both files",
             "a corrupt and clean pair of the same read has never been kept")
    rep.render()
    return rep


def selftest():
    """Prove each check can fail. A check that never fires is not a check."""
    import tempfile

    failures = 0

    def expect(condition, what):
        nonlocal failures
        if not condition:
            print("SELFTEST FAIL: {}".format(what))
            failures += 1

    with tempfile.TemporaryDirectory() as tmp:
        # A minimal, valid GB image: logo, sizes and both checksums correct.
        rom = bytearray(32768)
        rom[0x104:0x134] = GB_LOGO
        rom[0x134:0x13B] = b"TESTROM"
        rom[0x147] = 0x03          # MBC1+RAM+BAT
        rom[0x148] = 0x00          # 32 KB
        rom[0x149] = 0x03          # 32 KB save, four banks
        rom[0x14D] = gb_header_sum(rom)
        total = gb_global_sum(rom)
        rom[0x14E], rom[0x14F] = total >> 8, total & 0xFF
        rom[0x14D] = gb_header_sum(rom)
        total = gb_global_sum(rom)
        rom[0x14E], rom[0x14F] = total >> 8, total & 0xFF

        good = os.path.join(tmp, "TESTROM.gb")
        open(good, "wb").write(rom)
        expect(verify(good).failures == 0, "a good ROM passes")

        bent = bytearray(rom)
        bent[0x110] ^= 0x01
        path = os.path.join(tmp, "BENTLOGO.gb")
        open(path, "wb").write(bent)
        expect(verify(path).failures > 0, "a one bit logo error fails")

        bent = bytearray(rom)
        bent[0x2000] ^= 0xFF       # outside every header field
        path = os.path.join(tmp, "BENTBODY.gb")
        open(path, "wb").write(bent)
        expect(verify(path).failures > 0, "a corrupt body fails the global sum")

        # A 32 KB save whose four banks are all identical: the exact signature
        # of a bank select that did not take.
        one_bank = bytes(range(256)) * 32
        repeated = os.path.join(tmp, "TESTROM.sav")
        open(repeated, "wb").write(one_bank * 4)
        rep = verify(repeated)
        expect(rep.failures > 0, "four identical banks fail")

        # The same length, with banks that differ, passes.
        varied = b"".join(bytes((x + i) & 0xFF for x in range(BANK))
                          for i in range(4))
        path = os.path.join(tmp, "TESTROM.sav")
        open(path, "wb").write(varied)
        expect(verify(path).failures == 0, "four distinct banks pass")

        # And a save whose length disagrees with the ROM's 0x0149.
        path = os.path.join(tmp, "TESTROM.sav")
        open(path, "wb").write(varied[:BANK])
        expect(verify(path).failures > 0, "a save of the wrong size fails")

        # compare() on a one bit difference.
        a_path = os.path.join(tmp, "a.sav")
        b_path = os.path.join(tmp, "b.sav")
        open(a_path, "wb").write(varied)
        flipped = bytearray(varied)
        for i in range(0, len(flipped), 3):
            flipped[i] ^= 0x80
        open(b_path, "wb").write(flipped)
        expect(compare(a_path, b_path).failures > 0, "a difference is caught")
        expect(compare(a_path, a_path).failures == 0, "identical files pass")

    if failures:
        print("selftest: {} checks did not behave".format(failures))
        return 1
    print("selftest: every check fires when it should and not otherwise")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="images to verify")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"),
                    help="two reads of the same cartridge, byte for byte")
    ap.add_argument("--selftest", action="store_true",
                    help="prove the checks can fail, then exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    failures = 0
    if args.compare:
        failures += compare(*args.compare).failures

    for path in args.files:
        rep = verify(path)
        rep.render()
        failures += rep.failures

    if not args.files and not args.compare:
        ap.print_help()
        return 2

    if failures:
        print("{} check{} failed".format(failures, "" if failures == 1 else "s"))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
