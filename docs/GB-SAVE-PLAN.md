# GB/GBC save backup: a plan

> **Phases A, B (partly) and the refusals are built, 2026-08-28.**
> `cart_save_gb.sv`, `Y` on the main screen, `.sav` through the same engine.
> Two divergences from what is below, both deliberate, and the code is right
> in both cases:
>
> - **Phase A's display went to the main screen, not the diagnostics page.**
>   That page no longer exists; see `docs/STATUS.md`.
> - **Phase C, banking, is built** - 2 KB to 128 KB, the MBC1 mode trap and
>   the MBC3 RTC exclusion. It was first left out on the grounds that no
>   cartridge here could exercise it. That was wrong: Link's Awakening DX has
>   32 KB in four banks, and it was the first cartridge the save path met.
>   The coverage table below is corrected.
>
> **Phase B is done, including the check this plan calls the strongest
> available.** "An emulator loading the file alongside the matching ROM dump
> and finding the save intact is the strongest available external check -
> worth doing once, since it validates the whole chain against software that
> had no part in producing it." That was done on 2026-08-28 and it passed;
> `tools/podman/play-dump.sh` is the harness, so it is now worth doing every
> time rather than once.
>
> **Still missing, and it is the part this plan argues hardest for: the
> double read.** "Read it twice, by default, always" is not implemented. A
> `.sav` from this core today is a single read. See `docs/HANDOFF.md` item 4.

`plan.md` Phase 5, milestone v0.5. Written 2026-08-26.

Read the battery-backed RAM out of a Game Boy or Game Boy Color cartridge and
write it to the card as a `.sav` file.

Two things make this different from ROM dumping, and they pull in opposite
directions.

**It is smaller and easier.** Eight kilobytes to a hundred and twenty-eight,
against thirty-two kilobytes to a megabyte. The bus already does everything
required — `/CS` is implemented, tested, and derived from the address, so no
new bus capability is needed at all.

**It is the first operation that can destroy something irreplaceable.** A bad
ROM dump wastes a minute. A save is the only thing in the cartridge that is
not recoverable from elsewhere: nobody has a No-Intro record of somebody's
Pokémon file. And reading it requires putting the cartridge into the one state
where a stray write lands on it.

That asymmetry decides the whole shape of this plan.

## What already exists

More than I expected before checking.

| Piece | State |
|---|---|
| `/CS` on the bus | **done and tested.** `cs_active = (latched_addr[15:13] == 3'b101)` asserts it for `0xA000`-`0xBFFF` and nothing else. `tb_gb_cart_bus` reads and writes at `0xA000`, and asserts `/CS` never falls below `0x8000` |
| Mapper register writes | done. `gb_cart_bus` permits writes to `0x0000`-`0x7FFF` deliberately, which is how RAM gets enabled and banked |
| `ram_size_code` from `0x0149` | already parsed by `cart_identify_gb` and already routed to `core_top` and the screen |
| The whole streaming path | unchanged. `dump_chunk_src` → `dump_buffer` → `apf_file_writer` does not care what the bytes are |
| File extension | already a register. `dump_path_gen` has `EXT_GB` and `EXT_BIN`; `.sav` is a third constant |
| The write-abort hold | already in `SS_END`, and it matters more here than it did for ROM |

**No bus work.** That is worth saying twice, because it was the expensive part
of every previous phase.

## Reaching the RAM

Enable, bank, read, disable. The enable and disable are writes to ROM space,
which is legal and is the only mechanism the hardware provides.

```
enable      write 0x0A to 0x0000-0x1FFF
disable     write 0x00 to 0x0000-0x1FFF
read        0xA000-0xBFFF, 8 KB per bank
```

Per mapper, from `0x0147`:

| Mapper | RAM bank select | Notes |
|---|---|---|
| MBC1 `01`-`03` | 2 bits at `0x4000`, **and** mode 1 at `0x6000` | in mode 0 only bank 0 is reachable |
| MBC2 `05`-`06` | none | 512 × 4 bits inside the mapper; see below |
| MBC3 `0F`-`13` | 2 bits at `0x4000` | values `08`-`0C` map RTC registers instead of RAM |
| MBC5 `19`-`1E` | 4 bits at `0x4000` | up to 16 banks |
| none `00` | n/a | `08`/`09` exist for unbanked RAM |

Sizes from `0x0149`, and note that this table is not monotonic — `04` is
larger than `05`, which is exactly the kind of thing that gets transcribed
wrong:

| Code | Size | Banks |
|---|---|---|
| `00` | none | — |
| `01` | 2 KB | 1 partial |
| `02` | 8 KB | 1 |
| `03` | 32 KB | 4 |
| `04` | **128 KB** | 16 |
| `05` | **64 KB** | 8 |

### Three traps in the mapper detail

**MBC1 mode.** RAM banking only works in mode 1, set by writing `0x01` to
`0x6000`-`0x7FFF`. Mode 1 also changes how ROM banking behaves, so the mode
must be put back to 0 before any subsequent ROM dump. A save backup that
silently leaves the cartridge in mode 1 would corrupt the *next* ROM dump, not
its own output — the worst kind of bug to track down.

**MBC2 lies about its size.** `0x0149` reads `00` on an MBC2 cartridge even
though RAM exists, because the RAM is inside the mapper. Size must come from
`cart_type`, not the size byte. It is 512 nibbles at `0xA000`-`0xA1FF`,
echoed through the rest of the window, and the upper nibble of each byte is
not connected to anything. The convention question — write `0xF0 | value` or
`0x00 | value` into the file — has no correct answer from the hardware; pick
one, write it in the source, and say which.

**MBC3 RTC shares the bank register.** Writing `08`-`0C` to `0x4000` maps
clock registers into the RAM window instead of RAM. The reader must write only
`0`-`3`. RTC support is v0.10 and out of scope, but reading it by accident and
filing it as save data is in scope to prevent.

## The safety argument

This is the part I would want reviewed hardest.

**The invariant: `/WR` must never fall while `/CS` is low.** That single
sentence covers every way this operation can destroy a save. It is checkable
in simulation, continuously, over every transaction the reader issues — the
same shape as `tb_gba_cart_write_protect`, which already does the equivalent
job on the other bus for 62 cases.

Write that monitor first, before the reader that it watches. And **mutate it**
— make the reader issue a write into the RAM window and confirm the test
fails. A monitor for a condition that never occurs passes whether or not it
works; the write-abort monitor in `tb_dump_engine` passed for a while with the
fix removed, and only became real once the modelled transaction was long
enough for the fault to fit inside one.

The structural defences that already exist:

- `gb_cart_bus` drives `/WR` only when `wr` is set on the request. A read
  cannot pulse it.
- `/CS` is derived from the address inside the bus, not passed in, so a
  caller cannot assert it for a ROM-space write.
- The reader never sets `wr` with an address in `0xA000`-`0xBFFF`. This is the
  invariant above, and it is the reader's whole contribution to safety.

The discipline on top:

- **Keep the enabled window short.** Enable, read, disable. Do not leave RAM
  enabled across the file write, which takes far longer than the read.
- **Disable on every exit**, including abort and error. An abort that leaves
  RAM enabled is worse than an abort that fails loudly.
- **The mode hold matters more here.** `SS_END` already waits for the bus to
  go idle before dropping the connector mode, because `e_ctl_out` and
  `e_hi_oe` are gated by `gb_mode` combinationally and a mode change mid-write
  truncates the strobe. The write it could truncate here is the *disable*.

**What cannot be defended against, stated rather than buried:** losing slot
power mid-operation. `cart_mode_s` is the Pocket's decision and nothing in
this core controls it. Real cartridges carry a power-fail circuit that
disables RAM as Vcc droops, which is what protects saves during a normal
power-off, so this is not as dire as it sounds — but it is the cartridge's
protection, not ours, and it is worth knowing which is which.

## The verification problem, and why it is easier here

Save data contains nothing that describes itself. There is no logo, no header
checksum, no global checksum. Games often embed their own, but that is
game-specific and not something to build. So every check that made ROM
dumping trustworthy is unavailable.

**Read it twice, by default, always.** A 32 KB save read twice costs a couple
of seconds. This is not an option or a flag — the entire operation is small
enough that a second pass is free, and it converts a file that passes no
checks at all into one that is at least reproducible.

This session is the argument. Fifteen of the sixteen GB ROM dumps in
`STATUS.md` are single attempts; the two that turned out to be corrupt had
passed every check available when they were made. For ROM there was a
cartridge-supplied checksum to fall back on. Here there is nothing, and the
data matters more.

Report a mismatch plainly and do not write the file.

**Also compute and display CRC32.** Same module the GBA plan wants, and the
same reasoning: it cannot say a backup is correct, but it gives it an identity
that can be compared later.

### The blank-file trap

If the RAM enable does not take, reads return open bus — `0xFF` — and the
result is a 32 KB file of `FF` that looks exactly like a successful backup.
This is the direct counterpart of the open-bus problem in the GBA size probe,
and it deserves the same suspicion.

**A non-destructive presence test:** read the first 256 bytes with RAM
*disabled*, then again with it enabled. If the two agree byte for byte, the
RAM is very probably not responding. This costs one extra pass over a quarter
of a kilobyte and requires no write to the RAM window.

An all-`FF` or all-`00` result should still be reported on screen, because a
genuinely blank save exists — a cartridge whose battery has died reads exactly
this way, and that is information the user wants rather than an error. Say it;
do not refuse to write it.

## What is not in scope

**Restore.** That is v0.6, and it is the direction that writes to the RAM.
Nothing in this plan writes a single byte into `0xA000`-`0xBFFF`, and that
restriction is what makes the safety argument above short enough to verify.

**RTC.** v0.10. Reading MBC3 clock registers as if they were save data is a
bug this plan prevents, not a feature it adds.

**GBA saves.** Phases 12-14. SRAM, Flash and EEPROM are three different
technologies behind one address window and need a detection phase of their
own.

## Coverage, honestly, before any work starts

Every battery-backed cartridge dumped so far reports RAM size `02` — **8 KB,
one bank**. Re-checked 2026-08-28 against all nineteen images, and against
the matched official ROMs in `pocket-library/roms/` independently: ten
cartridges have battery-backed RAM and every one reports `02`. Mario's
Picross, Sangokushi, Tetris Plus, Super Mario Land 2, Moguranya, Donkey Kong,
Link's Awakening, both Oracle games and Super Mario Bros. Deluxe.

So on the cartridges available:

| Case | Testable |
|---|---|
| MBC1 + 8 KB, one bank | yes, seven cartridges |
| MBC5 + 8 KB, one bank | yes, three cartridges |
| **MBC5 + 32 KB, four banks** | **yes** - Link's Awakening DX, found 2026-08-28 |
| MBC1 or MBC3 multi-bank | no |
| RAM above 32 KB (`04`, `05`) | no |
| **MBC2's 512 nibbles** | **no** |
| **MBC3, including the RTC hazard** | **no** |

The banking path — the part with the MBC1 mode trap and the MBC3 RTC trap in
it — cannot be exercised on hardware here at all. It will be simulation-only,
exactly like MBC2, MBC3 and large MBC1 in the ROM path.

That is not a reason to skip it, but it is a reason to say so on the screen
and in the sidecar rather than let a 128 KB backup imply the same confidence
as an 8 KB one.

## Phasing

### Phase A — presence and size, display only

No file. After identification, enable RAM, read the first bytes, disable, and
put the result on the main screen along with the decoded size.

*Corrected 2026-08-28: this said "the diagnostics page", which no longer
exists. The plan is what changed, not the code. It is also the better place:
`ui_screen`'s diagnostics mux sat in the `col -> tb_char` path that has failed
setup three times, so adding rows there would have loaded the one path
the working rules say to keep clear. Four raw bytes beside the verdict, not a
page.*

Includes the disabled-then-enabled comparison, so the screen can say whether
the RAM actually responded rather than whether the reads returned something.

Done when: a cartridge with a battery shows plausible save data and a decoded
size, and a ROM-only cartridge shows no RAM. Nothing has been written to the
card and nothing has been written to the cartridge except enable and disable.

### Phase B — backup, single bank, double read

`cart_save_gb.sv` reads bank 0 twice, compares, streams to `.sav`. CRC32
displayed. Blank detection reported.

Done when: one of the 8 KB cartridges produces a file whose contents are
stable across two separate backups, and whose CRC32 matches between them.
An emulator loading the file alongside the matching ROM dump and finding the
save intact is the strongest available external check — worth doing once,
since it validates the whole chain against software that had no part in
producing it.

### Phase C — banking

Bank select for MBC1 (with the mode trap), MBC3 (with the RTC exclusion) and
MBC5. Simulation only, for the reason in the coverage table.

Done when: `tb_cart_save_gb` covers every size code and every mapper, the
MBC1 mode is proven to be restored, and MBC3 is proven never to write `08`-`0C`
to the bank register.

### Phase D — MBC2

512 nibbles, size from `cart_type` rather than `0x0149`, upper-nibble
convention documented in the source.

## Tests to write

- **`tb_gb_save_write_protect`** — the invariant. `/WR` never falls while
  `/CS` is low, asserted continuously across every transaction the reader
  issues, for every mapper and every size code. **Mutation-checked**: make the
  reader write into the RAM window and confirm the test fails.
- **`tb_cart_save_gb`** — every size code including the non-monotonic `04`/`05`
  pair; MBC1 mode set and restored; MBC3 bank never in `08`-`0C`; MBC2's
  echoing window; the double read and its mismatch path; RAM disabled on
  abort.
- **`tb_dump_engine`** through the save path, including that an aborted backup
  still disables RAM before the mode drops.
- **`tb_dump_crc32`**, shared with the GBA plan.
- **`check_pin_isolation`** unchanged — no new module names a pin.

## Wiring

Small, and mostly already parameterised:

- **A button.** Y is free: it was the self test, which has been removed, and
  X dumping the ROM beside Y dumping the save reads better than reaching for
  B. The help row is a fixed-width line of thirty characters, so
  `A scan  X dump  Y save` has to be counted before it is written.
- **`dump_engine`** gains a mode select: ROM or save. `total_bytes` comes from
  the RAM size table instead of the bank count.
- **`dump_path_gen`** gains `EXT_SAV`. The title-length input that the CGB
  filename bug and the GBA plan both need applies here too — one change, three
  callers.
- **The collision problem is worse for saves than for ROMs.** `POKEMON.sav`
  overwritten by a different cartridge is a destroyed backup, not a repeated
  dump. `HANDOFF.md` item 2 should land before this ships, not after.
