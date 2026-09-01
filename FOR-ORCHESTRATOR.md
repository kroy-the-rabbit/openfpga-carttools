# For the orchestrator

What `pocket-dev` needs from `pocket-cartridge`. Written 2026-09-01. The full
record is `docs/HANDOFF.md`, then `docs/STATUS.md`.

## What changed

**GBA save backup works, and it needs no write to a cartridge.** Verified on
two cartridges, each loaded in mGBA with its own state intact, which is the
only thing that can prove a save.

| Path | State |
|---|---|
| Save type scan, by reading the ROM for the SDK signature | verified, three cartridges refused correctly |
| Flash 64 KiB | verified, Golden Sun |
| SRAM 32 KiB | verified, Zero Mission |
| 128 KiB Flash, EEPROM | refused, both need a write |

**GB/GBC dumping widened.** Twenty-six cartridges now, 32 KB to 4 MB. MBC5
above 1 MB is verified for the first time, so the ninth bank bit at `0x3000`
runs on hardware. Cartridge types `19` and `1E` added, and the 8 KB
single-bank save size read on two cartridges.

## What the orchestrator has to route elsewhere

1. **The core and the picker derive a dump's basename differently**, and a real
   card proves it. `dump_path_gen.sv` keeps `A-Z0-9`, uppercases `a-z` and
   turns everything else into `_`. `cheatgui/dumps.py`'s `core_stem` keeps `-`
   and does not uppercase, following `docs/FILE-FORMATS.md` rather than the
   core. `DQM2-R` is the first title with a character outside `A-Z0-9`: the
   card says `DQM2_R_____BQLJ.gbc`, the picker derives `DQM2-R_____BQLJ`, and
   its `Dump.renamed` calls the file hand-renamed. Decide which side moves,
   then fix it in the picker's session. Those cartridges are also the real
   fixtures its `tests/test_dumps.py` was meant to be pinned against;
   `cart-dumps/`, `roms/` and `saves/` there are still empty.

2. **`pocket-cartridge` now has GBA saves the picker will see.** `.sav` files
   beside `.gba` files, 32 KiB and 64 KiB. Nothing in the picker knows about
   GBA saves yet.

## Open here, not for the orchestrator

- `scripts/verify_dump.py` checks a `.sav` against `0x0149` of the ROM beside
  it, a Game Boy header field, so it fails every GBA save. Same class of
  defect as the one just fixed in the core.
- `scripts/seed_sweep.sh` cannot run: it calls `docker` and writes a
  `build_output/` layout this repo no longer has.
- Two cartridges with dead save batteries, `HAMUPARA2__BHMJ` and
  `PNBALFRENZYVM2E`. Not core faults.
- The `ST_WRITE` abort defect in `gba_cart_bus` gates 128 KiB Flash, EEPROM
  and every restore path.

## What this cost, and the rule that came out of it

Two builds went to the card broken and one lied about a save that was correct.
All three were the same mistake: `gba_save_scan` was written from
`cart_dump_gba`'s shape, which is the tidiest master on that bus, instead of
`gba_size_probe`, which does the same job at the same point in the sequence
and carries a `cart_mode` input, a mode wait with a timeout and an abandon
guard, each one commented with the hang it already suffered.

**A new bus master gets read against the most bruised master on the same bus,
not the tidiest one.**
