CartTools 0.9999.20261125 adds experimental Game Boy flash cartridge programming. Save restore remains **alpha**.

### What changed

- **GB flash cartridge programming**, experimental. Erases, writes and reads back a 32 KiB image on a Ferrante Crafts flash cartridge with an SST39SF010A. Two three-second Start + R holds. See [Flash](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/v0.9999.20261125/docs/FLASH.md).
- **Flash ID probe** with the write enable on /WR (hold Start) or on connector pin 31 (hold Start + L). It sends no erase or program command.
- `instructions.txt` and `info.txt` describe flashing and list Oracle of Seasons among the verified restores.

### Pin 31

These cartridges wire the flash write enable to connector pin 31, the Game Boy audio input, which the Pocket samples with an audio ADC. The pin 31 ID probe and every write drive it as a 5 V digital output. This was not measured before use. The risk to the Pocket is yours.

### Verified on hardware

| | |
|---|---|
| GB flash write | Three 32 KiB images to one Ferrante Crafts cartridge, each over the last, each read back equal and booted: Tetris (World) (Rev 1) and two builds of a homebrew ROM |
| Save restore | The Legend of Zelda: Oracle of Seasons, MBC5 8 KiB, an edited copy of the cartridge's own save |

The flash results are from build `5D6E`, which is the published bitstream. The Oracle of Seasons restore is from build `7D63`, the previous release. Dumping, save backup and save restore were not repeated on `5D6E`.

### Scope

32 KiB images only. A flash ID other than `BF B5` is refused. Cartridges with the write enable on /WR can be identified but not written. Install all three folders from the ZIP into the Pocket card root, merging with the existing folders.
