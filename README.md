# Cartridge tools for Analogue Pocket

Reads cartridges through the Pocket's cartridge slot.

* Identifies GB, GBC and GBA cartridges
* Dumps ROMs to the SD card
* Backs up saves
* Restores GB / GBC saves (alpha)
* Dumps Game Gear and Atari Lynx ROMs through the official Analogue adapters

It does not play games.

## Status

Release `v0.9999.20260920.1`.

| Feature | Status |
|---|---|
| GB / GBC / GBA identification | Tested |
| GB / GBC ROM dump | Tested, 32 KiB to 4 MiB; ROM-only, MBC1, MBC3, MBC5 |
| GBA ROM dump | Tested, 4 to 16 MiB; larger untested |
| Game Gear ROM dump | Tested, 256 and 512 KiB. See [Game Gear](docs/GAME-GEAR.md) |
| Atari Lynx ROM dump | Tested, one cartridge, 256 KiB. See [Lynx](docs/LYNX.md) |
| CRC32 on the device | ROMs and saves |
| On-device checksum check | GB / GBC only |
| GB / GBC save backup | Tested at 8 and 32 KiB; 64 and 128 KiB untested |
| GBA save backup | Tested: 32 KiB SRAM, 64 KiB Flash, 512 byte and 8 KiB EEPROM. 128 KiB Flash refused |
| Save restore | Alpha. Verified: Pokemon Silver (MBC3 32 KiB), Dragon Warrior III (MBC5 32 KiB), Shadowgate Classic (MBC5 8 KiB). MBC1 8 KiB and other MBC3 / MBC5 untested. See [save restore](docs/SAVE-RESTORE.md) |
| Unknown adapter | APF report shown, bus idle |
| MBC2, MBC1 above 512 KiB | Simulation only |
| MBC2 save RAM | Refused |
| MBC3 RTC, GBA save restore, Game Gear and Lynx saves | Not supported |
| Readback of dumped files | Not built |
| Sidecar metadata | Specified in [FILE-FORMATS](docs/FILE-FORMATS.md), not written |

Known defects:

* Two native cartridges with the same title: the second dump overwrites the first.
* CGB filenames carry four bytes of manufacturer code.

Verified cartridges are listed in [CARTRIDGE-CORPUS](docs/CARTRIDGE-CORPUS.md).

## Cartridge writes

| Operation | Writes |
|---|---|
| GB / GBC dump | Bank registers; save RAM gate `0x0A` open, `0x00` close |
| GBA ROM dump | None |
| GBA save backup | EEPROM read requests only; no save data |
| Game Gear dump | Sega ROM-control registers |
| Lynx dump | None |
| Save restore | GB / GBC save RAM, after a verified recovery file and a three-second hold |

## Versions

Versions use `0.9999.YYYYMMDD`, where the date is UTC. Release tags add `v`,
for example `v0.9999.20260913`. A second release on one date adds `.1`. Each project releases independently.
The source commit and bitstream checksums are recorded in build provenance.
A published version is not reused for a different build.

## Installation

1. Download `kroy.CartTools_<version>.zip` from [Releases](../../releases),
   not the "Source code" archives.
2. Merge its `Assets`, `Cores` and `Platforms` folders into the SD card root.
   On macOS, copy the folders inside those three; Finder replaces rather than
   merges.

Installs as `Cores/kroy.CartTools`, under **Tools**. No boot ROM.

## Usage

1. Power off before changing a cartridge or adapter.
2. Insert the cartridge and launch the core. For Game Gear and Lynx, launch
   through **Play Cartridge**.
3. Choose an action. SELECT shows the raw header bytes.

Dumps land in `/Assets/carttools/common/`.

* [Game Gear guide](docs/GAME-GEAR.md)
* [Lynx guide](docs/LYNX.md)
* [Save restore guide](docs/SAVE-RESTORE.md)

If a dump fails its checksum, copy it off the card before dumping again, and
clean the cartridge contacts.

## Checking a dump

Run from an activated project venv.

```sh
scripts/verify_dump.py FILE...          logos, checksums, sizes, hashes
scripts/verify_dump.py --compare A B    two reads of the same cartridge
scripts/match_dats.py                   match every dump to a published record
tools/podman/play-dump.sh ROM [SAV]     play it in mGBA, in a container
```

| Dump | Check |
|---|---|
| GB / GBC ROM | Header and global checksums |
| GBA ROM | No-Intro DAT match, or two reads compared |
| Game Gear ROM | DAT match, or `--expect-size`, `--expect-sha1`, `--expect-crc32` |
| Lynx ROM | Folded hashes from `verify_dump.py` against a No-Intro or MAME record, or two reads compared |
| Save | Load it beside its ROM with `play-dump.sh` |

`match_dats.py` accepts zipped or extracted XML DATs. CRC-only records cannot
verify a dump.

```sh
scripts/verify_dump.py GG0000.gg --expect-size 524288 --expect-sha1 dabb452e416b4fa9cb83d8ddd307c2a32c3a1a7f --expect-crc32 95a18ec7
```

Reference: [Sonic the Hedgehog 2 (World)](https://github.com/mamedev/mame/blob/954def46685cd0276671138fbd032036b1a771fb/hash/gamegear.xml#L8086).

## The desktop app

[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools) identifies
dumps against a No-Intro DAT, files them into a library under their real names
and verifies the copy before deleting from the card. Optional. Its dump
features appear when this core is on the card.

## Layout

```
src/fpga/
  core/        Pocket top level, APF bridge glue, clocks, cartridge buses
  services/
    identify/  header readers and the platform probe
    dump/      readers, size probe, buffering, checksums, file writer
    restore/   save writer, guard, file I/O
  ui/          text renderer and screen
  apf/         the Pocket host interface, inherited
scripts/       dump verification, DAT matching, restore input preparation
tools/         simulation harness and the containerised build
docs/          reference documentation
```

`cart_pins.sv` is the only module that touches a connector pin.
`tools/sim/check_pin_isolation.py` enforces it.

## Documentation

| | |
|---|---|
| [SAVE-RESTORE](docs/SAVE-RESTORE.md) | writing a save to a cartridge |
| [GAME-GEAR](docs/GAME-GEAR.md) | Game Gear dumping |
| [LYNX](docs/LYNX.md) | Atari Lynx dumping |
| [CARTRIDGE-CORPUS](docs/CARTRIDGE-CORPUS.md) | verified cartridges |
| [FILE-FORMATS](docs/FILE-FORMATS.md) | files written to the card |
| [UI](docs/UI.md) | the text layer |
| [HARDWARE-NOTES](docs/HARDWARE-NOTES.md) | the cartridge connector |
| [APF-NOTES](docs/APF-NOTES.md) | the Pocket host interface |
| [LOGO-BYTES](docs/LOGO-BYTES.md) | the Nintendo logos |
| [PROVENANCE](docs/PROVENANCE.md) | what came from where |
| [DONOR-README](docs/DONOR-README.md) | the donor core's README |

[Engineering history](https://github.com/kroy-the-rabbit/pocket-engineering/tree/main/carttools)
is private.

## Building from source

Quartus and Icarus Verilog run in containers.

```sh
make cart                 # -> build/cart/{bitstream.rbf_r, sd/, *.zip, report.txt}
make cart SKIP_COMPILE=1  # repackage without running Quartus
make cart SEED=2          # different placement seed
make report               # regenerate build/cart/report.txt
make shell                # shell in the Quartus container
make sim-image            # build the simulation container, once
make test                 # testbench suite
make sim-shell            # shell in the simulation container
```

The build fails if the design misses timing.

## Where to report a problem

Open an issue here with the cartridge, the build stamp shown on screen and,
for a bad dump, the `verify_dump.py` output.

## Credits

Based on commit `0e1b2e1` of the `feat/cartridge-support` branch of
[Rai/openfpga-GBA](https://github.com/Rai/openfpga-GBA), a fork of
[mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) at
`v0.4.0`, which is a Pocket port of
[GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer). See
[PROVENANCE](docs/PROVENANCE.md).

| | |
|---|---|
| [GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer) | the original FPGA GBA |
| [mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) | the Pocket port, at `v0.4.0` |
| [Rai/openfpga-GBA](https://github.com/Rai/openfpga-GBA) | the `feat/cartridge-support` branch: the cartridge bus, the `cart_mode` plumbing and the header read |
| [No-Intro](https://no-intro.org/) | reference data for identifying dumps. Not shipped |
| [MAME](https://github.com/mamedev/mame) | Game Gear and Lynx reference hashes. Not shipped |
| [sfiera/pocket-adapters](https://github.com/sfiera/pocket-adapters) | the Game Gear and Lynx adapter pinouts |
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

Releases include the package, timing report, checksums and `BUILD.json`, which
records the build commit and bitstream SHA-256.
