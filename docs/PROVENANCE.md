# Provenance

`openFPGA-CartTools` is a subtraction from an existing core. This file records
what came from where.

## Base

| | |
|---|---|
| Repository | <https://github.com/Rai/openfpga-GBA> |
| Branch | `feat/cartridge-support` |
| Commit | `0e1b2e1` |
| Reached locally as | `refs/remotes/donor-rai/cartridge-support` |

That branch is itself a fork of
[mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA) at
`v0.4.0`, which is a port of
[GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer). CartTools inherits
GPL-2.0 through all of them.

The donor is reached by commit id, or through `hardware-bringup`, which
descends from it.

## `main` does not descend from it

This core began as a fork with the emulator taken out, and `main` is a
re-import of that tree rather than a continuation of it: it starts at its own
`initial commit` and shares no ancestor with the donor. So the commit above is
the record of where this came from. Nothing in `main`'s history says it.

## This base and not master

mincer-ray's `master` is newer (`v0.6.2` against `v0.4.0`) and is the better
emulator, but the emulator is what gets deleted. Only Rai's branch has the
cartridge access:

| Already working on this branch | Used by CartTools as |
|---|---|
| `src/fpga/core/gba_cart_bus.sv` | the GBA cartridge bus. Inherited, then changed: the connector-facing ports were replaced with the flat engine interface `cart_pins` requires |
| `src/fpga/core/gba_cart_bus_tb.sv` | its testbench, kept and extended |
| `cart_mode` plumbing in `core_top.sv` | the switch into physical-cartridge operation |
| the `physical_cart_id` header read | the seed of cartridge identification |
| the `cart_fill_*` state machine | the sequential ROM read the dump engine needs |
| EEPROM, SRAM and Flash access through `gba_memorymux.vhd` | the reference for save backup |

## Status of the inherited cartridge code

Rai's own commit message is `Initial WIP on cart support. Not all save types
have been tested!`. Every inherited behaviour is unverified until this
repository verifies it. `docs/STATUS.md` tracks which ones have been.

## Build harness

`Makefile`, `tools/podman/` and parts of `scripts/` came from the `cheats`
branch of the local `pocket-gba` clone. The cheat engine itself was not
brought across.

## Remotes

One: `origin`, <https://github.com/kroy-the-rabbit/openfpga-carttools>. The
donor is not a remote any more. A `refs/remotes/donor-rai/cartridge-support`
tracking ref survives from when it was, but the remote entry itself is gone, so
re-fetching means adding it back by hand. The base commit is recorded at the
top of this file and that is the durable record of it.

## `main` carries no commit history

`main` is a single commit. The development history that produced this tree, the
emulator subtraction, the bring-up and every hardware session, is not in it, so
this file and the per-file notices are the record of where the code came from.
`docs/STATUS.md`, `docs/HANDOFF.md` and `docs/BRINGUP.md` carry the reasoning.

`hardware-bringup` is the branch that descends from the donor, with the
inherited commits and their authors intact. `git rev-list --max-parents=0 --all`
therefore finds more than one root: ancestry read from `main` alone is not the
ancestry of the project.

**The GPL-2.0 obligations are unaffected by any of this.** CartTools inherits
GPL-2.0 from GBA_MiSTer through mincer-ray and Rai, the chain is recorded at
the top of this file, and removing the remotes does not remove the licence or
the attribution.
