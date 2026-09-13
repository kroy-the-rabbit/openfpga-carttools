# Save restore: targets

The first physical target is the original, non-DX **The Legend of Zelda:
Link's Awakening**. Its verified corpus pair is GB MBC1+RAM+BAT, cartridge type
`03`, RAM code `02`, with one 8 KiB RAM bank. The second, added 2026-09-12, is
**Pokemon Silver**: MBC3+TIMER+RAM+BATTERY, type `10` (or `13` without the
timer), RAM code `03`, four 8 KiB banks, CGB flag `80` (or `00`), ROM code up
to `06`. The save length follows the RAM code: 8,192 or 32,768 bytes. Every
check below applies to both; where a step names 8 KiB, read the geometry's
save length. GBA restore follows later.

This is experimental work after `v0.9999.250d6a0`. Corpus backup verification
does not establish that a new restore implementation is safe on hardware.

## Retained baseline

The Batch 6 pair passed the ROM DAT match and loaded correctly in mGBA:

| Artifact | Bytes | CRC32 | SHA-256 |
|---|---:|---|---|
| Non-DX ROM | 524,288 | `8CF27C90` | `21f712e213f43f9efb93ca039a5190fc09325d5d932af1fb2f8e90b4f9fd169f` |
| Original save | 8,192 | `19CCD1B4` | `d558d7f9400861fb3398eeb455be30b889ef8c021ce533a203535b3bc3729cae` |

Local original evidence is `build/evidence/batch-6/Assets/carttools/common/`
with `ZELDA.gb` and `ZELDA.sav`. A second identical pair is retained at
`build/card-verified-250d/`. Preserve these originals and the off-card library.
All raw saves, ROMs, and prepared restore artifacts remain ignored.

## One active input and deliberate authorization

Only one input save matters: `RESTORE.sav`, accompanied by `RESTORE.meta` in
`Assets/carttools/common/`. The companion metadata is an identity assertion,
not a second save. There is no restore library to enumerate in the core.

Prepare these files locally from an identified ROM and its associated raw save:

```sh
python3 scripts/prepare_restore.py \
  build/evidence/batch-6/Assets/carttools/common/ZELDA.gb \
  build/evidence/batch-6/Assets/carttools/common/ZELDA.sav \
  build/restore/la-nondx
```

The tool refuses existing output files. It verifies the ROM header checksum,
global checksum, exact ROM length for the header's ROM code, the CGB flag
allowed for the mapper, and one of the two supported type and RAM-code pairs.
The save must be exactly the geometry's length, 8,192 or 32,768 bytes; an
emulator's RTC trailer must be stripped first. The raw save is copied
unchanged. The tool never identifies games by filename. Core support may be
narrower during hardware qualification.

The UI uses two deliberate holds with a separate check action between them:

1. Hold Select continuously for three seconds to open the restore page.
2. Release the buttons, then press and release A to check the input and
   cartridge and create the mandatory recovery backup.
3. After checks pass, release all restore buttons, then hold A continuously
   for three seconds to authorize the final checks and one operation.

Both holds show progress. An A held during preflight cannot carry over into
final authorization. Unexpected buttons reset affirmative progress but keep
the page open. B explicitly closes an idle page or requests a safe stop when
work is in flight. Cancellation retains the stop screen until the engine and
electrical probe have drained. Results stay visible until B closes them or a
new Select hold begins a fresh attempt. There is no timed page dismissal.

Ordinary scan and dump buttons are claimed from the first Select sample,
before debounce opens the page. After exit, every controller button must stay
released for 20 ms before ordinary controls accept a new press. Interrupted
entry and B+X chords cannot fall through into dumping. Reset, cartridge state
change, validation failure, and completion revoke authorization. Each attempt
stages its own complete input; late SD transfers cannot replace the buffer
used by the writer. Save writes remain compiled out for initial hardware checks.

## Identity checks and their limits

Fixed inputs use their existing read-only deferred-load slots. Query each
slot's filename through `0190`, require the exact canonical path including
its NUL terminator, then verify slot ID and exact length before `0180` reads
the bytes. There is no input-file reopen or fallback path. The filename reply
must be ordered and aligned, include the complete name, and remain within
its 256-byte window. Padding after the terminator is not part of the name.
Keep the filename reply separate from the staged input data buffer.

The core must compare the manifest to freshly read cartridge identity and a
full ROM CRC32. It must independently compare staged save length and CRC32,
validate the metadata CRC32, and reject unsupported versions or nonzero
reserved fields. A different ROM of the same size is a mismatch. DX is a
different cartridge with a different mapper and save size, and is refused.
The initial hardware candidate requires metadata; there is no size-only
override in this first scope.

Raw save bytes generally cannot prove which game produced them. Preparing a
manifest asserts that the supplied save belongs to the supplied ROM. The
manifest binds those exact bytes to that asserted ROM identity and detects
accidental swaps after preparation. It cannot authenticate provenance or prove
that arbitrary imported save contents are meaningful to the game. CRC32 also
is not a cryptographic authenticity check. The retained corpus pair supplies
the first target's association evidence.

## Metadata version 1

`RESTORE.meta` is exactly 64 bytes, arranged as sixteen little-endian 32-bit
words. CRC32 is the standard reflected CRC used by `zlib.crc32` and the core's
`dump_crc32` (test vector `123456789` gives `CBF43926`).

| Word | Contents |
|---:|---|
| 0 | ASCII bytes `CTRS` |
| 1 | Format version `1` |
| 2 | Save byte length |
| 3 | Save CRC32 |
| 4 | ROM byte length |
| 5 | ROM CRC32 |
| 6 | Cart type bits 7:0, RAM code bits 15:8, ROM code bits 23:16, CGB flag bits 31:24 |
| 7 | Header checksum byte bits 7:0, software version bits 15:8; remaining bits zero |
| 8-11 | ROM bytes `0134-0143`, in their original byte order |
| 12-14 | Zero, reserved |
| 15 | CRC32 of bytes 0 through 59 |

## Mandatory recovery and write containment

Open File command paths and file payloads have different packing contracts.
Recovery path bytes occupy each word high byte first, matching the independently
hardware-tested PC Engine Open File implementation. Flags and size remain native
numeric words. The 8 KiB recovery payload remains low byte first, matching the
verified dumper. Get Filename input-path comparisons use normalized character
order and are not changed by the outgoing command-string correction. Tests must
decode path words independently of the producer and check nonzero scalar fields
separately from both path bytes and payload bytes.

ID and size validation must respect the shipped data-table RAM latency. Its
synchronous read has an additional registered output. After changing the
word address, allow both clock edges to propagate the value before comparing
it on the following edge. Unit and command/SPI models must include that output
register. An error `9` retains the table word index, actual value, and expected
value on the result screen; it never bypasses the ID or exact-size check.

Before authorization can reach the writer, read the existing RAM twice and
compare every byte. Save the original in a new recovery file, then reopen and
reread the entire file and compare it to the original buffer. Probe successive
`PRE0000.sav` style names with four hexadecimal digits and create a new file.
Only after APF confirms this operation created that exact name may the core
preallocate its 8,192 bytes. No preexisting backup is resized or overwritten.
The core checks the new file's size before writing and checks it again after
reopening for readback. Any short transfer, APF failure, mismatched length, or
reread mismatch blocks cartridge save writes. Revalidate the cartridge before
the final write authorization.

APF separates create and resize. A create-only operation may produce a zero-byte
file, making an immediate 8 KiB write out of range. The core therefore probes
with flags `0`, creates with flags `1` and requires result `1` (newly created),
then resizes that pinned name with flags `2`. Create-only sends desired size
zero; resize-only sends 8192. After create result 1, independently query the
slot's assigned filename and require the expected path through its terminator,
then verify slot ID before permitting resize. Retain the reported creation
size without assuming the API promises zero. A create result `0` means another
file already exists there and blocks resize and write. The sequence assumes
the running Pocket core is the sole writer to the card. APF supplies no inode
or exclusive file handle to prove identity against concurrent external
replacement between commands.

Restore must consume the full 16-bit command result. A truncated summary can
alias an unsupported result onto success or create ownership. Keep full
probe/create/name-query/resize results visible across subsequent commands;
unknown values fail closed. The legacy three-bit dumper interface does not
authorize any restore operation.

A successful reopen and byte comparison demonstrates APF can read back the
backup it just wrote. It does not establish power-loss durability beyond
firmware and SD caching guarantees. The APF flush command is not used because
it hangs on the tested firmware. The first hardware recovery test must include
power-cycling and copying that backup off-card before any save write is enabled.

The first candidate must keep cartridge save writes clamped off while the APF
file size and readback behavior is verified on hardware. An APF command that
times out cannot be reused while a late completion might still arrive.

MBC1 restore must explicitly select RAM bank zero, enable RAM, write only
`A000-BFFF`, reread the complete bank, compare all 8,192 bytes, and disable RAM
on every safe exit. MBC3 restore enables RAM, selects banks `0` to `3` in
order through `4000` (values `08-0C` would map the clock registers and cannot
be formed by the writer), writes each bank's `A000-BFFF`, rereads all four
banks, compares all 32,768 bytes, and disables RAM; it never writes `6000`,
the clock latch. Mapper setup writes are separately constrained. Other mapper
types, GBA saves, and RTC data remain refused.
Protocol tests must prove that no save-memory write can occur before every
authorization condition passes. Cancel/reset must not leave RAM enabled or
silently label a partial operation successful.

Saving to a physical cartridge cannot be atomic across power loss or removal.
The independently verified recovery file enables recovery, but cannot prevent
an interrupted save from being partial. A failure must retain the backup and
report that the cartridge needs recovery, with no automatic repeated writes.

## Qualification sequence

1. Establish APF staging, exact sizes, metadata checks, deliberate unlock, and
   recovery create/reopen/readback with cartridge save writes clamped off.
2. Exercise synthetic writable MBC1 and MBC3 models: bank selection, data order,
   wrong identity, bad CRC, wrong size, backup errors, stale authorization,
   reset, cancellation, cartridge changes, and readback mismatches.
3. Build on the requested runner through `../tools/runner-build` and pass normal simulation
   and FPGA timing checks. Keep the released core and original evidence.
4. On hardware, make a fresh baseline backup and retain it off-card before
   enabling the writer. First restore the exact corpus save, then dump it
   again and compare all bytes to the original.
5. To prove writes changed actual RAM, subsequently use a known, visibly
   different save prepared in an isolated emulator copy. Restore, read back,
   compare, power-cycle, and check the native cartridge path. An unchanged
   restore alone does not prove that writes worked.
6. Restore the retained original again, reread it, and check the native path.
   Record bitstream identity and hashes of each input, backup, and readback.

No hardware restore has passed merely because host tests or simulations pass.
Expand mapper and save-technology coverage only after this complete cycle.

## First hardware diagnostics

The first candidate must say `CORE WRITES DISABLED`. A successful complete
check says `CHECK COMPLETE`, never `RESTORE VERIFIED`. Capture the displayed
ROM CRC, save CRC, and recovery ID along with the build stamp. The diagnostic
candidate after B458 displays that stamp on the restore page as well.
Recovery ID `0000` identifies `Assets/carttools/common/PRE0000.sav`.

For an SD failure, the result screen includes `SD ERROR: x`. Codes `1` through
`7` are the APF command result, interpreted according to the failed command.
The file service adds these hexadecimal diagnostic codes:

| Code | Meaning |
|---|---|
| `8` | Command timed out; reload the core before another attempt |
| `9` | Dataslot identity or exact file length did not match |
| `A` | Input transfer was short, misaligned, duplicated, or out of order |
| `B` | All recovery names were occupied |
| `C` | Invalid file operation requested |
| `D` | Recovery creation did not establish ownership of a new file |
| `E` | Assigned input or newly created recovery path did not match its required path and terminator |
| `F` | Unsupported full-width APF result; no truncated result may authorize success |

An error may leave a partial new recovery file on SD. Preserve it for analysis;
the next attempt must choose a new name, not overwrite that file. No error
authorizes a cartridge save write.

### Retained SD trace after the B458 failure

B458 stopped with SD error `4` before completing checks. For APF open-file
command `0192`, that code means malformed path, but B458 did not display the
failed command. The diagnostic candidate does not assume a cause or alter the
protocol: it identifies the file and last stage on the failure screen.
The [APF command reference](https://www.analogue.co/developer/docs/host-target-commands)
defines each command's result codes separately.

Stages distinguish input open, slot-ID check, length check, input read,
recovery-name probe, create, assigned-backup-path query/check, resize, write,
reopen, and recovery readback.
The trace captures the responses actually held by the file service before
`bridge_rd`, not just the requested pathname. Values are normalized to the
service's internal byte-zero-low word representation:

| Field | Expected in the complete simulated open-structure read |
|---|---|
| `PATH WORDS` | `42 HEX`, 66 returned words for the 264-byte structure |
| `P0` | `7373412F`, first four path bytes `/Ass` |
| `P8`, metadata | `74656D2E`, filename bytes `.met` |
| `P8`, save or recovery | `7661732E`, filename bytes `.sav` |
| `FLAGS`, open/probe/reopen | `00000000` |
| `FLAGS`, create | `00000001` |
| `FLAGS`, resize new recovery | `00000002` |

These historical path-word expectations used the same byte-zero-low assumption
as the producer. The subsequent recovery-path correction uses raw `P0=2F417373`
and recovery `P8=2E736176`; flags and size do not change. The character-oriented
`PATH` and `NAME` display is normalized separately and still reads normally.

The count saturates at `7F`; firmware rereads or a different access pattern
can change it. These few words are diagnostic clues, not proof of every byte
in a hardware transfer or proof that firmware accepted the path. Capture the
entire screen, including stage and filename, before retrying. New attempts
clear the trace, and SD failure diagnostics do not display the success-only
ROM/save CRCs or `RECOVERY FILE VERIFIED` message.

### Complete path trace after the 2BDA result

Hardware localized error `4` to `RESTORE.meta` / `OPEN INPUT`. It observed
`46` hexadecimal responses, or 70, with the two displayed path words correct.
The actual SPI peripheral regression produces that count with 16-word chunks
and re-priming, while delivering all 264 bytes correctly. This demonstrates
why the response count alone cannot diagnose malformed data; it does not
prove that Pocket firmware uses this chunk pattern.

The `05AF` diagnostic screen includes the complete observed 40-byte path and
additional fields, all numbers hexadecimal:

| Field | Interpretation |
|---|---|
| `PATH`, `NAME` | Observed prefix and filename; `~` marks NUL and `?` marks an unread word or non-ASCII byte |
| `READS`, `UNIQUE`, `RPT` | Total observations, distinct word indices, and repeats; counters saturate at `7F` |
| `REPEAT` | First four repeated word indices, or `--` for unused positions |
| `FLAGS`, `SIZE` | Observed words 64 and 65; input open expects both zero |
| `BAD`, `GOT`, `EXP` | First mismatched word index, observed value, and generated expected value, retained even after a clean reread |

A complete structure has `42` unique words. The tested 16-word chunk pattern
reports `READS 46 UNIQUE 42 RPT 04`, repeats `10 20 30 40`, and no mismatch.
The observed metadata filename should render `RESTORE.meta~~~`; all three
trailing bytes are NUL. The post-12CD candidate sends size `00000000` for
create-only and `00002000` for resize-only. Earlier candidates sent 8192 for
both. That unused-field correction is not yet a hardware-proven repair.

The post-12CD failure overlay also retains `SEQ Pxxxx Cxxxx Nxxxx Rxxxx`:
full 16-bit results for probe, create, assigned-name query, and resize.
`----` means that command has not returned a result, distinct from actual zero
or an observed unknown `FFFF`. `NEW SIZE` is the table size observed after the
new backup's path and slot identity checks; `FFFFFFFF` is its initial sentinel.
These fields survive subsequent command traces, but clear for a new operation.
They report observed responses and table values, not proof of file durability.

The subsequent `05AF` hardware screenshot has the same counts, but repeats
`40 40 41 41`: flags and size each observed three times. It shows the correct
complete metadata path, NULs, zero flags and size, and no word mismatch, yet
still fails at metadata open with error `4`. It is not a preflight pass.
The resumed split-read simulation reproduces these counts and repeat indices
with correct data, and with a deliberately incorrect consumer retaining a
shifted path while observing the same bus responses. It does not establish
which returned words firmware consumes at the bulk/scalar read boundaries.
See the current resume section in `docs/HANDOFF.md` before another candidate.

The observer checks every returned structure word, including padding, against
the file service's generator and captures the selected top-level response.
Its first 40 bytes cover all current paths and terminators, not arbitrary
256-byte names. A shared path-generator mistake can agree with itself, and a
bridge observation does not prove firmware acceptance or physical SPI signal
integrity. The host regression separately checks literal expected bytes and
tests injected selected-response corruption through both modeled reads and
the actual SPI peripheral. No cartridge write is enabled by these diagnostics.

For the assigned-input candidate, `GET INPUT PATH` and `CHECK INPUT PATH`
replace input open. The displayed path is received from firmware, with an
`RX` word count; only bytes through the required terminator are compared.
Padding can be nonzero and appear as other characters or `?`. Recovery
failures still show the outbound `READS` trace and compare all 264 bytes.
