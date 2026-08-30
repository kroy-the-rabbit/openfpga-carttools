# Containerised Quartus build

Quartus never gets installed on the host. `make cart` runs upstream's own
`generate.tcl` inside `docker.io/raetro/quartus:21.1` against a copy of the
tree, then packages an SD-ready folder and gates the result on timing.

    make cart                  build -> build/cart/
    make cart SEED=2           re-run the fitter with another placement seed
    make cart SKIP_COMPILE=1   repackage existing outputs, no Quartus run
    make report               regenerate build/cart/report.txt
    make shell                shell in the container, tree at /work
    make clean                remove build/

Outputs land in `build/cart/`:

| Path | What |
|---|---|
| `work/` | the copy Quartus compiles, including its `db/` scratch, kept between runs so incremental compiles work |
| `bitstream.rbf_r` | bit-reversed bitstream, the form the Pocket loads |
| `sd/` | copy `Assets/`, `Cores/`, `Platforms/` to the card root |
| `*.zip` | the same tree zipped |
| `report.txt` | utilization, worst slack per analysis type, full fit and STA summaries |
| `build.log` | Quartus output |

## Why it is built this way

- **Quartus 21.1, not 25.1.** Upstream tunes constraints, seeds and its custom
  STA reports against 21.1, and this design closes setup by 0.102 ns on
  `clk_sys` in upstream's own CI build. A toolchain bump is a change to the
  result, not a neutral upgrade. The sibling GBC fork uses 25.1; keep them
  apart.
- **The build runs against a copy.** `build/cart/work` is what Quartus writes to,
  so the checked-in tree stays clean and the harness can patch fitter settings
  (processor count, seed) without touching files that CI and upstream share.
- **The harness gates on slack.** Quartus exits 0 on a design that misses
  timing. `report.sh` re-reads `ap_core.sta.summary`, takes the worst slack
  across every corner and analysis type, and exits 3 if it is negative, leaving
  a `TIMING_FAILED` marker next to the report. This is the lesson the GBC fork
  learned by shipping a build with -3.374 ns of setup slack that Quartus called
  a success.
- **Python runs from a venv** at `build/cart/venv`. Nothing is installed into it;
  `scripts/reverse_bitstream.py` is stdlib only and the venv keeps it that way.

## Running it somewhere other than a workstation

`make cart` works under three container setups and picks the right flags for
each from the runtime name and the uid:

| Where | Runtime | Flags used |
|---|---|---|
| workstation | rootless podman | `--userns=keep-id` |
| GitHub Actions | docker | `--user $(id -u):$(id -g)` |
| build node | podman as root | neither |

The third exists because Quartus fitting is largely single-threaded and a
laptop part throttles under a sustained fit; a node with steady clocks finishes
sooner on fewer cores and leaves the desk machine alone. On such a node:

    NPROC=4 FITTER_EFFORT="STANDARD FIT" make cart

`NPROC` caps `NUM_PARALLEL_PROCESSORS` and changes wall clock, not the fit.
`FITTER_EFFORT` changes the fit, so it is the one to hold fixed when comparing
two builds.

## Playing a dump, which is the only way to verify a save

    tools/podman/play-dump.sh ZELDA.gbc            ROM alone
    tools/podman/play-dump.sh ZELDA.gbc ZELDA.sav  ROM with its save RAM

Builds an mGBA container on first use and plays the image. A ROM dump proves
itself - the header and global checksums were written at manufacture and this
core checks both - but **save RAM carries no checksum of any kind**, so the
only way to know a `.sav` is right is to let the game that wrote it read it
back. That was done on 2026-08-28 and it is what moved save backup from built
to verified; `docs/STATUS.md` records the cartridge.

The originals are never handed to the emulator. mGBA writes to a `.sav` as you
play, so the script copies both files into `build/emu/` first - a test can
neither corrupt the dump nor write to the SD card it may still be sitting on.

Two host-specific obstacles are handled inside the script, and both look like
the emulator failing rather than the desktop refusing:

- **SELinux.** The X socket is `user_tmp_t` and a container runs as
  `container_t`, so the write is denied and mGBA reports `unable to open
  display`. `--security-opt label=disable` fixes it per container; nothing
  system-wide changes. Confirm a suspected case with `ausearch -m avc -ts
  recent`.
- **The xauth cookie is bound to this machine's hostname**, which the
  container does not share, so the server rejects it even once the socket is
  reachable. The script rewrites the family to `FamilyWild` in a copy under
  `build/emu/`. `xhost` is never called, so the desktop's own access control
  is untouched.

mGBA is not packaged for Fedora, so the image is Ubuntu, and the `mgba-sdl`
package installs a binary called `/usr/games/mgba`.

## Checking a dump without playing it

    scripts/verify_dump.py FILE...          logos, checksums, sizes, CRC32
    scripts/verify_dump.py --compare A B    two reads of the same cartridge
    scripts/verify_dump.py --selftest       prove the checks can fail

Everything a checksum can settle, computed by different code from the core's.
For a save it adds the one structural failure the device cannot see: **every
bank identical**, which is what a bank select that did not take produces - a
file of exactly the right length holding bank 0 over and over.

It cannot prove a save is correct and says so. A length check and a
looks-like-real-data check both passed on the first save this project took,
and neither would have caught a subtly wrong read.

## If the image will not pull

`podman pull docker.io/raetro/quartus:21.1` can fail with

    unable to retrieve auth token: invalid username/password

when `~/.docker/config.json` holds a stale docker.io login. The image is public,
so pull anonymously instead:

    printf '{"auths":{}}' > /tmp/anon-auth.json
    podman pull --authfile /tmp/anon-auth.json docker.io/raetro/quartus:21.1

Nothing else in the harness needs credentials once the image is local.
