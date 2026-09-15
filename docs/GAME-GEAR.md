# Game Gear ROM dumping

The development branch adds a ROM reader for the official Analogue Game Gear
adapter and standard Sega banking. The first hardware targets are Arch Rivals,
Sonic the Hedgehog 2 and World Series Baseball. Hardware qualification is pending.

The official adapter reported APF ID `0x01`, with raw report `0x01010001`
(`PLAY=1`, `POWER=1`), in the C982 diagnostic hardware capture. Routing is enabled
for that measured ID; ROM dumping has not yet been qualified on hardware. With an
unknown adapter, the core displays `RAW` and `ADAPTER ID` and keeps the cartridge
bus idle. Power off before changing a cartridge or adapter, then launch through
**Play Cartridge**.

The first ROM-reader candidate, **99E2**, read a stable `TMR SEGA` header at
`7FF0` on hardware, then stopped with APF error 4 before any GG file appeared.
The development correction uses the file-request and payload byte ordering
established by the working restore service. Full GG capture still needs a new
hardware test; a stable header alone does not verify the ROM's banked contents.

With that adapter selected, the GG screen shows product/revision,
region, the raw header and a manually selected capture length. Use Left for 256 KiB
or Right for 512 KiB. The first profiles are:

| Cartridge | Length |
|---|---:|
| Arch Rivals | 256 KiB |
| Sonic the Hedgehog 2 | 512 KiB |
| World Series Baseball | 256 KiB |

World Series Baseball '95 is a separate 512 KiB game. The header's size nibble
does not reliably describe the complete image; this reader does not automatically
determine physical capacity or mapper type. Header hints use the first `TMR SEGA`
signature in address order: `0x1FF0`, `0x3FF0`, then `0x7FF0`. Pocket Tools uses
the same order, reports conflicting headers, and keeps full-file hashes
authoritative for identification.

X requests a fresh header scan and then captures the selected Sega ROM profile.
The reader selects every 16 KiB bank in that range through slot 2 and repeats
the selected range with a freshly initialized mapper. `SELECTED RANGE CRC AGREES`
means both passes produced the same CRC32. It does not establish physical ROM
capacity or an external reference match, and it does not read the saved file
back from SD. Use Pocket Tools with a GG DAT, or
the verification scripts, to identify the complete file by its hash and length.

Captures use the first available `GG0000.gg`-style filename under
`Assets/carttools/common/`. Existing files are preserved, including files created
by failed attempts. A cancels an active capture after the current bus transaction
drains.
Loss of cartridge power or adapter authority releases the connector immediately.

This mode permits only Sega ROM-control writes. It keeps the World Series
Baseball EEPROM disabled and provides no GG save backup or restore. Unbanked
small ROMs, Codemasters cartridges and automatic mapper/size detection are outside
the initial supported profiles. Keep native GB/GBC/GBA hardware regression checks
alongside every GG qualification build.
