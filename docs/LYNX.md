# Atari Lynx ROM dumping

CartTools reads Atari Lynx ROMs through the official Analogue Lynx adapter.
On build 7D63, NFL Football (Euro, USA) was captured twice, byte-identical, and
the ROM matched the MAME reference size, SHA-1 and CRC32. One cartridge has
been tested.

The adapter reports APF ID `0x03`, raw report `0x01010003`.

## Dump

1. Power off. Fit the adapter and the cartridge.
2. Launch CartTools through **Play Cartridge**. If the screen does not show
   `ATARI LYNX CARTRIDGE`, quit and launch again.
3. Press X. The capture takes about five seconds.
4. Wait for `DUMP COMPLETE` and `SELECTED RANGE CRC AGREES`.

A cancels an active capture. Files use the first free `LX0000.lyx`-style name
under `Assets/carttools/common/`. Existing files are never overwritten.

## The file

| | |
|---|---|
| Length | Always 512 KiB: 256 blocks of 2048 bytes |
| Header | None. No `.lnx` header is added |
| 128 KiB ROM | Each block holds the same 512 bytes four times |
| 256 KiB ROM | Each block holds the same 1024 bytes twice |
| 512 KiB ROM | No repetition |

`SELECTED RANGE CRC AGREES` means two complete reads gave the same CRC32. It
does not compare against a reference and does not read the file back from SD.

## Verify

```sh
scripts/verify_dump.py LX0000.lyx
scripts/verify_dump.py --compare LX0000.lyx LX0001.lyx
```

`verify_dump.py` reports the block size, the ROM size, and the `folded` CRC32
and SHA-1 of the ROM without repetition. Match the folded hashes against a
No-Intro or MAME Lynx record. `every block identical` means the block number
did not reach the cartridge.

Reference for the tested cartridge:
[NFL Football (Euro, USA)](https://github.com/mamedev/mame/blob/954def46685cd0276671138fbd032036b1a771fb/hash/lynx.xml),
262144 bytes, CRC32 `006fd398`, SHA-1 `caea445bddcf75bcbe13920718279220d1acb869`.

## Limits

* Reads only. No Lynx cartridge pin is written and no save is handled.
* A Lynx cartridge has no header or checksum. Stable reads that are not blank
  identify it.
* Cartridges above 512 KiB and cartridges that bank through AUDIN are not
  supported.
