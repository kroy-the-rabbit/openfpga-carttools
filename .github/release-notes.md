**Download `kroy.CartTools_<version>.zip` below**, not the "Source code"
archives. Those are the repository, and the bitstream is not committed, so a
core installed from one is listed by the Pocket but cannot start.

Unzip and merge `Assets`, `Cores` and `Platforms` into the root of the SD card.
On macOS, Finder **replaces** a folder instead of merging it, which deletes the
ROMs already in `Assets`; copy the folders inside the three rather than the
three themselves. There is no boot ROM to find: this core runs no games.

Dumps land in `/Assets/carttools/common/`, named from the cartridge header.
The `<version>` in the filename is the exact commit the bitstream was built
from, and `Cores/kroy.CartTools/core.json` carries the same string.

## What this build has done

**Alpha.** Everything below was measured on cartridges through the Pocket's
own slot, and every image was checked against a record this project does not
control. The full record, cartridge by cartridge, is
[docs/CARTRIDGE-CORPUS.md](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/main/docs/CARTRIDGE-CORPUS.md).

| | |
|---|---|
| ROM images | **41**, all retained: 15 Game Boy, 11 Game Boy Color, 15 Game Boy Advance |
| Matched to No-Intro | **41 of 41**, by CRC32 and byte length, against 7,572 DAT entries |
| GB / GBC | 32 KB to 4 MB across five mapper families: ROM-only, MBC1, MBC1+RAM+battery, MBC5, MBC5+RUMBLE |
| GBA | 4, 8 and 16 MB, each size measured from open bus and each agreeing with the record |
| Reproduces | 12 GB/GBC cartridges and 2 GBA cartridges re-dumped byte for byte identical |
| Rejected reads | 2, both Yu-Gi-Oh! through dirty contacts, both failing the global checksum; the clean retry matched the record exactly |

**Saves.** 27 retained from 26 cartridges, each checked the only way a save can
be, by loading it in mGBA beside its own ROM and finding the game's state
intact.

| | |
|---|---|
| GB / GBC | 15 cartridges, 8 KiB and 32 KiB four-bank. One, Tetris Plus, shows no recognisable state and is carried as unverified; a depleted battery is possible and unproven |
| GBA SRAM 32 KiB | 2, Metroid: Zero Mission and Kirby: Nightmare in Dream Land |
| GBA Flash 64 KiB | 1, Golden Sun |
| GBA EEPROM 512 bytes | 4, Super Mario Advance, Harry Potter, Magical Quest, Shrek |
| GBA EEPROM 8 KiB | 4, A Link to the Past & Four Swords, The Minish Cap, NHL 2002, SimCity 2000 |

None of it writes to the cartridge. Flash and SRAM are read plainly, and the
EEPROM reader cannot form a write: its two command bits are constants, and the
simulation model kills the run if a write prefix is ever seen. EEPROM capacity
is measured rather than assumed, since a chip of either size answers a request
of either width; the discriminator is repeated block data under wide addressing.

**Refused, and the screen says so:** 128 KiB Flash, which needs a bank-select
write, and MBC2's 512 nibbles of save RAM. **Simulation only, no cartridge to
test:** MBC2, MBC3, MBC1 above 512 KB.

## What changed since v0.9999.52305c7

* **GBA EEPROM backup**, at both capacities, with the byte order that mGBA
  reads back correctly. A save is emitted in the order the chip delivers it.
* **GBA detection no longer fails intermittently.** The floating safety-gate
  bus is precharged to `FF` while both strobes are idle and released during
  setup. The cartridge that reproduced the failure could not be made to fail
  after the fix, and the two cartridges that had been marked scan-unstable are
  cleared.
* The screen names which probe failed, and hides a stale filename until the
  path is ready.
* The save dump's CRC32 is asserted in simulation at two lengths, mutation
  checked both ways.

## What it must not be taken for

A save is read **once**. The double read is not built, nothing reads a file
back off the card, and there is no restore path on either platform. A `.sav`
from this core is evidence, not yet a backup you would rely on.

This core writes to a cartridge in two places, both mapper registers in ROM
space: bank registers, which is how a Game Boy cartridge is banked, and the
save RAM gate on a save backup, which is closed again on every exit. It never
writes to GBA ROM space and never writes a byte into cartridge RAM.

## Checking a download

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

The zip and the timing report are the only artifacts. Read
[docs/STATUS.md](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/main/docs/STATUS.md)
for what is proven and how, and
[docs/HANDOFF.md](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/main/docs/HANDOFF.md)
for what is not.
