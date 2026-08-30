# First hardware bring-up

**Passed 2026-08-25.** Five cartridges identify correctly on real hardware;
`docs/STATUS.md` has the headers and the checksums. This file stays as the
procedure for repeating it on another Pocket, with another cartridge, or after
a change to the bus.

`plan.md` calls this the First Hard Stop. Nothing that writes to the SD card or
to a cartridge gets built until this works:

```text
launch core -> access physical GBA cartridge -> read header -> validate ->
display cartridge identity
```

## Order of testing

Least risk first. The risk is contention, two drivers on one pin. Nothing in
this build writes, so cartridge contents cannot change.

| Step | Slot | What it exercises | Cartridge exposure |
| --- | --- | --- | --- |
| 1 | empty | GB mode, the turnaround, GBA mode, the escalation | none |
| 2 | GB or GBC | GB mode only. A valid GB header stops the probe, so GBA mode is never entered | native protocol |
| 3 | GBA | GB mode first, then GBA mode | one unverified step, below |

Step 2 before step 3, not the other way round. A Game Boy cartridge never
reaches GBA mode, so it only ever sees the protocol it was built for.

Step 3 carries the one step that is reasoned rather than verified: a GB-mode
read against a GBA cartridge. `/CS` stays high so the GBA ROM is never
selected, and pins 22-29 are inputs on that cartridge, so nothing should drive
back. See `docs/HARDWARE-NOTES.md` section 5a. Use a cartridge you would not
mind losing.

## What simulation already proves

`tb_probe_pins` runs the whole chain at the connector, through both modes:

- WR# never falls. Verified by mutation: making an identifier ask for a write
  fails the test.
- The two engines never drive at once.
- No address or data bank is driven while the mode is idle or turning round.
- Losing slot power mid-probe releases every pin.

What it cannot prove is the pin mapping and the timing, which is what a
cartridge is for.

## Before you start

- **Insert and remove with Play Cartridge not selected.** The core holds every
  pin at the safe idle until the Pocket reports the slot selected and powered.
- Check the Pocket's firmware is at least 1.2. `core.json` requires it.
- **`data.json` must declare at least one data slot.** This is not optional and
  it is not obvious. `core.json` sets `cartridge_adapter` bit 24, which means
  "offer Play Cartridge in the Asset browser when starting the core", and
  Analogue's rule is that the slot is powered only if bit 24 is clear, or bit
  24 is set *and the user picks Play Cartridge*. With `"data_slots": []` the
  Pocket has nothing to browse, never opens the browser, and never offers the
  option, so the slot is never powered and the core sits on
  `SELECT PLAY CARTRIDGE` forever with no way to select it. The declared slot
  is `deferload`, so the Pocket announces it without streaming any bytes into a
  core that has no loader for them.

## What to do

1. Copy `build/cart/sd/` onto the card, or unzip the release into its root.
2. Launch **Cartridge Tools** from the Pocket menu.
3. Select **Play Cartridge** when the Pocket offers it. The core only drives
   the cartridge pins once the Pocket says the slot is selected and powered.
4. Read the screen. **The first result takes about two seconds.** That pause
   is deliberate: a cartridge is not readable for something close to a second
   after the slot is powered, so the first probe is delayed
   (`CART_WAKE_CYCLES` in `core_top.sv`). It is not a hang. Rescans with A are
   immediate.

## What the screen means

```text
CARTRIDGE TOOLS

GBA CARTRIDGE

Title  METROID FUSION
Code   AMTE
Maker  01
Ver    00

header ok  checksum ok

A rescan   SELECT details
```

| Line 2 says | Meaning |
|---|---|
| `READY` | nothing has been tried yet |
| `READING HEADER...` | in progress. It should never persist; the whole read is under a millisecond |
| `GBA CARTRIDGE` | present, stable, valid |
| `NO CARTRIDGE DETECTED` | every byte read back as 0x0000 or 0xFFFF |
| `UNSTABLE READ, RESEAT CART` | the header read differently the second time |
| `UNRECOGNISED CARTRIDGE` | something answered, consistently, but the header is not a GBA header |
| `SELECT PLAY CARTRIDGE` | the Pocket has not powered the slot. If it never clears and the Pocket never offered you the choice, check `data.json` has a slot, per "Before you start" |

A rescans, and is safe to press as often as you like. SELECT opens the
diagnostics page.

## The diagnostics page

> **Removed.** `SELECT`, the page, and the `B` / `<` / `>` controls it hosted
> are gone from the core. Every value the page existed to establish - byte
> order, the path root, what APF actually returns - is settled and recorded in
> `docs/STATUS.md`. What follows is what that page showed, kept because the
> hex layout is how the header reads were diagnosed and the next bring-up may
> want the same view built again.


```text
DIAGNOSTICS

play 1  power 1  id 01
result 0  stable 1

0A0 4554 5453 4143 2020
0A8 4D41 4554 0096 3130
0B0 0000 0000 0000 0000
0B8 0000 0000 DF00 0000

0BD read DF  calc DF

SELECT back   A rescan
```

The four hex rows are the bytes exactly as they came off the bus, in the order
they arrived, with no interpretation. Which engine's bytes they are follows
`answered_gba` from `cart_probe`, not the platform verdict, because
UNRECOGNISED and UNSTABLE can arrive from either engine. For a GBA answer they
are the 32 bytes at 0x0A0 to 0x0BF; for a GB answer they are the 26 bytes from
0x0134, and the address labels down the left are the GBA offsets in both cases
rather than the true GB addresses. `0BD read` against
`calc` is the header complement check as stored against as computed.

## Reading the hex

| What you see | Most likely |
|---|---|
| all `FFFF` | nothing driving the bus. Empty slot, cartridge not seated, or the slot never powered. Check `play` and `power` first |
| all `0000` | something is holding the bus low. Not an empty slot |
| plausible ASCII, `0096` in the right place, checksum matches | it works |
| plausible ASCII, checksum does not match | a read is landing slightly wrong. Suspect timing before suspecting the cartridge |
| bytes right but each pair swapped | endianness assumption wrong in the header reader, not in the bus |
| the right bytes shifted by one word | the address is off by one, or the first read of a burst is being dropped |
| changes between rescans | marginal contacts, or a timing problem. `stable` will already be 0 |
| `play 0` | the Pocket never reported Play Cartridge. Nothing else on this page means anything yet |
| every word equals its own address, e.g. `0A0 0050 0051 0052` | nothing is driving the bus, so it floats at the last value the core drove, which is the address. Normal for an empty slot; with a cartridge in, it means the cartridge is not responding |
| `power 0` with `play 1` | selected but not powered. An APF or firmware question, not a bus one |

## If it works

Record it in `docs/STATUS.md`, with which cartridges.

Then test the awkward ones: a cartridge with dirty contacts, the largest ROM
you own, a reproduction if you have one. The unstable-read path has never been
exercised outside a testbench.

## If it does not work

Record the hex on the diagnostics page in `docs/STATUS.md` before changing
anything. The next build will destroy that evidence. `plan.md` says to revisit
the architecture rather than add features.

Likeliest suspects, in order:

1. **The timing parameters.** `gba_cart_bus.sv` counts `clk_sys` cycles, and
   its defaults came from a fork whose author called the work in progress.
   They are simulated to the cycle, which proves they are what the design
   intends, not what a cartridge wants.
2. **`bank0[7]`.** The core template calls it PHI#, the module drives it
   constantly low in cartridge mode, and the working Game Boy core drives it
   non-inverted. Open question in `docs/HARDWARE-NOTES.md`.
3. **The address latch.** `ST_READ_TURN` keeps AD driven until RD# asserts,
   which is what a retail cartridge is documented to want.

`gba_cart_bus.sv` is the only module that touches the pins. Changing it is a
deliberate act with its own commit and its own testbench update.

---

# Second bring-up: dumping to the card

**Passed 2026-08-26.** Four cartridges dumped and verified; `docs/STATUS.md`
has the table. What follows was written before any of it worked and is kept
as the procedure, with the outcomes filled in.

The byte-order self test in step 1 is no longer a question being settled —
byte order is measured and fixed — but it is still the right first step,
because it exercises the whole SD path with no cartridge involved and fails
in an obvious way if something upstream has broken.

The core now writes files. That is a different class of thing from reading a
header: it hands data to APF, which hands it to the filesystem, and there is
no return path that tells the core what actually landed. The evidence has to
be collected on a PC.

## Order of testing

Do these in order. Each one removes a whole class of cause from the next.

### 1. The self test, byte order 1

> **Removed.** `Y` no longer does anything. The ramp still exists as a
> simulation hook in `dump_engine`, exercised by `tb_dump_engine`, but there
> is no way to write `SELFTEST.bin` from the core. Start at step 2.


No cartridge. Launch the core, press **Y**.

The screen should show `DUMPING 0000 OF 0001` briefly and then
`DUMP COMPLETE`. Take the card out and look at
`/Assets/carttools/common/SELFTEST.bin`.

| What the file looks like | What it means |
|---|---|
| 302 bytes, `00 01 02 03 ... FF 00 01 ... 2D` | byte order 1 is correct. Go to step 2 |
| 302 bytes, `03 02 01 00 07 06 05 04 ...` | byte order 0 is correct. Press SELECT, press **B** to flip it to `0`, press SELECT again, redo this step |
| the file does not exist | the open failed, or the path is wrong. See below |
| `DUMP FAILED err 6` | APF never answered a command, and row 12 says which. A stalled flush means the writes already succeeded; a stalled open or write means they did not |
| the file exists but is 0 bytes | the open worked and the writes did not. `DUMP FAILED` should have said so; if it said COMPLETE then `0x0184` reported success without writing |
| the right length but full of one repeated value | the bridge read window is answering with a stale word rather than the buffer |

The last two bytes are the tail of a partial bridge word and are the least
trustworthy in the file. Judge byte order on the first 300.

### 2. A small cartridge

Put in the smallest ROM you own. Wait for it to identify, then press **X**.
`X dump` only appears on the help row once a Game Boy cartridge has been
identified, because the dump takes its size from header `0x0148` and its
mapper from `0x0147`.

Expect `DUMPING xxxx OF xxxx` counting in hex, then `DUMP COMPLETE`. A 32 KB
cartridge is 8 chunks; a 1 MB one is 256.

Then, on a PC:

```
# .gb, .gbc or .gba depending on the cartridge; see docs/FILE-FORMATS.md
sha1sum /run/media/$USER/pocket/Assets/carttools/common/YOURTITLE.gb
```

and compare against No-Intro. **That comparison is the whole point of this
milestone.** A dump that reads plausibly and hashes wrong is worth more as
evidence than one that hashes right, because it says the bus works and
something above it does not.

### 3. Sizes and mappers

Then the awkward ones, in this order, because each is a bigger step than the
last:

1. another cartridge of the same mapper, to prove the first was not luck
2. an MBC3 or MBC1 cartridge, so the other bank-register paths run
3. the largest ROM you own, which is the first time the chunk loop runs for
   minutes rather than seconds

An MBC1 cartridge larger than 512 KB is expected to hash wrong, and
`cart_dump_gb.sv` says why: MBC1 cannot select banks `0x20`, `0x40` or `0x60`
at all, so those banks come back as `0x21`, `0x41` and `0x61`. That is the
mapper, not this core, and real dumps of those titles contain the same
duplicates.

## What the dump line means

```
DUMPING 0042 OF 0200            chunk 0x42 of 0x200, hexadecimal
DUMP COMPLETE                   every chunk written and the flush succeeded
DUMP FAILED  err 5  chunk 01A3  target_dataslot_err 5, at chunk 0x1A3
```

The error code is `target_dataslot_err`, three bits, and it is the only
failure channel APF offers:

| err | Meaning |
|---|---|
| 0 | success. Should never appear on a failure line |
| 1 | created and opened. Also not a failure, and treated as one only by a bug |
| 2 | slot not defined. `data.json` does not declare slot 20, or the card has an old copy |
| 3 | file not found. With the create flag set this should not happen; if it does, the directory in the path does not exist |
| 4 | malformed path. The path bytes reached APF in the wrong order or the wrong place |
| 5 | general error. A full card, a write-protected card and a filesystem error all land here |

A failure at chunk 0 with err 4 or 5 is a path problem. A failure at a late
chunk with err 5 is almost certainly a full card. A failure at chunk 0 with
err 2 means the card's `data.json` is stale.

## If nothing is written at all

In order:

1. **Is the card's `data.json` the new one?** Slot 20 must exist and must not
   be read-only. `0x0192` refuses to create or resize a read-only slot.
2. **Does `/Assets/carttools/common/` exist on the card?** Nothing in the
   `0x0192` documentation says APF will create a missing directory.
3. **Byte order.** A path that reached APF byte-reversed is a malformed path,
   err 4, and no file appears. This is the same toggle as step 1, and step 1
   exists so this question is already answered before a cartridge is involved.
4. **Firmware.** `0x0190` and `0x0192` arrived in openFPGA 1.1, and 2.3 fixed
   `0x0192` "to properly update dataslot size fields". An old Pocket firmware
   is a real possibility.

## If the file is written but the hash is wrong

Compare the first 512 bytes with a known good dump before anything else. The
shape of the difference names the cause:

| Difference | Cause |
|---|---|
| every group of four bytes reversed | byte order, press **B** |
| the first 16 KB correct, the rest wrong or repeated | banking. The mapper write is not taking effect |
| every 16 KB block correct but in the wrong order | the bank counter, not the mapper |
| scattered single bytes wrong | bus timing, and the same suspects as the first bring-up |
| the whole file is the first bank repeated | the mapper is not being written at all: check the cartridge type at `0x0147` on the details screen |

Keep the bad dump. It is evidence, and the next build overwrites it.
