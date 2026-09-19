# Save restore

Save restore is alpha. Cartridge writes and both readback checks have been
verified on **Pokemon Silver**, using 32 KiB of MBC3 save RAM. The game then
booted a publicly obtained save with player name **Mattia**, 16 badges,
Pokédex 251 and time 56:44, a public save sourced from [here](https://gbatemp.net/download/pokemon-silver-version-save-file.38572/).

Restore is also verified on **Dragon Warrior III**, MBC5 32 KiB (type `1B`,
4 MiB ROM), using the all-medals save from
[Woodus](https://www.woodus.com/den/games/dw3gbc/monstermedalsavestate.php).

MBC1 8 KiB and other MBC3 and MBC5 32 KiB cartridges (MBC5 ROM up to 4 MiB)
are implemented but untested on hardware. MBC3 RTC state and GBA
saves are not restored.

## Prepare the input

Use a verified dump of the cartridge's ROM and its matching raw save. Silver
requires exactly 32,768 save bytes, without an emulator's RTC trailer. Keep
the original save separately.

```sh
python3 -m venv .venv
.venv/bin/python3 scripts/prepare_restore.py game.gbc save.sav build/restore-input
```

Copy the generated `RESTORE.sav` and `RESTORE.meta` to
`Assets/carttools/common/` on the Pocket card. The preparation tool refuses
existing output files. The metadata binds the chosen save bytes to the ROM
you supplied; it cannot determine which game originally produced a save.

## Restore on the Pocket

1. Load CartTools with the matching cartridge inserted. Hold Select for
   three seconds to open the restore page, then release the buttons.
2. Press and release A to check the ROM identity and staged save and create
   a recovery file. Continue when the page reports `PREFLIGHT CHECKS PASSED`
   and `RECOVERY FILE VERIFIED`.
3. Release the buttons, then hold A for three seconds to authorize the
   cartridge write. A held during preflight does not count toward this hold.
4. Wait for `RESTORE VERIFIED` and `TWO READBACK CHECKS PASSED`. B closes an
   idle page or requests a safe stop while work is in progress.

Keep the `PRE0000.sav`, `PRE0001.sav`, … recovery files. Each contains the
cartridge save captured before that attempt. Copy them off the card before
further testing. The core verifies the recovery file before enabling a write.

A game can modify scratch RAM when it boots. The two immediate readbacks
compare the entire written save against the staged input; a later dump made
after playing can differ. Silver's recorded post-boot dump matched the
checksummed save region exactly.
