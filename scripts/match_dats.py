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
import hashlib
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib
from dataclasses import dataclass

LIBRARY = os.path.expanduser(
    os.environ.get("CARTTOOLS_LIBRARY", "~/Desktop/pocket-library/cart-dumps"))
DATS = os.path.expanduser(
    os.environ.get("CARTTOOLS_DATS", "~/Desktop/pocket-library/dats"))

ROM_EXT = (".gb", ".gbc", ".gba", ".gg")
MAX_DAT = 64 * 1024 * 1024


@dataclass(frozen=True)
class Record:
    name: str
    size: int
    crc: str


def hashes(path):
    """Hash every byte once; a header and the filename are not identities."""
    crc, size = 0, 0
    sha = hashlib.sha1()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            crc = zlib.crc32(b, crc)
            sha.update(b)
            size += len(b)
    return sha.hexdigest(), "%08X" % (crc & 0xFFFFFFFF), size


def dat_records(data):
    """Accept Standard and Parent-Clone XML regardless of attribute order."""
    root = ET.fromstring(data)
    if root.tag != "datafile":
        return
    for rom in root.iter("rom"):
        sha = rom.get("sha1", "").lower()
        crc = rom.get("crc", "").upper()
        size = rom.get("size", "")
        name = rom.get("name", "")
        if (name and re.fullmatch(r"[0-9a-f]{40}", sha)
                and re.fullmatch(r"[0-9A-F]{8}", crc)
                and size.isascii() and size.isdigit() and int(size) > 0):
            yield sha, Record(name, int(size), crc)


def load_dats(directory):
    """SHA-1 -> records, from bounded XML DATs, zipped or not.

    CRC-only records cannot authorize a match. Duplicate hashes are retained
    so loading another DAT cannot replace an otherwise matching record.
    """
    entries = {}
    files = sorted(glob.glob(os.path.join(directory, "*")))
    if not files:
        return entries, []
    read = []
    for path in files:
        if not os.path.isfile(path):
            continue
        try:
            payloads = []
            if zipfile.is_zipfile(path):
                with zipfile.ZipFile(path) as zf:
                    members = [i for i in zf.infolist() if not i.is_dir()
                               and i.filename.lower().endswith((".dat", ".xml"))]
                    if sum(i.file_size for i in members) > MAX_DAT:
                        raise ValueError("DAT archive exceeds size limit")
                    for member in members:
                        with zf.open(member) as f:
                            payloads.append(f.read(MAX_DAT + 1))
            elif path.lower().endswith((".dat", ".xml")):
                with open(path, "rb") as f:
                    payloads.append(f.read(MAX_DAT + 1))
            else:
                continue
            parsed = []
            for data in payloads:
                if len(data) > MAX_DAT:
                    raise ValueError("DAT exceeds size limit")
                parsed.extend(dat_records(data))
            for sha, record in parsed:
                entries.setdefault(sha, []).append(record)
            read.append(os.path.basename(path))
        except (OSError, ValueError, ET.ParseError, zipfile.BadZipFile,
                RuntimeError, NotImplementedError) as exc:
            print("  WARN  %s: %s" % (os.path.basename(path), exc), file=sys.stderr)
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
        base = os.path.basename(path)
        try:
            sha, crc, size = hashes(path)
        except OSError as exc:
            missed += 1
            print("  READ  %-24s %s" % (base, exc))
            continue
        hits = entries.get(sha, [])
        hit = next((r for r in hits if r.size == size and r.crc == crc), None)
        if not hits:
            missed += 1
            print("  MISS  %-24s %s  no record with SHA-1 %s" % (base, crc, sha))
        elif hit is None:
            missed += 1
            print("  HASH  %-24s %s  SHA-1 found; CRC32 or size disagrees"
                  % (base, crc))
        else:
            print("  ok    %-24s %s  %s" % (base, crc, hit.name))

    print()
    for ext in sorted(by_ext):
        print("  %-4s %d" % (ext, by_ext[ext]))
    print("  %-4s %d" % ("all", len(files)))
    return missed


def selftest(entries=None):
    """A match must be able to fail, or it is not evidence.

    Runs the real report() over a real file, changing only what the record
    says about it. Each acceptance and rejection has to happen.
    """
    import tempfile

    ok = True
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "SELFTEST.gg")
        with open(path, "wb") as f:
            f.write(bytes(range(256)) * 4)
        sha, crc, n = hashes(path)

        cases = [
            ("no record at all is a miss", {}, 1),
            ("the right hash with the wrong size is a miss",
             {sha: [Record("SELFTEST", n + 1, crc)]}, 1),
            ("the right SHA-1 with the wrong CRC32 is a miss",
             {sha: [Record("SELFTEST", n, "%08X" % (int(crc, 16) ^ 1))]}, 1),
            ("the right hash with the right size passes",
             {sha: [Record("SELFTEST", n, crc)]}, 0),
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

    if args.selftest:
        return selftest()

    entries, read = load_dats(args.dats)
    if not entries:
        print("no DAT entries found in %s" % args.dats)
        print("Without a DAT this check cannot run. It is not shipped here; "
              "see README.md.")
        return 2
    print("%d records from %s" % (len(entries), ", ".join(read)))
    print()

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
    print("all %d match a published record, on SHA-1, CRC32 and size" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
