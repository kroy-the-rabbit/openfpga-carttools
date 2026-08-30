# Salvage

Files deleted from this tree that a later phase is likely to want back. All
are reachable at `5158171^`, the commit before the strip, or at the fork point
`0e1b2e1`.

```
git checkout 5158171^ -- src/fpga/pocket/data_unloader.sv
```

## Wanted again, near certainly

| File | Why |
|---|---|
| `src/fpga/pocket/data_unloader.sv` | moves core bytes out to the APF bridge, which is how a dump reaches the SD card |
| `src/fpga/pocket/data_loader.sv` | the reverse, for save restore |
| `src/fpga/core/save_type_detector.sv` | scans a GBA ROM for the save-type signature strings, which Phase 12 needs |

## Wanted again, possibly

| File | Why |
|---|---|
| `src/fpga/gba/gba_memorymux.vhd` | the EEPROM, Flash and SRAM access sequences Rai wrote against a real cartridge. Reference for Phases 13 and 14, to read rather than reuse: it is VHDL wired into an emulator's bus. |
| `src/fpga/core/sdram_pocket.sv` | if a dump ever needs more staging than block RAM can give. `docs/APF-NOTES.md` argues it will not. |
| `src/fpga/core/cart_quirks.sv` | a per-game quirk table keyed on cartridge id. A utility core should not need one. |

## Not coming back

The CPU, PPU, APU, DMA, timers, save states, the cheat engine, the audio
chain, and the PSRAM controller.
