# GBA dumping: a plan

`plan.md` Phase 4 in the form the code actually takes. Written 2026-08-26,
after GB/GBC dumping was verified on sixteen cartridges.

The short version: **almost all of this already exists.** The bus does
sequential reads, the streaming path is platform-agnostic, the file writer
does not care what it is writing. One genuinely new mechanism is needed — the
size probe — and it is the only part that can be wrong in a way that produces
a plausible-looking bad dump. So it goes first, alone, before a single byte is
written to the card.

## What is already there

| Piece | State |
|---|---|
| `gba_cart_bus.sv` | reads ROM, including sequential bursts. Timing verified to the cycle by `tb_gba_cart_timing` |
| `cart_identify_gba.sv` | header, title, game code, header checksum. Verified on two cartridges |
| `cart_probe.sv` | reaches GBA mode through the GB probe. Verified on hardware |
| `dump_chunk_src`, `dump_buffer`, `apf_file_writer`, `dump_engine` | take a byte stream and produce a file. Nothing in them is GB-specific |
| `dump_path_gen.sv` | builds the APF open struct. GB title handling needs a length, see below |

The streaming path is the part that was expensive to get right, and it is
already paid for. `cart_dump_gb` emits bytes on `out_data`/`out_valid` with
back pressure on `out_ready`; anything that emits bytes the same way inherits
the whole chain to the SD card.

## What is genuinely new

### 1. Size determination — the only real unknown

A GBA header has no ROM size field. This is the substantive difference from
GB, where `0x0148` says exactly how many banks exist and `cart_dump_gb`
guesses nothing.

**The mechanism.** During a ROM read `gba_cart_bus` drives the halfword
address onto AD, then releases the bus for the cartridge to answer:

```verilog
wire [23:0] rom_word_addr = latched_addr[24:1] + {23'd0, beat[0]};
wire [15:0] addr_word     = save_space ? latched_addr[15:0] : rom_word_addr[15:0];
```

Past the end of ROM nothing answers, and the bus floats at the last value
driven onto it — the address. `docs/BRINGUP.md` records this observed on
hardware as `0A0 0050 0051 0052`: byte address `0x0A0` is halfword `0x50`,
and each successive read returns its own index.

The useful property is that **the open-bus value is determined by what this
core drove, not by the cartridge.** It is predictable rather than a floating
value we have to characterise.

**The probe.** For each candidate size `S` in 1, 2, 4, 8, 16, 32 MiB, read
eight consecutive halfwords at byte offset `S` and classify:

- **open bus** — `h[k] == ((S >> 1) + k) & 0xFFFF` for all eight. Nothing is
  driving; ROM ends before `S`.
- **mirror** — the eight halfwords equal the eight at offset 0. The address
  wrapped; ROM ends at `S`.
- **data** — neither. ROM is at least `S`; continue.

The smallest `S` that is open bus or mirror is the size. Reaching 32 MiB
without tripping means 32 MiB, which is also the ceiling the bus can address:
`latched_addr[24:1]` is 24 bits of halfword address, exactly 32 MiB, so the
hardware cannot be asked for more.

**The coincidence problem, and the defence.** Real ROM data could contain an
ascending halfword run at exactly the wrong offset. So sample at **two
distant points** — `S` and `S + 0x100000` — and require both to classify the
same way. A ROM that fakes an incrementing counter at one offset is
plausible; one that fakes it at two offsets a megabyte apart, with values
that match each location's own address, is not.

This case belongs in the testbench, not just in this paragraph.

**Risks.** The float has to hold for the read window — `READ_SETUP_CYCLES` is
14, about 139 ns. It has already been observed to hold at these timings, so
this is a known-good rather than an assumption, but it is capacitance
dependent and worth watching if the timings are ever tightened. Separately,
non-power-of-two ROMs exist as trimmed files; the mask ROM in the cartridge is
a power of two, and that is what gets dumped.

### 2. `cart_dump_gba.sv`

A straight counter, and simpler than `cart_dump_gb` because there is no
mapper: no bank registers, no `0x20`/`0x40`/`0x60` hole, no writes at all.

Read 32 bits at a time rather than 16. `gba_cart_bus` latches the address once
and takes the second halfword through `ST_READ_SEQ`, which is what the GBA's
own burst path does:

```
16-bit:  ADDR_HOLD 2 + ADDR_LATCH 4 + READ_TURN 4 + READ_SETUP 14  = 24 cycles / 2 bytes
32-bit:  the above + READ_TURN 4 + READ_SETUP 14                   = 42 cycles / 4 bytes
```

At 100.663296 MHz that is roughly 104 ns per byte, so **32 MiB takes about
3.5 seconds on the bus.** The bus is not the bottleneck; the SD writes are,
and their throughput is unmeasured. That measurement is Phase B.

Emit bytes little-endian — halfword at address `A` has its low byte at `A`, so
a 32-bit read `{hi, lo}` emits `lo[7:0], lo[15:8], hi[7:0], hi[15:8]`.

There is a named `ACCESS_8BIT` and `ACCESS_16BIT` but no `ACCESS_32BIT`; the
bus infers it from `acc` being neither. Add the constant rather than writing
`2'b10` and hoping the reader knows why.

**Longer bursts are possible and not worth doing yet.** `rom_page_end` allows
sequential reads to run to a 128 KiB boundary, so an N-beat burst could
amortise the address latch across a whole page. That saves 6 cycles in 42,
about 14%, on an operation already measured in seconds. Not now.

### 3. Verification — and the GB approach does not transfer

`dump_checksum.sv` compares against the cartridge's own global checksum at
`0x14E`. **A GBA cartridge has no equivalent.** The header checksum at `0xBD`
covers only `0xA0`-`0xBC` and `cart_identify_gba` already checks it. Nothing
in a GBA cartridge describes its own contents.

So the check that caught MarioLand2 has no GBA counterpart, and pretending
otherwise would be worse than admitting it. The honest substitute is
**CRC32 computed during the dump and displayed**, which `plan.md` already
asks for. It cannot say a dump is correct, but it gives the image an identity
that can be compared — against a second dump, or against No-Intro.

Build `dump_crc32.sv` platform-independent and show it for **GB as well**.
A GB dump then reports both: `image checksum ok` from the cartridge's own
value, and a CRC32 that can be matched externally without a PC in the loop.
That is a real gain for the GB path, not just scaffolding for GBA.

Keep it on `clk_sys` in the streaming path. The per-column path in
`ui_screen` has failed setup three times; eight new hex digits on row 13 go
through the same registered text row as everything else added since.

### 4. Wiring

Four changes, all small, all in `core_top.sv` and `dump_engine.sv`:

- **Mode request.** `cart_mode_req = dump_want_gb ? 2'b10 : probe_mode`
  becomes a two-bit request so a dump can hold the connector in GBA mode.
- **Bus arbitration.** The GBA bus has one master (`id_req`). It needs the
  same `dump_busy` mux the GB bus already has. Same argument applies: a probe
  cannot start during a dump and a dump cannot start without a finished
  probe, so the select is `dump_busy` and no arbiter is needed.
- **`dump_ready`.** `(platform == 3'd2)` becomes `platform == P_GB ||
  platform == P_GBA`, and the comment above it — which says X requires a Game
  Boy cartridge because the size comes from `0x0148` — needs rewriting, since
  that is precisely what stops being true.
- **`total_bytes`** selects between the GB bank count and the probed size.

**The write-abort hold still applies, and matters less.** `SS_END` waits for
the bus to go idle before dropping the mode. On GBA it is a smaller risk by
construction: `cart_write_enable` requires `eeprom_space || save_space ||
gpio_space`, so a ROM-space write can never pulse WR# — `tb_gba_cart_write_protect`
covers 62 cases of exactly this. A read truncated by a mode change is
harmless to the cartridge. Keep the hold anyway; the reason it is cheap is
the reason to keep it.

### 5. Filenames, which the GB path needs anyway

`dump_path_gen` takes fifteen bytes from `0x134`. A GBA title is twelve bytes
at `0xA0`, with a four-character game code at `0xAC`.

This wants a **title length input**, which is the same change the outstanding
GB filename bug needs — a CGB title is eleven bytes, not fifteen, which is why
`ZELDA_DIN__AZ7E.gb` has a manufacturer code stuck to it. One parameter fixes
both. Extension becomes `.gba`.

The collision problem gets worse here, not better: GBA titles are truncated to
twelve characters and sequels collide readily. `HANDOFF.md` item 2 covers
this; it should land before or with the first GBA dump, not after.

## Phasing

The order matters more than the content. The size probe is the only mechanism
that can silently produce a wrong answer, so it is validated **alone, with
nothing written to the card.**

### Phase A — size probe, display only

`cart_dump_gba` not yet written. The probe runs after identification and puts
the detected size on screen next to the title. No file, no writes, no risk.

Done when: both GBA cartridges report their true size, and an empty slot
reports open bus at the first candidate rather than a size.

This is cheap, entirely observable from a screenshot, and de-risks everything
downstream. If the probe is wrong, it is wrong here, in public, before it can
produce a 16 MiB file that looks fine.

### Phase B — reader and stream, bounded

`cart_dump_gba` reads a **fixed 1 MiB** regardless of the probed size. Proves
byte order, the stream, the chunk path and the file writer on a platform they
have never run on, at a size already known to work from GB.

Done when: the first 1 MiB matches the first 1 MiB of a known-good dump of
that cartridge, and the header inside the file matches what identification
read off the bus independently.

This is also where **SD throughput gets measured**, which is the number that
decides whether a 32 MiB dump is a few seconds or a few minutes. 32 MiB is
8192 chunk writes, each with a 1.8 s deadline in `apf_file_writer`.

### Phase C — full dump with CRC32

Remove the bound. Add `dump_crc32.sv`, display for both platforms.

Done when: a full cartridge dumps, its CRC32 is stable across two dumps, and
it matches an independently verified dump.

### Phase D — filenames and polish

Title length parameter, `.gba` extension, collision handling. Could be done
earlier; it is listed last only because nothing else waits on it.

## Tests to write

Simulation, before any of it reaches hardware:

- **`tb_gba_cart_model`** extended to model open bus past a configurable end,
  returning the address the way the real bus does.
- **`tb_cart_dump_gba`** — sizes 1, 4 and 32 MiB; open-bus detection; mirror
  detection; byte order; and the adversarial case, a ROM containing an
  ascending halfword run at a candidate boundary, which must not be mistaken
  for the end.
- **Mutation-check the size probe.** Break the comparison and confirm the test
  fails. The write-abort monitor in `tb_dump_engine` passed for a while with
  the fix removed; a test for a rare condition is worth nothing until it has
  been watched to fail.
- **`tb_dump_engine`** through the GBA path, including the mode request.
- **`tb_dump_crc32`** against known vectors.
- **`check_pin_isolation`** still passes — no new module names a pin.

## Exit criteria

From `plan.md` Phase 4, unchanged:

- Dumped ROM matches an independently verified dump.
- Repeated dumps are identical.
- Large cartridges complete without corruption.

The second one has more weight than it did when it was written. Fifteen of the
sixteen GB entries in `STATUS.md` are single dumps, and the two that turned out
to be corrupt passed every check available at the time. **A GBA dump should
not be recorded as verified on one attempt**, particularly since there is no
cartridge-supplied checksum to catch a misread.

## What is not in scope

- **Save data.** EEPROM, SRAM and Flash are Phases 12-14. The bus already
  permits writes in those spaces, which is exactly why they are held apart
  from a read-only dumping path.
- **GPIO and RTC.** Reading a cartridge with GPIO at `0xC4`-`0xC8` is normal
  ROM reading and needs nothing special.
- **Multi-boot images.** A separate format, not a ROM dump.
- **Verification by read-back.** Still not built for either platform. CRC32
  during the dump covers the read path only; a byte lost after the core hands
  it to APF would still report a matching CRC.
