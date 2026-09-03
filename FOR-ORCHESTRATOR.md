# For the orchestrator: cutting a release

What `pocket-dev` needs to cut a release of `pocket-cartridge`. Written
2026-09-02, at `70f03eb`. The full record is `docs/HANDOFF.md`, then
`docs/STATUS.md`.

## How a release is cut here

**Tag `main`. CI does the rest.** `.github/workflows/release.yml` fires on any
`v*` tag and refuses a tag that is not an ancestor of `main`.

1. Runs the simulation suite, 29 testbenches.
2. Builds the bitstream in Quartus. `build.sh` exits 3 on negative slack, so a
   release cannot be cut from a design that misses timing.
3. Stamps `core.json` with the tag name, so the Pocket menu shows the version.
4. Publishes the zip and `report.txt` to a GitHub release.

Nothing is built or uploaded by hand. The last release, `v0.9999.ed18b9b`,
went out this way with `kroy.CartTools_0.9999.ed18b9b.zip` and `report.txt`.

## Decide this first: there is no new bitstream

**Nothing in `src/` has changed since the last release.** `v0.9999.ed18b9b..HEAD`
is seven files: four documents, `scripts/match_dats.py`, `tb_dump_engine.sv`
and this file. The last fit was at `4a54db4`.

So a release cut today ships a bitstream identical to `v0.9999.ed18b9b`. What
changed is that several of the claims made about it were wrong, and that one
shipped behaviour now has a test. That is a real thing to release, but cut it
knowing that is what it is. The alternative is to leave the tag where it is
and let this ride to the next release that carries RTL.

## Fix before tagging: the release body is stale

`release.yml` hardcodes the text that appears on the public release page, and
every count in it is now wrong:

| It says | The truth |
|---|---|
| GB/GBC verified on twenty cartridges | twenty-six |
| GBA dumping on twelve | fifteen |
| Three images match published records | all forty-one, by CRC32 and size |
| Save backup on one cartridge's 32 KB save | six GB/GBC saves backed up, five verified in an emulator |
| no mention of GBA saves at all | GBA save backup works, Flash 64 KiB and SRAM 32 KiB |

The comment above the classify step says the same, including "no save
backup". That text is the first thing anyone downloading this reads, so it
matters more than any file in `docs/`.

## Two decisions that are not mine

1. **The version scheme does not match the tags.** `README.md` says the set is
   at `0.9999` and the next release is `0.99991`, then `0.99992`. The two tags
   cut so far are `v0.9999` and `v0.9999.ed18b9b`, which appends a commit
   rather than a digit. The version is shared across all five projects, so
   this is the orchestrator's call, not this repo's. Whichever way it goes,
   `README.md` and the tags have to say the same thing.

2. **Every `v0.9999.*` tag publishes as a stable release.** The classifier
   marks a tag as a prerelease only on `-alpha`, `-beta`, `-rc` or `-testing`.
   `v0.9999.ed18b9b` therefore published as stable while its own body text
   begins "**Alpha.**". Either the tag carries a suffix or the body stops
   saying alpha.

## What the core can honestly claim

| Path | State |
|---|---|
| GB/GBC identification and dumping | verified, twenty-six cartridges, 32 KB to 4 MB, five mapper families |
| GBA identification, sizing and dumping | verified, fifteen cartridges, 4 to 16 MB |
| Every dump matched to a published record | forty-one of forty-one, CRC32 and size, `scripts/match_dats.py` |
| CRC32 on the device, over a ROM or a save | `tb_dump_engine`, value checked at two lengths against an independent CRC32, mutation checked twice |
| GB/GBC save backup | six backed up, five loaded in an emulator with their state intact |
| GBA save backup, Flash 64 KiB and SRAM 32 KiB | verified, and needs no write to a cartridge |
| GBA 128 KiB Flash and EEPROM | refused, both need a write |
| Save restore, either platform | not started |
| MBC2, MBC3, MBC1 above 512 KB | simulation only, no cartridge to test |

**A save dump is CRC32'd on the device**, by the same accumulator as a ROM and
on the same screen row. That gives a save an identity to compare against a
second dump or against the file on the card. It is not a verdict: nothing in
the cartridge and nothing published holds the expected hash of a save, which
is why row 13 carries the presence probe instead.

That path had no test until `70f03eb`. The engine could have named the file,
sized it, written it and left `crc32` holding the previous ROM dump's number,
and the suite would have passed. It is asserted now, at two lengths and
mutation checked both ways.

**What it must not claim.** A save is read once, the double read is not built,
and nothing reads a file back off the card. A `.sav` from this core is not yet
a backup anybody should rely on, and the release text has always said so.
Keep that sentence.

## Still routed elsewhere, unchanged

1. **The core and the picker derive a dump's basename differently.**
   `dump_path_gen.sv` keeps `A-Z0-9`, uppercases `a-z` and turns everything
   else into `_`. `cheatgui/dumps.py`'s `core_stem` keeps `-` and does not
   uppercase, following `docs/FILE-FORMATS.md` rather than the core. The card
   says `DQM2_R_____BQLJ.gbc`, the picker derives `DQM2-R_____BQLJ`, and its
   `Dump.renamed` calls the file hand-renamed. Decide which side moves, then
   fix it in the picker's session.

2. **The picker knows nothing about GBA `.sav` files**, which now exist beside
   `.gba` files at 32 KiB and 64 KiB.

## Quartus 25.1 transition

All build entry points now use the local Quartus Prime Lite 25.1std build 1129
image:

    localhost/pocket-quartus:25.1std

`generate.tcl` and the seed sweep open the old project with `-force`. The main
harness runs Quartus against `build/cart/work`, so migration rewrites only the
build copy and leaves checked-in project metadata intact.

Do not publish this image. Quartus Lite is free to use without a license file,
but Altera's agreement does not grant redistribution rights. The private
`pocket-dev` orchestrator handoff records the ignored OCI archive, checksum,
and runner distribution procedure. The expected image ID after loading is:

    1b2a15f0b63cd1753aabdac8b2968e8ca0e4a208cb16ff0ba7f3647a3a5a9de6

The transition is not complete until a 25.1 compile passes the timing gate and
the resulting bitstream passes cartridge verification. Do not use a 21.1
bitstream as the hardware-test candidate for the EEPROM probe change.

## Open here, not for the orchestrator

- `scripts/verify_dump.py` checks a `.sav` against `0x0149` of the ROM beside
  it, a Game Boy header field, so it fails every GBA save.
- `scripts/seed_sweep.sh` cannot run: it calls `docker` and writes a
  `build_output/` layout this repo no longer has.
- The `ST_WRITE` abort defect in `gba_cart_bus` gates 128 KiB Flash, EEPROM
  and every restore path.
- `HAMUPARA2__BHMJ` has still never been dumped twice.
- A stray workflow worktree sits under `.claude/worktrees/`. Nothing has been
  deleted; somebody should say whether it goes.

## Checklist

1. Decide whether a docs-and-tests release is wanted at all, given the
   bitstream does not move.
2. Fix the release body in `release.yml`, which is the public text.
3. Settle the version scheme against `README.md`, across all five projects.
4. Decide stable or prerelease, and make the tag match the body.
5. Confirm the Build workflow is green on the commit being tagged.
6. Tag `main`. CI does the rest.

## Decided, 2026-09-02

1. **Version scheme: `v0.9999.<short sha>`.** The set stays at 0.9999 and a
   release appends the commit it was cut from. `README.md` now says this.
2. **Stable, not prerelease.** The classifier is unchanged, so a `v0.9999.*`
   tag publishes as a stable release while the body still opens "**Alpha.**".
   That is the state of the project, said in the text rather than in a badge,
   and it is how `v0.9999.ed18b9b` already went out.
3. **The release body is fixed**, to twenty-six GB/GBC, fifteen GBA, forty-one
   matched against No-Intro, and save backup verified on both platforms.
