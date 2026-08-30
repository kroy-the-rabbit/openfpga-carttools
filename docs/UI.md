# Text layer

The utility display. It replaces the GBA picture path entirely, so it owns the
framebuffer write port outright.

| File | What it is |
|---|---|
| `src/fpga/ui/ui_renderer.sv` | paints the framebuffer from the character buffer, free-running |
| `src/fpga/ui/ui_textbuf.sv` | the 600 cell character buffer, instantiated inside the renderer |
| `src/fpga/ui/ui_font.vh` | the 8x8 glyph ROM, generated and checked in |

`ui_renderer` instantiates the other two, so a caller instantiates one module.

`src/fpga/ui/ui_screen.sv` sits above them and decides what the display says.
It is not part of the text layer proper. See
[What ui_screen paints](#what-ui_screen-paints).

## Geometry

The Pocket framebuffer that `video_adapter.sv` scans out is 240x160. An 8x8
font divides it exactly. Cell and pixel numbering are both linear, row major,
top left first:

```text
240 / 8 = 30 columns    160 / 8 = 20 rows    30 x 20 = 600 cells

cell       = row * 30 + col              row 0..19, col 0..29, cell 0..599
pixel_addr = pixel_row * 240 + pixel_col                        0..38399
```

## The contract

### Write port

In the `clk_sys` domain, on `ui_renderer`:

| Signal | Width | Meaning |
|---|---|---|
| `tb_addr` | 10 | cell number, `row * 30 + col` |
| `tb_char` | 8 | ASCII |
| `tb_attr` | 2 | attribute, see below |
| `tb_we` | 1 | write strobe, one cycle per cell |

One cell per clock. There is no ready or busy signal and no acknowledgement: a
write always lands.

Writes with `tb_addr >= 600` are dropped rather than wrapped.

### Characters

`0x20` (space) through `0x7E` (tilde) have glyphs. Everything else renders as
a blank cell: the ROM address is forced to the space glyph, so the ROM is
never read out of range, and the pixel is gated off as well.

There are no control characters. Newline is not a thing; the caller works out
which cell it wants.

### Attributes

| Value | Name | Rendering |
|---|---|---|
| 0 | normal | foreground glyph on background |
| 1 | inverse | background glyph on foreground, the two colours swapped |
| 2 | dim | foreground with every channel halved, on background |
| 3 | reserved | renders as normal |

Inverse is the highlight for a selected menu item. Dim is for text present but
not currently actionable. An unmapped character under inverse gives a solid
foreground block, because it renders exactly as a space does.

### Colours

`color_fg` and `color_bg` are 18 bit inputs in the `{R[5:0], G[5:0], B[5:0]}`
packing `video_adapter` expects on `pixel_data`. They are inputs rather than
constants, so the palette can change at runtime.

Dim is derived: `color_fg` with each 6 bit channel shifted right by one.

Treat the colour inputs as static. They are sampled by the pipeline as it
goes, so changing them mid-pass tears the screen for one pass, about 382 us.

### Refresh

The pixel counter free-runs. Every `clk_sys` cycle produces one framebuffer
write, so a full pass over all 38400 pixels takes 38400 cycles:

```text
38400 / 100.663 MHz = 381 us
```

A displayed frame is 16.7 ms, so the screen is repainted about 44 times per
frame. There is no double buffer, no vsync handshake and no busy flag. A cell
changed mid-pass shows the old glyph on the scanlines already painted and the
new one below, for under 400 us.

`video_adapter` reads the framebuffer in the `clk_vid` domain with no
arbitration against these writes. Inherited behaviour, unchanged: the two
ports are on opposite sides of a dual clock block RAM, so the worst case is
one scanline showing a pixel from the pass either side of it.

### Latency

Three `clk_sys` cycles from the pixel counter to the framebuffer write:

```text
S0  pixel counter          drives the text buffer read address
S1  text buffer output     drives the font ROM address
S2  font ROM output        pick the pixel out of the glyph row
S3  registered outputs     pixel_addr, pixel_data, pixel_we
```

The address is pipelined alongside the data, so `pixel_we` is high on every
cycle after the pipeline fills and each of the 38400 addresses is written
exactly once per pass. `tools/sim/tb_ui_renderer.sv` checks that directly.

## Worked example

`NO CARTRIDGE` on row 2, starting at column 9, in normal text. The first cell
is `2 * 30 + 9 = 69`, and each following character is the next cell.

```systemverilog
localparam integer         MSG_LEN  = 12;
localparam integer         MSG_CELL = 2 * 30 + 9;       // row 2, column 9
localparam [MSG_LEN*8-1:0] MSG      = "NO CARTRIDGE";

// MSG is packed most significant character first, so character msg_i from
// the left sits at bit offset (MSG_LEN - 1 - msg_i) * 8.
tb_addr <= MSG_CELL[9:0] + msg_i;
tb_char <= MSG[(MSG_LEN - 1 - msg_i) * 8 +: 8];
tb_attr <= 2'd0;
tb_we   <= 1'b1;
```

Drive `msg_i` from 0 to `MSG_LEN - 1`, one cell per clock, then drop `tb_we`.

To clear the screen, walk `tb_addr` from 0 to 599 writing `8'h20` with
attribute 0. `ui_textbuf` powers up full of spaces, so that is only needed
when replacing an existing screen, not at boot.

To highlight a menu line, rewrite the same cells with `tb_attr = 2'd1`.

## Instantiation

```systemverilog
wire [15:0] ui_pixel_addr;
wire [17:0] ui_pixel_data;
wire        ui_pixel_we;

ui_renderer ui (
    .clk        (clk_sys),
    .reset      (~pll_core_locked),

    .color_fg   ({6'd63, 6'd63, 6'd56}),   // slightly warm white
    .color_bg   ({6'd0,  6'd0,  6'd0 }),   // black

    .tb_addr    (tb_addr),
    .tb_char    (tb_char),
    .tb_attr    (tb_attr),
    .tb_we      (tb_we),

    .pixel_addr (ui_pixel_addr),
    .pixel_data (ui_pixel_data),
    .pixel_we   (ui_pixel_we)
);
```

Feed those three wires to `video_adapter`'s `pixel_addr`, `pixel_data` and
`pixel_we`. Its other ports are unchanged.

The Quartus project lives in `src/fpga/build`, so the three files go in the
`.qsf` as:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE ../ui/ui_renderer.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../ui/ui_textbuf.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../ui/ui_font.vh
```

The explicit `SYSTEMVERILOG_FILE` on `ui_font.vh` is required: it holds a
complete module, and without the explicit type Quartus treats a `.vh`
extension as include-only and never compiles it. It is a module rather than an
include because the Quartus project root (`src/fpga/build`) and the
simulator's working directory (the repository root) differ, so no single
include path works for both tools.

## The font

`ui_font.vh` is generated. Do not edit it.

The glyphs are **font8x8_basic** by Daniel Hepper, released to the public
domain, from <https://github.com/dhepper/font8x8>. That file is Marcel
Sondaas' `font8x8`, a transcription of the public domain IBM VGA 8x8 glyph
set. The upstream header is checked in unmodified at
`tools/font/font8x8_basic.h` and is the input to the generator.

Regenerate:

```sh
python3 -m venv .venv && . .venv/bin/activate     # stdlib only, no packages
python3 tools/font/make_font.py
```

Check the committed file is not stale:

```sh
python3 tools/font/make_font.py --check
```

The generator emits only ASCII `0x20` to `0x7E`, 95 glyphs of 8 rows each, 760
bytes. Each row byte has **bit 0 as the leftmost pixel**, the upstream
convention, kept so the renderer can index a row byte directly with the glyph
column.

Nothing in the build needs Python. The ROM contents are an `initial` block,
which Quartus turns into the block's `.mif` at synthesis, so there is no
`$readmemh` and no data file for the build container to be missing.

## Cost

| | Bits | Blocks |
|---|---|---|
| `ui_textbuf` cells, 600 x 10 | 6,000 | 1 M10K |
| `ui_font_rom`, 760 x 8 | 6,080 | 1 M10K |

Both fit inside one M10K each (10,240 bits), and both are synchronous read
with initial contents, the pattern Quartus infers block RAM from. If Quartus
builds either out of logic instead, check that first when utilisation looks
wrong.

Logic is roughly 120 registers: the pixel counter, its three pipeline stages,
and the registered outputs. Expect well under 200 ALMs, about one percent of
the 5CEBA4's 18,480.

`video_adapter`'s own framebuffer is 38,400 x 18 bits, 691,200 bits, at least
68 M10K blocks and closer to 75 once the fitter is limited to 512 words at 18
bits wide per block. The inherited comment in `video_adapter.sv` calls it "~30
M10K blocks", which does not match the arithmetic; the file is not ours to
change, but do not size the device against that number.

## Simulation

```sh
make test ARGS="-k ui_renderer"
```

or directly:

```sh
podman run --rm -v "$PWD:/work:z" -w /work localhost/pocket-sim:1 sh -c \
  'iverilog -g2012 -o /tmp/tb.vvp tools/sim/tb_ui_renderer.sv \
     src/fpga/ui/ui_renderer.sv src/fpga/ui/ui_textbuf.sv src/fpga/ui/ui_font.vh \
   && vvp /tmp/tb.vvp'
```

`tools/sim/tb_ui_renderer.sv` puts the whole printable set on screen four
times over, once per attribute, plus a row of characters with no glyph. Per
pass it checks that all 38400 addresses were written exactly once, that every
pixel matches an independent model of font plus attribute, and that selected
glyphs match hand written bitmaps rather than only the ROM they came from. It
also writes a cell mid-pass with no handshake and checks the next pass shows
it.

## What ui_screen paints

`ui_screen.sv` turns a cartridge identification into 600 characters. Phase 3's
screen and nothing more:

```text
CARTRIDGE TOOLS

GBA CARTRIDGE

Title  TESTCART
Code   AMTE
Maker  01
Ver    00

header ok  checksum ok
```

It repaints all 600 cells whenever anything displayed changes, six
microseconds against a renderer that repaints the screen every 382. The detail
rows are blanked unless the result is a recognised GBA cartridge.

Two properties are deliberate:

- **Every result code puts a line on screen.** The message selector has a
  default arm that cannot be reached today, and `tb_ui_screen.sv` walks all
  eight possible codes and fails if any leaves the line blank.
- **The combinational logic is written as functions behind continuous
  assignments, not `always @(*)` blocks.** On a cold boot with an empty slot,
  none of the inputs to the message selector ever changes, so an `always @(*)`
  never fires and the line holds X in simulation while hardware settles it.
  That simulation and synthesis mismatch was a real bug here, caught by
  `tb_ui_screen.sv`'s first check.
