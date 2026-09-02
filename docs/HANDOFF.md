# Handoff

Traps and next steps. Read `docs/STATUS.md` for the current position and
`plan.md` for the direction.

## Both GBA save sizes are verified, 2026-09-01

`ZEROMISSIONE`, 8 MB, **32 KiB SRAM**, loaded in mGBA with its file intact.
Kroy: "Confirmed working". That was the last untested path in the accepted
set, and it arrived on a cartridge nobody expected to have.

    0x1c    ZeroMissionUSAver005
    0x80    ZERO_MISSION_010
    0xcf    Planet Zebes...
    0x2d0    - Samus Aran -
    175 distinct byte values, four banks all different, crc32 6C90074B

| Path | State |
|---|---|
| Save type scan | **verified**, EEPROM and 128 KiB Flash refused on three cartridges, SRAM and Flash accepted |
| Flash 64 KiB | **verified**, Golden Sun |
| SRAM 32 KiB | **verified**, Zero Mission |
| 128 KiB Flash, EEPROM | refused, both need a write |

`NHL 2002`, `ANLE`, 4 MB, also came back refused, so it is EEPROM or 128 KiB
Flash. That is three cartridges the refusal path has been right about.

**`scripts/verify_dump.py` has the same defect the core just had.** It
cross-checks a `.sav` against the byte at `0x0149` of the ROM beside it, which
is a Game Boy header field, so it reported `FAIL size matches the cartridge
header, 0x0149 = 00 wants 0 bytes` on Zero Mission's perfectly good save. It
will do that on every GBA save. Not fixed.

## GBA save backup is verified on hardware, 2026-09-01

**Golden Sun. The first GBA save this core has ever taken, and it loads.**
Stamp `52B6`. `GOLDEN_SUN_A.sav`, 65536 bytes, crc32 `32F42D38`, loaded in
mGBA beside its own ROM dump. Kroy's verdict: "save confirmed load".

The file carries its own corroboration, which is unusual for a save:

    43 41 4d 45 4c 4f 54 ...     ASCII "CAMELOT" at offset 0
    CAMELOT again at 0x1000, 0x2000, 0x3000, 0x4000, 0x5000
    "Adam" at 0x5010
    84.7% zeros, 0.5% FF, 222 distinct byte values

Camelot Software Planning wrote Golden Sun, and that header repeats once per
4 KB save slot. But the emulator is what proves it, as always: a save carries
no checksum, so nothing short of the game loading its own state counts.

**The assumption held.** A GBA Flash chip answers plain reads with no command
first. That was the load bearing guess behind accepting Flash at all, it is
now measured rather than assumed, and it means **a 64 KiB Flash save needs no
write to the cartridge.** `bus_wr` stayed tied low throughout.

**What is verified, precisely:**

| | |
|---|---|
| Save type scan on hardware | **yes**, EEPROM refused on two cartridges, Flash accepted on one |
| Flash 64 KiB backup | **yes**, Golden Sun, loaded in an emulator |
| SRAM 32 KiB backup | **no**. Same code path, never run: no SRAM cartridge to hand |
| 128 KiB Flash, EEPROM | refused, both need a write |

## Two defects the Golden Sun run exposed

**1. The evidence rows lie about a GBA save, and they lie in the dangerous
direction.** The screen said `SAVE RAM DID NOT ANSWER` and `first 00000000`
over a read that had just worked. `save_responded`, `save_blank_ff`,
`save_blank_00` and `save_first` are wired in `dump_engine` from
`cart_save_gb`, which never runs for a GBA save, so the screen was showing a
stale Game Boy verdict about a Game Boy Advance read. `cart_save_gba` was
built without any of the evidence outputs its GB counterpart has, and nothing
caught it because nothing had ever run it. **A save path that reports failure
on success is worse than one that reports nothing**, because the next person
re-dumps a good save chasing a fault that is not there.

**2. Y disappears for a second after a ROM dump.** A finished dump releases
`dump_want_mode`, the connector mode drops, and that is indistinguishable from
a cartridge being removed, so `scan_start` fires, `save_scan_valid` clears and
the whole ROM is scanned again to rediscover a save type that cannot have
changed. It comes back on its own, so nothing is stuck, but it is a needless
8 MB read and a confusing gap. The result should survive a dump of the same
cartridge and clear only on a real removal or on A.

## Flash 64 KiB, which needs no writes at all, 2026-09-01

Golden Sun, 8 MB, came back `save RAM here is not supported`. It is a Flash
cartridge, and refusing it was leaving an easy case on the floor.

**A GBA Flash chip powers up in read array mode and sits in the same
`0x0E000000` window as SRAM.** Commands are needed for chip ID, erase, program
and bank select. A backup does none of those, so **reading a 64 KiB Flash is
the same plain byte read `cart_save_gba` already does.** The change is the
accept condition in `core_top` and a size, not a new module and not a write
path. `tb_gba_save_write_protect` still holds at the pins.

    SRAM_V, SRAM_F_V      32 KiB   accepted
    FLASH_V, FLASH512_V   64 KiB   accepted, new
    FLASH1M_V                      refused: its first bank would read, but the
                                   second needs 0xB0 and a bank number written
                                   to 0x0E000000, and half a save is worse
                                   than none
    EEPROM_V                       refused: the address is clocked in, so
                                   reading starts with writing, and the string
                                   does not say 512 B or 8 KiB

`tb_cart_save_gba` gains a 64 KiB read, which is the largest this module can
be asked for and the one that runs the save window's 16 bit address to its
last value. An offset that wrapped would re-read the head of the chip and the
content check catches it.

**The assumption worth naming:** that Flash answers reads with no command
first. It is standard behaviour and it is why this works, but it is not
verified against a cartridge. Golden Sun settles it in one test, and this is
the change that lets that test happen.

## The GBA save scan works on hardware, 2026-09-01

**Verified.** Stamp `141B`, seed 5. Two GBA cartridges, nothing pressed, both
showing `save RAM here is not supported` on their own:

    GBAZELDA MC    16 MB    EEPROM    refused, correctly
    SUPER MARIOA    4 MB    EEPROM    refused, correctly

That row can only come from `gba_save_refused`, which needs `save_scan_valid`,
which needs `complete`. So the scan started after the size probe, waited for
the connector to turn round, read **every byte of a 16 MB cartridge**, found
the `EEPROM_V` signature and reported it. The whole path is exercised except
the part that reads a save.

**What this does not prove.** `cart_save_gba` has never run. No cartridge here
is SRAM, so the reader itself is still simulation only, and so is every
refusal other than EEPROM. Ambiguity has never been seen on a cartridge.

**What to try next:** a GBA cartridge that is actually SRAM, which is the
minority of the platform. Until one turns up, the reader stays unverified no
matter how many EEPROM cartridges are correctly refused.

## The same defect, twice, and what it should have been copied from

**Second hardware run.** The freeze was gone: Minish Cap at 16 MB, Super Mario
Advance at 4 MB and ZELDA all dumped clean on stamp `3AC8`. But both GBA
cartridges showed `A scan  X dump` with no save row at all, and a five second
wait with no button pressed changed nothing. Both are EEPROM cartridges, so a
refusal row was owed and never came.

**The scan was hanging, and for the reason the first fix should have found.**
`cart_probe` parks the mode. `gba_size_probe` drops `want_gba` in the same
cycle it raises `done`. `cart_pins` takes sixteen cycles to turn the connector
round. So `cart_mode` is low exactly when the scan starts, and
`gba_cart_bus` ignores requests while it is low and never raises `done`.

`gba_size_probe` already had all three defences, with comments saying why, and
`gba_save_scan` had none of them:

| | `gba_size_probe` | `gba_save_scan`, as shipped |
|---|---|---|
| `cart_mode` input | yes | absent |
| `ST_MODE` wait, with a timeout | yes | absent |
| Abandon guard if the mode drops | yes | absent |

That module's own comment records the abandon guard hanging it once and being
caught by case 11 of `tb_gba_size_probe`. **The lesson is narrow and worth
keeping: this module was written from `cart_dump_gba`'s shape, and the parts
that matter were in `gba_size_probe`'s scars.** A new bus master gets read
against the most bruised master on the same bus, not the tidiest.

**The fix.** `cart_mode` input, `ST_MODE` with the same 4096 cycle timeout, and
the abandon guard in the same shape. A new `complete` output, because without
it an abandoned scan and a ROM carrying no save string are the same answer and
only one of them means the cartridge has no save; `core_top` sets
`save_scan_valid` only when `complete` is set. And `save_scan_start` now holds
the mode as well, closing a one cycle gap where the request fell back to
parked idle between the size probe finishing and the scan asking.

**Four new cases in `tb_gba_save_scan`:** the mode arriving late, never
arriving, dropping mid-scan, and the next cartridge scanning normally
afterwards. Mutation checked: removing the `ST_MODE` wait or the abandon guard
makes the testbench **hang**, which is the hardware symptom reproduced in
simulation rather than described in a comment.

**Known and deliberately left:** pressing X while a scan is running abandons it
and nothing restarts it, so that cartridge shows no save row until A is
pressed. Worth fixing separately rather than bundled into a third emergency
build.

## The GBA save scan froze the core, 2026-09-01

**Shipped to the card, ran on hardware, broke it.** Kroy: "All the dumping
options disappeared and it froze up trying to dump both minish cap and super
mario advance", both cartridges that had dumped fine before. Two defects, one
cause each, and the fix is in `a624443`'s successor.

**1. The scan never asked for the connector.** `cart_probe` parks the mode at
idle when it finishes identifying. `gba_size_probe` already knows this and
raises `want_gba` for its whole run; its comment says so in as many words.
`gba_save_scan` had no such output, so it started after the mode was parked,
`gba_cart_bus` held its FSM in `ST_IDLE` because `cart_mode` was low - line
118, `if (reset || !cart_mode)` - and never raised `done`. The scan waited
forever with `busy` high.

**2. That stuck flag was wired into `cart_engine_busy`**, which `dump_ready`
gates on, so every dump option vanished and never came back. Only a core
reload recovered it.

Either alone would have been survivable. The first is a hang in a module
nobody has to press a button to reach; the second turned it into a dead core.

**The fixes.**

- `gba_save_scan` has a `want_gba` output, held for exactly as long as `busy`,
  and `core_top`'s mode mux honours it beside `sz_want_gba`.
- The scan is **out of `cart_engine_busy`**. It runs for seconds on a large
  cartridge and a ROM dump must stay available throughout, which was a
  regression in its own right even without the hang.
- The scanner is reset by `dump_busy` and by `scan_start`. Both take the bus
  through the mux, so it is abandoned rather than left waiting. Its result
  never becomes valid, so Y is absent rather than offering a read from a scan
  that never finished.

**What the tests did and did not do.** All 29 passed before the fix and all 29
pass after, which is the whole lesson: the invariant was never stated, so
nothing could check it. `tb_gba_save_scan` now asserts `want_gba == busy`
every cycle, and it is mutation checked both ways - removing the request
entirely, which is the bug as shipped, and dropping the hold one state early.
Both fail the run.

**The half that is still not covered.** Nothing here tests that `core_top`
honours `want_gba`. There is no core_top level testbench in this tree and this
change did not add one, so the integration half of both defects rests on
reading the mode mux rather than on a test.

## GBA save backup, started 2026-09-01

**In simulation only. Nothing here has seen a cartridge and nothing on the
device can reach it yet.**

Two new modules, both read-only, both in `ap_core.qsf`, neither instantiated
in `core_top`:

| Module | What it does |
|---|---|
| `src/fpga/services/identify/gba_save_scan.sv` | reads the ROM and reports which of the six SDK save library strings it saw, plus `ambiguous` when two families are present |
| `src/fpga/services/dump/cart_save_gba.sv` | reads SRAM out of the save window a byte at a time and emits the same byte stream `cart_dump_gba` does |

`make test` is 29 of 29, up from 26.

**Why SRAM only.** Of the five GBA save technologies, SRAM is the only one
that can be read without writing to the cartridge. Flash is identified by a
command sequence, 128 KiB Flash needs a bank select, and EEPROM is addressed
by clocking the address in. All three are writes, and **writes to a GBA
cartridge are blocked** by the open defect in `gba_cart_bus`: aborting inside
`ST_WRITE` raises WR# and releases the data pins on the same instant, so the
cartridge latches whatever the bus settles to. It is asserted in its real form
in `tb_gba_cart_async` under a KNOWN DEFECT heading. That defect is the gate
on v0.8 and v0.9, not a shortage of code.

**Why the type comes from a string and not a probe.** Same reason. The scan
reads the ROM, which costs time and nothing else. It reports what it saw
rather than resolving a winner, because a cartridge carrying two families of
string is a real thing and `plan.md` Phase 12 says ambiguous cases are
reported as ambiguous.

**One defect was found and fixed while writing the tests.** `gba_save_scan`
first compared the registered ten-byte window, which evaluates one byte
behind, so a signature ending on the final byte of the ROM was never tested:
the scan finishes on the same cycle that byte is fed. The window now includes
the byte being fed. `tb_gba_save_scan` covers it, and reverting the fix fails
exactly those two cases and no others.

**Every new test was mutation checked**, and each was watched to fail:

- stuck address, and a widened access, against `tb_cart_save_gba`
- a reader asserting `bus_wr` on one byte, against `tb_gba_save_write_protect`,
  which tripped four separate checks
- the registered-window defect, and a reversed byte order, against
  `tb_gba_save_scan`

`tb_gba_save_write_protect` also carries the built-in mutation `cart_save_gb`'s
does: phase 2 takes the bus off the reader and drives a deliberate write into
the save window, so a monitor that has quietly stopped working takes the run
down with it.

**Wired up, and it fits.** `dump_engine` has a fourth reader and the GBA bus
has a two master mux, the same shape the GB bus already had. `core_top` has
the scanner as a fourth bus master, ordered dump, scan, size probe, identify,
with `save_scan_busy` and `save_scan_start` both in `cart_engine_busy` so a
dump started underneath a scan cannot strand it waiting for a `done` the mux
took away. `save_scan_valid` clears on `scan_start`, so a scan result cannot
outlive the cartridge it describes.

**Nothing new reaches `ui_screen`.** A refused GBA save drives the
`ROW_NO_SAVE` row a refused GB save already drives.

**`scan_start` was already taken**, by `cart_probe`, which is the A button.
The save scan's signals are `save_scan_*` and the scanner's own results are
`svs_*`.

**A/B on `quartus-build`, sisko, identical conditions, scratch wiped between
runs.**

| | `9530316` baseline | `a94d78e` this branch | delta |
|---|---|---|---|
| Setup slack | 0.856 ns | 0.496 ns | **-0.360 ns** |
| Hold slack | 0.123 ns | 0.122 ns | -0.001 ns |
| ALMs | 3,391, 18% | 3,549, 19% | +158 |
| Registers | 4,466 | 4,761 | +295 |
| RAM blocks | 99 | 99 | 0 |
| Elapsed | 280 s | 299 s | |

Timing is met on every corner. **The worst setup path is the PLL output
counter in both builds, not `ui_screen` and not any of this**, so what changed
is congestion rather than a new critical path.

**The -0.360 ns was noise, and the sweep is what proved it.** Five seeds per
commit, ten builds, scratch wiped between every one, all rc=0 and all met
timing:

    setup slack, ns

    9530316   0.381  0.736  0.789  0.873  0.996    mean 0.755  spread 0.615
    a94d78e   0.667  0.702  0.883  0.888  0.979    mean 0.824  spread 0.312

The branch's mean setup slack is **0.069 ns higher**, not lower, and its worst
seed beats the baseline's worst seed. The baseline's own spread across seeds,
0.615 ns, is wider than the regression a single pair appeared to show. The
worst build in the sweep is the baseline on seed 3.

Hold is the same: baseline 0.028 to 0.124, branch 0.045 to 0.117, both dipping
on seed 5, so that dip belongs to the seed rather than to this change.

**Area is the real cost, and it is measurable precisely because ALMs barely
move with seed:** baseline 3383 to 3394, branch 3547 to 3554. **+164 ALMs,
about 4.8%**, 18% to 19% utilisation, +295 registers, no change in RAM.

Two things fell out of it. The default seed is a poor one for this design:
`a94d78e` first fitted at 0.496 ns, near the bottom of its own range. And
**`scripts/seed_sweep.sh` is stale** - it shells out to `docker` and writes a
`build_output/` layout this repo no longer has. The sweep ran on
`make cart SEED=n` instead, which is the maintained path.

**What is left:**
1. A cartridge to test on. Nothing in the set here is known to be GBA SRAM,
   and the type cannot be known until the scan runs on hardware.
2. EEPROM's string does not say whether it is 512 B or 8 KiB, so even were
   EEPROM readable the size would still be undetermined.
3. The write defect, if Flash or EEPROM is ever wanted.
4. `scripts/seed_sweep.sh` needs rewriting onto the current harness or
   removing. It cannot run as it stands.

## Where this was left, 2026-08-31

**Six new GB/GBC cartridges are on the card, structurally clean.** Written by
the core to `/Assets/carttools/common/`, five of them with a save beside the
ROM. Every ROM passes its Nintendo logo byte for byte, its header checksum,
its global checksum and the size its header declares. Every save is the
length `0x0149` declares, is not blank, and where it has four banks the four
banks differ. `scripts/verify_dump.py` on all thirteen files: `all checks
passed`.

| File | Bytes | Type | RAM | CGB | CRC32 | Save CRC32 |
|---|---|---|---|---|---|---|
| `DQM2_R_____BQLJ.gbc` | 4,194,304 | `1B` MBC5+RAM+bat | `03` 32 KB, 4 banks | `80` | `2C428A87` | `08BE7E23` |
| `YUGIOUDM4J_BY6J.gbc` | 4,194,304 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `C0` | `298BD054` | `6646D2D7` |
| `HAMUPARA2__BHMJ.gbc` | 2,097,152 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `C0` | `542C78B6` | `D29428FB` |
| `JINSEI_TOMOACJJ.gbc` | 1,048,576 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `80` | `C8D46E99` | `A6F62B50` |
| `PNBALFRENZYVM2E.gbc` | 1,048,576 | `1E` MBC5+RUMBLE+RAM+bat | `02` 8 KB, 1 bank | `C0` | `364F9CCD` | `D6A21D0D` |
| `TYCORAT1___BTIE.gbc` | 1,048,576 | `19` MBC5 | `00` none | `C0` | `D6881014` | none |

**What these cartridges actually are.** The stem is the header's 11-character
title field, not a name: a cartridge whose retail title is longer spends those
characters on whichever part of it fits, so the stem cannot be expanded back
into a title by reading it. No No-Intro DAT is configured, so nothing here
resolves a stem automatically. Filled in as each one is confirmed; blank means
nobody has said, and guessing from the stem is what this table exists to stop.

| Stem | Game code | Cartridge |
|---|---|---|
| `PNBALFRENZY` | `VM2E` | Disney's The Little Mermaid II: Pinball Frenzy |
| `DQM2_R` | `BQLJ` | |
| `YUGIOUDM4J` | `BY6J` | |
| `HAMUPARA2` | `BHMJ` | |
| `JINSEI_TOMOA` | `CJJ` | |
| `TYCORAT1` | `BTIE` | |

**What this closes.** `docs/STATUS.md`'s hardware coverage table stopped at
1 MB for MBC5 and at one save size.

| Gap | Closed by |
|---|---|
| MBC5 ROM above 1 MB | 2 MB, and 4 MB twice. 4 MB is 256 banks, so the ninth bank bit at `0x3000` is exercised on hardware for the first time |
| Cartridge type `1E`, MBC5+RUMBLE+RAM+battery | `PNBALFRENZYVM2E` |
| Cartridge type `19`, MBC5 with no RAM, at 1 MB | `TYCORAT1___BTIE`, and `Y` is correctly absent on it |
| RAM size code `02`, 8 KB, single bank | four cartridges. Only `03` had been read on hardware |
| A second cartridge through the four-bank save path | `DQM2_R_____BQLJ` |

**What is still open after them.** MBC2, MBC3 and MBC3 RTC. MBC1 above
512 KB, which is the case `cart_dump_gb.sv` expects to differ. RAM size codes
`01` (2 KB), `04` (128 KB) and `05` (64 KB). GBA saves, which are not started.
None of these six is a cartridge that could have covered any of them.

**Loaded in mGBA, 2026-08-31.** A save carries no checksum, so this is the
only check that can prove one. `tools/podman/play-dump.sh`, one cartridge at a
time, `ZELDA` first as a control and it came up intact. Screenshots were
kept locally in `screenshot_proofs/` and are gitignored.

| Cartridge | ROM | Save | Evidence |
|---|---|---|---|
| `DQM2_R_____BQLJ` | pass | **pass** | file select gives master name, `031:17` played, three monsters at Lv99/54/50, location. In world afterwards with gold and party HP/MP, which is what proves 4 MB high banks rather than a menu |
| `YUGIOUDM4J_BY6J` | pass | **pass** | records screen reads Duelist Level 255, Deck Capacity 2728. `2728` is `a8 0a` little endian at `0x4b7` and `0x11af` in the dumped file, stored twice and both copies identical |
| `JINSEI_TOMOACJJ` | pass | **pass** | character file holds five player entered names, slot 1/10, portrait rendered |
| `HAMUPARA2__BHMJ` | pass | **fail** | game refuses to let the cursor reach Continue. See below |
| `PNBALFRENZYVM2E` | pass | **pass** | the save reads correctly. Its battery was flat, measured 0 V and replaced, but the content differed between rips because the game was played between them, not because of the battery. See below |
| `TYCORAT1___BTIE` | pass | none | boots and plays. Type `19`, no save RAM, so `play-dump.sh` correctly reports no save rather than failing |

**Two cartridges are flagged as suspected battery failures, to be re-ripped
before anything is concluded from them.** Neither is evidence against the save
path: three saves of two sizes read correctly in the same session on the same
build.

`HAMUPARA2__BHMJ.sav` is noise. All 256 byte values present, no run of zeros
longer than 4, `0xFF` on 26.8% of bytes and alternating with data:

    80 ef 06 ff a6 ff e1 ff 8e ff 53 ff 25 ff 35 bf

The game's own checksum rejects it, which is the correct behaviour and not a
symptom of this core.

`PNBALFRENZYVM2E` had **two separate things going on, and treating them as one
answer is what took four rounds to unpick.**

**The battery was dead.** Measured at 0 V and since replaced. That is settled
by a multimeter, not by inference from bytes.

**The save read was correct throughout, and is not a core fault.** The ROM read
three times byte identical. Across four save rips the header
`44 41 56 45 dd ca ba aa` and the high score initials `BRO` were constant
while the six score digit bytes differed every time.

**Those digits changed because the game was being played between rips.** Every
digit in every rip was in the range 0 to 9 because they were scores. The table
read empty early on because it had not been played yet. And the contents
survived from one rip to the next despite the flat battery **because the
cartridge stayed powered in the slot** - it held the save until it was
unplugged, which is exactly what a dead cell with continuous power looks like.

**The mistakes, both worth keeping.** The first call, that the battery was
fine, came from a single rip whose byte 0 read `FAVE`; every rip since reads
`DAVE`, so one bit error carried a hardware recommendation and nobody said out
loud that it rested on one sample. Then, told the scores varied, the swing was
all the way to "nothing was wrong with the cartridge", which was equally
wrong.

**Two rules out of it.** Before theorising about data that changes between
reads, ask what the human did between the reads: a cartridge that has been
played is not a cartridge at rest and no byte pattern will tell you that. And
a dead battery and a correct read are not competing explanations, they are
both true here; a single answer that tidily covers every symptom is a reason
for suspicion, not confidence.

`HAMUPARA2__BHMJ` is a different case and still looks genuinely dead: all 256
byte values present, `0xFF` alternating with data, longest zero run of 4, and
the game's own checksum refuses it. That claim now stands on one cartridge
with a poor track record behind it, and it has still not been dumped twice.

**One item belongs to `pocket-tools`, not here**, and is carried as open
item 5 in `pocket-dev/docs/HANDOFF.md`. `DQM2-R` is the first
cartridge on a real card whose title holds a character outside `A-Z0-9`.
`dump_path_gen.sv`'s `sanitize` turns it into `_` and the card says
`DQM2_R_____BQLJ.gbc`. `cheatgui/dumps.py`'s `core_stem` keeps `-`, so it
derives `DQM2-R_____BQLJ` and its `Dump.renamed` reports the file as renamed
by hand. The divergence is already written down in `docs/FILE-FORMATS.md`,
the row reading "basename may contain spaces, `-`, mixed case | uppercased;
everything outside `A-Z0-9` becomes `_` | differs". The core follows the core;
the app follows the spec. `core_stem` also does not uppercase, which no
cartridge on the card exercises yet. Route to the picker's session: the six
files here are the fixtures its `tests/test_dumps.py` was meant to be pinned
against, and `cart-dumps/`, `roms/` and `saves/` in that repo are still empty.

## Where this was left, 2026-08-26

Committed and clean on branch `hardware-bringup`, not merged to `main`.
`make test` is 20 of 20. The card carries `ec566cd`, stamp `EC56` on the
title row.

**GBA dumping is verified on hardware, and reproduces.** `gba_size_probe.sv`,
`cart_dump_gba.sv` and `dump_crc32.sv`, wired through `dump_engine` and
`core_top`. Twelve images at 4, 8 and 16 MB, every one passing the Nintendo
logo byte for byte, the header checksum, the `0x96` fixed byte and an entry
point that is a real ARM branch. Two are matched against published records.
Golden Sun and Minish Cap have each been dumped twice and are byte identical,
so the single-attempt caveat no longer applies to the GBA path.

`dump_crc32` agrees with `zlib` on hardware, and `dump_checksum` has now
caught a real bad dump rather than only agreeing with good ones - see
`docs/STATUS.md`.

The card holds `be33725`, stamp `BE33`, with `.gb`, `.gbc` and `.gba` naming
confirmed in the wild. The repository is at
<https://github.com/kroy-the-rabbit/openfpga-carttools>, first release tagged
`v0.1.0-alpha.1`.

**GB/GBC dumping works and is verified.** Eighteen cartridges dumped by the
core, from 32 KB to 1 MB across ROM-only, MBC1 and MBC5, plus four Game Boy
Color images. Every one passes its own logo, header checksum, global checksum
and size byte, except `TENNIS.gb` - see below. One is matched to a No-Intro
record by CRC32. `docs/STATUS.md` has the tables. The images are not in the
repo; they are on the card under `/Assets/carttools/common/`, except Link's
Awakening DX, which is off the card because a second Zelda cartridge
overwrote it and survives only in a copy.

**The on-device checksum has caught a real bad dump.** `TENNIS.gb` came back
corrupt and the screen said `image sum BB29 want E047`; both numbers were
confirmed independently on a PC. The header checksum on the row above it
passed, which is the same blind spot that let MarioLand2 through. This is the
first time that check has found something rather than agreeing with a good
cartridge. The re-dump is clean (`5009215F`), so the fault is intermittent;
what it correlates with is item 1 below.

**`TETRIS.gb` and `OTHELLO.gb` are resolved, and the earlier conclusion was
wrong.** This file previously recorded them as cartridges that probably ship
an incorrect global checksum. They do not: re-dumped on `ec566cd` both verify
completely, with different CRC32s (`46DF91AD` and `C17A002E`). The old files
were corrupt, in a way that is structured rather than random — the head of
each 1 KB window holding the head of a different window, with the same
relocation map in both cartridges. The mechanism is not identified; it has
not reproduced on `ec566cd`, and Tetris has since dumped identically four
times, but nothing in the difference between the two bitstreams plausibly
touches the chunk path. `docs/STATUS.md` has the evidence.

That caution has since been answered. Twelve cartridges were re-dumped in one
session, including all three that have ever failed, and every one came back
byte for byte identical. The dump path reproduces; what does not is the
connection to the cartridge. See item 1.

`MARIOLAND2.gb` was a bad contact and its re-dump verifies clean; the two
attempts differ in 105,121 bytes and every difference is bit 7 alone, which
is one data line reading randomly.

The diagnostic artifacts (`PROBE.gb`, `CARTDUMP.gb`, `SELFTEST.bin`) have
been removed from the card. `CARTDUMP.gb` was for the fallback that writes
into the slot's own file when `0x0192` is refused; that path still exists and
is tested, but `0x0192` works now and it has never been used on hardware.

## Position

Subtracted from Rai's cartridge-support branch of the Pocket GBA core, the
v0.4.0 lineage rather than mincer-ray's `master` (`docs/PROVENANCE.md`; the
abandoned first attempt is on branch `abandoned-master-base`). The emulator is
gone.

Identification is **verified on hardware** for both platforms: five cartridges
across two GB mappers, all three CGB flag values, both GB header layouts, and
two GBA cartridges. `plan.md`'s First Hard Stop is cleared.

Dumping is **verified on hardware** for both platforms: twenty GB/GBC
cartridges across ROM-only, MBC1, MBC1+RAM+battery and MBC5, and fourteen GBA
cartridges at 4, 8 and 16 MB. The core computes the GB global checksum itself
while dumping and a CRC32 on both platforms.

## Inherited code

`src/fpga/core/gba_cart_bus.sv` is unchanged from the fork, byte for byte, and
is the only module allowed to touch GBA-mode cartridge pins.
`tools/sim/check_pin_isolation.py` enforces that in the test suite.

Any `tools/sim/check_*.py` joins `make test` automatically - they run before
the testbenches and are reported the same way. `check_qsf_sources.py` is the
second: every `.sv` under the synthesised directories must appear in
`ap_core.qsf`. It exists because each testbench names its own sources in a
`// SOURCES:` header, so a new module compiles under Icarus the moment a
testbench asks for it and the whole suite goes green while Quartus has never
heard of the file. `cart_save_gb.sv` did exactly that: three testbenches
passing, and `Error (12006): instantiates undefined entity` on the runner.

Its author's own commit message is "Initial WIP on cart support. Not all save
types have been tested!". Specifically:

- Its testbench had never passed. It failed its own assertion 146 ns in, and
  the assertion was wrong rather than the module.
- That testbench overrode all six timing parameters to 1 or 2, so the numbers
  that reach a cartridge were never simulated. The suite now covers the
  defaults.
- Its `physical_cart_id` probe never worked: it drove request signals nothing
  was connected to, and captured whatever the emulator's ROM cache was
  fetching at the time.

## The traps

**A Game Boy cartridge in this slot will contend with the GBA bus.** On a GB
cartridge, `bank1` carries D0-D7 and the cartridge drives them on any read in
ROM space. `gba_cart_bus` holds `bank1` as an output for the whole
transaction, read window included. `cart_probe` is what keeps this from
happening: it probes GB first and escalates to GBA only when the GB probe
found nothing at all. Never reorder that. Established in
`docs/HARDWARE-NOTES.md`, asserted in `tb_cart_probe`.

**The core cannot tell you why an SD write failed.** From
`docs/APF-NOTES.md`: a full card, a write-protected card and a filesystem
error all return `target_dataslot_err` 5. `0x0188` flush is now implemented
and `apf_file_writer` checks every command rather than the last one, which is
the most that can be done. The error codes and what they narrow to are
tabulated in `docs/BRINGUP.md`.

**Aborting a write mid-pulse corrupts what the cartridge latches. Fixed for
the mode-change case; still open for slot power loss.** `e_ctl_out` and
`e_hi_oe` in `gb_cart_bus` are both gated by `gb_mode` combinationally, so
the instant the connector mode goes away `/WR` rises and the data pins
release together, on the edge a cartridge latches a mapper register on. The
strobe cannot defend itself, because `cart_pins` owns the pins and honours
the mode immediately.

So whoever changes the mode must wait for `gb_cart_bus`'s `busy` to fall
first, and `dump_engine` now does, including on an abort: the reader is
reset but the transaction it left in flight still completes on its own,
because `req` is only sampled in `ST_IDLE`. Bounded by one transaction, with
a counter as a backstop.

`tb_dump_engine` watches `want_gb` continuously and fails if it ever falls
while the bus is busy. That test was vacuous when first written — at a
three-cycle bus transaction an abort always arrived after the transaction
had finished, so it passed with or without the fix. It only became real once
the modelled transaction was made long enough for an abort to land inside
one. A monitor for a one-cycle window has to be shown to fire.

Still open: losing **slot power** mid-write does the same thing and nothing
here can prevent it, because `cart_mode_s` is the Pocket's decision. If VCC
is going away the cartridge has other problems, but the window during the
fall is real.

**A cartridge pulled mid-dump used to hang the core.** `gb_cart_bus` drops a
transaction when `gb_mode` goes away and never asserts `done`, so the reader
waited forever and so did everything above it, with `dump_busy` stuck high
blocking the probe. Recovery needed exiting the core. `dump_engine` now
watches `cart_powered` and turns it into a failure with error code 7, which is
outside the 0 to 5 APF returns. Covered by `tb_dump_engine` and
`tb_apf_file_writer`, including that the next dump still works.

## APF's file interface, measured

All of this is measured. Where an earlier version of this file stated
something confidently that had not been, it is called out below, because
that pattern cost four sessions.

**The read window is pipelined and both halves are required.**
`io_bridge_peripheral.v` holds the address from the SPI phase, waits four
clocks, samples `bridge_rd_data`, then pulses `bridge_rd`. So the address
must free-run: a window that waits for `bridge_rd` looks too late. And the
value the host keeps is the one presented during the **previous**
transaction, exactly as `core_bridge_cmd.v` does with the datatable. Free-run
the address, latch the data on `bridge_rd`. Getting only the first half right
makes every read arrive one word early, which reads as a malformed path, a
wrong byte order, a wrong struct layout, or anything else you happen to be
varying at the time.

**Byte order differs by direction.** On reads, byte 0 of an array is the low
byte of the word the core presents. On writes, `0x0190`'s reply put byte 0 in
the high byte. Do not reason from one to the other; that produced the wrong
answer twice.

**Paths are absolute from the card root.** `/Assets/carttools/common/NAME`.
APF confirmed it by describing its own output slot via `0x0190`.

**`0x0188` flush is not answered and must not be issued.**
`core_bridge_cmd`'s target state machine waits in `TARG_ST_WAITRESULT_DSO`
forever, so one stalled flush blocks every target command after it. It is off
behind `USE_FLUSH`. Writes commit without it. An earlier version of this file
called its absence a defect, on the grounds that it is documented. Being
documented turned out not to mean it is answered.

**Every command has a deadline.** There is no cancel and no documented upper
bound, so `apf_file_writer` gives each command about 1.8 seconds and reports
`err 6` with `stall_at` naming open, write or flush. Without that a core can
wait forever, and two sessions did.

**How to diagnose the next one in one screenshot.** On the diagnostics page, when it existed,
`<` cycles the four text rows between the cartridge header, APF's reply to
`0x0190` for slot 0, the same for slot 20, and the first 128 bytes this core
last handed APF. Reading what the far side received next to what this side
sent is what finally worked; everything before that compared a screen against
an intention. `0x0190` needs a file assigned to slot 0, so launch by browsing
to one rather than by Play Cartridge.

## Driving the bus

`req` is a level sampled in the bus's idle state, and its done state returns
to idle the cycle after raising `done`. A caller that holds `req` until it
sees `done` is one cycle too late and gets a second transaction. Drop `req`
the cycle after raising it, as `cart_identify_gba` does. Nothing in the module
enforces this.

## The cartridge is asleep for about two seconds after slot power

`cart_pins` only releases pin 30, which is `/RES` on a GB cartridge, once
`mode_ready` asserts. Read it any sooner and the first identification after
launch fails while every rescan succeeds, because a rescan follows a cartridge
that was awake moments earlier. `cart_probe`'s `WAKE_CYCLES` is 2 s and so is
`dump_engine`'s, for the same reason: `cart_probe` parks the mode at idle when
it finishes, so a dump starting afterwards is starting from reset again.

The constant works and is not explained. It may vary with cartridge or battery
level. Both modules parameterise it so testbenches can set it to a handful of
cycles.

## Timing hazards found in synthesis

Neither was visible in simulation. Both cost a failed build.

- **Constant division is not free.** `row = cell / 30` in the screen painter
  became an `lpm_divide`, an 11.4 ns path against a 9.93 ns clock, failing
  setup by 2.3 ns. Use counters that advance together. This is why the dump
  progress counter is displayed in hexadecimal.
- **The column path is walked six hundred times a repaint.** This failed
  setup three times: a divide by 30, then the dump bar and filename fields on
  top of an already deep mux, then a 128-byte text index with a multiply in
  it. The rule is not "avoid division"; it is that anything the screen
  selects per cell must come from a row chosen and registered in the cycle
  before.
- **Wide combinational reductions become the critical path even when they run
  once.** The header checksum summed 29 bytes in one block. Accumulating as
  the words arrive is two adds deep instead of twenty-nine. The same reasoning
  keeps `ui_screen`'s repaint comparator to 35 bits: only the low eight bits
  of the chunk count are in it.

Every milestone must build before moving forward.

## Tests

`make test` runs the suite in a container. Every testbench declares its
sources in a `// SOURCES:` header and must print `TB PASS: <name>` before
finishing: `vvp` exits 0 for a testbench that printed nothing, one that
stopped half way, and one that only called `$error`. Silence is failure.

`tb_dump_engine` is the one that matters for dumping. It reads a modelled
32 KB cartridge, crosses the payload into the bridge domain, answers the
target commands the way APF does, reassembles the file the way a little-endian
host would, and compares it byte for byte. It also covers a short trailing
chunk and a partial bridge word, which no cartridge size can produce, a failed
open, and a cartridge pulled at chunk 4 followed by a clean dump.

`tb_gb_save_write_protect` is the one that matters for saves, and it is the
first test here that **carries its own mutation**: phase 1 runs the real
reader and must be clean, phase 2 drives a deliberate write into the RAM
window through the same bus and the run fails unless the monitor catches it.
A monitor for a condition that never occurs passes whether or not it works,
which is how two earlier monitors in this tree passed with their fixes
removed. Copy the shape rather than the note.

Mutation-test anything that matters. The header checksum test once passed with
a mutation that dropped the last reserved word from the sum, because the
fixture had zeros there; there is now a fixture with a non-zero byte in all 29
checksummed positions.

`ui_screen`'s combinational logic is written as functions behind continuous
assignments, not `always @(*)`, to avoid a simulation and synthesis mismatch
on a cold boot with an empty slot. See `docs/UI.md`.

## What to do next, in order

1. **Probably dirty contacts, and downgraded accordingly.** Three cartridges
   have ever produced a corrupt dump - `TETRIS.gb`, `OTHELLO.gb`, `TENNIS.gb`
   - and all three are cartridge type `00`, ROM only, which looked like a
   sharp correlation. Then twelve cartridges were re-dumped in one session,
   including all three of those, and **every one came back byte for byte
   identical**. Tennis had been corrupt hours earlier, with no code change in
   between.

   That makes intermittent contact the better explanation and the mapper
   correlation a coincidence: the three suspects are the three smallest
   cartridges, hence the oldest and most handled. It also fits the shape of
   the corruption, which had no structure that maps to the RTL - two runs
   holding data from sixteen bytes higher, early in bank 0, not at a bank
   boundary, not chunk aligned, not on a byte lane.

   **It is not proven.** Twelve clean dumps are equally consistent with a rare
   logic defect that did not fire. What settles it is unchanged and still not
   done: **when a dump fails, copy the bad image off before re-dumping it.**
   There has still never been a corrupt-and-clean pair of the same cartridge
   to diff, because Tennis's bad file was overwritten by its own re-dump.

   The practical handling is already right: `dump_checksum` turns a silent bad
   file into a loud one, and the answer to a mismatch is to clean the contacts
   and dump again. `docs/STATUS.md` has the counts and the byte map.

2. **Fix the filename: the two halves that are left.** The extension half is
   done in `47bcd54` - `.gb`, `.gbc`, `.gba`. Still outstanding: `dump_path_gen`
   takes fifteen bytes from `0x134`, which is the old title field, so on a CGB
   cartridge the four-byte manufacturer code at `0x13F`-`0x142` lands in the
   name and `ZELDA_DIN__AZ7E.gbc` should be `ZELDA_DIN.gbc`. And nothing
   checks whether the chosen name is taken: Link's Awakening and Link's
   Awakening DX both title themselves `ZELDA`, and the second dump silently
   destroyed the first. See the collision entry under *Deliberately not done*
   for why overwriting was thought correct, and why that reasoning does not
   cover two different cartridges.

3. **Close the gap between `docs/FILE-FORMATS.md` and what the core writes.**
   That document specifies a `Dumps/`/`Saves/`/`Metadata/`/`Restore/` tree and
   a `.cart.json` sidecar; the core writes flat files and no sidecar. Decide
   which is right and move one of them - the companion app in
   `docs/COMPANION-APP-PLAN.md` is already written against the spec, so
   leaving them apart means the app is built against fiction. The sidecar is
   also where the MBC1 large-cartridge caveat belongs, which
   `cart_dump_gb.sv` has wanted somewhere since it was written.
4. **Add the double read to the save path.** The save backup itself is
   **done and verified**: a 32 KB four-bank GBC save was dumped, loaded in
   mGBA beside its own ROM, and the game came up with everything intact. See
   `docs/STATUS.md`. What is left is the check the plan calls mandatory and
   the core still does not do.

   - **The double read.** Read twice, compare, and do not write the file on a
     mismatch. A save has no checksum, no logo and no length, so a second
     pass is the only check available to it at all - and unlike a ROM dump, a
     bad one cannot be fetched from anywhere else. It needs the buffering in
     `docs/DUMP-VERIFY-PLAN.md`; 32 KB fits in block RAM with room to spare,
     which is what makes "do not write the file on a mismatch" achievable
     here and not for a 16 MB ROM. Until it lands, the second opinion is
     dumping twice and running `scripts/verify_dump.py --compare`.

   - **More cartridges, and specifically an MBC1 one.** One cartridge proves
     one path. The verified one is MBC5, which has no mode register, so
     **MBC1's mode-1 trap is still simulation only** - and it is the trap
     that produces a plausible file rather than an obvious failure. Seven
     MBC1 cartridges here have 8 KB saves; any of them exercises the mode
     write, none exercises banking. 64 KB and 128 KB have no cartridge at all.

   - **The collision bites hardest here.** Link's Awakening and Link's
     Awakening DX both title themselves `ZELDA`, so their `.sav` files land
     on the same name and the second destroys the first. For a ROM that means
     a re-dump; for a save it means the backup is gone. Item 2 should land
     before anyone backs up two cartridges with the same title.

   Also open: **GBA saves.** `gba_cart_bus.sv` already implements the save
   window - `save_space`, `/CS2`, the 16-bit address on AD, the byte off the
   high bus - so SRAM needs no bus work either, and unlike GB it needs no
   write to the cartridge at all. Two cartridges here use SRAM (Kirby:
   Nightmare in Dream Land, Metroid: Zero Mission), one uses Flash (Golden
   Sun) and seven use EEPROM, read out of each ROM's SDK id string. SRAM
   first: it is a plain 32 KB read window with no command sequence.

5. **Cover the mappers that still have no cartridge.** ROM-only, MBC1 to
   512 KB, MBC1+RAM+battery and MBC5 to 1 MB are proven on hardware. MBC2,
   MBC3 and MBC1 **above** 512 KB are simulation only, and GBA above 16 MB is
   untested.

   MBC1 above 512 KB is the interesting one: the mapper forces the low five
   bits of the bank register to 1 when written as 0, so banks `0x20`, `0x40`
   and `0x60` cannot be selected at all. A real dump will contain duplicates
   and will not match a published hash - documented behaviour that has never
   been watched to happen. `DONKEY_KONG.gb` at 512 KB is the largest MBC1
   tested and sits one size below it.

   Cartridges that would settle each: Donkey Kong Land, Kirby's Dream Land 2
   or Wario Land II for MBC1 at 1 MB; Kid Icarus or Golf for MBC2; Pokemon
   Gold or Crystal for MBC3, and Crystal also has 32 KB of save RAM, which is
   the only way to exercise the save banking path in `docs/GB-SAVE-PLAN.md`.

## Deliberately not done

- **No cartridge bus HAL layer.** The bus that exists is the HAL.
- **No flush, so no commit confirmation.** `0x0188` is unanswered and
  issuing it wedges the target command path. Writes land; nothing verifies
  they reached the card. `dump_checksum` covers the read path but not this
  one: it sums the bytes on their way out of the core, so a byte lost after
  that point would still report `image checksum ok`.
- **The slot-file fallback has never run on hardware.** If every `0x0192`
  open is refused, `dump_engine` writes into the file `data.json` names for
  slot 20 instead. Tested in simulation, never needed since `0x0192` started
  working.
- **No read-back verification pass.** `dump_checksum` checks the image
  against the cartridge's own value as it streams, which catches a misread,
  but it never re-reads the file from the card, so it cannot catch a bad
  write. A dump that needs that level of trust still gets it from a hash
  comparison on a PC.
- **No collision handling on filenames**, and this has now cost something.
  The reasoning was that two dumps of the same cartridge should overwrite:
  there is no directory listing command, so uniquifying would mean probing
  names one round trip at a time, and a dump that silently became
  `POKEMON_3.gb` is worse than one that replaced `POKEMON.gb`. The resize
  flag is set so a shorter dump does not leave the tail of a longer one
  behind.

  What that missed is that two *different* cartridges can produce the same
  name — Link's Awakening and Link's Awakening DX both title themselves
  `ZELDA` — and the second silently destroyed the first. Overwriting a
  re-dump is fine; overwriting a different cartridge is not, and the core
  cannot currently tell the two cases apart. Item 2 above.
- **No sidecar metadata, and no `Dumps/` tree.** `docs/FILE-FORMATS.md`
  specifies both in full - subdirectories for dumps, saves, metadata and
  restore, plus a `<basename>.cart.json` next to every image with hashes,
  header judgements and a `verified` field. The core writes flat into
  `/Assets/carttools/common/` and writes no sidecar at all. That document now
  carries a table of what is specified against what exists, because for two
  days it read as a contract while describing nothing that had been built.
- **The engine's introspection ports have no consumer.** `dump_engine` still
  drives `dbg_reads`, `dbg_struct_reads`, `dbg_last_addr`, `dbg_first_word`,
  `dbg_flags_word`, `dbg_size_word`, `probe_err`, `resp_words` and
  `sent_words`, and `core_top` no longer reads any of them, so Quartus strips
  them. They were how the APF path search was diagnosed and they are worth
  keeping until the save path has been through its own bring-up; after that,
  either delete them or give them somewhere to go.
- **No companion app.** `docs/COMPANION-APP-PLAN.md` plans the desktop side.
  It waits on a core that has written files to a real card.
