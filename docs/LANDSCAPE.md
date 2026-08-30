# What else exists

Checked 2026-08-25.

Someone else has done the Game Boy half. Nobody appears to have done the Game
Boy Advance half.

## MROM

| | |
|---|---|
| What | DMG/MGB/CGB cartridge tool: dump ROM, back up and restore saves, read cartridge details, MBC3 RTC |
| By | lemouel (Noel), with contributions from agg23 |
| Where | <http://mrom.lemouel.io/>, gateware at <https://github.com/lemouel/openfpga-litex> branch `MROM` |
| Built on | [agg23/openfpga-litex](https://github.com/agg23/openfpga-litex), MIT |
| Released | around December 2025 |
| Covers | this plan's Phases 6 to 11 and 15, so milestones v0.3 to v0.6 and v0.10 |
| Does not cover | Game Boy Advance. Its repository states "DMG/MGB/CGB support, no AGB compatibility" |

Described by its own author as early, with some cartridges not yet dumping.

MROM is prior art and should be credited as such.

Updated 2026-08-27: this project now dumps GB, GBC and GBA on hardware, so the
recommendation is no longer "use MROM for everything". It splits: **MROM for
saves and MBC3 RTC**, neither of which exists here, and **CartTools for Game
Boy Advance**, which MROM does not cover. Either will do for a plain GB or GBC
ROM. The README carries the same table.

## The Pocket itself

Stock firmware extracts cartridge saves in Play Cartridge mode through its
save state feature, for Game Boy, Game Boy Color and Game Boy Advance, landing
in `/Memories`. It does not dump ROMs, and it is not a deliberate save backup
and restore flow with verification.

## External hardware

GBxCart RW, GB Operator, Sanni's cart reader, and the various Arduino dumper
PCBs. All work, most better than anything that fits in a Pocket. None work
with only the hardware someone already owns.

## What was not found

Game Boy Advance ROM dumping on the Analogue Pocket. Nor GBA save technology
detection, nor a deliberate GBA save restore with verification. Four searches,
nothing. That is where this project sits, and where Phase 3 already got to.

## Architecture not taken

MROM is software on a RISC-V SoC, not RTL. agg23 built `openfpga-litex`
explicitly to host cart dumpers. For mappers, filesystem naming, hashing and
menus, software on a CPU is the better tool by a wide margin. It is MIT
licensed and would be a legitimate base.

This project stays in RTL for the two operations that cannot be taken back,
bus timing and pin direction: an edge in the wrong place misreads, and a
direction bit in the wrong state drives eight outputs into a cartridge that is
driving them too, because the translators switch per bank. Everything above the
bus would genuinely be better as software, and the cost of not having it came
due exactly where this section predicted. Everything in `docs/APF-NOTES.md` about the SD write path is a
problem MROM had already solved, and Phase 4 had to solve it again from
nothing.

It took four sessions. The APF file API is undocumented in the ways that
matter, and the answer turned out to be that the bridge read window is
pipelined - the address must free-run, but the value the host keeps is the one
presented during the *previous* transaction. Sixty-four path forms were tried
against a window that was delivering every word one early. `docs/STATUS.md`
records that, and the three conclusions stated as established that had never
been measured.

The paragraph that used to sit here said that if Phase 4 turned into a long
fight with the APF file API, reconsidering the base was a legitimate option.
It did turn into one, the base was not reconsidered, and it worked. That is
worth leaving on the record rather than quietly deleting, because it was a
close call and the reasoning for it was sound either way.

## Interoperability

Where this project writes files to the card, it should match MROM's layout
rather than invent a competing one, so a user running both does not end up
with two directories of the same dumps and a companion app does not need two
parsers.

MROM's actual on-card layout has not been read yet. Open question, to settle
before Phase 16 fixes a layout here.

## Sources

- <https://www.timeextension.com/news/2025/12/you-can-now-use-the-analogue-pocket-to-dump-your-game-boy-cartridges>
- <https://metalgamesolid.com/fpga/analogue-pocket/mrom-a-new-tool-for-game-boy-cartridge-preservation-via-an-analogue-pocket/>
- <https://github.com/lemouel/openfpga-litex>
- <https://github.com/agg23/openfpga-litex>
- <https://retrohandhelds.gg/how-to-backup-cartridge-saves-on-an-analogue-pocket/>

Read from documentation and coverage, not from MROM's source. Two things to
verify before relying on them:

1. Whether "no AGB compatibility" is scoped to its run-code-from-a-cartridge
   feature or to cart access generally.
2. How it writes to the card, given both litex READMEs still say "Writing to
   disk broken in Pocket firmware".
