# GB flash cartridge programming

Experimental. CartTools writes a 32 KiB ROM image to a Ferrante Crafts Game Boy
flash cartridge, labelled 64 KB. Three writes to one cartridge on build 5D6E,
each over the last, each read back equal and booted:

| Image | CRC32 |
|---|---|
| Tetris (World) (Rev 1) | `46DF91AD` |
| Homebrew, ROM only, title `WICK` | `37758195` |
| The same, a later build | `FEEC30C4` |

| | |
|---|---|
| Flash | SST39SF010A, ID `BF B5` |
| Write enable | Connector pin 31, not /WR |
| Image | Exactly 32,768 bytes. Larger images are not supported |
| Other flash IDs | Refused |

**Pin 31.** On a Game Boy this pin is the cartridge audio input, and the Pocket
samples it with an audio ADC. CartTools drives it as a 5 V digital output for
the pin 31 ID probe and for the whole write. The risk to the Pocket is yours.

## Controls

Every action is a three-second hold on an identified GB cartridge.

| Hold | Action |
|---|---|
| Start | ID probe with write enable on /WR |
| Start + L | ID probe with write enable on pin 31 |
| Start + R | Load the image; held again, erase, write and verify |

## Write

1. Copy the image to `Assets/carttools/common/RESTORE.sav`.
2. Launch CartTools with the cartridge inserted.
3. Hold Start + R. Check the CRC32 on `FLASH FILE CRC`.
4. Release, then hold Start + R again. Do not remove the cartridge.
5. Wait for `FLASH VERIFIED` and `32768 BYTES READ BACK EQUAL`.
6. Press A to rescan.

The write takes about four seconds. It erases the whole chip, checks that
32,768 bytes read `FF`, programs, then reads every byte back.

## Errors

| `ERR` | Meaning | Cartridge |
|---|---|---|
| 1 | Image did not load, or is not 32,768 bytes | Unchanged |
| 2 | Flash ID is not `BF B5` | Unchanged |
| 3 | Not blank after erase | Erased or partly erased |
| 4 | Slot power or bus mode lost | Unknown |
| 5 | Read-back differs from the image | Written, wrong |

Repeat both holds to retry.

## ID probe

`FLASH ID BF B5  ANSWERED P31` identifies a supported cartridge. `NO ANSWER`
means the flash did not enter ID mode on that write enable. The probe sends no
erase or program command.

## Reference

Command sequences are from the SST39SF010A / 020A / 040 datasheet. Cartridge
wiring follows the FlashGBX profiles `fc_DMG_FerranteCrafts_32KB.txt`,
`fc_DMG_FerranteCrafts_32KB_2.txt` and `fc_DMG_FerranteCrafts_64KB.txt`. No
FlashGBX code is used.
