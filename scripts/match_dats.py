#!/usr/bin/env python3
"""Match every dump against a published record, and count what is on the disk.

    scripts/match_dats.py                     match the whole library
    scripts/match_dats.py FILE...             match just these
    scripts/match_dats.py --selftest          prove the check can fail

A GB or GBC dump proves itself: the header checksum and the global checksum
were written at manufacture and cover the image. **A GBA dump cannot.** No
checksum anywhere in a GBA cartridge covers its ROM, so the logo and the
header complement are the whole of what `verify_dump.py` can check, and both
pass on an image that is wrong everywhere they do not look.

Matching a No-Intro DAT is the only external check a GBA image can have. It is
external in the way that matters: the DAT was not produced by this core or
this repo, so it cannot agree with a dump for the same reason the dump is
wrong.

This also counts. A count written by hand into a document is a claim with
nothing behind it; this reads the disk. **Count from the artefacts, not from
the narrative.**

A match is not proof that a cartridge is undamaged, and a miss is not proof of
a bad dump: a cartridge can legitimately hold something no DAT lists. A miss
means go and look, not throw it away.

Point it at a library with $CARTTOOLS_LIBRARY and $CARTTOOLS_DATS, or with
the arguments. No DAT is shipped here; see README.md.
"""

import argparse
import glob
import html
import os
import re
import sys
import zipfile
import zlib

LIBRARY = os.path.expanduser(
    os.environ.get("CARTTOOLS_LIBRARY", "~/Desktop/pocket-library/cart-dumps"))
DATS = os.path.expanduser(
    os.environ.get("CARTTOOLS_DATS", "~/Desktop/pocket-library/dats"))

ROM_EXT = (".gb", ".gbc", ".gba")

# No-Intro DATs are XML: <rom name="..." size="..." crc="..." .../>. Attribute
# order is stable across the three DATs this reads, and a DAT that orders them
# differently will produce no entries rather than wrong ones, which is why the
# entry count is printed.
ROM_RE = re.compile(
    r'name="([^"]+)"\s+size="(\d+)"\s+crc="([0-9A-Fa-f]{8})"')


def crc32(path):
    h = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h = zlib.crc32(b, h)
    return h & 0xFFFFFFFF


def load_dats(directory):
    """CRC32 -> (name, size), from every DAT in the directory, zipped or not."""
    entries = {}
    files = sorted(glob.glob(os.path.join(directory, "*")))
    if not files:
        return entries, []
    read = []
    for path in files:
        texts = []
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as zf:
                for name in zf.namelist():
                    texts.append(zf.read(name).decode("utf-8", "replace"))
        elif path.lower().endswith((".dat", ".xml")):
            with open(path, "rb") as f:
                texts.append(f.read().decode("utf-8", "replace"))
        else:
            continue
        read.append(os.path.basename(path))
        for text in texts:
            for m in ROM_RE.finditer(text):
                entries[m.group(3).upper()] = (
                    html.unescape(m.group(1)), int(m.group(2)))
    return entries, read


def collect(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(glob.glob(os.path.join(p, "*"))):
                if f.lower().endswith(ROM_EXT):
                    out.append(f)
        else:
            out.append(p)
    return out


def report(files, entries):
    """Returns the number of dumps with no matching record."""
    missed = 0
    by_ext = {}
    for path in files:
        ext = os.path.splitext(path)[1].lower().lstrip(".")
        by_ext[ext] = by_ext.get(ext, 0) + 1
        c = crc32(path)
        size = os.path.getsize(path)
        hit = entries.get("%08X" % c)
        base = os.path.basename(path)
        if hit is None:
            missed += 1
            print("  MISS  %-24s %08X  no record with this CRC32" % (base, c))
        elif hit[1] != size:
            missed += 1
            print("  SIZE  %-24s %08X  %s: record says %d, file is %d"
                  % (base, c, hit[0], hit[1], size))
        else:
            print("  ok    %-24s %08X  %s" % (base, c, hit[0]))

    print()
    for ext in sorted(by_ext):
        print("  %-4s %d" % (ext, by_ext[ext]))
    print("  %-4s %d" % ("all", len(files)))
    return missed


def selftest(entries):
    """A match must be able to fail, or it is not evidence.

    Runs the real report() over a real file three times, changing only what
    the record says about it. Each of the three outcomes has to happen.
    """
    import tempfile

    ok = True
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "SELFTEST.gb")
        with open(path, "wb") as f:
            f.write(bytes(range(256)) * 4)
        c = "%08X" % crc32(path)
        n = os.path.getsize(path)

        cases = [
            ("no record at all is a miss", {}, 1),
            ("the right hash with the wrong size is a miss",
             {c: ("SELFTEST", n + 1)}, 1),
            ("the right hash with the right size passes",
             {c: ("SELFTEST", n)}, 0),
        ]
        for label, table, want in cases:
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                got = report([path], table)
            if got == want:
                print("  ok    %s" % label)
            else:
                ok = False
                print("  FAIL  %s: %d misses, wanted %d" % (label, got, want))

    if entries:
        crc, (name, _) = next(iter(entries.items()))
        bad = "%08X" % ((int(crc, 16) ^ 1) & 0xFFFFFFFF)
        print("  ok    a real CRC32 resolves    %s -> %s" % (crc, name))
        if bad in entries:
            print("  note  %s is also in the DAT, so that pair is one bit "
                  "apart. Not a fault here." % bad)

    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description="Match dumps against No-Intro DATs.")
    ap.add_argument("paths", nargs="*", default=[LIBRARY],
                    help="dumps or directories of dumps (default: %s)"
                         % LIBRARY)
    ap.add_argument("--dats", default=DATS,
                    help="directory of No-Intro DATs (default: %s)" % DATS)
    ap.add_argument("--selftest", action="store_true",
                    help="prove the check can fail")
    args = ap.parse_args()

    entries, read = load_dats(args.dats)
    if not entries:
        print("no DAT entries found in %s" % args.dats)
        print("Without a DAT this check cannot run. It is not shipped here; "
              "see README.md.")
        return 2
    print("%d records from %s" % (len(entries), ", ".join(read)))
    print()

    if args.selftest:
        return selftest(entries)

    files = collect(args.paths)
    if not files:
        print("no dumps found in %s" % ", ".join(args.paths))
        return 2

    missed = report(files, entries)
    print()
    if missed:
        print("%d of %d have no published record. Go and look at each one: a "
              "cartridge may legitimately hold something no DAT lists."
              % (missed, len(files)))
        return 1
    print("all %d match a published record, on CRC32 and on size" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
