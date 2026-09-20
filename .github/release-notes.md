CartTools 0.9999.20260920.1 adds Atari Lynx ROM dumping. Save restore remains **alpha**.

### What changed

- **Atari Lynx ROM dumping** through the official Analogue adapter. Fixed 512 KiB capture with a CRC reread, saved as `LX0000.lyx`. ROM only. See [Lynx](https://github.com/kroy-the-rabbit/openfpga-carttools/blob/v0.9999.20260920.1/docs/LYNX.md).
- `scripts/verify_dump.py` checks a `.lyx` and reports the ROM size and hashes without the repetition a smaller ROM leaves in the file.
- `instructions.txt` lists all three verified restore cartridges.

### Verified on hardware

| | |
|---|---|
| Lynx ROM dump | NFL Football (Euro, USA), two captures byte-identical, ROM matches the MAME reference size, CRC32 and SHA-1 |

This result is from build `7D63`, which is the published bitstream. Game Boy, Game Boy Advance, Game Gear and save restore results are from builds `6BDB` and `9302` and were not repeated on `7D63`.

### Scope

One Lynx cartridge has been tested. Cartridges above 512 KiB and cartridges that bank through AUDIN are not supported. Install all three folders from the ZIP into the Pocket card root, merging with the existing folders.
