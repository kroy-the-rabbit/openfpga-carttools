# For the orchestrator: CartTools after the 250D release

Current as of 2026-09-05. The release is complete. New restore development is
on `save-restore-la`, branched from current `main`. Read `docs/HANDOFF.md` for engineering history and traps,
`docs/STATUS.md` for supported paths, and `docs/CARTRIDGE-CORPUS.md` for the
cartridge-by-cartridge evidence.

## Released baseline

`v0.9999.250d6a0` is published on exact commit `250d6a0`, stable, with:

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.250d6a0.zip` | `2736deb674613ac268ec6e1eb873eaf30f5d4f3eca101a568fe45021b1414fff` |
| `report.txt` | `055c201555f40454f0d8c1438af1c4711ef45a33550290e788b1df0f9ccdb991` |
| packaged `bitstream.rbf_r` | `2932ed7c67ed1658eb4cb4ff813db3a1180e09132c89806c6509da1ad8a3d596` |

Quartus Prime Lite 25.1std build 1129 completed in 347 seconds on sisko. It
used 3,901 ALMs and passed timing with `+1.549 ns` setup, `+0.109 ns` hold,
and `+0.827 ns` minimum pulse width. This exact package was installed and used
for the final hardware regression.

The retained corpus contains 41 No-Intro-matched ROMs: 15 GBA, 15 GB, and 11
GBC. It contains 27 saves from 27 cartridges: 16 GB/GBC and 11 GBA. Every save
except the documented Tetris Plus case exposed recognizable state when loaded
with its matching ROM in mGBA. Tetris Plus loaded without an error but exposed
no recognizable state, so it remains explicitly unverified.

## Build and release boundary

GitHub no longer runs Quartus:

- `.github/workflows/build.yml` is the simulation gate.
- `.github/workflows/release.yml` runs simulation and verifies an already
  published package against the tag.
- Synthesis runs only on sisko or kira through the shared utility.

All routine fits use:

    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build current
    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build start sisko pocket-cartridge cart JOB REF
    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build job sisko pocket-cartridge cart JOB REF
    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build fetch sisko pocket-cartridge cart JOB REF

The private image is `localhost/pocket-quartus:25.1std`, cached on both
builders. The complete builder recipe and private cache procedure are under:

    /home/kroy/Desktop/repos/pocket-dev/tools/quartus-image/

Never publish the Quartus image or its OCI archive. GitHub receives only source,
the finished core package, checksums, and reports.

## Next work in this repository

The active task is save restore, beginning with the original, non-DX Link's
Awakening. Its retained Batch 6 corpus has ROM CRC32 `8CF27C90` and an 8 KiB
save with CRC32 `19CCD1B4`. Read `docs/SAVE-RESTORE-PLAN.md` before changing
the cartridge write gate.

The first candidate keeps `RESTORE_WRITE_ENABLED = 0`. It must prove the
single input file and metadata, five Select taps, further X/Y/X/A confirmation,
fresh cartridge identification, two matching original-save reads, and a new
recovery file reopened and compared from SD. A full ROM match and another
original-save comparison follow final confirmation. No game hash is built
into the RTL. Save writes stay disabled until this preflight passes on the
Pocket and the recovery file is independently verified off-card after remount.

The subsequent writer qualification restores the retained original, then a
known different save to prove actual RAM mutation, then the original again.
Each needs readback, power-cycle, and native cartridge verification. Do not
publish this as hardware restore support based on simulation alone.

Remaining work after the first restore qualification:

1. Extend independent save rereads to the ordinary backup workflow.
2. Qualify further GB/GBC mappers and GBA restore technologies individually.
3. Add GBA Flash 128 KiB backup with modeled bank-select commands.
4. **Missing cartridge families.** MBC2, MBC3, RTC, and MBC1 above 512 KiB lack
   physical coverage. Add hardware evidence when cartridges become available;
   do not turn simulation coverage into a hardware claim.

## Work routed outside this repository

The controlled-builder transition must be repeated for `pocket-pcengine`. Its
current release workflow installs Quartus on an ephemeral GitHub-hosted runner.
Move its synthesis to `tools/runner-build`, preserve its strict timing gate and
seed retries, and publish only the PC Engine package, checksums, and reports.
The private `pocket-dev/docs/HANDOFF.md` owns that task.

Picker behavior and corpus import belong to `openfpga-GBC-cheats-ui`. Re-audit
the card and that repository before acting on older save-only notes because the
card now contains the full curated ROM and save set.
