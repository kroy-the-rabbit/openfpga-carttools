# Verifying a dump on the device: a plan

Written 2026-08-27, after GBA dumping was verified on hardware and the gap it
left became obvious.

Two additions, aimed at two different failure classes. They are complementary
rather than alternatives, and the reason to build both is that each is blind
to what the other catches.

## The gap, stated exactly

Every corruption this project has actually hit was invisible to the checks
that existed before it and visible to the one added afterwards. There have
been two.

**Super Mario Land 2, a floating D7.** 105,121 of 524,288 bytes wrong, every
difference bit 7 alone, flipping both directions. It passed identification:
25 header bytes each shifted `+0x80` sum to `0xC80`, whose low byte is `0x80`,
and the stored checksum byte took the same shift, so the two cancelled. An
8-bit header checksum is structurally blind to a uniform bit-7 offset. The
header-read-twice stability check did not help either, because D7 was
*consistently* high during that window.

**Tetris and Othello, corrupt at 1 KB window boundaries.** Recorded for a day
as cartridges shipping wrong checksums, on a plausible story, because
everything the core could check passed.

What each check can see:

| | intermittent fault | stuck or floating line |
|---|---|---|
| header checksum `0x14D` | no | **no** — the MarioLand2 case |
| header read twice | no — consistent faults reproduce | **no** |
| `dump_checksum` vs `0x14E` | yes | yes |
| GBA today | **nothing** | **nothing** |

A GBA cartridge carries no whole-image checksum, so `dump_checksum` has
nothing to read and the GBA row is empty in both columns. That is the gap.

## 1. Check the Nintendo logo

Both identify modules deliberately skip it, and both say why. From
`cart_identify_gba.sv`:

> The Nintendo logo at 0x04..0x9F is deliberately not checked. It would be a
> strong validity test, but it needs 156 bytes of known-good data compiled
> into this core, and getting those bytes wrong would reject good cartridges
> for a reason nobody could see.

`cart_identify_gb.sv` says the same about its 48 bytes at `0x0104`.

**That reasoning was correct and its objection has now been answered.** The
blocker was never the idea, it was the absence of a trustworthy source for
the bytes. Both constants can now be taken from this project's own verified
dumps rather than transcribed from a document:

- **GBA, 156 bytes at `0x04`-`0x9F`.** Byte-identical across
  `GBAZELDA_MC.gb` and `GOLDEN_SUN_A.gb`, two different cartridges dumped
  independently. `sha1 17daa0fec02fc33c0f6abb549a8b80b6613b48ee`. That region
  is covered by no checksum in a GBA header, so the agreement is not
  circular: nothing verified those bytes in either dump, and they match
  anyway.
- **GB, 48 bytes at `0x0104`-`0x0133`.** Byte-identical across **all fifteen**
  GB cartridges dumped, spanning ROM-only, MBC1 and MBC5 and every size from
  32 KB to 1 MB. `sha1 0745fdef34132d1b3d488cfbdf0379a39fd54b4c`.

The exact bytes are in `docs/LOGO-BYTES.md`, with the command that produced
them, so a future reader can regenerate rather than trust.

### Why this is the right complement

It is an **exact comparison against a known value**, which is a different
instrument from a checksum. A checksum can be defeated by compensating
errors — `tb_dump_checksum` has a case demonstrating exactly that, two bytes
wrong by equal and opposite amounts. A byte-for-byte comparison against 156
known bytes cannot be. A stuck or floating data line changes them and the
comparison fails.

It also costs nothing to run: 156 bytes on GBA, 48 on GB, read once.

### Where it goes

In the **identify** modules, not the dump path, so it runs on every scan and
a bad contact is visible before anyone presses X. Report it as a third
independent judgement alongside the fixed byte and the complement check —
kept separate rather than collapsed into one boolean, which is the house
pattern and the reason those modules already keep three.

**Do not gate dumping on it.** A homebrew or reproduction cartridge with a
wrong logo is a legitimate thing to want to dump. Say so on screen; refuse
nothing.

Storage: 156 bytes as a packed constant. Compare a halfword at a time as the
header is read, accumulating a single mismatch flag, rather than storing what
was read — the comparison is the only thing anyone needs the answer to.

## 2. Dump twice, compare, before trusting

### The ordering matters, and the obvious ordering is wrong

The natural design is read, read, compare, then write. **It has a hole**: the
bytes written come from a third read that nothing verified. Two agreeing
reads followed by an unobserved third proves nothing about the file.

```
pass 1   read the whole ROM, CRC32 only, bytes discarded, card untouched
         reset the CRC
pass 2   read again, stream to the card, CRC32 over the bytes actually written
         compare the two
```

Agreement now certifies the file, because the second CRC was computed on
exactly the bytes that went out. Two passes rather than three, and a stronger
guarantee from fewer.

### It cannot avoid writing a bad file, and should not pretend to

Never writing a bad file would need the whole image buffered — 16 MB against
roughly 384 KB of block RAM. Impossible. So on mismatch the file exists and
the screen says so unmistakably.

That is the right trade. The danger was never a bad file; a retry overwrites
it. The danger was a bad file that looked fine, which is what happened to
`TETRIS.gb` and `OTHELLO.gb` for a day.

### Cost

Pass 1 needs no buffer, so `out_ready` ties high and the reader free-runs at
bus speed:

| | per byte | full dump |
|---|---|---|
| GB | ~800 ns | 1 MB in 0.84 s |
| GBA | ~104 ns | 16 MB in 1.75 s |

Against SD write time that is noise, which is why this is the default rather
than a flag.

**One cost that is not noise, on GB only.** Pass 1 repeats every mapper
bank-switch write, doubling the writes this core makes to a cartridge — a
1 MB MBC5 goes from about 128 register writes to 256. These are writes the
cartridge is designed for and it is not a real risk, but writes are the only
thing in this project that can damage anything, so it is recorded rather than
waved through. GBA does zero writes and the question does not arise.

### What it catches, and what it cannot

**Intermittent faults: yes.** A marginal contact reading differently twice is
precisely what this sees.

**Stuck faults: no.** MarioLand2's D7 was consistent, which is why reading
the header twice missed it. A double read is blind to a fault that
reproduces. On GB `dump_checksum` covers that; on GBA the logo check is what
covers it, which is why these two are one plan.

## Implementation notes

`dump_engine` owns the sequencing. What it needs:

- A pass counter and a first-pass state before the existing path, with
  `out_ready` forced high so the reader free-runs. `dump_chunk_src` is
  bypassed in pass 1: there is no buffer to throttle against.
- A register holding pass 1's CRC, and a reset of `dump_crc32` between passes.
- A comparison at the end, and a screen state for agree and differ. Row 14
  already carries the CRC; the verdict belongs next to it.
- On GB, `dump_checksum` runs in both passes. Its pass 2 result is the one to
  report, for the same reason pass 2's CRC is: it describes the bytes written.
- The self test no longer exists in the core, so there is no second case to
  special-case here: every dump this plan covers reads a cartridge. The
  `selftest` port survives in `dump_engine` as a simulation hook, and a
  double read has nothing to do in that mode, so it should skip pass 1 on
  `sel_l` for the testbench's sake alone.

## Tests

- **`tb_cart_identify_gb` / `tb_cart_identify_gba`**: a correct logo passes; a
  single bit flipped anywhere in it fails; the verdict is independent of the
  other two judgements, proven by a cartridge with a good logo and a bad
  complement check and vice versa.
- **Mutation-check the logo comparison.** Break it so it always passes and
  confirm the bad-logo case fails. A comparison against a constant is exactly
  the kind of check that can be silently inert.
- **`tb_dump_engine`**: two passes run; the CRC is reset between them; a
  cartridge model that returns *different data on the second pass* produces a
  mismatch verdict, and one that is stable produces agreement. That
  differing-model case is the whole test — without it this is a feature with
  no failing case behind it.
- **A stuck-line model**: a model with D7 forced high on both passes must
  produce *agreement* from the double read and a *logo failure* from the
  check. That single case demonstrates the division of labour between the two
  halves of this plan, and demonstrates the limit rather than hiding it,
  which is the house pattern from `tb_dump_checksum`.
- **`tb_ui_screen`**: the agree and differ rows, and that neither paints
  until a dump has completed.

## Not in scope

- **Read-back verification.** Both CRCs here are taken from bytes leaving the
  reader, so a fault between the core and the SD card still reports
  agreement. Reading the file back is a separate operation and is not built
  for either platform.
- **Gating dumps on the logo.** Reported, never enforced. See above.
- **Retry on mismatch.** Report and stop. An automatic third attempt hides
  how flaky a contact is, and how flaky it is happens to be the thing worth
  knowing.
