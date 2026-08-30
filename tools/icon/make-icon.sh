#!/usr/bin/env bash
# Render assets/icon.svg into the Pocket's core icon format.
#
#   tools/icon/make-icon.sh [source.svg] [out.bin]
#
# APF core icons are 36x36 and one byte of intensity per pixel, stored as
# 36*36 little-endian 16-bit words whose high byte is always zero (2,592
# bytes). There is no colour: the Pocket draws the icon as a greyscale bitmap,
# so the SVG's palette survives only as brightness. That is why the render is
# flattened onto black and lifted slightly, rather than passed through as is.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC=${1:-$REPO/assets/icon.svg}
OUT=${2:-$(ls -d "$REPO/pkg/Cores"/*/ | head -1)icon.bin}
VENV="$REPO/build/gba/venv"

command -v magick >/dev/null || { echo "ImageMagick (magick) is required" >&2; exit 1; }
[[ -x "$VENV/bin/python3" ]] || python3 -m venv "$VENV"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Render big, then downsample: a 36x36 direct rasterise of a 64-unit viewBox
# loses the tick's stroke ends.
magick -background none -density 1152 "$SRC" -resize 36x36 "$TMP/icon.png"
# Gamma 1.3 lifts the cartridge body off the black background without washing
# out the label, which is the only part still legible in the core list.
magick "$TMP/icon.png" -background black -flatten -colorspace Gray \
       -level 0%,100%,1.3 -depth 8 "$TMP/icon.pgm"

"$VENV/bin/python3" - "$TMP/icon.pgm" "$OUT" <<'PY'
import sys

src, out = sys.argv[1:]
data = open(src, 'rb').read()

# Minimal binary PGM reader: P5, then width height maxval, then the pixels.
fields, rest = [], data
while len(fields) < 4:
    nl = rest.index(b'\n')
    line = rest[:nl]
    rest = rest[nl + 1:]
    if line.startswith(b'#'):
        continue
    fields += line.split()
magic, w, h, maxval = fields[0], int(fields[1]), int(fields[2]), int(fields[3])
assert magic == b'P5' and (w, h) == (36, 36) and maxval == 255, (magic, w, h, maxval)
assert len(rest) == w * h, (len(rest), w * h)

# One 16-bit little-endian word per pixel, intensity in the low byte.
with open(out, 'wb') as f:
    for px in rest:
        f.write(bytes((px, 0)))
print(f"wrote {out}: {w}x{h}, {w * h * 2} bytes")
PY
