CartTools 0.9999.20260920 adds Game Gear ROM dumping and MBC5 save restore. Save restore remains **alpha**.

### What changed

- **Game Gear ROM dumping** through the official Analogue adapter, with 256 and 512 KiB profiles and a CRC reread of the selected range. ROM only; saves are not supported. See [Game Gear](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/v0.9999.20260920/docs/GAME-GEAR.md).
- **MBC5 save restore**, 8 KiB and 32 KiB (type `1B`, ROM up to 4 MiB).
- **Cartridge pin timing no longer depends on the fit.** Every cartridge output and direction bit is now registered in its I/O cell. A development build that met Quartus timing lost MBC5 bank-select writes on hardware; this removes that class of failure.
- The GBA probe fix from artifact revision `0.9999.20260914.1` (`57513fc`) is now on `main`.
- An unrecognised adapter shows its APF report and the cartridge bus stays idle.

### Verified on hardware

| | |
|---|---|
| Restore, MBC3 32 KiB | Pokemon Silver |
| Restore, MBC5 32 KiB | Dragon Warrior III, post-restore dump byte-identical to the input |
| Restore, MBC5 8 KiB | Shadowgate Classic, post-restore dump byte-identical to the input |
| GB / GBC ROM dump | Shadowgate Classic, Dragon Warrior III, Pokemon Silver |
| GBA ROM and save dump | Metroid Zero Mission, SimCity 2000 |
| Game Gear ROM dump | Sonic the Hedgehog 2 (World), 512 KiB, matches the MAME reference; World Series Baseball and Arch Rivals on the earlier 563E build |

These results are from builds `6BDB` and `9302`. The published bitstream is a rebuild of the same logic from the release commit, with only comments and the build stamp changed; it met timing and was not separately re-run on hardware.

### Scope

MBC1 8 KiB and other MBC3 and MBC5 cartridges are implemented but untested. **MBC3 RTC state and GBA saves are not restored.** Read the [save restore guide](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/v0.9999.20260920/docs/SAVE-RESTORE.md) before writing to a cartridge, and keep the `PRE*.sav` recovery files. Install all three folders from the ZIP into the Pocket card root, merging with the existing folders.
