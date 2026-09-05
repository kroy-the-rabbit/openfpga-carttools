# Status

What is actually true right now, as opposed to what is written. The plan in
`plan.md` says where this is going; this file says where it is.

The rule for this file: nothing moves to **verified** without evidence that
someone could go and check. For anything touching a cartridge, that evidence
has to come from a cartridge.

## Milestones

| | Milestone | State |
|---|---|---|
| v0.1 | GBA cartridge identification | **verified on hardware** |
| v0.2 | GBA ROM dumping and verification | **verified on hardware** |
| v0.3 | GB/GBC cartridge identification | **verified on hardware** |
| v0.4 | GB/GBC ROM dumping and verification | **verified on hardware** |
| v0.5 | GB/GBC save backup | **verified on hardware** |
| v0.6 | GB/GBC save restore | not started |
| v0.7 | GBA SRAM backup and restore | backup **verified on hardware**, Zero Mission's 32 KiB SRAM loaded in mGBA with its file intact. Needs no write. Restore not started |
| v0.8 | GBA Flash backup and restore | 64 KiB backup **verified on hardware**, Golden Sun loaded in mGBA with its state intact, and it needs no write. 128 KiB blocked on the bank select write. Restore not started |
| v0.9 | GBA EEPROM backup and restore | backup **verified on hardware**, eight cartridges at 512 bytes and 8 KiB, each loaded in mGBA with its state intact. The read command is the only one the reader can form. Restore not started |
| v0.10 | RTC support | not started |
| v1.0 | Stable GB/GBC/GBA cartridge utility | not started |

## Phases

| Phase | State | Notes |
|---|---|---|
| 0. New repository | done, builds | history preserved, metadata renamed |
| 1. Strip the emulator | done | `core_top.sv` 1851 lines to 629 |
| 2. Cartridge bus HAL | done | `cart_pins.sv` owns the pins, two engines behind it |
| 3. GBA identification | **verified on hardware** | `cart_identify_gba.sv`. Minish Cap read and validated |
| 5. GB/GBC bus mode | **verified on hardware** | `gb_cart_bus.sv`, `cart_probe.sv`, including the escalation |
| 6. GB/GBC header parsing | **verified on hardware** | `cart_identify_gb.sv`. Link's Awakening DX read and validated |
| 8. GB/GBC dumping | **verified on hardware** | twenty-six cartridges, 32 KB to 4 MB, five mapper families; every retained image passes its own checks, **all twenty-six externally matched** to No-Intro by CRC32 and size, and the on-device checksum is confirmed too |
| 4. GBA dumping | **verified on hardware** | `gba_size_probe.sv`, `cart_dump_gba.sv`, `dump_crc32.sv`. Fifteen images at 4, 8 and 16 MB; **all fifteen externally matched** to No-Intro by CRC32 and size; two reproduce byte for byte on a second dump |
| 7+ | not started | no longer gated: the hard stop is cleared |

## The hard stop is cleared

2026-08-25. `plan.md`'s First Hard Stop was:

```
launch core -> access physical GBA cartridge -> read header -> validate ->
display cartridge identity
```

That now happens, for both platforms, on a real Analogue Pocket. Anyone can
re-run it: put the cartridge in, launch the core, choose Play Cartridge, and
press SELECT for the raw bytes.

| Cartridge | Screen | Diagnostics |
|---|---|---|
| Zelda: Link's Awakening DX (GBC) | `GB / GBC CARTRIDGE`, title `ZELDA`, type `1B` (MBC5+RAM+BATTERY), ROM `05` (1 MB), RAM `03` (32 KB) | `result 2`, `stable 1`, `0BD read 3B calc 3B` |
| Zelda: The Minish Cap (GBA) | `GBA CARTRIDGE`, title `GBAZELDA MC`, code `BZME`, maker `01`, header ok | `result 1`, `stable 1`, `0BD read D8 calc D8` |
| Golden Sun (GBA) | `GBA CARTRIDGE`, title `Golden_Sun_A`, code `AGSE`, maker `01`, header ok | `result 1`, `stable 1`, `0BD read 42 calc 42` |
| Zelda: Oracle of Seasons (GBC) | `GB / GBC CARTRIDGE`, title `ZELDA DIN  AZ7E`, type `1B`, ROM `05`, RAM `02` | `result 2`, `stable 1`, `0BD read EE calc EE` |
| Tetris Plus (GB) | `GB / GBC CARTRIDGE`, title `TETRIS PLUS`, type `03` (MBC1), ROM `03`, RAM `02` | `result 2`, `stable 1`, `0BD read F9 calc F9` |

Five cartridges, chosen so they are not five copies of the same case: two
mappers (MBC5 and MBC1), all three CGB flag values (`80` dual, `C0` CGB-only,
`00` DMG-only), both GB header layouts (with and without the 4-character
manufacturer code that shortens the title field), a non-Nintendo licensee
(Jaleco), and both destination codes. Every header checksum matched.

Two independent cross-checks, not just our own arithmetic agreeing with
itself. The Pocket's own menu reported Link's Awakening DX as **Rev 1**, and
byte `0x014C` of the header we read is `01`. And the GBA header's defined
fixed byte `0x96` landed at `0x0B2`, which is where a GBA header is required
to put it.

The GB to GBA escalation is included in that: the Minish Cap was identified by
probing GB first, finding nothing, turning the pins round, and then reading in
GBA mode. That is the path `docs/HARDWARE-NOTES.md` section 5a is most worried
about, and it works.

What this does **not** license is dumping. Identification reads 26 or 32 bytes
from a fixed address. A dump reads millions across banks, and none of the
mapper, bank-switching or sustained-throughput behaviour has been touched.

## What hardware taught us that simulation could not

Three faults, none of which any testbench could have found, because all three
are about the world outside the FPGA.

**The core never got the slot powered, and the reason was one bit in
`core.json`.** `framework.hardware.cartridge_adapter` was `"0x01000000"`,
inherited from the branch this forked from, whose commit message asserted it
"is what asks the Pocket to power the slot". It is not. It is a bitmask, and
bit 24 means "enable the Play Cartridge option in the Asset browser when
starting the core". Analogue's documented rule: power activates if bit 24 is
unset, or if bit 24 is set **and the user selects Play Cartridge**. Meanwhile
the strip had emptied `data.json` to `"data_slots": []`, so the Pocket had no
assets to browse, opened no browser, and offered no Play Cartridge entry. Bit
24 gated power behind a menu item that could not exist. The core reported
`play 0` forever and was right to.

Fixed by keeping bit 24 and declaring one `deferload` slot so the browser
appears. `deferload` matters: it makes the Pocket announce the slot without
streaming bytes into a core that has no loader for them. Setting the field to
`0` also powers the slot but removes the user's explicit consent, which
`docs/BRINGUP.md` depends on for safe insertion.

**The diagnostics page showed the wrong buffer on exactly the failure it
exists to explain.** `core_top.sv` selected the GB or GBA byte buffer with
`platform == P_GB`. But `P_UNKNOWN` and `P_UNSTABLE` arrive from *either*
engine, so a GB-path failure displayed the GBA reader's buffer, which had
never run. The question is which engine answered, not what the verdict was.
`cart_probe` now reports `answered_gba` and the page selects on that. This
cost real debugging time: it produced a screen full of plausible hex that
described nothing.

**A cartridge is not readable for something like a second after the slot is
powered.** The first probe after launch always returned UNRECOGNISED while
every rescan succeeded and was stable. Ruled out by experiment, in this order:
a 100 ms delay before probing (no effect), and 50 ms of `/RES` held high
before the first strobe (no effect). About 2 s does fix it. The mechanism is
not understood, only bounded: somewhere between 50 ms and 2 s, and it is
elapsed time rather than anything the core does, since a rescan that follows a
failure by a second works without any change of state.

The variable was then isolated. Moving the 2 s out of the probe and into a
one-shot delay after the slot is powered, leaving only 50 ms per probe, still
identifies correctly on the first attempt. So the quantity is **elapsed time
since the slot was powered**, not time since `/RES` release and not anything
per-probe. That is why it belongs in `core_top`'s `CART_WAKE_CYCLES` and why
rescans are not slowed by it.

This still deserves suspicion rather than satisfaction. Knowing *which* clock
matters is not knowing *why* about 2 s is needed, and 2 s remains a number
picked because it worked. If the underlying quantity is a rail slew or a
cartridge's own power-on behaviour, it may vary with the cartridge and with
the Pocket's battery level. Testing near a flat battery is the cheapest way to
find out whether this constant is generous or merely lucky.

## Known defects in inherited code

**The cartridge identification probe does not work.** `core_top.sv` in the
fork this is based on has a `cart_probe_state` machine that reads the header
at `0xAC` and `0xAE` into `physical_cart_id`. It drives `probe_cart_req` and
`probe_cart_addr`, and nothing reads either signal: the bus request is
`cart_fill_req | gba_cart_req`, with the probe absent. So the probe captured
whatever the ROM cache happened to fetch, at whatever address it happened to
want. Any cartridge identification that appeared to work on that branch was
reading the emulator's traffic, not its own. This is why Phase 3 is real work
rather than salvage. The dead logic came out with the strip.

**GB cartridges are handled by a separate engine, not by the GBA one.**
`gba_cart_bus.sv` drives `bank1` as an address output through every read; a GB
cartridge drives D0-D7 on those pins on any /RD low. `gb_cart_bus.sv` handles
GB mode and `cart_probe.sv` probes GB first, escalating to GBA only on an
all-0x00 or all-0xFF read. `docs/HARDWARE-NOTES.md` section 5a. `plan.md`
states the opposite probe order and is wrong.

**The bus testbench never passed, and was thinner than it looked.** It failed
on its own assertion 146 ns in, and the assertion was wrong rather than the
module. It also overrode every timing parameter to 1 or 2, so the numbers that
actually reach a cartridge were never simulated, and it never proved that a
write to ROM space is suppressed. Both are now covered, along with 32-bit
accesses, ROM page boundaries and asynchronous aborts. `tools/sim/README.md`
lists what is covered and what still is not.

**Aborting a write mid-pulse corrupts what the cartridge latches.** Found by
sweeping reset and `cart_mode` across every cycle of a transaction. A reset
landing two cycles into WR# low leaves a 3-clock WR# pulse instead of 12 and
raises WR# on the same edge that releases the data pins; a `cart_mode` drop
does the same with no clock edge involved, because those pin assignments are
combinational. A cartridge latches write data on the WR# rising edge, so what
it captures is whatever the released bus settles to.

This cannot affect anything built today, because identification only reads and
the module holds WR# high outside EEPROM, save and GPIO space. It is a
blocker for save restore, Phases 11 and 14, and must be fixed before a write
to a real cartridge is ever attempted. Asserted in its real form in
`tb_gba_cart_async` under a KNOWN DEFECT heading, so the suite stays green and
the assertion fails if the module is ever changed.

**The bus request handshake has a trap in it.** `req` is a level sampled in
the bus's idle state, and its done state returns to idle the cycle after it
raises `done`. So a caller that waits for `done` before dropping `req` is one
cycle too late and gets a second transaction it never asked for. This is not a
defect in the module so much as an unwritten rule about how to drive it, which
is worse, because nothing announced it.

`cart_identify_gba` is not affected: it drops `req` the cycle after raising
it, long before `done`. The dump engine will have to do the same. Pinned in
`tb_gba_cart_async`.

**A 32-bit write to save space writes one byte twice.** Redundant rather than
wrong, since a real GBA 32-bit SRAM write moves only the low byte, but a
caller expecting four bytes to land will not get them. Asserted in
`tb_gba_cart_wide`.

**The PHI divider in `gba_cart_bus` is dead code.** It generates a correct
16.78 MHz clock that nothing uses, because `bank0[7]` is hardwired low. The
core template calls that pin PHI#, and the working GB core drives it
non-inverted, so which polarity is correct is an open question in
`docs/HARDWARE-NOTES.md`.

## Dumping: what is built

`X` dumps the cartridge in the slot to `/Assets/carttools/common/<TITLE>`,
with `.gb`, `.gbc` or `.gba` chosen from the platform and `0x0143` since
`47bcd54`. Flat, with no sidecar: `docs/FILE-FORMATS.md` specifies a
`Dumps/` tree and a `.cart.json` alongside each image and neither is
implemented.
`A` rescans, `X` dumps the ROM and `Y` backs up the save. That is the whole
control surface.

`Y` appears only when the cartridge in the slot has a save this core can read:
GB or GBC, with a RAM size code `dump_engine` can reach: 2 KB, 8 KB, 32 KB,
and on MBC5 also 64 KB and 128 KB. Anything else is refused before the press
rather than after a file has been opened - `dump_engine` exposes
`save_supported` live off the header for exactly this - and **the screen says
which cartridges are refused**, on row 15, because the first cartridge the
save path ever met was refused in silence.

The `Y` self test and the `SELECT` diagnostics page were **removed**: the page
took `B` for byte order, `>` for the path root and `<` for APF's reply to
`0x0190` with it. Every value those controls existed to find has been settled
and is recorded below, so `byte_order` is a constant `1` and `path_style` a
constant `0` in `core_top.sv`. `dump_engine` still searches outward from them,
so a wrong constant would cost extra attempts rather than a failed dump.

`dump_engine`, `dump_path_gen` and `dump_chunk_src` keep a `selftest` port,
tied to `1'b0` in `core_top`. It is a simulation hook: it is how
`tb_dump_engine` exercises the APF path search with no cartridge modelled.
Tied off, Quartus folds the ramp generator and the `.bin` extension out, so
nothing of it reaches the bitstream.

### Saves, added and verified on hardware 2026-08-28

`cart_save_gb.sv` reads battery-backed RAM out of a GB or GBC cartridge and
writes it as `<TITLE>.sav` beside the ROM dump. The sequence is the only one
the hardware provides: write `0x0A` to `0x0000` to open the RAM gate, read
`0xA000`-`0xBFFF`, write `0x00` to shut it again.

**The invariant is that nothing ever sets a write with an address in
`0xA000`-`0xBFFF`.** That one sentence covers every way this operation can
destroy a save, and it is the reason the module exists in this shape:

- `tb_gb_save_write_protect` watches `/WR` and `/CS` at the connector pins on
  every clock edge of a full 8 KB read. It is **mutation proof by
  construction**: phase 2 drives a deliberate write into the RAM window
  through the same bus, and the run fails unless the monitor catches it. So
  the test cannot rot into one that passes because the condition never
  arises, which is how two earlier monitors in this tree passed with their
  fixes removed.
- Mutating the reader to write at `0xA000` was also run by hand and produced
  three independent failures: the pin monitor, the model's RAM write count,
  and the gate being left open.
- The gate is shut on **every** exit including an abort, which is why the save
  reader is the one reader `dump_engine` does not hold in reset on an abort -
  a reset would leave the cartridge's RAM writable as it left the slot.
  `SS_END` waits for the save reader as well as the bus before dropping the
  connector mode, because the write that must never be truncated is the
  disable.

**What a save cannot tell you, and what is shown instead.** Save data carries
no logo, no header checksum, no global checksum and no length. Every check
that makes a ROM dump trustworthy is missing. So the screen reports facts:

| Row | What it says |
|---|---|
| 13 | whether the RAM answered, or that it did not, or that the save is blank |
| 14 | CRC32, the same as for a ROM dump |
| 15 | the first four bytes, as hex |

"Did not answer" comes from a **non-destructive presence probe**: the first
256 bytes are read with the gate shut and again with it open, and the two sums
compared. Equal sums mean the enable very probably did not take and what
follows is open bus - an 8 KB file of `0xFF` that looks exactly like a
successful backup. A dead battery and a dead enable are genuinely
indistinguishable from outside, both give `0xFF`, and the screen says both
facts rather than picking between them.

### The single-bank claim was wrong, 2026-08-28

The save path first shipped reading one bank and refusing everything else, on
the evidence that all ten battery-backed cartridges here report `0x02`, 8 KB,
one bank - checked against both the nineteen filed images and the nineteen
matched official ROMs. That survey was taken over a set with a hole in it.

**Link's Awakening DX is 1 MB, MBC5 + RAM + battery, with 32 KB of save RAM
in four banks**, and its image is missing from the library for a reason
already written down: it and Link's Awakening both title themselves `ZELDA`,
and the second dump silently overwrote the first. `docs/HANDOFF.md` item 2.
So a known bug removed the one counter-example, and the survey then confirmed
what the missing data would have refuted.

It was the first cartridge anyone pointed the save path at. No `Y` in the
help row, nothing on screen, no reason given.

Both halves are fixed. Banking is built - 2 KB to 128 KB, with the MBC1 mode
trap and the MBC3 RTC exclusion, mutation checked both ways - and a cartridge
that is still refused now says so on row 15.

**What is still refused.** MBC2's 512 nibbles, which live inside the mapper
and report `0x00` at `0x0149` even though RAM exists, so the type is checked
as well as the size. And sizes above 32 KB on MBC1 or MBC3, which have no
bank bits to reach them: a size a mapper cannot address is refused rather
than truncated to one it can, because a 128 KB file holding the low four
banks four times over would pass every check there is.

**The two traps, and the write each one justifies.** MBC1 needs mode 1 at
`0x6000` before the bits at `0x4000` mean a RAM bank at all - in mode 0 they
extend the ROM bank, so a banked read without it returns bank 0 as many times
as there are banks. Mode 0 is written back afterwards, because the register
persists and a ROM dump that followed would otherwise bank wrongly. MBC3 maps
its clock registers over the RAM window when `0x08`-`0x0C` is written to the
bank register, so only `0x00`-`0x03` is ever written there and
`tb_cart_save_gb` counts it.

Bank 0 is selected explicitly rather than assumed. The register survives
whatever ran before - another tool, a game, an aborted read - and trusting its
power-on value would put some other bank's contents at the head of the file
with nothing to show it had happened.

**And it is the path that got verified.** The cartridge that exposed the bug
is the one that proved the fix: see below.

### The save read is verified, by the only test that can verify one

**2026-08-28. A 32 KB save was dumped off a Game Boy Color cartridge, loaded
into mGBA beside its own ROM dump, and the game came up with everything
intact.** The user's verdict: *"It's working perfect. All states restored."*

That is the whole proof, and nothing weaker would have done. A ROM read
verifies itself - the header checksum and the global checksum were written at
manufacture, and both matched, and the declared 1024 KB matched the file.
**Save RAM carries no checksum of any kind.** The only way to know the bytes
are right is to let the game that wrote them read them back.

The cartridge:

| | |
|---|---|
| header title | `ZELDA` - Link's Awakening DX |
| type `0x0147` | `1B`, MBC5 + RAM + battery |
| ROM | 1 MB, header checksum and global checksum both matched |
| save `0x0149` | `03`, 32 KB, **four banks** |
| `.sav` written | exactly 32,768 bytes |

So the banked path is verified, not just the single-bank one - and it is
verified on the cartridge whose existence disproved the survey that had
refused it an hour earlier.

**What this does not prove.** One cartridge, one mapper, one size. MBC1's
mode-1 trap is still simulation only, because the cartridge that exercised
banking here is MBC5 and MBC5 has no mode register. 64 KB and 128 KB have no
cartridge at all. And a single verified read says nothing about the next one.

**Two checks that a size or an entropy test cannot give you**, both done here
and neither sufficient: the `.sav` was exactly the length `0x0149` declares,
and it did not look blank. Both would have passed on a subtly wrong read.
`scripts/verify_dump.py` performs them and says so in as many words.

**The double read is still not implemented.** `docs/GB-SAVE-PLAN.md` calls it
mandatory - read twice, compare, do not write the file on a mismatch - and it
needs the buffering in `docs/DUMP-VERIFY-PLAN.md`. Until it exists, a `.sav`
from this core is a single read, and the way to get a second opinion is to
dump twice and run `scripts/verify_dump.py --compare`.

### How to re-run the verification

    tools/podman/play-dump.sh ZELDA.gbc ZELDA.sav

Builds an mGBA container on first use, copies the ROM and save into a scratch
directory - never the originals, because mGBA writes to a `.sav` as you play -
and plays it. Two host-specific obstacles are handled inside the script and
both look like the emulator failing when they are wrong: SELinux denies a
container write on the X socket without `--security-opt label=disable`, and
the xauth cookie is bound to a hostname the container does not share, so it
needs rewriting to `FamilyWild`. Neither loosens anything outside the scratch
directory; in particular `xhost` is never called.

`scripts/verify_dump.py` covers what a checksum can: logos, header and global
checksums, sizes against what the header declares, CRC32, and for a save the
one structural failure the device cannot see - **all banks identical**, which
is what a bank select that did not take produces. It has a `--selftest` that
proves each check fires.

Seven modules, all of them under test:

| Module | What it does |
|---|---|
| `cart_dump_gb.sv` | reads every bank through the mapper, emits a byte stream |
| `cart_save_gb.sv` | opens the RAM gate, reads the save, shuts the gate, on every exit |
| `dump_chunk_src.sv` | throttles that stream into one buffer's worth at a time |
| `dump_buffer.sv` | packs bytes into bridge words, and is the payload's clock crossing |
| `dump_path_gen.sv` | builds the 264-byte `open_dataslot_file_t` APF reads the filename out of |
| `apf_file_writer.sv` | `0x0192` open, `0x0184` write per chunk, checking every one, with a deadline on each |
| `dump_engine.sv` | sequences them, holds the connector in GB mode, and owns the three clock crossings |

`tb_dump_engine` reads a modelled 32 KB cartridge through both clock domains,
answers the target commands the way APF does, reassembles the file the way a
little-endian host would, and compares it byte for byte. It also covers a
short trailing chunk and a partial bridge word, which no cartridge size can
produce, and a failed open.

## v0.4 is done: sixteen dumps, all clean, 2026-08-26

*Superseded by the later sections in this file. Kept because it records what
was believed on the day, including two conclusions that turned out to be
wrong.*

Written by the core to `/Assets/carttools/common/`, each under a name it
chose from the cartridge title. Every one checked against the header the
cartridge carries about itself. `Link's Awakening DX` is kept off the card
for the reason given under the filename wart below.

| File | Bytes | Type | Logo | Header sum | **Global sum** | Banks | CRC32 |
|---|---|---|---|---|---|---|---|
| `TETRIS.gb` | 32,768 | `00` ROM only | exact | ok | ok | 2/2 | `46DF91AD` |
| `OTHELLO.gb` | 32,768 | `00` ROM only | exact | ok | ok | 2/2 | `C17A002E` |
| `SUPER_MARIOLAND.gb` | 65,536 | `01` MBC1 | exact | ok | ok | 4/4 | `2C27EC70` |
| `BOMBER_BOY.gb` | 131,072 | `01` MBC1 | exact | ok | ok | 8/8 | `EF9595AC` |
| `TETRIS_FLASH.gb` | 131,072 | `01` MBC1 | exact | ok | ok | 8/8 | `9DFCB385` |
| `UNO2SMALL_WORLD.gb` | 131,072 | `01` MBC1 | exact | ok | ok | 8/8 | `A7AD65EF` |
| `BOMBERMAN_GB.gb` | 262,144 | `01` MBC1 | exact | ok | ok | 12/16 | `94337D56` |
| `MARIO_S_PICROSS.gb` | 262,144 | `03` MBC1+RAM+bat | exact | ok | ok | 16/16 | `17533700` |
| `SANGOKUSHI.gb` | 262,144 | `03` MBC1+RAM+bat | exact | ok | ok | 16/16 | `83706E92` |
| `TETRIS_PLUS.gb` | 262,144 | `03` MBC1+RAM+bat | exact | ok | ok | 15/16 | `2EC9120A` |
| `MOGURANYA.gb` | 524,288 | `03` MBC1+RAM+bat | exact | ok | ok | 32/32 | `82FCA204` |
| `MARIOLAND2.gb` | 524,288 | `03` MBC1+RAM+bat | exact | ok | ok | 32/32 | `29E0911A` |
| `ZELDA.gb` | 524,288 | `03` MBC1+RAM+bat | exact | ok | ok | 32/32 | `8CF27C90` |
| `ZELDA_DIN__AZ7E.gb` | 1,048,576 | `1B` MBC5+RAM+bat | exact | ok | ok | 64/64 | `D7E9F5D7` |
| `ZELDA_NAYRUAZ8E.gb` | 1,048,576 | `1B` MBC5+RAM+bat | exact | ok | ok | 64/64 | `3800A387` |
| Link's Awakening DX | 1,048,576 | `1B` MBC5+RAM+bat | exact | ok | ok | 63/64 | `B38EB9DE` |

`TETRIS.gb` is the one with more than a single dump behind it: **four
consecutive dumps, byte for byte identical**, taken while confirming the
on-device checksum. Everything else in the table is a single dump that passes
every check the file can be made to answer. That distinction is the point of
the section below.

Mapper and size coverage on hardware:

| Mapper | Sizes proven |
|---|---|
| ROM only (`00`) | 32 KB |
| MBC1 (`01`) | 64 KB, 128 KB, 256 KB |
| MBC1+RAM+battery (`03`) | 256 KB, 512 KB (three cartridges) |
| MBC5+RAM+battery (`1B`) | 1 MB (four cartridges), 2 MB, 4 MB (two cartridges) |
| MBC5 (`19`) | 1 MB |
| MBC5+RUMBLE+RAM+battery (`1E`) | 1 MB |

MBC2, MBC3 and MBC1 above 512 KB remain simulation only. MBC1 above 512 KB
is the case expected to differ, for the reason `cart_dump_gb.sv` documents:
banks `0x20`, `0x40` and `0x60` cannot be selected at all.

### The three that did not verify, and what each turned out to be

**`MARIOLAND2.gb` was a bad contact, and the re-dump proves it exactly.**
The second attempt verifies completely: logo exact, header and global
checksums correct, 32/32 distinct banks, `29E0911A`. Diffed against the first
attempt, 105,121 of 524,288 bytes differ and **every single difference is bit
7 alone**, flipping both ways: 61,220 set-to-clear and 43,901 clear-to-set.
One data line reading randomly. Not stuck, floating, and nothing to do with
the bus timing or the core.

**And the first attempt passed identification, which is the part that
matters.** Its header region came back with bit 7 set on every byte, and its
header checksum still balanced:

    0x134-0x14D  cd c1 d2 c9 cf cc c1 ce c4 b2 80 80 ... 92
    stored 92, computed 92 -> passes

Twenty-five bytes each shifted by `+0x80` sum to `0xC80`, whose low byte is
`0x80`; the stored checksum byte took the same `+0x80`, and the two shifts
cancelled. **An 8-bit header checksum is structurally blind to a uniform
bit-7 offset.** So the screen showed a garbled title next to `checksum ok`
and let the dump proceed.

`cart_identify_gb`'s stability check did not help either: it reads the header
twice and compares, and D7 was consistently high during that window, so
nothing disagreed with itself. Consistent and wrong looks exactly like
correct.

The global checksum caught it, and at the time that ran on a PC after the
fact. That was the argument for `dump_checksum.sv`, which now computes the
same sum on the device while the image streams past. It is confirmed on
hardware: see below.

**`TETRIS.gb` and `OTHELLO.gb` were the dumper's fault, not the
cartridges'.** This entry previously read that both cartridges probably ship
an incorrect global checksum — true of some commercial cartridges, since the
boot ROM checks only the logo and the header checksum, and both of these are
1989-90 ROM-only titles. That explanation was recorded as plausible rather
than established, and it was wrong.

Re-dumped on the `ec566cd` bitstream, both verify completely, and both CRC32s
changed:

| File | Was | Now |
|---|---|---|
| `TETRIS.gb` | `171361BA`, global sum differs | `46DF91AD`, everything ok |
| `OTHELLO.gb` | `57F3A938`, global sum differs | `C17A002E`, everything ok |

Tetris was then dumped four times in total, byte for byte identical every
time. The cartridges are fine.

**The old files are corrupt in a structured way, and the structure rules out
a contact fault.** In `OTHELLO.gb` every one of the 224 wrong bytes falls in
the first sixteen bytes of a 1 KB window, and those bytes are the head of a
*different* window:

    old 0x800   cd 46 0d d1 7a e6 10 28    = good dump's 0xC00 head
    old 0xC00   19 11 2f cb fa 0e cb cb    = good dump's 0x800 head

The same relocation map appears in `TETRIS.gb` at the same offsets. Two
different cartridges producing an identical map is not noise. `TETRIS.gb`
carries heavy additional corruption on top of it — 23% of bytes, rising with
address, with no byte-lane bias and no one-word pipeline lag — so there were
either two faults or one whose severity varied.

**The mechanism is not identified.** It reproduced on the `86118ac`
bitstream and has not reproduced on `ec566cd`, but nothing in the difference
between them plausibly touches the chunk path: `dump_checksum` is passive and
the write-abort change only affects `SS_END`. Four identical Tetris dumps
make "still live and got lucky" the weaker explanation of the two, without
making it wrong. Treat the fifteen single-dump entries above accordingly.

**What this cost, and what it bought.** Two good cartridges were recorded as
suspect for a day on the strength of a plausible story, because every check
the core had at the time passed. That is the same failure as MarioLand2: the
corruption was invisible to the checks that existed before it and visible to
the one added after.

**Externally matched.** `B38EB9DE` identifies *The Legend of Zelda: Link's
Awakening DX (USA, Europe) (Rev B)*. Three header fields nobody consulted
while dumping agree with that record independently:

| Header | Value | Record |
|---|---|---|
| `0x14C` version | `01` | Rev B |
| `0x143` CGB flag | `80` | Game Boy Compatible, not CGB-only |
| `0x146` SGB flag | `03` | Super Game Boy Enhanced |

The lookup was a search summary rather than the No-Intro DAT itself, so the
corroboration is what makes it worth recording: a bare hash match from a
secondary source would not be. **Closed 2026-09-02**: this image, and every
other, has since been matched against the DAT itself.

`SELFTEST.bin` is a clean ascending ramp, which confirms byte order and the
read pipeline with no cartridge involved. `0x0192` succeeded throughout, so
the core named every file itself; the slot-file fallback has still never run
on hardware.

### The on-device checksum works, confirmed 2026-08-26

`dump_checksum.sv` sums every byte as it streams to the card and compares
against the cartridge's own value at `0x14E`, which `dump_engine` holds back
from the sum. The result lands on row 13 of the completion screen:

    DUMP COMPLETE
    [####################]
    TETRIS.gb
    image checksum ok

Confirmed on hardware, on a cartridge whose correct image was already known
from four identical dumps — so a wrong verdict there would have indicted the
display rather than the read path. Note that row 13 is gated on
`dump_state == 2`, meaning it paints only while the dump sits in its
completed state; press A to rescan and it clears. The `checksum ok` on the
identification rows is a different check — the 8-bit header sum at `0x14D`,
the one MarioLand2 proved blind.

The limits are stated rather than hidden, and `tb_dump_checksum` has a case
for each: a sum cannot localise an error, and two compensating faults cancel.

**Known wart in the filenames, and it is not only cosmetic.**
`ZELDA_DIN__AZ7E.gb` should be `ZELDA_DIN.gb`. `dump_path_gen` takes fifteen
bytes from `0x134`, which is the old title field. On a CGB cartridge the
title is eleven bytes and `0x13F`-`0x142` is a four-character manufacturer
code, so it lands in the name.

**The same generator silently overwrote a dump.** Link's Awakening and
Link's Awakening DX both carry the title `ZELDA` at `0x134`, so both produce
`ZELDA.gb`, and dumping the second replaced the first with no warning — the
DX image (`B38EB9DE`, the only dump in this file corroborated against an
outside source) was recovered from a copy made earlier in the session and is
kept off the card. Nothing in the core checks whether the name it chose is
already taken.

Two fixes, and the second is the one that matters: truncate CGB titles to
eleven bytes, and refuse to overwrite an existing file whose contents differ
— or disambiguate the name, as APF's own slots do.

## GBA dumping works, 2026-08-27

The ROM size is not in a GBA header, so it is measured rather than read. Past
the end of ROM nothing drives the bus and it floats at the last value this
core put there — the halfword address — so a read at byte address `A` comes
back as `(A >> 1) & 0xFFFF`. `gba_size_probe` reads four halfwords at spread
offsets from each candidate boundary and classifies open bus, mirror or data.

**Sized correctly on three cartridges**, each by observation rather than by
reaching the ceiling:

| Title | Code | Probed | Actual |
|---|---|---|---|
| `GBAZELDA MC` | `BZME` | 16 MB | Minish Cap, 128 Mbit |
| `Golden_Sun_A` | `AGSE` | 8 MB | Golden Sun, 64 Mbit |
| `ZEROMISSIONE` | `BMXE` | 8 MB | Zero Mission, 64 Mbit |

The probe never reads the title or the game code. It arrives at a size from
bus behaviour alone, so the code identifying the cartridge and the probe
agreeing on its size are two unconnected facts.

**Externally matched.** `GOLDEN_SUN_A.gb`, 8,388,608 bytes, CRC32
`E1FB68E8`, identifies *Golden Sun (USA, Europe)*. Four header fields the
lookup did not use agree with that record independently:

| Header | Value | Record |
|---|---|---|
| `0xAC` game code | `AGSE` — GBA, Golden Sun, USA/English | USA, Europe |
| `0xB0` maker | `01` | Nintendo |
| `0xBC` version | `00` | base entry, no revision |
| probed size | 8 MB | 64 Mbit release |

The lookup was a search summary rather than the No-Intro DAT, so as with the
Zelda match it is the corroboration that makes it worth recording. **Closed
2026-09-02**, against the DAT itself.

**Minish Cap, and the tightest match here.** `GBAZELDA_MC.gb`, 16,777,216
bytes, CRC32 `ABCEBBB1`. A reference table that lists all three regional
releases separately agrees on every field, and discriminates region on two
identifiers that have nothing to do with each other:

| | This dump | Record, USA | JPN | EUR |
|---|---|---|---|---|
| CRC32 | `ABCEBBB1` | `ABCEBBB1` | `6CE771A5` | `E8637292` |
| header checksum | `D8` | `D8` | `D3` | `CD` |
| game code | `BZME` | `BZME` | | `BZMP` |
| ROM | 16 MB probed | 16 MiB | | |

The CRC32 is a hash over all sixteen megabytes; the header checksum is an
eight bit value computed here from 29 header bytes. They are unrelated, and
both select the same region, as do the game code and the size.

**The Nintendo logo is verified, by two cartridges rather than by a
reference.** All 156 bytes of `0x04`-`0x9F` are identical between
`GBAZELDA_MC.gb` and `GOLDEN_SUN_A.gb`, beginning `24 ff ae 51 69 9a a2 21`.
That region is covered by no checksum in a GBA header, so nothing in this
repo had ever verified it. Two independent dumps of two different cartridges
agreeing across all of it validates both, in a place neither could have
faked.

**A padded mask ROM reads correctly, which is the case the classifier was
argued about in advance.** Minish Cap's last two megabytes are each 100%
`FF`, one distinct byte value apiece; the game occupies through MB 13 and the
silicon is 16 MB. An all-ones region is not open bus - open bus returns the
address, so it reads `0000 0001 0002`, never `FFFF` - and `gba_size_probe`
read past both padding megabytes to the true chip boundary. A classifier that
treated all-ones as the end would have reported 14 MB, a size no GBA
cartridge has. The refusal of that rule is recorded in the module rather than
left to be rediscovered as a bug.

**`dump_crc32` agrees with `zlib`.** The screen read `E1FB68E8` and the file
on the card computes `E1FB68E8`. Since the CRC is taken from bytes leaving
the reader, agreement with the file also means nothing was lost between the
core and the SD write — which is the one thing `dump_checksum` cannot say.

**The size is corroborated, not merely asserted.** All eight megabytes carry
real data: every 1 MB block distinct, all 256 byte values present in each,
and the densest byte in the last block is `00` at 4.8%. A truncated dump
leaves a tail of padding or repeats. There is none.

### The size probe is where three implementations disagreed

Three were written independently and cross-tested against each other rather
than scored on their authors' descriptions. Two reported **1 MiB for a 4 MiB
cartridge** whose upper 3 MiB answers with its own halfword address — a
silently truncated dump, the exact failure the module exists to prevent.

The survivor distinguishes them with a 32-bit confirmation read.
`gba_cart_bus` takes beat 1 through `ST_READ_SEQ` with the bus released, so
genuine open bus returns `{A,A}` while a cartridge answering the burst
returns `{A+1,A}`. That is evidence of a different kind from the data
pattern, and no amount of further 16-bit sampling substitutes for it.

`docs/GBA-DUMP-PLAN.md` still describes the classifier that did not survive
contact: eight consecutive halfwords, offset 0 as the mirror reference, and
no confirmation read. The code is right and the plan is behind it.

### Not done

Phases C and D of the plan. A GBA dump still gets a `.gb` extension — the
extension and the CGB title-length bug are one change and half of it would
leave two half-fixes. Zero Mission has been sized but not dumped, and the 32 MB
ceiling is untested - no cartridge that size is to hand, and the probe reaches
it by exhaustion rather than by observation, which is a weaker claim the
screen distinguishes as `ROM 32 MB max`.

Both GBA dumps are single attempts. Neither has been dumped twice, which is
the check that settled Tetris and the one thing an external CRC match does
not substitute for: it proves this image is right, not that the next one will
be.

## The on-device checksum caught a bad dump, 2026-08-27

`dump_checksum` was built after Super Mario Land 2's first attempt passed
identification with a floating D7. Until now it had only ever run on
cartridges that were fine, so it had never been shown to catch anything.

`TENNIS.gb` is corrupt and the Pocket said so:

    TENNIS
    ROM only                       00
    ROM 32 KB      RAM none
    checksum ok                    <- the 8 bit header sum, over 25 bytes
    DUMP COMPLETE
    [####################]
    TENNIS.gb
    image sum BB29 want E047       <- dump_checksum, over all 32,768
    crc32 BB0A08E1

Recomputed on a PC from the file on the card: computed `BB29`, stored `E047`.
**Exactly the two numbers the device displayed.**

Note the row above it. The header checksum passed, which is the same blind
spot that let MarioLand2 through: a check that reads 25 bytes cannot see what
a check reading 32,768 can.

**The corruption is an addressing fault, not a data line fault.** Two runs
hold the contents of the address sixteen bytes higher:

    0x108-0x10F   holds what belongs at 0x118-0x11F
    0x120-0x12B   holds what belongs at 0x130-0x13B

The second is visible by eye: the title `TENNIS`, which lives at `0x134`,
appears inside the Nintendo logo sixteen bytes early.

**Re-dumped clean.** Second attempt: CRC32 `5009215F` against `BB0A08E1`,
logo exact, header checksum `15` correct, `image sum 3FAB want 3FAB`, and the
screen said `image checksum ok`. So the fault is **intermittent**, which is
what Tetris and Othello also did.

### The correlation is mapper type, not size

Three cartridges have ever produced a corrupt dump: `TETRIS.gb`, `OTHELLO.gb`
and `TENNIS.gb`. All three are cartridge type `00`, ROM only. They are also
the *only* three type `00` cartridges tested. Fifteen banked cartridges -
types `01`, `03`, `19` and `1B`, from 64 KB to 1 MB - have never produced a
bad dump.

    type 00  ROM only    3 cartridges, all 3 have failed at least once
    type 01  MBC1        4 cartridges, 0 failures
    type 03  MBC1+RAM    5 cartridges, 0 failures
    type 19/1B MBC5      3 cartridges, 0 failures

Size and type are confounded here, since every ROM-only cartridge is 32 KB.
But they are different *code paths*: `cart_dump_gb` skips the bank register
write entirely for `T_ROM_ONLY`, so bank 1 is entered with no bus transaction
between the last read of bank 0 and the first read of bank 1, where a banked
cartridge gets two ~800 ns writes of settling time.

**The obvious explanation does not fit the evidence, and that is worth
saying.** If the bank 0 to bank 1 transition were the mechanism, the
corruption would appear at `0x4000`. In `TENNIS.gb` it was at `0x108`-`0x12B`,
early in bank 0, nowhere near it. So the correlation is real and the first
hypothesis it suggests is already refuted. Do not start there.

The sample is also small: three ROM-only cartridges, roughly ten ROM-only
dumps, three failures - against zero in about twenty banked dumps. Suggestive,
not conclusive.

**The corrupt image was not preserved.** It was overwritten by the re-dump
before a copy was taken, which was an avoidable loss: four other images had
been preserved that morning and the one known-bad file was not among them. The
byte map above is what survives of it. Keep known-bad dumps.

## Reproducibility, closed for the GBA path, 2026-08-27

Every image except Tetris had been a single attempt, which is the gap an
external hash match does not close: it proves that image is right, not that
the next one will be. Four cartridges re-dumped on `be33725` and compared
byte for byte against copies preserved beforehand:

| | | |
|---|---|---|
| `GOLDEN_SUN_A.gba` | 8 MB | identical |
| `GBAZELDA_MC.gba` | 16 MB | identical |
| `ZELDA_DIN__AZ7E.gbc` | 1 MB | identical |
| `ZELDA_NAYRUAZ8E.gbc` | 1 MB | identical |

Both GBA images now reproduce exactly, including at 16 MB.

## Twelve GBA and four GBC images, 2026-08-27

> Twelve was the count on the day, and it stayed in these documents until
> 2026-09-02, by which point fifteen GBA images existed. See "Every image
> matches a published record" below.

All verified against what the cartridge carries: Nintendo logo byte for byte
against the constant in `docs/LOGO-BYTES.md`, header checksum, `0x96` at
`0xB2`, and an entry point that is a real ARM branch. The GBC images also
pass their global checksum.

| File | Bytes | CRC32 |
|---|---|---|
| `AGB_KIRBY_DX.gba` | 8,388,608 | `20EF3F64` |
| `DISNEY_PRINC.gba` | 8,388,608 | `4A2B9E0B` |
| `GBAZELDA.gba` | 8,388,608 | `8E91CD13` |
| `GBAZELDA_MC.gba` | 16,777,216 | `ABCEBBB1` |
| `GOLDEN_SUN_A.gba` | 8,388,608 | `E1FB68E8` |
| `HARRY_POTTER.gba` | 8,388,608 | `F755065C` |
| `MIC_MIN_MA.gba` | 4,194,304 | `B4294FA7` |
| `NAMCOMUSEUM.gba` | 4,194,304 | `C58A04C1` |
| `PIGLET_SGAME.gba` | 8,388,608 | `52919538` |
| `SHREK_HATC.gba` | 4,194,304 | `09E7472C` |
| `TETRISWORLDS.gba` | 4,194,304 | `7B729804` |
| `ZEROMISSIONE.gba` | 8,388,608 | `5C61A844` |
| `BUGSBUNNY_CC3.gbc` | 1,048,576 | `7A2801FB` |
| `MARIO_DELUXAHYE.gbc` | 1,048,576 | `62BBAE83` |
| `ZELDA_DIN__AZ7E.gbc` | 1,048,576 | `D7E9F5D7` |
| `ZELDA_NAYRUAZ8E.gbc` | 1,048,576 | `3800A387` |

`.gbc` and `.gba` naming are both confirmed on hardware. `BUGSBUNNY_CC3.gbc`
has 26 of 64 distinct banks and still passes its global checksum, so the
repetition is the ROM's rather than the dumper's.

`MARIO_DELUXAHYE.gbc` shows the filename defect in the wild: the trailing
`AHYE` is the CGB manufacturer code at `0x13F`-`0x142` leaking into a name
built from fifteen bytes of an eleven byte title.

## Twelve for twelve: the dump path reproduces, 2026-08-27

Every dump on the card was copied off and kept before a large re-dumping
session, so re-dumps could be compared byte for byte rather than by hash.
Twelve cartridges were then re-dumped.

**All twelve are byte identical to their previous dumps. Nothing differed.**

    BOMBERMAN_GB  BOMBER_BOY  MARIOLAND2  MARIO_S_PICROSS  MOGURANYA
    OTHELLO  SANGOKUSHI  SUPER_MARIOLAND  TENNIS  TETRIS
    UNO2SMALL_WORLD  ZELDA

That includes all three cartridges with a history of failing - `TETRIS.gb`,
`OTHELLO.gb` and `TENNIS.gb` - and Tennis had produced a corrupt image only
hours earlier.

### This makes dirty contacts the best explanation

The correlation recorded above, that every bad dump came from a cartridge type
`00` ROM-only cartridge, now looks like coincidence rather than cause. If a
defect lived in `cart_dump_gb`'s ROM-only path, twelve dumps including all
three suspect cartridges should have shown something. None did.

Three things fit contact intermittency and fit no code hypothesis:

- **The corruption had no structure that maps to the RTL.** Tennis's fault was
  two runs holding the data from sixteen bytes higher, at `0x108`-`0x12B`:
  early in bank 0, not at a bank boundary, not aligned to the 4096 byte chunk,
  not confined to a byte lane. An address line making poor contact for a few
  microseconds produces exactly that. A logic defect would land somewhere
  structural.
- **Every failure recovered on a re-dump**, with no code change between
  attempts in the Tennis case.
- **The three suspect cartridges are the three smallest**, which are also the
  oldest and the most handled. That explains the correlation without needing
  the mapper type to mean anything.

### What this does and does not establish

It establishes that the dump path is reproducible: given a good connection,
the same cartridge produces the same bytes, across ROM-only, MBC1, MBC1+RAM
and MBC5, from 32 KB to 16 MB.

It does not prove the earlier corruption was contacts. Twelve clean dumps are
consistent with an intermittent hardware fault and also consistent with a rare
logic defect that did not fire. What has changed is which is the better
explanation, not that the question is closed. `docs/HANDOFF.md` item 1 is
downgraded rather than removed, and the way to settle it remains the same:
keep a corrupt image when one appears, so a corrupt and clean pair of the same
cartridge can be diffed.

**The practical consequence is a procedure, not a fix.** A dump that reports
`image sum X want Y` should be re-taken after cleaning the contacts, and the
core already refuses to be quiet about it. That check is what turned this from
a silent bad file into a known bad file.

## Donkey Kong: the largest MBC1 so far, 2026-08-27

`DONKEY_KONG.gb`, 524,288 bytes, CRC32 `EDAB3378`, cartridge type `03`
MBC1+RAM+battery, 32 of 32 distinct banks, all checks pass.

512 KB is the size immediately below the point where MBC1 banking breaks: at
1 MB the mapper forces the low five bits of the bank register to 1 when
written as 0, so banks `0x20`, `0x40` and `0x60` cannot be selected at all. A
1 MB MBC1 cartridge is still the missing test.

## What APF actually wants, established 2026-08-26

Four sessions went into this and only the last measurement was decisive. The
useful part is which conclusions were wrong and why.

**The read window is pipelined, and that was the whole of `result 4`.**
`io_bridge_peripheral.v` holds the address from the SPI phase, waits four
clocks, samples `bridge_rd_data`, and only then pulses `bridge_rd`. So the
address must free-run — a window that waits for `bridge_rd` looks too late.
But the value the host keeps is the one presented during the **previous**
transaction, exactly as `core_bridge_cmd.v` does with the datatable. Both
halves are required. Free-running the output as well as the address made
every read arrive one word early, so APF read the path as
`ets/carttools/...` and answered 4, malformed path, sixty-four times.

**Byte order on reads: byte 0 in the low byte** of the word the core
presents. Measured from a ramp that reached the card, not reasoned.

**This is the opposite of the direction APF writes in.** `0x0190`'s reply
arrived with the first character of the path in the *high* byte. Reads and
writes are not symmetric across this bridge, and arguing from one to the
other produced the wrong answer twice.

**The path is absolute, from the card root**: `/Assets/carttools/common/NAME`,
leading slash included. That was the first form tried and it was never wrong.
APF confirmed it by describing its own output slot.

**`0x0188` flush is not answered, and issuing it is harmful.** Every write
returns success and the flush never completes; `core_bridge_cmd`'s target
state machine then waits in `TARG_ST_WAITRESULT_DSO` forever, so one stalled
flush blocks every target command after it. It is off. Writes commit without
it; what is lost is the confirmation that they did.

### Three conclusions that were wrong, and what they have in common

**"A plain 32-bit number reads back correctly, because that is how the
datatable reports slot sizes."** The datatable is written by APF and read
back by APF; that round trip says nothing about how the host interprets it.
This sat in a comment explaining itself confidently while the struct's fields
were rearranged around it.

**"`0x0188` is missing and that is a defect."** It is in the documentation.
Being in the documentation turned out not to mean it is answered.

**"`bridge_rd` is not a request."** True, and half a fix. The lag it removed
was not an accident, it was the contract.

Every one of these was stated as established and none of them had been
measured. The diagnostics that finally worked were the ones that showed what
the *other side* received rather than what this side intended: `0x0190`'s
reply, and the sent-versus-received views. Those should have been built three
sessions earlier, instead of widening a search from eight combinations to
sixty-four.

## Two defects found by reading, not by testing, 2026-08-27

Neither has a testbench behind it, because both live where this tree has no
testbench. Recorded so they are not rediscovered as mysteries.

**`cart_identify_gb` publishes before it judges.** `ST_JUDGE` writes `title`,
`cart_type`, `rom_size_code`, `ram_size_code` and `checksum_read`
unconditionally, and only then decides between `RESULT_GB`, `RESULT_NOT_GB`,
`RESULT_UNSTABLE` and `RESULT_NO_CART`. So after a read that came back all
zeros, `checksum_read` is `00` and the title is fifteen zero bytes, published
as though they described a cartridge.

The `RESULT_NO_POWER` path is the other half. It returns straight to `ST_DONE`
without touching any of those registers, so they keep the **previous**
cartridge's values.

The main screen hides both: its detail rows are gated on `platform == P_GB`,
and a failed read yields `P_UNKNOWN`, `P_UNSTABLE` or `P_NO_POWER`. The
diagnostics page was not gated at all - `D_SUM` printed `checksum_read` and
`checksum_calc` as hex whatever happened - and that page was the only way to
see the stale values.

**Removing the page closed the exposure without fixing the cause.** The
registers are still published before the verdict; nothing displays them any
more. That is worth being precise about, because the next thing to read them
will inherit the bug: anything added that shows a GB header field must gate on
the result, not assume the identifier only writes when it succeeded.

**The dump result survived a change of cartridge.** Fixed in `3b9437f`.
`dump_state` only ever cleared on reset, so dumping one cartridge, swapping to
another and pressing A left `DUMP COMPLETE` on screen with the previous
cartridge's filename and its checksum verdict under the new cartridge's
title. Rows 13 and 14 are what made it matter: `image checksum ok` about a
cartridge no longer in the slot is the one thing on that screen a person acts
on. It now clears on the same event that starts a scan and on the slot itself
changing.

`core_top` has no testbench, so the clearing is verified by elaboration only.
What is tested is the contract it depends on: rows 13 and 14 blank when
`dump_state` is idle even with `sum_checked` and `crc_checked` still
asserted, mutation checked by removing the state gate from either row.

## Every image is kept, corrected 2026-09-02

**Forty-one images, all retained.** This section previously said
`DONKEY_KONG.gb` had not been retained and that its CRC32 `EDAB3378` was all
that survived of it. That is wrong. The file exists and still reads
`EDAB3378`.

Keeping the images rather than only their hashes is what made the
twelve-for-twelve comparison above possible: a hash says a re-dump differs, the
file says where and in what pattern, which is how both the 1 KB window heads
and the sixteen byte displacement were characterised. It is also what makes
the check below possible at all.

## Every image matches a published record, 2026-09-02

**Forty-one dumps, forty-one matches, no misses.** Checked against the
No-Intro DATs for Game Boy, Game Boy Color and Game Boy Advance, 7,572
entries between them. Every dump is present by CRC32, and the size the DAT
records agrees with the size on disk in all forty-one cases.
`scripts/match_dats.py` is the check.

**External**, unlike every other check here: the DAT was not produced by this
core or this repo. The header checks come from the same bytes the core just
read and catch only a dump that is internally inconsistent. And it is the only
external check a GBA image can have, because a GBA cartridge carries no
checksum over its ROM. Two GBA images had been matched by hand; the other
thirteen rested on their logo and header alone.

**Three GBA images had never been recorded anywhere.** Every count in these
documents said twelve GBA cartridges. The answer is fifteen.

| File | Bytes | CRC32 | No-Intro |
|---|---|---|---|
| `NHL_2002.gba` | 4,194,304 | `D1D9E515` | NHL 2002 (USA) |
| `SIMCITY_2000.gba` | 4,194,304 | `733751B3` | SimCity 2000 (USA) |
| `SUPER_MARIOA.gba` | 4,194,304 | `1E4C6D6A` | Super Mario Advance (USA, Europe) |

`NHL_2002` and `SIMCITY_2000` were dumped 2026-08-27, the same day as the
twelve above, and were left out of the table written that day. `SUPER_MARIOA`
was dumped 2026-09-01.

**Count from the artefacts, not from the narrative.** `scripts/match_dats.py`
prints the count it matched, so a number in this file has a command behind
it.

## Unverified assumptions in code written here

**Audio pins are held low rather than clocked.** `core_top.sv` ties
`audio_mclk`, `audio_dac` and `audio_lrck` to zero, on the assumption that a
core with no audio does not need to present a running I2S clock. Untested. If
the Pocket objects, the fix is to bring `audio_mixer` back feeding silence.

**The cartridge pins are cut with `set_false_path`.** Correct only while the
bus keeps its long wait states. `src/fpga/core/core_constraints.sdc` says what
would make it wrong.

## What has been proven

| Claim | How |
|---|---|
| The stripped tree builds and closes timing | `make cart` |
| The header reader parses and judges a header correctly | `tb_cart_identify`, mutation checked |
| The text layer puts the right pixels on screen | `tb_ui_renderer`, mutation checked |
| The screen says the right thing, including on every failure code | `tb_ui_screen` |
| No module outside the cartridge layer touches cartridge pins | `check_pin_isolation` |
| Every synthesised source is listed in the Quartus project | `check_qsf_sources`, added after a module passed three testbenches and failed synthesis |
| The bus holds its shipped timing, to the cycle | `tb_gba_cart_timing` |
| A GB header is parsed and judged correctly, through the real bus | `tb_cart_identify_gb`, mutation checked |
| A GB ROM read never asserts /CS | `tb_gb_cart_bus`, `tb_cart_identify_gb` |
| A GBA probe never follows a GB probe that found something | `tb_cart_probe`, mutation checked |
| A write outside a writable space never reaches WR# | `tb_gba_cart_write_protect`, 62 cases |
| Reading a GB save never pulses /WR while /CS is low | `tb_gb_save_write_protect`, at the pins, every clock edge of a full 8 KB read, and it proves it can fail in the same run |
| A save read opens the RAM gate and shuts it again | `tb_cart_save_gb`, mutation checked |
| Reading a GBA save never pulses WR# at the connector | `tb_gba_save_write_protect`, over a whole 32 KiB read, and it drives a deliberate write in the same run to prove the monitor is live. Mutation checked: a reader that asserts `bus_wr` on one byte trips four separate checks |
| A GBA save is read a byte at a time, in ascending addresses, from the save window | `tb_cart_save_gba`, against the real bus and cartridge model, counting CS2# phases and RD# pulses. Mutation checked on a stuck address and on a widened access |
| A GBA cartridge's save type is found without writing to it | `tb_gba_save_scan`, every signature at all four byte alignments, one ending on the last byte of the ROM, and two families at once reported as ambiguous. Mutation checked both ways |
| **A save this core dumped is the save the cartridge held** | **Hardware. A 32 KB four-bank GBC save loaded in mGBA beside its own ROM dump, game state intact. The only test that can prove a save read, because save RAM carries no checksum** |
| A save's length is the length its cartridge declares | `scripts/verify_dump.py`, cross-checking `0x0149` in the ROM beside it. Necessary, not sufficient - it passed on the first save ever taken and would pass on a subtly wrong one |
| A banked save is not bank 0 repeated | `scripts/verify_dump.py` compares the banks to each other; nothing on the device can see this |
| Every RAM bank is read, and MBC1's mode 1 is what makes its bank bits work | `tb_cart_save_gb`, content derived from the bank, mutation checked both ways |
| MBC3's clock registers are never selected over the RAM window | `tb_cart_save_gb` counts writes of `0x08`-`0x0C` to the bank register |
| A save that could not be read is not filed as a blank one | `tb_cart_save_gb`, a model that ignores the enable |
| A save dump is CRC32'd, and over the save | `tb_dump_engine`. The value is compared against a CRC32 computed in the testbench over the modelled content, at 8 KB and at 2 KB so a fixed count cannot pass. Mutation checked twice: stop feeding the accumulator on a save and both values read `00000000`; clear `crc_checked` for a save and the row claim fails. It is an identity, not a verdict, and `sum_checked` stays false |
| Reset and slot power loss leave the bus in a safe state | `tb_gba_cart_async`. A reset inside WR# low is sequenced: WR# rises, the data is held, and the cartridge captures the byte that was asked for. A `cart_mode` drop is not sequenced and must not be, because it means the slot is losing power |
| A mode change cannot cut a live write beat | `tb_cart_mode_hold`, mutation checked on the hold and on which value it freezes. `core_top` is not simulated, which is why the logic is its own module |
| A GB/GBC ROM is dumped correctly, end to end | Hardware, twenty-six cartridges from 32 KB to 4 MB across ROM-only, MBC1, MBC1+RAM+battery, MBC5 and MBC5+RUMBLE. Every retained image passes its own logo, header sum, global sum and size byte, and **all twenty-six match No-Intro by CRC32 and size**. Three cartridges have produced a corrupt image at some point and every one was clean on a re-dump |
| The same cartridge dumps identically on repeat | Hardware, **twelve cartridges re-dumped and every one byte for byte identical**, across ROM-only, MBC1, MBC1+RAM and MBC5, 32 KB to 512 KB, plus two GBA images at 8 and 16 MB |
| The core checks the image against the cartridge's own checksum, on the device | Hardware, `dump_checksum.sv`, row 13. **It has caught a real bad dump**: `TENNIS.gb`, reported as `image sum BB29 want E047`, both numbers confirmed independently on a PC |
| The same cartridge dumps identically on repeat, on GBA | Hardware, Golden Sun at 8 MB and Minish Cap at 16 MB, each byte for byte against a copy preserved beforehand |
| The core names files by system | Hardware, `.gb`, `.gbc` and `.gba` all seen on the card |
| The core can name a file it creates | Hardware, `0x0192` accepted; forty-one files named from cartridge titles, with `.gb`, `.gbc` and `.gba` all seen. It does not check whether the name is already taken — see the filename wart |
| A GBA ROM's size is measured correctly from open bus | Hardware, **fifteen cartridges at 4, 8 and 16 MB**, each sized by observation rather than by reaching the ceiling, and every one of the fifteen sizes agrees with the size No-Intro records for that CRC32 |
| A GBA ROM is dumped correctly, end to end | Hardware, **fifteen images, every one matched to No-Intro by CRC32 and size.** This is the only external check a GBA dump can have, because no checksum in the cartridge covers the ROM. Minish Cap's record discriminates region on CRC32 and header checksum independently and this dump agrees with both |
| The GBA Nintendo logo is read correctly | Hardware, all 156 bytes of `0x04`-`0x9F` identical across two different cartridges. Covered by no checksum, so nothing else here verifies it |
| A mask ROM larger than its game is sized correctly | Hardware, Minish Cap's last two megabytes are pure `FF` padding and the probe read past both to the real 16 MB boundary |
| The core's CRC32 agrees with `zlib` | Hardware, the screen and the file on the card both say `E1FB68E8` |
| A real GB/GBC cartridge is identified correctly | Hardware, three cartridges: Link's Awakening DX, Oracle of Seasons, Tetris Plus. MBC5 and MBC1, all three CGB flag values, both header layouts |
| A real GBA cartridge is identified correctly | Hardware, fifteen cartridges, header and checksum, fixed byte `0x96` in place on every one |
| The GB to GBA escalation works at the connector | Hardware, the Minish Cap read is reached through it |
| The Pocket powers the slot and reports it | Hardware, `play 1 power 1` on the diagnostics page, before that page was removed |
| Every bank of a GB ROM is read once, in order, through the right mapper register | `tb_cart_dump_gb`, four mappers, content derived from the linear address |
| A file is opened, written in chunks and flushed, and every failure is caught | `tb_apf_file_writer`, including a mid-dump failure and a flush-only failure |
| A whole ROM survives both clock crossings and comes out byte for byte correct | `tb_dump_engine`, 32 KB end to end against a modelled host |
| The filename APF is given is the right 264 bytes | `tb_dump_path_gen`, including padding, case, punctuation and an unreadable title |
| Both byte orders produce the file they claim to | `tb_dump_buffer`, `tb_dump_engine` |
| A dump holds the connector in GB mode and releases it after | `tb_dump_engine` |

That is the whole list, and it is meant to stay short and honest.

The strip is worth quoting in numbers, because "materially lower utilization"
was a Phase 1 exit criterion:

```
                        after the strip    identify, GB, and the screen
Logic utilization (ALMs)   471  ( 3 % )       1534  ( 8 % )
Total registers            969                2239
Total RAM Blocks             2  ( < 1 % )       94  ( 31 % )
Total PLLs                   1  ( 25 % )         1  ( 25 % )
Setup slack               6.461 ns            1.305 ns
```

The donor filled most of this device and closed setup by a fraction of a
nanosecond. There is room to be careful rather than clever.

The RAM blocks are the framebuffer, which the strip had reduced away because
nothing wrote to it, plus one block each for the character buffer and the font.

The setup slack moved twice on the way to 1.579 ns and both moves are recorded
in the commit that made them: a divide by 30 in the screen painter failed the
build outright at -2.321 ns, and fixing that exposed a 29-term adder chain in
the header checksum. Neither was visible in simulation. Build every phase.
