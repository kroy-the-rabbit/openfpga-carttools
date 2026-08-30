# openFPGA-CartTools Plan

## Goal

Create a single openFPGA utility core for Game Boy, Game Boy Color, and Game Boy Advance cartridges.

Primary functions:

- Identify inserted cartridges
- Dump cartridge ROMs to SD
- Back up cartridge saves to SD
- Restore saves to physical cartridges
- Verify all destructive and archival operations

The project should be derived from the existing openFPGA GBA work, then stripped down into a cartridge utility rather than an emulator.

## Design Rules

- Keep the core platform-neutral at the service layer.
- Keep GB/GBC and GBA cartridge logic isolated behind shared interfaces.
- Do not retain emulation components unless they are required for hardware access.
- Every milestone must build before moving forward.
- Every write operation must support verification.
- Every restore must create a backup first.
- Prefer small, reviewable commits.
- Avoid speculative abstraction before the first working hardware path exists.
- Adversarially review every milestone before accepting it.

## Adversarial Review Standard

At each milestone, explicitly try to prove the implementation wrong.

Review questions:

- What assumption could make this fail on real hardware?
- What state could corrupt a cartridge?
- What timing assumption is undocumented?
- What behavior depends on a specific cartridge revision?
- What happens if detection is wrong?
- What happens if power, reset, or SD I/O fails mid-operation?
- Can the result be independently verified?
- Is any emulator-specific behavior leaking into cartridge services?
- Is the design becoming more complex than the current milestone requires?

A milestone is not complete until the review findings are resolved or documented.

---

## Phase 0: Establish the New Repository

Create:

```text
openFPGA-CartTools
```

Base it on the known-good GBA project state.

Tasks:

- Tag the donor repository before changes.
- Create the new repository with preserved history.
- Rename project metadata.
- Rename build artifacts and core identifiers.
- Confirm an unchanged build still succeeds.

Exit criteria:

- New repository builds.
- Generated core launches.
- No behavioral changes yet.

Adversarial review:

- Confirm repository history was preserved correctly.
- Confirm renamed metadata does not collide with the donor core.
- Confirm no build step still depends on the old repository name.

---

## Phase 1: Strip the Emulator

Remove components not required for cartridge utility work.

Remove:

- ARM7TDMI CPU
- PPU
- APU
- DMA
- Timers
- Interrupt controller
- GBA system RAM emulation
- Game execution path
- Emulator-only cartridge abstractions

Keep:

- Pocket top-level integration
- APF bridge
- Clock and reset handling
- Cartridge pin definitions
- Physical cartridge control
- Input handling
- Minimal video output
- SD-facing APF support

Replace the GBA display path with a simple static utility display.

Target:

```text
openFPGA-CartTools

No cartridge detected
```

Exit criteria:

- Core launches on Pocket.
- Static UI works.
- Cartridge interface remains present.
- FPGA utilization is materially lower.

Adversarial review:

- Verify removed modules are truly unused.
- Check for hidden timing dependencies on removed GBA logic.
- Confirm cartridge pins remain in a safe idle state.
- Confirm booting without a cartridge is safe.

---

## Phase 2: Define the Cartridge Bus HAL

Create a hardware abstraction between services and Pocket cartridge pins.

Suggested structure:

```text
src/
  cart/
    cart_bus.sv
    cart_controller.sv
```

Conceptual interface:

```text
request
read_write
address
write_data

ack
read_data
error
```

Requirements:

- Service logic must not directly manipulate cartridge pins.
- Bus timing must be contained in the cartridge layer.
- Power and reset behavior must be explicit.
- GB/GBC and GBA modes must be selectable.

Exit criteria:

- Raw cartridge transactions can be issued through one internal interface.
- Direct pin use outside the cart layer is eliminated.

Adversarial review:

- Verify voltage and direction changes cannot conflict.
- Check reset and hot-insert behavior.
- Check invalid requests and timeout behavior.
- Confirm no bus contention is possible during mode changes.

---

## Phase 3: GBA Cartridge Identification

Start with the donor project's native cartridge family.

Tasks:

- Read the GBA header.
- Validate header fields.
- Extract:
  - Title
  - Game code
  - Maker code
  - ROM identity data
- Detect no-cart and invalid-cart states.

UI target:

```text
METROID FUSION

Platform: GBA
Game Code: AMTE
ROM: detected
```

Exit criteria:

- Multiple real GBA cartridges identify correctly.
- Invalid reads are rejected.
- No cartridge does not produce false detection.

Adversarial review:

- Test damaged or unusual headers.
- Test slow or marginal cartridges.
- Confirm detection does not depend on known ROM databases.
- Confirm false positives are unlikely.

---

## Phase 4: GBA ROM Dumping

Implement sequential GBA ROM reads.

Pipeline:

```text
cartridge
  -> cart bus
  -> dump engine
  -> APF transfer
  -> SD
```

Requirements:

- Determine dump size safely.
- Stream data rather than requiring full-ROM buffering.
- Compute CRC32 during dump.
- Optionally compute SHA-256 if practical.
- Support post-dump verification.

Exit criteria:

- Dumped ROM matches an independently verified dump.
- Repeated dumps are identical.
- Large cartridges complete without corruption.

Adversarial review:

- Test boundary addresses.
- Test maximum supported ROM size.
- Test interrupted dumps.
- Verify partial files are not reported as valid.
- Compare hashes against known-good dumps.

---

## Phase 5: Add GB and GBC Bus Support

Add an alternate cartridge bus mode for GB/GBC.

Suggested structure:

```text
src/
  cart/
    gb/
      gb_bus.sv
    gba/
      gba_bus.sv
```

Detection flow. **This was written backwards and is corrected here**; the
implementation and `docs/HARDWARE-NOTES.md` section 5a are authoritative:

```text
probe GB/GBC
  -> valid: GB/GBC mode
  -> something answered but not a GB header: unsupported. STOP.
  -> nothing at all (all 0x00 or all 0xFF): probe GBA
      -> valid: GBA mode
      -> invalid: unsupported or no cart
```

GB is probed first, and a GB probe that found *anything* must never be
followed by a GBA probe. GBA mode drives connector pins 22-29 as address
outputs, and a Game Boy cartridge drives its data bus on those same pins, so
escalating after a successful GB read is contention. Escalation happens only
when the bus was silent, which is exactly how a GBA cartridge reads in GB
mode.

Exit criteria:

- GB, GBC, and GBA cartridges are distinguished correctly.
- Bus mode switches safely.

Adversarial review:

- Check false GBA detection on GB/GBC carts.
- Check bus voltage assumptions.
- Check mode transitions for contention.
- Test original GB carts, GBC-only carts, and dual-mode carts.

---

## Phase 6: GB and GBC Header Parsing

Read and parse the GB cartridge header.

Extract:

- Title
- CGB flag
- Cartridge type
- ROM size
- RAM size
- Header checksum
- Global checksum if useful

UI target:

```text
POKEMON CRYSTAL

Platform: GBC
Mapper: MBC3
ROM: 2 MiB
RAM: 32 KiB
RTC: Yes
```

Exit criteria:

- Header parsing works across representative carts.
- Invalid headers are rejected.

Adversarial review:

- Test malformed headers.
- Test titles using edge-case header layouts.
- Confirm mapper and RAM interpretation matches hardware.

---

## Phase 7: GB and GBC Mapper Layer

Create mapper-specific control behind one interface.

Initial support:

- ROM only
- MBC1
- MBC2
- MBC3
- MBC5

Suggested interface:

```text
select_rom_bank
select_ram_bank
enable_ram
disable_ram
read_rtc
write_rtc
```

Do not duplicate the dump engine per mapper.

Exit criteria:

- Mapper selection is based on cartridge metadata.
- ROM bank reads work across supported mapper types.
- RAM access can be enabled safely.

Adversarial review:

- Verify bank zero behavior.
- Verify high bank bits.
- Test carts near mapper size limits.
- Check MBC1 mode behavior.
- Check MBC2 internal RAM behavior.
- Check MBC3 RTC register selection.

---

## Phase 8: GB and GBC ROM Dumping

Use the shared dump service with the mapper layer.

Requirements:

- Iterate all ROM banks.
- Compute hashes during dump.
- Verify dumped size.
- Support optional reread verification.

Exit criteria:

- Supported GB/GBC carts dump byte-for-byte correctly.
- Repeat dumps are identical.

Adversarial review:

- Compare against trusted dumps.
- Test first and last banks.
- Test unusual ROM sizes.
- Confirm mapper writes do not affect cartridge state unexpectedly.

---

## Phase 9: Common Cartridge Service API

Create the platform-neutral service interface.

Conceptual API:

```text
cart_get_info
cart_read_rom
cart_read_save
cart_write_save
cart_read_rtc
cart_write_rtc
```

Services:

```text
services/
  identify/
  rom_dump/
  save_backup/
  save_restore/
  verify/
```

The UI should call services, not platform-specific bus logic.

Exit criteria:

- GB/GBC and GBA operations use the same top-level service flow.
- Platform-specific behavior remains below the service boundary.

Adversarial review:

- Look for platform-specific assumptions in common code.
- Reject abstractions that add complexity without reducing duplication.
- Confirm errors propagate cleanly to the UI.

---

## Phase 10: GB and GBC Save Backup

Support battery-backed RAM.

Flow:

```text
detect save layout
  -> enable RAM
  -> iterate banks
  -> write .sav
  -> verify size and checksum
```

Requirements:

- MBC1 RAM
- MBC2 RAM
- MBC3 RAM
- MBC5 RAM

Exit criteria:

- Backup imports correctly into trusted emulators.
- Backup can be restored to a test cartridge and verified.

Adversarial review:

- Test empty saves.
- Test maximum RAM sizes.
- Check mapper bank switching.
- Confirm RAM is disabled after operations.

---

## Phase 11: GB and GBC Save Restore

Restore `.sav` data to physical cartridges.

Mandatory safety flow:

```text
identify cartridge
  -> validate save compatibility
  -> create pre-restore backup
  -> write save
  -> reread save
  -> compare
  -> report result
```

Requirements:

- Never overwrite without a backup.
- Reject size mismatches.
- Warn on identity mismatch.
- Verify every restore.

Exit criteria:

- Byte-for-byte verification passes.
- Failed verification produces a clear failure state.
- Original save can be recovered from the automatic backup.

Adversarial review:

- Simulate wrong save file.
- Simulate interrupted restore.
- Check partial-write behavior.
- Confirm a verification failure is never reported as success.

---

## Phase 12: GBA Save Type Detection

Support the common GBA save technologies:

- SRAM
- FLASH 64 KiB
- FLASH 128 KiB
- EEPROM 512 B
- EEPROM 8 KiB

Detection should not rely on one method alone where avoidable.

Possible signals:

- ROM signature scan
- Known protocol behavior
- Cartridge database as optional metadata
- Safe runtime probing

Exit criteria:

- Representative carts identify their save technology correctly.
- Ambiguous cases are reported as ambiguous.

Adversarial review:

- Test ROMs containing misleading save strings.
- Verify probing cannot alter save data.
- Prefer refusing a destructive operation over guessing.

---

## Phase 13: GBA Save Backup

Implement save readers for:

```text
src/
  cart/
    gba/
      save_sram.sv
      save_flash.sv
      save_eeprom.sv
```

Exit criteria:

- SRAM backup works.
- Flash backup works.
- EEPROM backup works.
- Files match trusted tools.

Adversarial review:

- Test both Flash sizes.
- Test both EEPROM sizes.
- Check command timing.
- Confirm reads cannot trigger destructive commands.

---

## Phase 14: GBA Save Restore

Implement writes with strict verification.

Mandatory flow:

```text
backup existing save
  -> validate target
  -> write
  -> reread
  -> compare
```

Exit criteria:

- All supported save types restore successfully.
- Verification failures are detected.
- Automatic backup is always created first.

Adversarial review:

- Test interrupted Flash erase/write sequences.
- Test wrong save sizes.
- Check EEPROM address width handling.
- Check Flash vendor command differences.
- Confirm failures leave recoverable state where possible.

---

## Phase 15: RTC Support

Initial RTC target:

- MBC3

Keep RTC separate from `.sav`.

Suggested files:

```text
game.sav
game.rtc.json
game.cart.json
```

Metadata example:

```json
{
  "platform": "GBC",
  "mapper": "MBC3",
  "rom_sha256": "...",
  "save_size": 32768,
  "rtc": true
}
```

Exit criteria:

- RTC registers can be backed up.
- RTC state can be restored correctly.
- Save and RTC data remain independently usable.

Adversarial review:

- Check latched versus live RTC behavior.
- Check halt and carry flags.
- Avoid assuming emulator RTC formats are interchangeable.

---

## Phase 16: Metadata and File Layout

Recommended layout:

```text
Assets/
  CartTools/
    Dumps/
    Saves/
    Metadata/
```

Each dump should have metadata containing:

- Platform
- Title
- Cartridge type
- Mapper or save technology
- ROM size
- Save size
- ROM hash
- Dump timestamp
- Tool version

Do not depend on metadata for basic recovery.

Exit criteria:

- ROM and save files remain usable without metadata.
- Metadata improves matching and validation.

Adversarial review:

- Check filename collisions.
- Check malformed metadata.
- Confirm metadata cannot override hardware safety checks.

---

## Phase 17: UI

Keep the UI operational, not decorative.

Primary screen:

```text
CARTRIDGE TOOLS

POKEMON CRYSTAL

Platform: Game Boy Color
Mapper: MBC3 + RAM + RTC
ROM: 2 MiB
Save: 32 KiB

Dump ROM
Backup Save
Restore Save
```

Operations must show:

- Progress
- Current stage
- Verification status
- Clear failure reason

Exit criteria:

- No destructive action can be triggered accidentally.
- Errors are understandable without debug logs.

Adversarial review:

- Check button ambiguity.
- Check accidental double input.
- Check cancellation behavior.
- Check UI state after failed operations.

---

## Phase 18: Unsupported and Special Hardware

Only after the main path is stable.

Possible later targets:

### GB/GBC

- MBC6
- MBC7
- MMM01
- HuC1
- HuC3
- TAMA5
- Game Boy Camera

### GBA

- RTC carts
- Sensors
- Gyroscope
- Solar sensor
- Rumble
- Special Flash variants

Each should be isolated from the common path.

Adversarial review:

- Do not generalize from one tested cartridge.
- Require hardware evidence before marking support complete.

---

## Proposed Repository Layout

```text
openFPGA-CartTools/
├── src/
│   ├── top.sv
│   │
│   ├── pocket/
│   │   ├── apf_bridge.sv
│   │   ├── clocks.sv
│   │   └── video.sv
│   │
│   ├── cart/
│   │   ├── cart_bus.sv
│   │   ├── cart_controller.sv
│   │   │
│   │   ├── gb/
│   │   │   ├── gb_bus.sv
│   │   │   └── mapper/
│   │   │       ├── mapper.sv
│   │   │       ├── mbc1.sv
│   │   │       ├── mbc2.sv
│   │   │       ├── mbc3.sv
│   │   │       └── mbc5.sv
│   │   │
│   │   └── gba/
│   │       ├── gba_bus.sv
│   │       ├── save_sram.sv
│   │       ├── save_flash.sv
│   │       └── save_eeprom.sv
│   │
│   ├── services/
│   │   ├── identify/
│   │   ├── rom_dump/
│   │   ├── save_backup/
│   │   ├── save_restore/
│   │   └── verify/
│   │
│   └── ui/
│       ├── menu.sv
│       └── text_renderer.sv
│
├── assets/
├── docs/
├── tests/
├── README.md
└── plan.md
```

## Milestones

```text
v0.1  GBA cartridge identification
v0.2  GBA ROM dumping and verification
v0.3  GB/GBC cartridge identification
v0.4  GB/GBC ROM dumping and verification
v0.5  GB/GBC save backup
v0.6  GB/GBC save restore
v0.7  GBA SRAM backup and restore
v0.8  GBA Flash backup and restore
v0.9  GBA EEPROM backup and restore
v0.10 RTC support
v1.0  Stable GB/GBC/GBA cartridge utility
```

## Commit Strategy

Keep commits narrow.

Suggested initial sequence:

```text
1. reland GBA donor as openFPGA-CartTools
2. rename project metadata
3. remove CPU
4. remove PPU
5. remove APU
6. remove remaining GBA execution logic
7. add minimal utility video
8. isolate physical cartridge bus
9. add raw GBA read transaction
10. add GBA header reader
11. add GBA identification UI
12. add ROM dump engine
13. add verification
14. add GB/GBC bus mode
15. add GB/GBC header reader
16. add mapper abstraction
17. add MBC1
18. add MBC2
19. add MBC3
20. add MBC5
21. add GB/GBC dumping
22. add save backup
23. add save restore
24. add GBA save technologies
25. add RTC support
```

Each commit should build where practical.

## First Hard Stop

**Cleared 2026-08-25 on hardware, for GB, GBC and GBA. See `docs/STATUS.md`
for the cartridges and the header bytes.** The requirement was:

```text
launch core
  -> access physical GBA cartridge
  -> read header
  -> validate header
  -> display cartridge identity
```

This is the first major proof point, and it passed. Three GB/GBC cartridges
across two mappers and five cartridges in total identify correctly, including
the GB to GBA escalation.

It cleared nothing beyond identification. A header read is 26 or 32 bytes from
a fixed address; a dump is millions of bytes across banks. Mapper behaviour,
bank switching and sustained throughput remain entirely unproven.

## Definition of Done

`openFPGA-CartTools` reaches 1.0 when one core can:

- Detect standard GB, GBC, and GBA cartridges
- Dump supported ROMs to SD
- Verify ROM dumps
- Back up supported save types
- Restore supported save types
- Automatically back up before restore
- Verify restored data
- Handle MBC3 RTC data
- Reject unsupported or ambiguous hardware safely
- Keep platform-specific logic isolated
- Pass adversarial review for each supported operation
