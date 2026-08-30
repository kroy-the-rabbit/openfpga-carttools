# File formats

What CartTools is intended to write to the SD card, and what it actually
writes today. Read the status table below before building anything against
this: the two are not the same, and the gaps are not small.

**Status: specification, version 1. Most of it is NOT implemented.** Updated
2026-08-27.

The core has written nineteen files to a real card across GB, GBC and GBA, so
the old status line here - "nothing has written a file yet, the core has not
reached Phase 4" - was false for two days. What follows is still the design
target for the companion app; this section says how much of it the core
actually does, so nobody builds a consumer against the parts that do not
exist.

| This document specifies | The core does | |
|---|---|---|
| `Dumps/`, `Saves/`, `Metadata/`, `Restore/` subdirectories | writes **flat** into `/Assets/carttools/common/` | not implemented |
| `<basename>.cart.json` sidecar | **nothing writes one** | not implemented |
| `.gba` / `.gbc` / `.gb` by platform | `.gba` / `.gbc` / `.gb` since `47bcd54` | **in the code, not yet on hardware** - that build failed timing and was not flashed |
| basename may contain spaces, `-`, mixed case | uppercased; everything outside `A-Z0-9` becomes `_` | differs |
| GBA basename appends ` (game code)` | no game code appended | not implemented |
| `_2`, `_3` on a collision | **silently overwrites** | not implemented, and it has already cost a dump |
| `verified: "reread"` | double read is being built, see `docs/DUMP-VERIFY-PLAN.md` | not implemented |
| `verified: "readback"` | nothing reads a file back on either platform | not implemented |

The collision row is the one that has done damage. Link's Awakening and
Link's Awakening DX both title themselves `ZELDA`, so the second dump replaced
the first and the DX image survived only because a copy had been made.
`docs/HANDOFF.md` carries it as an open item.

What the core writes today, for a consumer that has to cope with it now:

```text
/Assets/carttools/common/
    TETRIS.gb              flat, no subdirectory
    ZELDA_DIN__AZ7E.gbc    the trailing AZ7E is a bug, not a game code
    GOLDEN_SUN_A.gba
```

Two things could still change the specification below: what the APF file API
allows on hardware, and MROM's on-card layout, which this should match rather
than compete with where it sensibly can. Both are open questions in
`docs/LANDSCAPE.md`.

## The rule that outranks everything else

**A ROM or save file must be usable with the metadata deleted.** Metadata
improves matching and validation. It is never required for recovery. A
consumer that cannot open a dump because its sidecar is missing is a broken
consumer, not a broken dump. From `plan.md` Phase 16.

## Layout (specified; the core writes flat)

```text
/Assets/carttools/common/
    Dumps/       <basename>.gba  <basename>.gbc  <basename>.gb
    Saves/       <basename>.sav
    Metadata/    <basename>.cart.json   <basename>.rtc.json
    Restore/     <basename>.sav        staged by the app, read by the core
```

`/Assets/<platform id>/common/` is where APF expects a platform's files, and
the platform id is `carttools`. The APF file API restricts core-chosen paths
to `Assets` and `Saves`.

`Restore/` is separate from `Saves/`. `Saves/` is output, written by the core.
`Restore/` is input, written by the app. No operation can then read its own
output by accident.

## Basenames

One basename per cartridge, shared by every file belonging to it.

Derivation, in order:

1. Start from the cartridge title as read from the header, trailing spaces and
   NUL padding removed.
2. Replace any character outside `A-Z a-z 0-9 space _ -` with `_`.
3. Collapse runs of spaces, trim.
4. If the result is empty, use `UNTITLED`.
5. For GBA, append ` (` + game code + `)`. Game Boy has no equivalent field,
   so it gets nothing.
6. If that name is taken, append `_2`, `_3`, and so on.

```text
METROID FUSION (AMTE).gba
POKEMON CRYSTAL.gbc
```

The core cannot list a directory; step 6 probes one name at a time by trying
to open it without the create flag. A consumer must not assume the numeric
suffix means anything, and in particular must not assume `_2` is a second
revision rather than a second cartridge with the same title.

**Identity lives in the metadata and in the ROM hash, never in the filename.**

## `<basename>.cart.json` (specified; nothing writes one)

UTF-8, no BOM, LF line endings.

```json
{
  "carttools": 1,
  "tool_version": "0.1.0",
  "dumped_utc": "2026-08-25T19:41:03Z",
  "platform": "gba",

  "cartridge": {
    "title": "METROID FUSION",
    "game_code": "AMTE",
    "maker_code": "01",
    "software_version": 0,
    "header_ok": true,
    "header_checks": {
      "fixed_byte": true,
      "complement": true,
      "reserved_zero": true
    },
    "read_stable": true
  },

  "rom": {
    "file": "Dumps/METROID FUSION (AMTE).gba",
    "size": 16777216,
    "crc32": "9f2c41ab",
    "sha256": null,
    "verified": "reread"
  },

  "save": {
    "file": "Saves/METROID FUSION (AMTE).sav",
    "technology": "flash_1m",
    "size": 131072,
    "crc32": "1e77b004",
    "verified": "reread"
  },

  "rtc": null
}
```

### Field rules

| Field | Rule |
|---|---|
| `carttools` | schema version, integer. Bumped only for a change that breaks an existing consumer. A consumer seeing a higher number than it knows should say so and stop, not guess. |
| `tool_version` | the core version that wrote it. Informational. |
| `dumped_utc` | ISO 8601, UTC, always with the `Z`. From the Pocket's clock, which the user may not have set, so it is not a trustworthy ordering key. |
| `platform` | `gba`, `gbc`, or `gb`. Lower case, matching the picker's existing platform ids. |
| `rom.file`, `save.file` | path relative to `/Assets/carttools/common/`, forward slashes. Never absolute. |
| `crc32` | 8 lower case hex digits, no prefix. |
| `sha256` | 64 lower case hex digits, or `null` if not computed. |
| `verified` | see below. |
| `save`, `rtc` | `null` when the operation was not performed. Absent and `null` mean the same thing. |

Unknown fields are ignored by consumers. New optional fields do not bump
`carttools`.

### `verified`

| Value | Means |
|---|---|
| `"none"` | written, not checked |
| `"reread"` | read back from the cartridge a second time and compared byte for byte |
| `"readback"` | read back from the SD card and compared against what was sent |
| `"both"` | both of the above |

A consumer must treat `"none"` as unverified rather than as probably fine. A
consumer must not invent a fifth value.

### Game Boy cartridge block

Same envelope, different `cartridge` contents:

```json
  "cartridge": {
    "title": "POKEMON CRYSTAL",
    "cgb_flag": "cgb_enhanced",
    "mapper": "mbc3",
    "features": ["ram", "battery", "rtc"],
    "rom_size": 2097152,
    "ram_size": 32768,
    "header_checksum_ok": true,
    "global_checksum": "1d2f",
    "read_stable": true
  }
```

`mapper` is a lower case identifier: `romonly`, `mbc1`, `mbc2`, `mbc3`,
`mbc5`, and later additions. `features` is an unordered set drawn from `ram`,
`battery`, `rtc`, `rumble`, `sensor`. `cgb_flag` is `none`, `cgb_enhanced`, or
`cgb_only`.

## `<basename>.rtc.json`

Kept apart from the save: `plan.md` Phase 15 requires them to stay
independently usable.

```json
{
  "carttools": 1,
  "mapper": "mbc3",
  "captured_utc": "2026-08-25T19:41:03Z",
  "latched": {
    "seconds": 12, "minutes": 34, "hours": 5,
    "days": 271, "halt": false, "day_carry": false
  }
}
```

**No consumer may convert this into an emulator's RTC format silently.**
Emulator RTC layouts are not interchangeable; they disagree about the epoch and
about where the halt and carry bits live, and a bad conversion corrupts an
in-game clock. A conversion may be offered; it must be explicit, named after
its target, and reversible.

## Restore input

The app writes `Restore/<basename>.sav` and the core reads it. The core
validates before writing anything to a cartridge:

1. The cartridge in the slot is identified.
2. The save size matches what that cartridge can hold. A mismatch is refused.
3. The identity is compared against `Metadata/<basename>.cart.json` if present.
   A mismatch is a warning the user must confirm, not a refusal: the same game
   on a different physical cartridge is legitimate.
4. The existing save is read off the cartridge and written to
   `Saves/<basename>.pre-restore-<timestamp>.sav` first. **Always, with no way
   to switch it off.**
5. Only then is the cartridge written, and it is read back and compared.

The app performs checks 2 and 3 as well. **The app's checks are a courtesy.
The core's checks are the ones that count**, because the app is not running
when the button is pressed. No app behaviour may be built on the assumption
that a core check exists.

## Failure

A dump that failed leaves no `.cart.json`. The sidecar is written last, after
the ROM is complete and verified, so its presence is the signal that the dump
finished. A `.gba` with no sidecar is an interrupted dump, and a consumer
should present it as interrupted rather than as an untagged dump. The file is
still readable; the app should not claim it is complete.
