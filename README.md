# Cartridge tools for Analogue Pocket

A Pocket core that reads cartridges through the handheld's own cartridge slot.
It identifies Game Boy, Game Boy Color and Game Boy Advance cartridges, dumps
their ROMs to the SD card, and backs up Game Boy and Game Boy Color saves. It is
not an emulator and it will not play anything.

**Based on commit `0e1b2e1` of the `feat/cartridge-support` branch of
[Rai/openfpga-GBA](https://github.com/Rai/openfpga-GBA)**, which is a fork of
[mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) at
`v0.4.0`, which is a Pocket port of
[GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer). Rai's branch is where
the cartridge bus came from; the emulator around it is what got deleted.
[docs/PROVENANCE.md](docs/PROVENANCE.md) records exactly what was inherited and
what was written here.

## What works

| | |
|---|---|
| GB / GBC cartridge identification | **works** |
| GBA cartridge identification | **works** |
| GB / GBC ROM dumping | **works**, twenty-six cartridges, 32 KB to 4 MB |
| GBA ROM dumping | **works**, fifteen cartridges, 4 to 16 MB |
| GBA ROM size detection | **works**, measured from open bus, and every size agrees with the published record |
| CRC32 shown on the device | **works**, both platforms |
| Image checked against the cartridge's own checksum | **works**, GB / GBC only |
| Files named `.gb` / `.gbc` / `.gba` | **works** |
| GB / GBC save backup | **works**, six cartridges backed up, five loaded in an emulator with their state intact. The sixth is refused by its own game, a dead battery |
| Save RAM banking, to 128 KB | **works** at 8 KB one bank and 32 KB four banks; 64 KB and 128 KB built, untested |
| GBA save backup | **works**, two cartridges: 64 KiB Flash and 32 KiB SRAM, each loaded in an emulator with its state intact. Needs no write to the cartridge. 128 KiB Flash and EEPROM refused, both need a write |
| Save restore | not started |
| MBC3 RTC | not started |
| MBC2, MBC3, MBC1 above 512 KB | simulation only, no cartridge to test |
| MBC2's 512 nibbles of save RAM | refused, and the screen says so |
| GBA cartridges above 16 MB | untested |
| Reading a file back off the card to verify it | not built |
| Sidecar metadata | specified in [docs/FILE-FORMATS.md](docs/FILE-FORMATS.md), not written |
| Two cartridges with the same title | the second dump silently overwrites the first |
| CGB filenames | four bytes of manufacturer code land in the name |

## Why cartridge control stays in RTL

Everything this core gets right or wrong comes down to two things: **when an
edge happens, and which way a pin is pointing.** Both are hardware properties,
so they live in hardware, where they can be held to the cycle and checked at
the connector rather than inferred.

**Direction is the dangerous half.** The Pocket's level translators are
switched per bank of eight pins, not per pin, so a single wrong direction bit
does not misread anything, it drives eight outputs into a cartridge that is
also driving them. That is not a bug you observe and fix afterwards; it is
current through somebody's Game Boy cartridge. Connector pin 30 makes the same
point from the other side: it is held low by a clamp that keeps a Game Boy
cartridge in reset, and the core has to release it deliberately.

So one module owns the pins. `cart_pins.sv` makes every direction decision and
is the only file allowed to read or assign a cartridge pin. Two files above it,
`core_top.sv` and the APF wrapper, may name one only in a port declaration or a
named port connection, because that is how the pins reach the owner at all;
they may not touch a value. Everything below, `gba_cart_bus.sv` and every other
protocol engine included, sees a flat interface and cannot reach a pin even by
accident.

`tools/sim/check_pin_isolation.py` enforces exactly that, on the six
`cart_tran_*` signals plus `cart_pin30_pwroff_reset` and their `_dir`
companions. `make test` discovers it automatically and CI runs `make test`, so
the rule is checked rather than remembered. It is not wired into `make cart`:
a local bitstream can be built without it, which is worth knowing before
trusting a build you did not test first. Widening the allowlist is a visible
edit to a file that says it has to be argued for.

**Timing is the half that has to be exact.** A cartridge answers to edge
spacing measured in tens of nanoseconds, and it answers whether or not the
reader was ready. Software on a soft CPU can be correct on average and wrong on
the cycle that mattered, because a fetch stall or an interrupt lands where it
likes. In RTL the spacing is a counter, and the same counters ship as run in
simulation: `tb_gba_cart_timing.sv` exercises the parameters the build uses,
separately from the bus tests that turn them down to make the suite fast.

**The invariants are small enough to state in one sentence each, which is what
makes them checkable at every clock edge.**

| Invariant | Checked by |
|---|---|
| `/WR` never falls while `/CS` is low, for a whole save read | `tb_gb_save_write_protect.sv` |
| `WR#` never reaches a cartridge outside the three writable spaces | `tb_gba_cart_write_protect.sv` |
| What the connector actually sees across a full probe, empty slot included | `tb_probe_pins.sv` |
| No module outside the cartridge layer touches a cartridge pin | `check_pin_isolation.py` |

That is the argument for RTL and it is not a general one. Everything above the
bus, meaning mappers, filenames, hashing and menus, is better as software, and
[docs/LANDSCAPE.md](docs/LANDSCAPE.md) says so plainly: a RISC-V SoC already
exists for exactly this and would have been a legitimate base. Staying in RTL
cost four sessions on the SD write path alone, which that document also
records. The trade was made for the two operations that cannot be given back
once they go wrong.

## Early, and why

Twelve cartridges have been re-dumped and every one came back byte for byte
identical, so the dump path reproduces. But three cartridges have at some point
produced a corrupt image, most likely from dirty contacts, and one was caught
only because the core compares the image against the cartridge's own checksum:
the header checksum on the row above it passed. Nothing reads a file back off
the card, so a fault between the core and the SD write is invisible to
everything above.

Every dumped image passes the checks the cartridge itself carries: the Nintendo
logo, the header checksum, and for Game Boy the global checksum.

**And every one of the forty-one images matches a published record.** Checked
2026-09-02 against the No-Intro DATs for Game Boy, Game Boy Color and Game Boy
Advance, 7,572 entries: all forty-one dumps are present by CRC32, and the size
agrees too. That is the strongest evidence this project has, because it is
external to the core, external to this repo, and it covers the GBA images,
which carry no checksum of their own. [docs/STATUS.md](docs/STATUS.md) has the
evidence for each claim and [docs/HANDOFF.md](docs/HANDOFF.md) has what is
left.

## What this core writes to a cartridge

**It never writes save data to a cartridge.** It dumps; it does not restore.
There is no restore path in it, and the byte that would carry save data back has
nowhere to go.

It does write to mapper registers, in ROM space, because the hardware offers no
other way to read:

* **bank registers**, which is how a Game Boy cartridge is banked and the only
  way to read past bank 0;
* **the save RAM gate**, `0x0A` to open it and `0x00` to close it, because a
  cartridge answers in the RAM window only while the gate is open. It is closed
  again on every exit, including an abort.

Nothing this core does puts a byte into `0xA000` to `0xBFFF` or into GBA ROM
space. `gb_cart_bus` derives `/CS` from the address rather than taking it from
the caller, and `tb_gb_save_write_protect` checks at the connector pins, every
clock edge of a full read, that `/WR` never falls while `/CS` is low.

## Versions

The five projects in this set share one version number, and this core is part of
that set. It never carried an inherited number, so nothing here is being
renumbered; the cores it sits beside are.

The set is at **0.9999**. The next release is 0.99991, then 0.99992, and so on:
each one adds to the tail rather than climbing toward a round number. Nothing
here reaches 1.0, because 1.0 is a claim to be finished and none of this is.

What 1.0 would mean for this core is listed below, and it is a long way off.

## What 1.0 would mean

* Detect standard GB, GBC and GBA cartridges
* Dump supported ROMs to SD, and verify the dump
* Back up supported save types, and verify the backup
* Restore saves, always taking a backup first, always verifying afterwards
* Handle MBC3 RTC data
* Refuse unsupported or ambiguous hardware rather than guessing

## Installation

Prebuilt cores are on the [Releases](../../releases) page. Download
`kroy.CartTools_<version>.zip`, not the "Source code" archives: the bitstream is
built by CI rather than committed, so a core installed from a source archive is
listed by the Pocket and cannot start.

This core installs as `Cores/kroy.CartTools`. Copy the `Assets`, `Cores` and
`Platforms` folders to the root of the SD card. Finder on macOS *replaces*
folders rather than merging them the way Windows does, which will delete the
ROMs already in `Assets`, so copy the folders inside those three rather than
dragging the three themselves.

There is no boot ROM to find. This core needs none, because it does not run
games.

## Usage

Put a cartridge in, launch the core, and choose what to do with it. Dumps land
on the card under `/Assets/carttools/common/`. SELECT shows the raw header bytes
for anything that identifies itself.

## Checking what came off the cartridge

```sh
scripts/verify_dump.py FILE...          logos, checksums, sizes, CRC32
scripts/verify_dump.py --compare A B    two reads of the same cartridge
scripts/match_dats.py                   match every dump to a published record
tools/podman/play-dump.sh ROM [SAV]     play it in mGBA, in a container
```

**A Game Boy or Game Boy Color dump proves itself.** The header checksum and
the global checksum were written at manufacture, they cover the image, and this
core checks both on the device.

**A Game Boy Advance dump does not, and cannot.** A GBA cartridge carries a
Nintendo logo, a header complement over the first 29 bytes, and the fixed `0x96`
byte, and nothing that covers the ROM itself. `verify_dump.py` says so where it
checks the logo: no checksum in a GBA cartridge covers those bytes, which is
what makes the logo an independent check rather than a circular one. The CRC32
this core shows for a GBA image is computed from the bytes it just read, so it
proves a second read matches the first, not that either matches the cartridge.
Matching a published record, or dumping twice and comparing, is the evidence
there is, and `match_dats.py` is the first of those: it checks every dump
against a No-Intro DAT by CRC32 and size. The DAT is external to this core and
to this repo, so it cannot agree with a dump for the same reason the dump is
wrong. **Save RAM
carries no checksum of any kind**, so the only thing that can prove a `.sav` is
loading it beside its ROM and seeing the game's own state come back. That is
what `play-dump.sh` is for, and it is what moved save backup from built to
verified.

`verify_dump.py` covers what a checksum can, computed independently of the core,
plus the one structural failure the device cannot see: **every bank identical**,
which is what a bank select that did not take produces, a file of exactly the
right length holding bank 0 over and over. It cannot prove a save is correct and
says so.

## The desktop app

[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools) is the desktop
side of this set, and it is the other half of the dumping workflow. This core
can read a title out of a header and sanitise it, but it cannot list a
directory, so it cannot tell that two cartridges named the same have overwritten
each other or that four bytes of manufacturer code are stuck to a filename. The
app can, because it is the only part that sees the bytes after they land.

It identifies a dump by SHA-1 against a No-Intro DAT, files it into a library
under its real name, keeps the core's original beside it as evidence of what was
actually produced, and only deletes the card's copy after comparing the two byte
for byte.

**Those features appear in the app only when this core is on your card.** The
app always offers to install it and never installs it for you, so putting it
there is the whole of opting in.

You do not need any of it. The dumps are ordinary files on the card.

## Layout

```
src/fpga/
  core/        Pocket top level, APF bridge glue, clocks, the two cartridge buses
  services/
    identify/  header readers and the platform probe
    dump/      the readers, the size probe, buffering, checksums, the file writer
  ui/          text renderer and screen
  apf/         the Pocket host interface, inherited
tools/         simulation harness and the containerised build
docs/          design notes, hardware notes, milestone records
```

There is no `src/fpga/cart/`; the buses live in `core/` under `cart_pins.sv`,
which is the only module allowed to drive a connector pin.

## Documentation

| | |
|---|---|
| [plan.md](plan.md) | the phase plan |
| [docs/STATUS.md](docs/STATUS.md) | current position and every known defect |
| [docs/HANDOFF.md](docs/HANDOFF.md) | traps and next steps |
| [docs/BRINGUP.md](docs/BRINGUP.md) | the first hardware test and how to read the result |
| [docs/LANDSCAPE.md](docs/LANDSCAPE.md) | prior art, and the architecture this project did not take |
| [docs/FILE-FORMATS.md](docs/FILE-FORMATS.md) | what gets written to the card |
| [docs/UI.md](docs/UI.md) | the text layer contract |
| [docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md) | the cartridge connector, verified claims separated from assumed |
| [docs/APF-NOTES.md](docs/APF-NOTES.md) | the Pocket host interface |
| [docs/PROVENANCE.md](docs/PROVENANCE.md) | what came from where |
| [docs/SALVAGE.md](docs/SALVAGE.md) | deleted files and how to get them back |
| [docs/COMPANION-APP-PLAN.md](docs/COMPANION-APP-PLAN.md) | the desktop side |

## Building from source

Quartus runs in a container and nothing is installed on the host:

```sh
make cart                 # -> build/cart/{bitstream.rbf_r, sd/, *.zip, report.txt}
make cart SKIP_COMPILE=1  # repackage existing outputs without running Quartus
make cart SEED=2          # re-run the fitter with a different placement seed
make report               # regenerate build/cart/report.txt
make shell                # interactive shell in the Quartus container
```

Simulation, also containerised. Every cartridge-facing module is expected to
have a testbench, because the hardware it talks to cannot be put in CI and a
wrong write to a cartridge is not recoverable:

```sh
make sim-image            # build the Icarus Verilog container, once
make test                 # run the testbench suite
make sim-shell            # interactive shell with the repo at /work
```

The build fails if the design misses timing. Quartus exits 0 on negative slack,
so the harness checks worst-case slack itself and stops, because a bitstream
with negative slack may work on one bench and fail on somebody's handheld.

## Credits

This core is a subtraction from other people's work.

| | |
|---|---|
| [GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer) | the original FPGA GBA |
| [mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) | the Pocket port, at `v0.4.0` |
| [Rai/openfpga-GBA](https://github.com/Rai/openfpga-GBA) | the `feat/cartridge-support` branch, which is where the cartridge bus, the `cart_mode` plumbing and the header read came from |
| [No-Intro](https://no-intro.org/) | the reference data a dump is identified against. None of it is shipped here |
| [Analogue openFPGA](https://www.analogue.co/developer) | the Pocket framework |

## License

**GPL-2.0**, inherited from the donor core through
[Rai/openfpga-GBA](https://github.com/Rai/openfpga-GBA),
[mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) and
[GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer).

`src/fpga/apf/` is not GPL. Those files are Analogue's Pocket Framework,
supplied under Analogue's own software licence agreement and the Pocket EULA
linked from their headers, which provide that where the MIT or GNU licences must
apply, those prevail.

Binary releases here are built by CI from a tagged commit of this repository,
which is the corresponding source for them.
