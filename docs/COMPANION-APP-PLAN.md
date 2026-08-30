# Companion app plan

CartTools becomes another system the desktop app,
[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools), manages
alongside Game Boy, Game Boy Color, Game Boy Advance and PC Engine. It gains
ROM dumps, save backups, RTC captures, and the metadata tying each to the
cartridge it came off.

`docs/FILE-FORMATS.md` is the normative contract. This file is the app-side
plan for consuming it. The core has not written a file yet: Phase A is safe to
start now because it only reads, and phases that stage a restore wait for a
core that can perform one.

## Split of responsibility

| Job | Where |
|---|---|
| Reading a cartridge | core |
| Verifying a dump against its own reread | core |
| Naming a dump correctly | app |
| Checking a dump against No-Intro | app |
| Keeping dated backups of a save | app |
| Choosing which save to restore | app |
| Deciding whether a restore is safe | both |

The core must refuse an unsafe restore even though the app also checks: the
app is not in the loop when the button is pressed.

Constraints from `docs/APF-NOTES.md`:

- A core writes files through target command `0x0192`, which takes a full path
  under `/Assets/...` or `/Saves/...` plus create and resize flags. A dump can
  be named after the cartridge.
- The core is blind to the filesystem. It cannot list a directory, delete,
  rename, or ask how much space is left. It can only probe whether one name is
  taken.
- The core learns almost nothing about failures. A full card and a bad slot id
  produce the same error code.

The core writes a well named file and cannot tidy up, deduplicate, or recover
from a mess. The app owns all three.

## Where it plugs in

| Module | What it does today | Change |
|---|---|---|
| `card.py` | finds the SD card, reads `/Platforms/*.json`, lists games per platform | add `carttools` to `KNOWN`, and to `ENABLED` once the core can dump |
| `carts.py` | user-maintained list of cartridges you own, name and platform, stored outside the repo in `cartridges.json` | `Cartridge` gains an optional identity: ROM hash, game code, platform, dump basename |
| `library.py`, `db.py`, `match.py` | index the libretro cheat database, match a game to its cheats by name | match a dump to a cheat file, the same problem one step earlier |
| `writer.py` | writes a file to the card, atomically | its atomic write pattern stages a restore |
| `prefs.py` | remembered choices outside the checkout | holds the dump index |
| new `dumps.py` | | read `/Assets/carttools/common/`, parse sidecars, verify hashes, present a list |
| new `tests/test_dumps.py` | | pinned against real files a core wrote, not app-invented fixtures |

`carts.py` states in its own docstring that a cartridge "is not a file on the
card, so it never appears in the game list". A dump gives it a title, a game
code and a hash, so a cheat file can be matched to it the same way a ROM's is.

## Phases

Numbered separately from `plan.md`.

### A. Read what the core wrote

Read only. No writes, no renames, no staging.

- Walk `/Assets/carttools/common/`, pair each dump with its sidecar, and cope
  with a dump that has none.
- Reject a sidecar whose `carttools` version is higher than the app knows,
  with a message, rather than guessing.
- Verify each dump against `rom.crc32` and surface a mismatch.
- Present `verified` honestly. `"none"` is not "probably fine".
- Show a ROM with no sidecar as an interrupted dump.

Done when: a card with dumps on it lists them accurately, a deliberately
truncated dump is flagged, and a sidecar from the future is refused politely.

### B. Attach dumps to the cartridge list

- Match a dump to an existing `carts.py` entry by title and, for GBA, game
  code.
- Offer to create an entry from a dump where none exists.
- Store the ROM hash on the entry, so the same physical cartridge is
  recognised next time and a different revision is recognisable as different.
- Keep any cheat file already chosen for that cartridge.
- `cartridges.json` needs a version field before it gains these keys. That is
  the first commit of this phase.

Done when: dumping a cartridge already in the list enriches that entry instead
of creating a second one.

### C. Name and organise

- Check a dump against a No-Intro DAT: match, mismatch, or unknown. A mismatch
  is information, not an error: it can mean a bad dump, a revision the DAT
  lacks, or a reproduction cartridge, and the app should say it cannot
  distinguish them.
- Offer renaming to the canonical name, moving the sidecar and save with it so
  the basename stays shared.
- Import dumps off the card into a library directory on the computer.

### D. Saves

- Keep dated, immutable backups of every save the core writes, off the card.
  The core writes one file per cartridge and overwrites it.
- Show that history and let one be chosen.
- Stage a chosen save to `Restore/<basename>.sav`, refusing a size mismatch
  and warning on an identity mismatch, per `docs/FILE-FORMATS.md`.
- Surface the core's `pre-restore-<timestamp>.sav` files as recovery points,
  and never delete one automatically.

Done when: a save can be backed up, listed, chosen and staged, and an
incompatible pairing is refused with a sentence.

### E. RTC

Only once the core produces `.rtc.json`. Display it readably and keep it with
its save. Never convert it to an emulator format silently. A conversion may be
offered; it must be explicit, named after its target, and reversible.

## Design constraints

- **The file on the card is the state.** The app must not keep a private
  database the card can disagree with. It may keep an index rebuildable from
  the card and the library, and dated save backups, which are copies.
- **Metadata is advisory.** Anything needing a sidecar must degrade sensibly
  without one. Sidecars get deleted and cards get copied by tools that drop
  them.
- **Never write to a cartridge from the app.** The app writes to the SD card;
  the core writes to cartridges. There is no path where the app talks to
  hardware.
- **Platform gating follows `card.py`'s `KNOWN`/`ENABLED` pattern**, driven by
  which milestones in `docs/STATUS.md` are verified rather than by which code
  paths exist.
- **Test against real files.** No assumption about the file layout counts
  until it is checked against files a real core wrote to a real card.

This is not a ROM manager, not a launcher, not a second Pocket Sync.

## Open questions

1. **Does MROM's layout conflict with this one?** A user will reasonably run
   both, and the app should read both. Settle before Phase A fixes a reader,
   and prefer matching MROM's layout. See `docs/LANDSCAPE.md`.
2. **Does the core actually get to choose filenames on hardware?**
   `docs/APF-NOTES.md` says yes through target command `0x0192`, and nothing
   in this codebase has ever issued a target command. If it fails, every dump
   lands under a fixed name and Phase A's first job becomes renaming.
3. **What does the core do when a basename is taken?** It cannot list a
   directory, so collision handling is a probe at a time. The numeric suffix
   rule in `docs/FILE-FORMATS.md` is written but untested on hardware.
4. **Two Game Boy cartridges with the same title.** GBA has a game code to
   disambiguate. Game Boy has nothing equivalent, and the global checksum is
   not unique across revisions.
5. **Does `cartridges.json` need a migration, or is a version field enough?**
