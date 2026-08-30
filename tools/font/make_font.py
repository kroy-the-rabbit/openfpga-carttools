#!/usr/bin/env python3
"""Generate src/fpga/ui/ui_font.vh from tools/font/font8x8_basic.h.

The Quartus build never runs Python, so the generated .vh is checked in.
This script exists so the ROM contents are reproducible from a readable
source rather than being unexplained hex.

Source font
-----------
font8x8_basic by Daniel Hepper, released to the public domain.
    https://github.com/dhepper/font8x8  (file font8x8_basic.h)
It is in turn Marcel Sondaas' font8x8, which is a transcription of the
public domain IBM VGA 8x8 glyph set.

Format of the source header: 128 rows of 8 comma separated byte literals,
one row per scanline, top scanline first.  Within a byte, bit 0 is the
LEFTMOST pixel and bit 7 the rightmost; a set bit is foreground.  The
generated ROM keeps that bit order unchanged, so ui_renderer.sv can index
a row byte directly with the glyph column.

Usage
-----
    python3 tools/font/make_font.py
    python3 tools/font/make_font.py --check     # verify checked-in file
"""

import argparse
import os
import re
import sys

FIRST_CHAR = 0x20   # space
LAST_CHAR = 0x7E    # tilde
GLYPH_ROWS = 8

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_HEADER = os.path.join(REPO_ROOT, "tools", "font", "font8x8_basic.h")
DST_VH = os.path.join(REPO_ROOT, "src", "fpga", "ui", "ui_font.vh")

ROW_RE = re.compile(r"\{([^}]*)\}")
BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{1,2})")


def parse_header(path):
    """Return a list of 128 glyphs, each a list of 8 row bytes."""
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    # Drop the outer initialiser braces so only the per-glyph ones remain.
    body = text[text.index("font8x8_basic[128][8]"):]
    body = body[body.index("{") + 1:]

    glyphs = []
    for match in ROW_RE.finditer(body):
        rows = [int(b, 16) for b in BYTE_RE.findall(match.group(1))]
        if len(rows) != GLYPH_ROWS:
            raise ValueError("glyph %d has %d rows, expected %d"
                             % (len(glyphs), len(rows), GLYPH_ROWS))
        glyphs.append(rows)

    if len(glyphs) != 128:
        raise ValueError("expected 128 glyphs in %s, found %d" % (path, len(glyphs)))
    return glyphs


def ascii_art(rows):
    """Render one glyph as eight 8-character strings, for the comment block."""
    return ["".join("#" if (row >> col) & 1 else "." for col in range(8))
            for row in rows]


def render_vh(glyphs):
    count = LAST_CHAR - FIRST_CHAR + 1
    depth = count * GLYPH_ROWS

    out = []
    w = out.append
    w("//")
    w("// ui_font.vh - 8x8 glyph ROM for the CartTools on-screen text layer")
    w("//")
    w("// GENERATED FILE. Do not edit by hand.")
    w("// Regenerate with:  python3 tools/font/make_font.py")
    w("// Verify in CI with: python3 tools/font/make_font.py --check")
    w("//")
    w("// Source font: font8x8_basic by Daniel Hepper, public domain.")
    w("//   https://github.com/dhepper/font8x8  (font8x8_basic.h)")
    w("//   Checked in unmodified at tools/font/font8x8_basic.h. That file is")
    w("//   Marcel Sondaas' font8x8, itself a transcription of the public domain")
    w("//   IBM VGA 8x8 glyph set. No copyright is claimed on the glyphs here and")
    w("//   none is inherited by this file.")
    w("//")
    w("// Contents: ASCII 0x%02X (space) through 0x%02X (tilde), %d glyphs, %d rows"
      % (FIRST_CHAR, LAST_CHAR, count, GLYPH_ROWS))
    w("//   each, top row first. Control codes and 0x7F are not stored;")
    w("//   ui_renderer.sv range-checks the character and blanks anything outside")
    w("//   this window, so the ROM is never addressed past the end.")
    w("//")
    w("// Addressing:  addr = (ascii - 8'h%02X) * %d + glyph_row      // 0..%d"
      % (FIRST_CHAR, GLYPH_ROWS, depth - 1))
    w("// Bit order:   bit n of a row byte is column n, bit 0 leftmost.")
    w("//              1 = foreground, 0 = background.")
    w("//")
    w("// Size: %d x 8 = %d bits, one M10K block when inferred as a ROM."
      % (depth, depth * 8))
    w("//")
    w("// This file holds a complete module rather than a fragment to be")
    w("// `include`d. An include would have to be found by a relative path, and")
    w("// the Quartus project root (src/fpga/build) and the simulator's working")
    w("// directory (the repository root) are not the same place, so no single")
    w("// path works for both. A module is just another source file to both")
    w("// tools. Add it to the Quartus project with an explicit file type so the")
    w("// .vh extension is not mistaken for an include-only file:")
    w("//")
    w("//   set_global_assignment -name SYSTEMVERILOG_FILE ../ui/ui_font.vh")
    w("//")
    w("// The initial block is how the contents get in. Quartus turns it into the")
    w("// block's .mif at synthesis, so there is no $readmemh and no external")
    w("// data file for the build container to be missing.")
    w("//")
    w("// SPDX-License-Identifier: GPL-2.0-or-later")
    w("//")
    w("")
    w("`default_nettype none")
    w("")
    w("module ui_font_rom (")
    w("    input  wire       clk,")
    w("    input  wire [9:0] addr,      // 0..%d, see addressing above" % (depth - 1))
    w("    output reg  [7:0] q          // one glyph row, one cycle later")
    w(");")
    w("")
    w("    reg [7:0] font_rom [0:%d];" % (depth - 1))
    w("")
    w("    initial begin")

    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        rows = glyphs[code]
        base = (code - FIRST_CHAR) * GLYPH_ROWS
        art = ascii_art(rows)
        name = "space" if code == 0x20 else "'%s'" % chr(code)
        w("        // 0x%02X %s" % (code, name))
        for i, row in enumerate(rows):
            w("        font_rom[%3d] = 8'h%02X;   // %s" % (base + i, row, art[i]))

    w("    end")
    w("")
    w("    // Synchronous read, which is what makes Quartus infer a ROM here")
    w("    // instead of %d bits of logic." % (depth * 8))
    w("    always @(posedge clk) begin")
    w("        q <= font_rom[addr];")
    w("    end")
    w("")
    w("endmodule")
    w("")
    w("`default_nettype wire")
    w("")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero if the checked-in .vh is stale")
    args = parser.parse_args()

    glyphs = parse_header(SRC_HEADER)
    text = render_vh(glyphs)

    if args.check:
        if not os.path.exists(DST_VH):
            print("missing: %s" % DST_VH, file=sys.stderr)
            return 1
        with open(DST_VH, "r", encoding="utf-8") as handle:
            current = handle.read()
        if current != text:
            print("stale: %s does not match tools/font/make_font.py output" % DST_VH,
                  file=sys.stderr)
            return 1
        print("up to date: %s" % DST_VH)
        return 0

    os.makedirs(os.path.dirname(DST_VH), exist_ok=True)
    with open(DST_VH, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("wrote %s (%d glyphs, %d bytes of ROM)"
          % (DST_VH, LAST_CHAR - FIRST_CHAR + 1,
             (LAST_CHAR - FIRST_CHAR + 1) * GLYPH_ROWS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
