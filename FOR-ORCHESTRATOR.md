# For the orchestrator: cutting the CartTools release

Current as of 2026-09-04. Read this file first, then the private
`pocket-dev/docs/HANDOFF.md`. The detailed hardware record is in
`docs/CARTRIDGE-CORPUS.md` and `docs/HANDOFF.md`.

## Release candidate

The release candidate is exact commit `250d6a0`, package version
`0.9999.250d6a0`, build stamp `250D`. It is not merely the last commit before
documentation work. It is the exact Quartus output installed on the card and
used for the final hardware regression and corpus work.

Candidate artifacts in the ignored `build/cart/` directory:

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.250d6a0.zip` | `2736deb674613ac268ec6e1eb873eaf30f5d4f3eca101a568fe45021b1414fff` |
| `bitstream.rbf_r` | `2932ed7c67ed1658eb4cb4ff813db3a1180e09132c89806c6509da1ad8a3d596` |
| `report.txt` | `055c201555f40454f0d8c1438af1c4711ef45a33550290e788b1df0f9ccdb991` |

Quartus Prime Lite 25.1std build 1129 completed in 347 seconds on sisko. It
used 3,901 ALMs and passed timing with `+1.549 ns` setup, `+0.109 ns` hold,
and `+0.827 ns` minimum pulse width.

The candidate fixes intermittent GBA detection by precharging the floating GB
safety-gate input bank to `FF` while both strobes are inactive, then releasing
it during setup before the read. The reproducing cartridge could not be made
to fail after the fix. The wider regression included NHL 2002, Metroid: Zero
Mission, SimCity 2000, Tetris Plus, and Oracle of Ages.

The current corpus contains 41 externally matched ROMs: 15 GBA, 15 GB, and 11
GBC. Every ROM matches a current No-Intro record by CRC32 and byte length. The
27 retained saves have completed their applicable mGBA checks. Batch 6 also
captured two rejected reads caused by dirty contacts, followed by a clean dump
that exactly matched the known-good image. That is useful evidence that header
recognition alone is not treated as a pass.

All 41 verified ROMs and 27 verified saves have been restored to
`Assets/carttools/common/` on the card. The GB and GBC Link's Awakening dumps
would otherwise share `ZELDA.sav`, so the GBC pair is stored as
`ZELDA_DX.gbc` and `ZELDA_DX.sav`. The staged local copy is ignored at
`build/card-verified-250d/`.

## Build boundary

Quartus builds run only on the controlled sisko or kira builders through:

    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build

The image is `localhost/pocket-quartus:25.1std`. It is cached on both builders
and is intentionally not published. Quartus Lite requires no license file,
but that does not grant permission to redistribute its installed files. Do not
put the image or its 4.6 GiB OCI archive in GitHub Actions artifacts or a
container registry.

The private orchestrator now contains the full image recipe at:

    /home/kroy/Desktop/repos/pocket-dev/tools/quartus-image/

Its README names the two exact Altera inputs, their vendor-published hashes,
the explicit license-acceptance step, the Containerfile, image verification,
and private cache-warming procedure. The existing tested image archive remains
under the ignored `pocket-dev/backups/images/` directory.

The current GitHub-hosted synthesis and release jobs still assume that their
runner can resolve the private image. They cannot. Treat those jobs as stale
until their repository transition is completed. They must not be repaired by
uploading the Quartus image.

## Rebuild the exact candidate if the ignored artifacts are unavailable

First confirm both runners are idle:

    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build current

Then build, monitor, and fetch exact commit `250d6a0`:

    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build start sisko pocket-cartridge cart release250d 250d6a0
    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build job sisko pocket-cartridge cart release250d 250d6a0
    /home/kroy/Desktop/repos/pocket-dev/tools/runner-build fetch sisko pocket-cartridge cart release250d 250d6a0

Use a new job label if `release250d` already exists. A rebuilt bitstream is a
new binary even at the same commit. It must pass timing and hardware smoke
verification before replacing the tested hashes above.

## Release procedure

The intended release tag is `v0.9999.250d6a0` on exact commit `250d6a0`.
Later commits on `gba-eeprom-save` record the hardware corpus and improve local
emulator presentation, but do not change the candidate RTL or package inputs.

1. Merge or fast-forward `gba-eeprom-save` into `main` and push `main`. Confirm
   that `250d6a0` is an ancestor of `origin/main`.
2. Run the 32-testbench simulation suite from the repository tree.
3. Recheck the three SHA-256 values above. Inspect the zip and confirm its
   `core.json` version is `0.9999.250d6a0`.
4. Create `v0.9999.250d6a0` on exact commit `250d6a0`.
5. Publish only `kroy.CartTools_0.9999.250d6a0.zip` and `report.txt`. The raw
   bitstream may remain local because it is already inside the zip. Never
   attach the Quartus image or OCI archive.

The legacy tag workflow at `250d6a0` attempts synthesis on a GitHub-hosted
runner and cannot access the private image. The orchestrator must publish the
already verified package and report directly rather than waiting for that job
to build them. Do not substitute a package built from a later commit under the
`250d6a0` version.

## Public claims that are supported

| Path | Supported release claim |
|---|---|
| GB/GBC identification and ROM dumping | Verified across 26 retained GB/GBC images, 32 KiB to 4 MiB, with all externally matched |
| GBA identification and ROM dumping | Verified across 15 retained images at 4, 8, and 16 MiB, with all externally matched |
| GB/GBC save backup | Verified by loading the captured saves with their matching ROMs |
| GBA SRAM, Flash 64 KiB, and EEPROM backup | Verified by loading captures with their matching ROMs |
| On-device CRC32 | Available for ROM and save output, but a save hash is identity evidence rather than an external correctness oracle |
| Save restore | Not implemented on either platform |
| GBA Flash 128 KiB backup | Still gated by the required bank-select write |

A save is read once. There is no double-read comparison and no restore path.
Keep that limitation in the release text.

## Follow-up transition

Repeat this build and release boundary work for `pocket-pcengine`. Its current
GitHub release workflow downloads and installs Quartus on an ephemeral hosted
runner. Move its synthesis to `tools/runner-build` on sisko or kira, keep the
builder image private, and publish only the PC Engine release zip, checksums,
and appropriate reports. Preserve its existing seed retry and strict timing
behavior when making that change.
