# Handoff

Traps and next steps. Read `docs/STATUS.md` for the current position and
`plan.md` for the direction.

## Latest hardware result: 12CD still fails, 2026-09-08

Screenshot `20260908_000409.png` confirms stamp 12CD and stops at
`SIZE NEW BACKUP`, error `3` (file not found), for `PRE0000.sav`.
Flags are `00000002`, size `00002000`, reads/unique/repeats `46/42/04`,
repeat indices `40 40 41 41`, with no observed word mismatch.
This is later than 1540's malformed-path refusal at the initial name probe.
By controller flow, reaching resize requires accepting probe result 3 and
create result 1. It does not independently prove file creation: no `PRE*.sav`
is present in the copied common directory. No recovery payload write or
cartridge save write was reached. Cartridge writes remain disabled.

All screenshots, common files, and the installed core are copied and
byte-verified under ignored `build/hardware/12cd-result-20260908.u0JBfV/`.
The installed bitstream matches 12CD. Fresh Zelda ROM/save dumps still match
the verified corpus, and restore inputs are unchanged. The screenshot hash is
`f3b20c3882d613b70729eeb21c8858ef52226360159bf62f68082819312e3fce`.
The card was unchanged and left mounted. Next: investigate the create-to-resize
sequence, completion attribution, and firmware's retained file identity.
Do not weaken the recovery gate. No implementation or new build was started
during this screenshot check.

## Post-create identity candidate in progress

The user requested maximum-effort parallel investigation after that failure.
Independent byte-level simulation covered 69 literal paths, all 256 path bytes,
128 structure indices, and all three flags without finding a path-generator
defect. A cycle trace through the actual command FSM found no normal stale-done
race: each new command clears done before the restore service accepts a new
result. Those tests do not establish what firmware retained or wrote to disk.

The hardware-tested PC Engine flow sends size zero during create-only. Our
12CD flow sent 8192 even though the resize flag was clear. The API documents
size as relevant only during resize, so zeroing this unused field removes an
unnecessary difference but is not a proven repair of the hardware failure.
PC Engine also uses a different slot type and accepts resize result 0 or 1;
its file-level hardware evidence does not prove each intermediate result or
zero-length file persistence for our deferred asset slot. Do not change our
slot parameters, path root, or resize acceptance based on that comparison.

The candidate retains create-only and resize as separate commands. After
exact create result 1 it queries Get Filename for slot 23, validates the entire
intended recovery path through NUL, and checks slot ID before any resize.
The reported creation size is retained, not required to be zero, because the
API does not promise a zero-size value. Both exact 8192-byte gates after resize
and reopen, and the full payload reread comparison, remain mandatory.

A separate safety gap was found in result handling: the shared command service
exposed only three bits of the 16-bit APF result. The candidate adds a full-width
result beside that legacy interface and restore checks the complete value.
An unsupported result cannot alias success or newly-created ownership; unknown
results fail as error 15. Legacy dumper behavior is unchanged. This is a
defensive correction, not evidence that the failing hardware returned such a
result. Probe/create/Get Filename/resize full results and creation table size
are retained across commands for the next screenshot.

Independent RTL review found the new filename and slot gates fail closed and
the registered table latency is preserved. Expanded unit/UI tests and the
complete actual-command/SPI regression pass. The latter covers an independent
created-file association, both endian modes, bulk/split reads, wrong returned
names, and full results 0009/0008. Deliberately restoring result truncation
breaks the rejection test. Actual top-level result and diagnostic wiring are
checked separately with truncation mutations. Full-top elaboration and nine
control negative tests also pass. The candidate is committed as
`2b0b0ba500f3c37cd376016052fb0d50abfef2ab`, display stamp `2B0B`.
All 45 checks passed against that exact commit, with the same four-worker
wrapper retained from the preceding build. The source was checked against the
commit before and after execution. The log and wrapper are retained under
ignored `build/restore/candidate-2b0b0ba/`; `simulation-2b0b0ba.log` SHA-256 is
`f45ee4f52ac2e0e4d1cb42834f88004127221207ebd4d08aa45d46de458948d9`.
Sisko is temporarily occupied by a sibling GBA build; do not interrupt it.
The FPGA build has not started. The user was offered an optional switch to
kira if free; absent a reply, keep waiting for sisko. Cartridge writes stay
disabled and 12CD remains installed.

When the selected runner is free, use the exact source, not the newer
documentation commit:

```sh
../tools/runner-build start sisko pocket-cartridge cart la-restore-created-binding 2b0b0ba
../tools/runner-build job sisko pocket-cartridge cart la-restore-created-binding 2b0b0ba
../tools/runner-build fetch sisko pocket-cartridge cart la-restore-created-binding 2b0b0ba
```

The next guarded installer is `build/restore/install-created-binding.sh`.
It requires the seven-character source, ZIP/bitstream/report/simulation hashes,
and freshly verified mounted device. Its prior-bitstream precondition is 12CD.
It now copies screenshots from the correct `Memories/Screenshots/` directory,
preserves common files, verifies all 14 package files after flush, and does not
unmount. Do not run it before the completed build and timing gate pass.

## Recovery Open File path candidate installed, 2026-09-07

The user requested parallel investigation and the next build on sisko after
1540 reached `PROBE BACKUP NAME` and returned error `4` for `PRE0000.sav`.
Independent reviews found the restore tests assumed that the Open File path
used the same low-byte-first packing as file payloads. Their host decoder
therefore agreed with the producer without independently testing that contract.

The sibling PC Engine implementation provides a hardware-tested comparison:
source `5ec086d55cada4676998b70263fa3401e1b73974` places Open File path byte
zero in bits 31:24. Its P1 result `G0 O0 R0 L033 P62696E00` confirms opening
and reading the derived file. Source `b86a38b0e07120fbbc58a1b1c61a271c17c16786`
adds hardware-tested save creation with native numeric flags 1/2 and size 2048.
Its SPI peripheral is functionally identical. Evidence is documented in the
sibling `docs/CD-PLAN.md` P1 section and `docs/CD-HANDOFF.md` p21 results.

The candidate changes recovery command path words only, from byte-zero-low to
byte-zero-high. Flags and size remain native numeric words. Backup payloads
remain low-byte-first, and Get Filename input validation retains its existing
normalized character order. The diagnostic path display normalizes characters
separately; raw first/tail and mismatch words describe actual outgoing words.
No command sequence, path, slot, package setting, cartridge bus behavior,
identity check, backup-ownership guard, or save-write permission changes.

Focused tests pass with independent command-string decoding, rejection of the
old per-word reversal, and successful recovery creation, resize, write, reopen,
and full 8192-byte readback through the actual command/SPI path. Both endian
modes pass, including separate repeated reads of native flags and size during
probe, create, resize, and reopen. File-service and UI tests also pass.
Exact candidate source is `12cd3c148cffff4a7b102684c2e36ba66364aee8`, display
stamp `12CD`. All 45 checks passed against that commit, using the unchanged
suite implementations with four independent simulation workers. The source
tree was checked against the commit before and after execution. The retained
log is `build/restore/candidate-12cd3c1/simulation-12cd3c1.log`, SHA-256
`dbcf4b766e8bb8708e409f92ca9999c3704eaa3a9cdaceb4ae5831adec891c7e`.
The ignored parallel wrapper is retained beside it for reproducibility.

Sisko completed this exact commit through runner-build with `rc=0` in 576
seconds, Quartus Lite 25.1 build 1129. Setup `+0.788 ns`, hold `+0.095 ns`,
minimum pulse width `+0.827 ns`; 8,357 ALMs and 129 RAM blocks. No timing
constraints changed. Inspect or fetch the completed job with:

```sh
../tools/runner-build job sisko pocket-cartridge cart la-restore-open-path 12cd3c1
../tools/runner-build fetch sisko pocket-cartridge cart la-restore-open-path 12cd3c1
```

Artifacts are retained under ignored `build/restore/candidate-12cd3c1/`,
including the ZIP, independently fetched bitstream, timing report, build log,
simulation log, parallel wrapper, and extracted package. ZIP integrity passed,
the packaged bitstream matches the independent artifact, and packaged data-slot
definitions match source. The package version is `0.9999.12cd3c1`; its UTC
release date is 2026-09-08, while local deployment was still 2026-09-07.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.12cd3c1.zip` | `16943ca575b3965b07b9f983cbf1cbf62fa1c0a681c72fc1b1bb72cdf4aba58d` |
| `bitstream.rbf_r` | `4a3ee413f898a1d3326723f39cf2231b5ffe41255b30a022882aa0040c3601a1` |
| `report.txt` | `1419433dba39e76d5210f686910ac2648d74a067f9c99ace14948e929053be31` |
| `build.log` | `5e173beb5faf217d841f8d42dcf509b3682fe5788bbab420eac637bf8a267156` |

12CD is installed and byte-verified. The guarded installer checked the prior
1540 bitstream, restore-input hashes, candidate hashes, and exact passing test
and timing reports before writing. The mount resolved to `/dev/sdc1`. All 14
package files passed byte comparison after filesystem flush. Every common file
is byte-identical to its pre-install copy. The card was left mounted as requested.
Recovery evidence is retained in `build/restore/deploy-12cd3c1.e9fT7Q/`:
replaced package files in `before/`, all common files in `common-before/`,
and the new `package/`. The earlier claim of `screenshots-before/` was wrong:
the installer checked root `Screenshots/`, not `Memories/Screenshots/`.
Screenshots were untouched and are now retained by the 2026-09-08 intake above.
The guarded
installer is `build/restore/install-12cd3c1.sh`; its old-bitstream precondition
intentionally prevents blindly running it again after this successful install.

Next hardware test: reload and confirm stamp 12CD. Hold Select for three
seconds, release, then press and release A to run the write-disabled checks and
recovery backup. Capture the result. A successful attempt must create a fresh
8192-byte `PRExxxx.sav` and reread all bytes. Preserve it locally, then verify
it survives a power cycle and matches the original RAM dump before considering
any cartridge-write-enabled candidate. `RESTORE_WRITE_ENABLED` remains zero.
The subsequent 12CD hardware attempt failed at resize, as recorded above.
No recovery success or cartridge restore is claimed.

## Verified slot-table latency candidate, 2026-09-07

The user requested the fix after AC63 stopped at `CHECK SLOT ID`, error `9`.
The shipped `mf_datatable` has a synchronous RAM read and registered output
(`outdata_reg_a = CLOCK0`). The old test doubles omitted the output register.
Restore compared the ID one edge too early after changing the address, and
would make the same mistake when changing from ID to size.

Correcting the unit-test RAM model before changing the controller reproduced
`failed=1 error=9 stage=2 reads=0`. The candidate adds a settle state before
each comparison, including recovery size checks. It does not relax either
comparison or change APF commands, slot assignments, save buffers, cartridge
bus logic, write authorization, or the physical save-write disable.
Table errors now retain table word index, actual value, and expected value,
displayed as `TBL xx GOT xxxxxxxx` and `EXP xxxxxxxx`.

Focused file-service and UI tests pass. `check_restore_datatable.py` checks
the shipped RAM configuration and requires deliberately removing either wait
to reproduce error 9 at its respective stage with zero reads. Both the unit
RAM and actual command/SPI integration RAM now model registered outputs.
The first synthesis attempt, source `3401e31`, stopped on multiple drivers in
the newly added table diagnostic registers. The corrected candidate keeps all
diagnostic assignments in their original clocked owner. The regression also
checks single procedural ownership. No artifact from the failed attempt was
installed. Its initial suite run was stopped and is superseded by the final
complete run at `build/restore/table-latency-final-simulation.log`.

Exact corrected source is `154097cd0b71b3ca1cfad563d92e344068c0eacc`, display
stamp `1540`, package `0.9999.154097c`. All 45 checks passed on this source,
including actual command/SPI integration, both early-sample negative controls,
and the full-size 512 KiB restore-engine test. Kira completed with `rc=0` in
894 seconds on Quartus Lite 25.1 build 1129. Setup `+0.969 ns`, hold
`+0.013 ns`, minimum pulse width `+0.827 ns`; 8,252 ALMs, 129 RAM blocks.
No timing constraints changed. Inspect or fetch this exact job with:

```sh
../tools/runner-build job kira pocket-cartridge cart la-restore-table-latency-final 154097c
../tools/runner-build fetch kira pocket-cartridge cart la-restore-table-latency-final 154097c
```

Artifacts are retained under ignored `build/restore/candidate-154097c/`:
ZIP, bitstream, timing report, build log, full simulation log, and extracted
package. ZIP integrity passed, the packaged bitstream matches the independently
fetched bitstream, and the packaged data-slot definitions match source.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.154097c.zip` | `1480fd03b0838754c4b06b95fb4f5aaeffcee7f2089d7dfb3bca739fd4d5e9a7` |
| `bitstream.rbf_r` | `c3e18e9849eb2d2bc3c0d7f3428ed6d0b522a64cf2c04d9b186d1fa2942a766c` |
| `report.txt` | `c57ebf6d1da8410086d598b0d7292167071491cb8730e036173f06d774e55978` |
| `simulation-154097c.log` | `6ce7abc4dadbaa46fae5c9e52738e9d7121e96685a303804e467bdf7b9b8eeef` |

1540 was installed and byte-verified on 2026-09-07 after the user remounted the
card and explicitly requested no unmount. The mount resolved to `/dev/sdb1`
at deployment. The guarded installer verified the prior AC63 bitstream,
restore-input hashes, candidate hashes, and 45-check result before writing.
All 14 installed package files passed byte comparison after filesystem flush.
The installed bitstream matches the hash above. Every file in the common
directory, including saves, dumps, and restore inputs, is byte-identical to
its pre-install copy. The card was left mounted.

Deployment evidence is retained under ignored
`build/restore/deploy-154097c.LNFWmR/`: replaced package files in `before/`,
all prior common files in `common-before/`, and the extracted new `package/`.
The installer is `build/restore/install-154097c.sh`; its AC63 precondition
means it is not a command to rerun blindly after this completed deployment.
The latest hardware result is now 1540, retained under ignored
`build/hardware/1540-result-20260907.HKV47R/`. Screenshot
`20260907_224214.png`, SHA-256
`cc5b8eb67f65c5bbf21ba5c435bb72a74e0a475649c50acd32d9410f06088558`,
shows error `4` at `PROBE BACKUP NAME`, file `PRE0000.sav`, intended path
`/Assets/carttools/common/PRE0000.sav`, flags/size zero, and writes disabled.
The trace shows `READS 46 UNIQUE 42 RPT 04`, repeats `40 40 41 41`, and no
observed word mismatch. The card bitstream still matches the 1540 artifact.

This result gets past the previous slot-ID failure. By the controller's
control flow, reaching this recovery stage means metadata validation, save
staging/CRC, full ROM identity, and two matching original RAM reads completed.
It is not a completed preflight or an independent intermediate-buffer check.
The recovery probe's `0192` call returns malformed-path error `4`, not the
file-not-found result `3` required to proceed to creation. No recovery file
was created, and no cartridge save write occurred. The fresh Zelda ROM and
save still match the verified corpus; the ROM also passes No-Intro CRC/size.
All evidence was copied and verified locally. The card was left unchanged
and mounted during this intake.

Next: investigate recovery `0192` request delivery and path acceptance.
The observed FPGA words do not prove which bytes firmware retained, and this
screenshot does not establish the underlying rejection cause. Do not bypass
recovery creation/readback or enable cartridge save writes. The slot-table
change has hardware evidence of progress, but restore still does not work.

## Resumed restore input work, 2026-09-07

The user resumed work. This historical section supersedes the pause below;
the 1540 deployment above is now current. Build `AC63` was installed and
byte-verified on the card. Its first hardware preflight
passed metadata filename validation, then stopped at `CHECK SLOT ID` with
error `9`. No cartridge save write has been enabled.

The split-read regression now reproduces `READS 46 UNIQUE 42 RPT 04` with
repeats `40 40 41 41`, using a bulk path read and separate scalar flag/size
reads, including command-register transitions and both endian modes through
the actual SPI peripheral. Correct consumption yields the correct path.
A deliberately wrong consumer retains the stale prime and drops the final
response, producing a four-byte shift without changing the FPGA trace.
This demonstrates a limitation of the trace, not the actual firmware cause.
The exact firmware request order and its retained buffer are still unknown.

The next candidate changes fixed input staging, not the recovery sequence:

1. Query firmware with `0190 Get Filename` for the existing read-only,
   deferred-load input slot, 21 for metadata or 22 for save.
2. Require its exact canonical path through the NUL terminator, then check
   slot ID and exact size before issuing `0180 Read`. There is no input-file
   reopen, create, fallback, or filename guessing. Package filenames and
   read-only parameters are unchanged.
3. Keep every metadata, ROM, save CRC, original-RAM, and recovery check.
   Only recovery operations still use `0192`. If recovery open also fails,
   it continues to block all subsequent writes.

The filename reply has a dedicated `C0000000` response window. Ordered,
aligned writes must include the complete fixed path and terminator, with at
most 256 bytes total. Bytes after the NUL are unspecified padding. Get-path
traffic cannot enter the staged save buffer, and command timeouts continue
to poison the service until core reload. New error `E` means input path
mismatch; malformed or incomplete filename transfer uses `A`.

The UI adds `GET INPUT PATH` and `CHECK INPUT PATH` stages. For an input
failure, `PATH`/`NAME` and `RX` describe the firmware's returned path, not a
copy of the desired outbound path. Recovery retains the existing `READS`
trace. The hardware question is now whether firmware has the expected fixed
input association, and whether that slot can be read without reopening it.
This is not a claimed repair of the underlying `0192` refusal.

Focused file-service, actual command/SPI, UI, and top-integration checks pass.
The integration test transfers all 64 metadata bytes and all 8,192 save
bytes in both endian modes, and rejects four deliberately broken command
mux variants. File-service tests include bad/missing/unterminated paths,
reversed bytes, malformed transfers, final-word completion, arbitrary
post-NUL padding, timeouts, and unchanged recovery-file refusal protections.
Exact candidate source is `ac6333374074303b7345e2a6379fc84a6d168e71`, stamp
`AC63`. All 44 simulation and structural checks passed, with output retained
at `build/restore/simulation-ac63333.log`. Kira completed the exact-source
fit with `rc=0` in 948 seconds using Quartus Lite 25.1 build 1129. Setup
`+0.474 ns`, hold `+0.025 ns`, minimum pulse width `+0.827 ns`; 8,144 ALMs
and 129 RAM blocks. No timing constraints changed. Inspect the completed
job with the exact source commit, not a later documentation-only HEAD:

```sh
../tools/runner-build job kira pocket-cartridge cart la-restore-assigned-input ac63333
../tools/runner-build fetch kira pocket-cartridge cart la-restore-assigned-input ac63333
```

The verified artifacts are retained under ignored
`build/restore/candidate-ac63333/`: ZIP, bitstream, report, build log,
simulation log, and extracted package. ZIP integrity passed, its embedded
bitstream matches the separately fetched file, and its `data.json` matches
committed source.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.ac63333.zip` | `f4a1166a73ad3b99494e7077c743c8f805eff32c5953788dab8c13f89ca017ab` |
| `bitstream.rbf_r` | `64a4baffc51bc2584bf1d0919d2bb2401724983379eec53383b1ab476289de4c` |
| `report.txt` | `5098efc4f5c51c0317d1800dda9dcfaea602b488e1488a130ceae110c7ceac54` |
| `simulation-ac63333.log` | `8d4e67707a3c2ccae555a33801e93bf30317d02f70b9affcaf334d3619e0db7c` |

AC63 was installed on 2026-09-07 after the user requested deployment. The
installer validated the exact package hash, mounted device, previous 05AF
bitstream, and prepared input hashes before merging the complete package.
All 14 installed files passed byte comparison after filesystem flush. The
bitstream matches the AC63 hash above. Both restore inputs and the newly
redumped Zelda ROM/save remain unchanged. Replaced files and the extracted
package are retained under ignored `build/restore/deploy-ac63333.3bqba2/`.
The card was left mounted as requested.

The immediately preceding intake is retained under ignored
`build/hardware/card-intake-20260907.xSMAAC/`. Its new non-DX Zelda ROM
matches No-Intro on CRC32 and size, and both ROM and save are byte-identical
to the verified Batch 6 corpus. That intake's latest screenshot, taken before AC63
installation, is byte-identical to the previous 05AF metadata-open failure.
Do not treat that screenshot as an AC63 test.

The subsequent AC63 hardware result is retained under ignored
`build/hardware/ac63-result-20260907.UYzItJ/`. Screenshot
`20260907_212906.png`, SHA-256
`f663028a99f31dd53310dbbb74401b349d2d1e1e9af1e17059528e0c7716e4c1`,
shows build AC63, error `9`, stage `CHECK SLOT ID`, `RX 40 UNIQUE 40 RPT 00`,
and the correct metadata path. The received filename and exact-path checks
passed. The following data-table ID check did not match metadata slot 21.
The actual compared table value is not displayed, so the screenshot cannot
distinguish a missing entry from an addressing, mux, or timing problem.
Displayed zero flags/size are not that table value. Metadata payload reading,
save reading, and recovery creation were not reached; no `PRE*.sav` appeared.
Installed bitstream hash still matches AC63. Fresh Zelda ROM and save match
the verified corpus exactly; the ROM also passes the No-Intro CRC/size check.
The card was not changed or unmounted during intake.

Next: inspect the actual data-table ID/address and timing at the failed check.
Retain the identity/size guards and keep cartridge save writes disabled.
The assigned-filename step now has hardware evidence, but no completed
preflight, cartridge restore, or repair of the `0192` refusal is claimed.

The use of assigned deferred-load slots and `0190` is documented in
[data.json](https://www.analogue.co/developer/docs/core-definition-files/data-json)
and [APF commands](https://www.analogue.co/developer/docs/host-target-commands).

## Historical pause, 2026-09-06 local time

The user explicitly stopped work at this point. At that time, the instruction
was to resume from this section, not the older
"next screenshot" instructions below. No new test, source change, build, or
card deployment was started during the investigation after the latest
screenshot. The only new changes at this stop are documentation. Do not
automatically resume work until asked. The dated resume above now supersedes
this pause and its unimplemented next steps.

### Current position

- Branch: `save-restore-la`. Installed source:
  `05af4a96598975de3579136ed2654323afc8c76c`, package `0.9999.05af4a9`,
  on-screen stamp `05AF`. Later commits are documentation only.
- All 44 checks passed. Kira completed the exact-source fit with setup
  `+0.664 ns`, hold `+0.123 ns`, and pulse width `+0.827 ns`. Full package
  installation was byte-verified. Detailed artifacts and hashes follow below.
- Hardware preflight still fails at the first metadata open. No metadata
  content read, staged save read, recovery creation, or cartridge save write
  was reached. This is not a working restore yet.
- `RESTORE_WRITE_ENABLED=1'b0` in `src/fpga/core/core_top.sv`. Keep it zero.
  Preserve the prepared inputs in `build/restore/la-nondx/` and the original
  non-DX Link's Awakening Batch 6 corpus in `build/evidence/batch-6/`.
- The card was last observed mounted after screenshot capture. No unmount
  command was issued. The user specifically requested that it stay mounted
  after writing. Recheck the mount on resume, since it can disappear at any
  time. Copy new evidence to ignored local storage before analysis.

### Latest hardware evidence

`build/hardware/05af4a9/20260906_213648.png` was copied from the card and
SHA-256 compared before inspection:
`506d2a456133d9c8af5c7cecfa129729831fd2661c76e5528e489e63f6ffcd4f`.
An ignored text transcription is retained beside it. The important fields:

```text
BUILD 05AF
FILE: RESTORE.meta
PATH /Assets/carttools/common/
NAME RESTORE.meta~~~
CORE WRITES DISABLED
SD ERROR: 4
SD STAGE: OPEN INPUT
READS 46 UNIQUE 42 RPT 04
REPEAT 40 40 41 41
FLAGS 00000000 SIZE 00000000
NO OBSERVED WORD MISMATCH
```

Numbers are hexadecimal. The trace has 70 observations, all 66 unique
structure indices, and four repeats. Flags at index 64 and size at index 65
were each observed three times. The complete visible path and three NUL
bytes match the expected metadata path. This is NOT the simulated 16-word
chunk pattern, whose repeat indices are `10 20 30 40`.

The observation is at the selected FPGA bridge response before `bridge_rd`.
It does not show which responses firmware retained versus discarded during
pipeline priming. Thus, no mismatch does not establish that the firmware's
path buffer contains those same bytes. Neither a firmware defect nor a
remaining core pipeline defect has been demonstrated.

### First work on resume

1. Extend `tools/sim/restore_bridge_model.sv` and
   `tools/sim/check_restore_bridge.py` with separate 256-byte path reads and
   scalar flag/size accesses that reproduce repeats `40 40 41 41`. Exercise
   both endian modes through the actual SPI peripheral, including command
   register transitions. Existing tests prime each modeled burst correctly;
   they do not reproduce the latest access pattern.
2. Track the host's retained byte buffer separately from FPGA observations.
   Test deliberate stale-first-word/incorrect-prime consumption as negative
   controls. It is a hypothesis that a shifted retained buffer can coexist
   with this complete, mismatch-free trace. That hypothesis has NOT yet been
   implemented or tested. Do not report it as the reproduced hardware cause.
3. Consider verifying the existing fixed input slots instead of reopening
   them. `RESTORE.meta` and `RESTORE.sav` are already declared as read-only,
   deferred-load slots 21 and 22. APF documents direct target reads from such
   slots and `0190` to retrieve their associated filenames. This is an
   alternative under consideration, not an implemented fix or approval to
   remove identity checks. If adopted, validate the returned canonical path,
   exact slot ID and size, complete ordered transfer, and existing metadata,
   ROM and save checks before accepting anything. Missing/mismatched inputs
   must fail closed. Recovery still needs collision-safe `0192` creation,
   resize, write, reopen and independent readback; none may be bypassed.
4. Update the handoff with what the new tests actually prove before choosing
   another hardware change. Avoid another diagnostic fit without a specific
   discriminating question. Any candidate still needs full regressions,
   timing approval, retained artifacts, and guarded full-package deployment.

Relevant implementation: `src/fpga/services/restore/restore_file_io.sv`,
`src/fpga/core/core_top.sv`, and `src/fpga/ui/ui_restore_screen.sv`.
`tools/sim/tb_restore_file_io.sv` covers file-service error containment.
The working dumper's held bridge response and existing `0190` capture are in
`src/fpga/services/dump/dump_engine.sv`. At this historical pause, the measured
low-byte-first outbound payload order was incorrectly generalized to command
strings. The newer recovery-path section above corrects that assumption:
payloads stay low-first, Open File strings use high-first, and numeric fields
remain numeric. Do not free-run the response output; that caused the historical
one-word path shift.

Official references rechecked during the paused investigation:
[APF commands](https://www.analogue.co/developer/docs/host-target-commands)
and [data slots](https://www.analogue.co/developer/docs/core-definition-files/data-json).
The current absolute path is consistent with the declared `carttools`
platform. Parameter bit 3 is read-only, and extensions may have up to seven
characters, so `.meta` being four characters is not a documented violation.
Do not rename inputs or weaken the read-only settings based on speculation.

Use `../tools/runner-build` for every fit, with a committed exact source.
Kira is the most recently requested runner. Do not interfere with the
sibling GBA work. Container tests must run outside the process sandbox to
avoid the known AVC transition denial; see `RUNNERS.local.md`.

## Restore SD refusal diagnostics, 2026-09-06

The subsequent `2BDA` screenshot identifies the failure as metadata input
open: `FILE: RESTORE.meta`, `SD STAGE: OPEN INPUT`, result `4`. It shows
`PATH WORDS: 46 HEX`, `P0 7373412F`, `P8 74656D2E`, and flags zero.
The copied screenshot is `build/hardware/2bdad36/20260906_205020.png`, SHA-256
`b4b760c2d6b21ddd7787fcc8e7987063f99fb93ca6a8b61f6a90ef37ba8ffc8a`.
No metadata read, save read, or recovery creation was reached. Cartridge save
writes remain compiled out. The failure is now localized to the first open,
but its cause is still unproven.

The expanded regression exercises the actual SPI peripheral, command
registers, and extracted top mux. A 16-word chunk model produces the same
70 response observations while all 264 structure bytes arrive correctly,
in both endian modes. Continuous and eight-word chunk tests also pass.
The extra four observations alone are therefore not evidence of corruption.
Chunking is a compatible hypothesis, not a capture of Pocket firmware's
actual read order. Injected error 4 still tests refusal handling only.

The installed diagnostic revision changes no file protocol or write gate. It
captures all 40 path bytes, unique and repeated word counts, the first four
repeated indices, flags, size, and the first mismatched response with its
expected value. It taps the selected top response, not just the file
service's output. The mismatch remains latched after a subsequent clean
reread. The UI renders the complete path, NULs, and unread/non-ASCII bytes.
Both complete-path checks and deliberately corrupted-response tests cover
this instrumentation. Source is `05af4a96598975de3579136ed2654323afc8c76c`,
stamp `05AF`. All 44 simulation and structural checks passed. The retained
log is `build/restore/simulation-05af4a9.log`, also copied into
`build/restore/candidate-05af4a9/`, SHA-256
`155a177b4aa250c1a668342c8400a9bd6e3da6accf8e6a4ea1732b87cacfcb91`.
The exact-source kira fit completed with `rc=0` in 957 seconds using Quartus
Lite 25.1 build 1129. Setup `+0.664 ns`, hold `+0.123 ns`, minimum pulse
width `+0.827 ns`; 7,944 ALMs and 129 RAM blocks. No timing constraints changed.

```sh
../tools/runner-build job kira pocket-cartridge cart la-restore-full-path 05af4a9
../tools/runner-build fetch kira pocket-cartridge cart la-restore-full-path 05af4a9
```

Artifacts are retained under ignored `build/restore/candidate-05af4a9/`,
including ZIP, bitstream, report, build log, simulation log, and extracted
package. ZIP integrity passed, the packaged bitstream matches the fetched
one, and packaged `data.json` matches committed source.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.05af4a9.zip` | `ee9e95a597a64841123bc45558c372dfce755d317c729f12094b6b6eba0359fb` |
| `bitstream.rbf_r` | `9890f45be68d08515e31a319073e198a5b11e190b0f17fe41b53f6bfff3c8d30` |
| `report.txt` | `af7d78e41d65b50c7469029f186def73bdd5b45156ef0ab50f6d04b90d722c44` |

Installed on 2026-09-06 local time as `0.9999.05af4a9`, stamp `05AF`.
The card was remounted during the build. Before installation, `2BDA` and
both prepared inputs still matched their recorded hashes. The complete
14-file package was merged, flushed, and compared byte for byte. Both
restore inputs remain unchanged; no ROMs, saves, or screenshots were removed.
Replaced files are retained under
`build/restore/deploy-05af4a9.R04WMw/before/`, alongside the exact deployed
files in `package/`. The installer left the card mounted as requested.

That hardware check is now complete: `05AF` still reports metadata-open
error `4`, with the full path trace recorded in the pause section above.
Do not ask for the same screenshot again as if it were pending. Cartridge
save writes stay compiled out. No malformed-path fix or hardware restore is
claimed, and any new recovery file must still be preserved locally.

### Retained 2BDA deployment record

Installed `B458` reached the restore stop screen on hardware with
`SD FILE OPERATION FAILED` / `SD ERROR: 4`. It did not complete preflight.
The screenshot was copied and hash-verified off-card before analysis:
`build/hardware/b458927/20260906_194810.png`, SHA-256
`9c38bc14fc60b3026691a0a10b9411b5262627d3e2a34c813378b8af5f03bc10`.
Both prepared restore inputs still matched the retained originals at that
read. Cartridge save writes were compiled out and remain so.

The failed command is not identified by B458's screen. APF error 4 on an
open-file command means malformed path, but the screen alone does not prove
which operation failed or why. Do not rename files or change byte order on
that evidence alone. No root cause has been reproduced yet.

The next candidate adds retained file-operation diagnostics without changing
the file protocol or write gate: build stamp on the restore page, the actual
input or recovery filename on SD failure, the last operation stage, observed
path-response count, path words 0 and 8, and flags. The observer samples the
held response before `bridge_rd`, matching the existing peripheral contract;
the hex words use the internal byte-zero-low representation. Trace details
remain visible after refusal and are hidden when a new attempt starts.
`docs/SAVE-RESTORE-PLAN.md` explains the expected values and their limits.

The new `check_restore_bridge` runs the actual command registers and file
service with command/response mux expressions extracted from `core_top`.
It checks all 264 path-structure bytes in both endian modes, all three file
operations, refusal propagation, and two deliberately broken mux variants.
Injected APF refusals test containment, not a reproduction of the firmware
failure. File-service and UI regressions also check retained trace output.

Exact diagnostic source is `2bdad36f6b68fd6c19778dd32e2d674ea2188a08`, stamp
`2BDA`. All 44 simulation and structural checks passed. The retained log is
`build/restore/simulation-2bdad36.log`, SHA-256
`3f45a9955bcd536b9471f747f3c097a8d2765314ddf7bf6645eb49259e7cac3b`.

The first sisko start attempt was refused before launch because its lock was
held by `pocket-gba` job `p5cart-seq20-s1` at `85bb71a90452`. That is the
sibling's new 20/6 sequential timing build, not this restore candidate. The
user then approved kira, where the exact-source job completed with `rc=0` in
790 seconds using Quartus Lite 25.1 build 1129. Worst setup was `+0.556 ns`,
hold `+0.065 ns`, and minimum pulse width `+0.827 ns`; 6,968 ALMs and 129 RAM
blocks. No timing constraints changed.

Inspect or refetch this completed job with the exact source commit, not a
later documentation-only HEAD:

```sh
../tools/runner-build job kira pocket-cartridge cart la-restore-sd-trace 2bdad36
../tools/runner-build fetch kira pocket-cartridge cart la-restore-sd-trace 2bdad36
```

Artifacts are retained under ignored `build/restore/candidate-2bdad36/`.
ZIP integrity passed, the packaged bitstream matches the separately fetched
one, and packaged `data.json` matches committed source.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.2bdad36.zip` | `1782723ce58035d7af52e040b2908b9a7e2d3dd86a391588461ff0e03d7f279e` |
| `bitstream.rbf_r` | `abda045f006e0a7a9388a0aa44b34b2952ad1adbbe8dd300d3088ebab690cfb0` |
| `report.txt` | `7b9d54f7376c4c30ea49fecf572bbbb05fb5d31582e4d0de2a94680b4b946703` |
| `simulation-2bdad36.log` | `3f45a9955bcd536b9471f747f3c097a8d2765314ddf7bf6645eb49259e7cac3b` |

Installed on 2026-09-06 local time as `0.9999.2bdad36`, stamp `2BDA`.
The full 14-file package was merged, flushed, and compared byte for byte.
`RESTORE.sav` and `RESTORE.meta` remain unchanged and match the retained pair.
Other saves, ROMs, and screenshots were untouched; the card was left mounted.
Replaced B458 files are retained in
`build/restore/deploy-2bdad36.TF78ra/before/`, alongside the exact deployed
files in `package/`.

Keep `RESTORE_WRITE_ENABLED=0`. The subsequent `2BDA` hardware result is
recorded above. Preserve any new recovery file locally. This is a diagnostic build,
not a claimed fix for error 4 or a qualified cartridge restore.
Do not enable save writes until a complete preflight and an independently
verified recovery backup survive power-cycle and remount.

## Restore controls revised, 2026-09-06

Hardware feedback on installed `54CB`: the five-tap/button-sequence path
returned to ordinary dump controls unexpectedly. The old guard did return to
LOCKED on an out-of-sequence button. Do not continue using that UI procedure.

The replacement is Hold Select 3 seconds, release, A press/release for checks
and backup, then a fresh A hold for 3 seconds after checks pass. Both holds
show progress. Wrong buttons keep the page open; B closes or safely stops it.
All buttons must be released before normal scan/dump controls can resume.
The main screen now advertises restore only for supported cartridge geometry.

Candidate `b458927`, package `0.9999.b458927`, stamp `B458`, passed all 43
simulation and structural checks, including nine deliberately broken
integration variants. Sisko job `la-restore-hold-gates`, through
`../tools/runner-build`, returned `rc=0` after 447 seconds. Quartus Lite 25.1
build 1129 reported setup `+0.895 ns`, hold `+0.102 ns`, minimum pulse width
`+0.827 ns`, 6,456 ALMs and 129 RAM blocks. No timing constraints changed.

The full package was installed on 2026-09-06, flushed, and all 14 files compared
byte for byte. The existing `RESTORE.sav` and `RESTORE.meta` were not replaced;
their hashes still match the retained prepared corpus pair. Other saves,
dumps, and screenshots were untouched. Replaced files are retained under
ignored `build/restore/deploy-b458927.AEpxhJ/before/`, with deployed files in
`package/`. The card was left mounted.

Artifacts and logs are retained under ignored `build/restore/candidate-b458927/`.
ZIP integrity passed, its bitstream matches the separately fetched artifact,
and its data-slot definition matches committed source.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.b458927.zip` | `cf1c97b59f472b387f4a9159d646f6db13b4b82933b189ff94878609675c7a85` |
| `bitstream.rbf_r` | `32bd83e2917348ec628c138896df58390723e6bdd1a9a0fc7aacb2798bce26a6` |
| `report.txt` | `34f91ef2a4ad11c4460ec9eb0f396ff2b9ec87dd5917c8e98a38ad6f16b64d3a` |
| `simulation-b458927.log` | `8f49ce8a5cd1cd4d2203221fa048dea5344f4b254d92745f8ea86f10b70ea5b3` |

`RESTORE_WRITE_ENABLED` remains zero. The subsequent hardware attempt reached
an SD error rather than the expected preflight completion; see the diagnostic
entry above. Expected completion remains `CHECK COMPLETE` / `WRITES DISABLED`.
After power-cycle
and remount, copy the new `PREhhhh.sav` off-card and compare all bytes before
enabling any save writes. No actual hardware restore is qualified yet.
Use `docs/SAVE-RESTORE-PLAN.md` for the remaining original/different/original
restore acceptance sequence.

## Previous restore preflight candidate, 2026-09-06

The timing-clean candidate is exact code commit `54cb159`, package
`0.9999.54cb159`, build stamp `54CB`. It is retained locally and was installed
on the card on 2026-09-06. Cartridge save writes are still compiled out. This is
a hardware preflight candidate, not a verified restore release.

- All 43 simulation and structural checks passed. The retained log is
  `build/restore/simulation-54cb159.log`.
- Sisko job `la-restore-crc-pipeline`, run through `../tools/runner-build`,
  returned `rc=0`. Quartus Lite 25.1 build 1129 took 444 seconds.
- Setup `+0.795 ns`, hold `+0.122 ns`, minimum pulse width `+0.827 ns`;
  6,383 ALMs, 129 RAM blocks. No timing constraints were relaxed.
- ZIP integrity passed; its embedded bitstream matches the separately fetched
  bitstream, and its data-slot definition matches the committed source.
- ZIP, bitstream, reports, build log, and simulation log are retained under
  ignored `build/restore/candidate-54cb159/` as well as the generic build output.

| Artifact | SHA-256 |
|---|---|
| `kroy.CartTools_0.9999.54cb159.zip` | `3ba4a32bee37428ebe094cbbfc889a5ffac67da48a710b40ab6782743112c607` |
| `bitstream.rbf_r` | `3d1adf695fddb72132332922b026e0f3cb36200e490c60a9c8b58e5cbd6696d2` |
| `report.txt` | `6933ed8dedf64e568cb448020d5947c7be55aafc12d4952a4cbf5e99b550e80c` |
| `simulation-54cb159.log` | `8f49ce8a5cd1cd4d2203221fa048dea5344f4b254d92745f8ea86f10b70ea5b3` |

Deployment is complete: the full package and both prepared files from
`build/restore/la-nondx/` were copied onto the card, then flushed and all 16
files compared byte for byte. The restore pair is in
`Assets/carttools/common/`. Replaced files are preserved under ignored
`build/restore/deploy-54cb159.WCI4Vm/before/`, alongside the exact deployed
files in `package/`. Existing ROMs, saves, and screenshots were not removed.
The card was left mounted. Preserve every corpus original and released package.
The UI was subsequently rejected by hardware feedback; the replacement above
needs a new build before repeating write-disabled checks. Preserve any new
`PREhhhh.sav` off-card after power-cycle and remount, and compare it with the
current cartridge baseline before enabling save-memory writes. The expected
write-disabled result remains `CHECK COMPLETE` / `WRITES DISABLED`.

`runner-build fetch` also copies packages from failed builds. A successful
fetch is not a timing pass. Candidate `13fd4c6` remains rejected; use the
explicit `54cb159` ZIP rather than an arbitrary newest file in `build/cart/`.

## Save restore development, 2026-09-05

Work is on `save-restore-la`, starting from released-main commit `3b62eac`.
First target: original GB Link's Awakening, MBC1+RAM+BAT type `03`, RAM code
`02`, one 8 KiB bank. The verified Batch 6 ROM and save remain intact, with
matching independent copies in the retained library. Prepared single-save
input and identity metadata are under ignored `build/restore/la-nondx/`.

`docs/SAVE-RESTORE-PLAN.md` owns the new transaction and hardware gates. The
first candidate clamps cartridge save writes off. Qualify exact file sizes,
input byte order, ROM matching, two original-save reads, recovery name collision
handling, backup preallocation, and reopened SD readback first. Then copy that
new backup off-card after remount and compare it to the retained original.

Authorization requires five Select press/release cycles, X preflight, Y then X,
and a continuous three-second A hold. Both preflight and final confirmation
request the existing GB-first platform safety probe. The staged file is bound
to a full ROM CRC through `RESTORE.meta`; its filename carries no identity.
Only after these gates are physically proven should the MBC1 writer be enabled.

APF soft reset and user cancellation must drain operations and disable RAM.
Cold FPGA reset, clock loss, power loss, and physical cartridge removal cannot
guarantee an intact last write. APF command timeouts poison the file service
until core reload so a late reply cannot authorize a subsequent operation.

The automated checks exercise the enabled writer as well as the default
write-disabled engine, including exact data, ROM identity, staged-buffer
ownership, recovery-file errors, cartridge changes, cancellation, and two
post-write comparisons. The pin test sweeps 1,665 cancellation positions
across abort, authorization loss, and writer reset. Separate top integration
checks covered the actual action gates and rejected eight deliberately broken
variants. These are simulation evidence, not hardware qualification.

The exact released ZIP, bitstream, and timing report have an additional ignored
copy in `build/restore/released-baseline/` before candidate outputs replace the
generic files in `build/cart/`. No card deployment is implied by a local fit.

Candidate `13fd4c6` passed all 43 tests, including the separate 512 KiB ROM
case, but failed setup timing by 0.554 ns on sisko. Do not install that ZIP.
Detailed paths are retained under ignored `build/restore/timing-13fd4c6/`.
The failing path ran from staged-save BRAM through CRC calculation and final
equality into error/timer control. The next revision compares the registered
final CRC one cycle later, without weakening the check or timing constraints.

The release details and dated investigations below remain historical evidence.

## Released baseline, 2026-09-05

`v0.9999.250d6a0` is published from exact commit `250d6a0`. The feature branch
was fast-forwarded into `main`, the final save-count correction was pushed, and
this checkout is back on `main`. GitHub runs simulation and release-artifact
verification only. Quartus fits run on sisko or kira through
`/home/kroy/Desktop/repos/pocket-dev/tools/runner-build`.

At release, there was no pending hardware candidate. The original follow-up
list was:

1. Add an independent second save read and compare before reporting success.
2. Add GBA 128 KiB Flash backup only after its bank-select write is fully
   modeled and safety-tested.
3. Design save restore as a separate write-safety project for both platforms.
4. Expand physical coverage for MBC2, MBC3, RTC, and large MBC1 cartridges.

The dated sections below preserve how the released behavior was established.
Labels such as "candidate", "awaiting hardware", or "not yet re-dumped" are
historical state at that point in the investigation, not current instructions.

## GBA safety-gate fix passed the wider hardware regression, 2026-09-04

Commit `250d6a0`, build stamp `250D`, is the current hardware candidate. The
same GBA control that repeatedly failed under the preceding builds could not
be made to fail under repeated manual rescans. The following fresh capture
then passed the wider scan and dump regression: NHL 2002, Metroid: Zero
Mission, SimCity 2000, Tetris Plus, and Oracle of Ages. That set includes both
previously unstable GBA cartridges plus GB and GBC controls.

The diagnostic sequence located the defect precisely:

1. `21a0da6` exposed whether a failure came from the GB-first safety gate or
   the GBA header reader. Hardware reported `GB SAFETY GATE`. Only about one
   scan in ten advanced far enough to recognize the GBA cartridge.
2. `9c55408` added weak pull-ups to `cart_tran_bank1`, the bus actually sampled
   as GB `D0-D7`. The success rate improved to roughly four or five scans in
   ten, confirming the floating input path but proving weak pull-ups alone were
   insufficient.
3. `250d6a0` actively precharges bank 1 to `FF` while the GB bus is idle and
   both strobes are inactive. A read releases the bus at the start of the
   existing 200 ns address setup window, before `/RD` falls. A real GB
   cartridge only drives these pins while `/RD` is low. The direct bus test
   asserts the idle value, inactive strobes, release before reads, and absence
   of contention.

The original `c745719` pull-ups on banks 2 and 3 did not address this failure.
Those banks carry the GB address output during the safety probe. Bank 1 is GB
data and maps to GBA `A16-A23`, which a GBA cartridge leaves as inputs. The
partial improvement from the correct bank 1 pull-ups and the clean precharge
result tie the failure to that floating path.

The exact archived Quartus 21.1 `e510c8e` bitstream also showed the broad
intermittency. That excludes Quartus 25.1 as the sole explanation, while the
successful `250D` result shows the 25.1 build can operate the reproducer
reliably once the bus is precharged.

**Build and evidence:**

- Branch `gba-eeprom-save`, current hardware candidate `250d6a0`.
- Full runner test suite passed on sisko.
- Built through `/home/kroy/Desktop/repos/pocket-dev/tools/runner-build`.
- Quartus Lite 25.1 build 1129, 347 seconds, 3,901 ALMs.
- Timing passed: setup 1.549 ns, hold 0.109 ns.
- Package `build/cart/kroy.CartTools_0.9999.250d6a0.zip`, SHA-256
  `2736deb674613ac268ec6e1eb873eaf30f5d4f3eca101a568fe45021b1414fff`.
- Bitstream SHA-256
  `2932ed7c67ed1658eb4cb4ff813db3a1180e09132c89806c6509da1ad8a3d596`.
- The installed package was compared byte for byte with the ZIP before the
  card was safely unmounted.
- The full preceding dump, save, and screenshot set remains preserved under
  `build/evidence/batch-5-unstable/`. Do not delete or overwrite it.
- The fresh regression is preserved under
  `build/evidence/250d-safety-regression/`. All five ROMs match No-Intro by
  CRC32 and size. Every save present was loaded successfully in mGBA. SimCity
  2000 has no new save file in this capture and remains a capture-specific
  exception under the corpus rules.

## EEPROM capacity probe corrected again, awaiting hardware, 2026-09-03

Super Mario Advance is the first 512-byte EEPROM cartridge through this path,
and it disproved the size probe's remaining simulation-only assumption. A
14-bit request to the narrow chip is not silent. It answers using the first six
address bits. The resulting 8 KiB dump contained four distinct 8-byte blocks,
each repeated 256 times. Cleaning the cartridge pins and dumping again produced
the exact same bytes.

The probe no longer treats a wide response as proof of an 8 KiB chip. It reads
wide blocks 0 through 63 and compares them with block zero. A 512-byte chip
aliases all 64 requests to the same physical block. An 8 KiB chip changes as
the block number changes. The saved hardware captures separate cleanly: Minish
Cap, NHL 2002, and SimCity 2000 differ at block 1, Zelda Nayru differs at block
2, and only Super Mario Advance repeats block zero through block 63.

`gba_eeprom_model` now models both hardware observations: short-to-wide returns
a wrong block, and wide-to-narrow aliases. The probe test checks that a wide
chip stops after the first difference and a narrow chip consumes all 64 alias
checks. All 33 checks pass. For the mutation check, forcing every request to
block zero made the test call the wide chip 512 bytes; restoring the block walk
made it pass again.

The repetition test is data-dependent. A real 8 KiB save whose first 512 bytes
are one repeated 8-byte value would look narrow, and all-FF remains
indistinguishable from open bus. The latter is refused. The candidate needs a
Quartus fit, a 512-byte Super Mario Advance dump that loads with the live state,
and a Minish Cap regression dump before the general EEPROM path can be called
verified.

## Both EEPROM defects fixed, on the card, not yet re-dumped, 2026-09-03

**Minish Cap gave up save data**, and then gave up both defects in the path
that read it. The read itself was never in doubt: reversing each 8-byte block
of the first dump produced `ISH CAP:ZELDA 5`. The request, the 68-bit read and
the block walk all work against a cartridge.

**1. Byte order inside a block.** The byte the chip sends first is the LAST
byte of the block in the file. `cart_save_gba_eeprom` emitted in arrival order,
which gives a file of exactly the right length that no emulator can read.
Fixed by emitting `io_data[7:0]` first and shifting the block down instead of
up.

**2. The size probe.** It rested on a chip refusing a request of the wrong
address width. Only one direction actually refuses.

| | |
|---|---|
| 6 bit request to an 8 KiB chip | **answers**, with a block that is not the one asked for |
| 14 bit request to a 512 byte chip | silent: the over-run aborts the read it had started, and open bus is all ones |

So the wide request is the only one that discriminates, and it now goes first:
four attempts at 14 bits, then two at 6, first answer wins. Several blocks at
each width because the test is "did anything come back" and a blank block reads
all ones exactly like a chip that said nothing.

**Every 14 bit probe address keeps `addr[7:0]` clear**, and that is a safety
constraint, not a style. A 512 byte chip reads the over-run bits as a fresh
command, and an over-run beginning `1 0` is a WRITE command aimed at somebody's
save. Zeros are hunted for a start bit and discarded. Anything added to that
list must keep the low eight bits clear.

**The model was the reason simulation missed both.** `gba_eeprom_model` was
written from the same reading of the protocol as the module, so the testbench
agreed with the bug and every mutation still failed correctly. A model and a
module that share an assumption do not test that assumption at all. It now
answers an under-run rather than staying silent, which is what the cartridge
does, and `tb_gba_eeprom_probe` fails if the widths are tried the old way
round. Both fixes were mutation-checked: reverting either kills its testbench.

**What is verified and what is not.** The 8 KiB branch is settled on a
cartridge. The 512 byte branch has only ever run in simulation, because no
512 byte EEPROM cartridge has been through here, and it rests on the over-run
above. Distrust it first if a small save ever comes out wrong.

**Unexplained, and nothing depends on it.** The 6 bit request to Minish Cap
came back with the block two along from the one asked for. No mechanism is
known for the offset. The `+ 14'd2` in the model reproduces the observation;
what the model is asserting is only that an under-run answers with the wrong
block.

**The prediction to check.** A correct dump should be **8,192 bytes**, and the
save should open in mGBA. The first dump's block 0 was the string `ISH CAP:`,
which reads as the middle of `AGBZELDA:THE MINISH CAP:ZELDA 5`. If the new
file still starts there rather than at the beginning of that string, the byte
order is fixed but the block addressing is still off and the probe is not the
whole story.

**Where things are.** Branch `gba-eeprom-save`, `0513dcf`, nine commits, not
pushed. 33 testbenches. The card carries `0.9999.0513dcf`, setup 1.065 ns,
hold 0.065 ns, 3,870 ALMs, md5 `b709d0d5`, and is mounted. Both numbers are
better than the build it replaced. Three earlier dumps and their saves are on
the card alongside the Minish Cap pair, which is still the 512 byte one.

**Next, in order.**

1. Re-dump Minish Cap's save. Check the length first: 8,192 or the fix did not
   take.
2. Load it in mGBA. That is the only thing that proves a save.
3. Only then touch the docs that still say EEPROM is refused: `README.md`,
   `docs/STATUS.md` v0.9, and `FOR-ORCHESTRATOR.md`. They are correct about
   `main` and wrong about this branch, and they stay that way until a save
   loads.

## The write defect is fixed, and verified on hardware, 2026-09-02

**A cartridge latches write data on the WR# rising edge.** `gba_cart_bus`
raised WR# and released the data in the same instant, so what a cartridge
captured was whatever the floating bus settled to, at an address the module
had already selected. In save space that is a corrupted byte in somebody's
save.

`ST_WRITE` is the only state where this can happen: `ST_WRITE_SETUP` has not
pulsed yet, `ST_WRITE_HOLD` has already raised WR#. A reset landing there now
goes through `ST_WRITE_ABORT`, which raises WR# and holds the data for
`WRITE_HOLD_CYCLES` before releasing. The write is still truncated, and must
be, but the cartridge captures the byte that was asked for.

**A `cart_mode` drop is deliberately not sequenced.** `cart_mode` is
`cart_play & cart_power`, so a falling `cart_mode` means the slot is losing
power, and driving pins into an unpowered cartridge is the worse fault. The
pin gates are combinational on it for that reason. What is removed is the
internally chosen case: `cart_mode_hold` freezes the mode request while
`write_active` is high, so a requester changing its mind cannot tear the
connector down under a live write. Extracted into its own module because
nothing simulates `core_top`, and a fix left inline there would be untestable.

`tb_gba_cart_async`'s KNOWN DEFECT block is now a check that the truncated
write is attributable to save space and delivers `A3`. It said it would fail
when the module was fixed; it did, and it was updated to the new behaviour
rather than around it. New `tb_cart_mode_hold`. 30 testbenches.

**Verified on hardware, `0102c92`.** Three cartridges, three save
technologies, both bus engines. Every file that had a prior read came back
byte for byte identical, `cmp` and not just a hash.

| Cartridge | Path | Result |
|---|---|---|
| Golden Sun | GBA Flash 64 KiB | ROM and save identical to the previous read |
| Zero Mission | GBA SRAM 32 KiB | ROM and save identical to the previous read |
| Oracle of Ages | GB/GBC save RAM, 8 KB | ROM matches No-Intro and its own checksums; save is a first read, loaded in mGBA and confirmed |

Oracle of Ages is the one that matters most here, because `cart_mode_hold`
sits between the two engines: a GBC dump and save means the request was held,
released and handed to the other engine, and both read correctly.

**It buys timing, once the hold is a register rather than a mux.** All three
on the same runner, same seed, scratch wiped between:

| | Setup | ALMs |
|---|---|---|
| Before the fix | 0.762 ns | 3,573 |
| Fix, request muxed | 0.511 ns | 3,670 |
| Fix, request registered | **1.208 ns** | 3,591 |

The mux cost 0.251 ns and 97 ALMs, which is far more than two bits of
selection should, because `cart_mode_req` feeds `gb_mode_s` and `gba_mode_s`
and from there the `cart_mode` of both engines: putting `write_active` in
front of that fanout replicates it. Driving the same signal from a flop
instead starts the fanout at a register and ends up **0.446 ns better than
the code without the fix at all**, because the mode request was combinational
from `dump_want_mode` through to both engines before any of this.

The price is that a mode change lands a cycle later. `cart_pins` registers the
mode into its own `mode_q` and runs a settle counter of tens of cycles from
there with `mode_ready` low throughout, so nothing downstream can observe it.

The fit is deterministic: a repeat build of the muxed version gave the same
slack and the same bitstream md5.

## Forty-one dumps, all externally matched, 2026-09-02

**Every image this core has produced matches a published record.** Checked
against the No-Intro DATs, 7,572 entries: forty-one dumps, forty-one present
by CRC32, and the recorded size agrees in every case. `scripts/match_dats.py`
runs it. `docs/STATUS.md` has the full entry under "Every image matches a
published record".

Twenty-six GB/GBC and **fifteen** GBA. Every count in these documents said
twelve GBA. `NHL_2002.gba` and `SIMCITY_2000.gba` were dumped 2026-08-27 and
left out of the table written the same day; `SUPER_MARIOA.gba` was dumped
2026-09-01 during the GBA save work. All three pass `verify_dump.py` and all
three are in the DAT.

**Count from the artefacts, not from the narrative.** Every count here had
been carried forward by hand from the previous session's prose.
`scripts/match_dats.py` reads the disk instead.

The same check upgraded thirteen GBA dumps from "passes its own header" to
"matches a published record", and it had been available all along while this
file said "No No-Intro DAT is configured". **Before writing that something
cannot be verified, check whether the means to verify it is already to
hand.**

## Both GBA save sizes are verified, 2026-09-01

`ZEROMISSIONE`, 8 MB, **32 KiB SRAM**, loaded in mGBA with its file intact.
Kroy: "Confirmed working". That was the last untested path in the accepted
set, and it arrived on a cartridge nobody expected to have.

    0x1c    ZeroMissionUSAver005
    0x80    ZERO_MISSION_010
    0xcf    Planet Zebes...
    0x2d0    - Samus Aran -
    175 distinct byte values, four banks all different, crc32 6C90074B

| Path | State |
|---|---|
| Save type scan | **verified**, EEPROM and 128 KiB Flash refused on three cartridges, SRAM and Flash accepted |
| Flash 64 KiB | **verified**, Golden Sun |
| SRAM 32 KiB | **verified**, Zero Mission |
| 128 KiB Flash, EEPROM | refused, both need a write |

`NHL 2002`, `ANLE`, 4 MB, also came back refused, so it is EEPROM or 128 KiB
Flash. That is three cartridges the refusal path has been right about.

**`scripts/verify_dump.py` has the same defect the core just had.** It
cross-checks a `.sav` against the byte at `0x0149` of the ROM beside it, which
is a Game Boy header field, so it reported `FAIL size matches the cartridge
header, 0x0149 = 00 wants 0 bytes` on Zero Mission's perfectly good save. It
will do that on every GBA save. Not fixed.

## GBA save backup is verified on hardware, 2026-09-01

**Golden Sun. The first GBA save this core has ever taken, and it loads.**
Stamp `52B6`. `GOLDEN_SUN_A.sav`, 65536 bytes, crc32 `32F42D38`, loaded in
mGBA beside its own ROM dump. Kroy's verdict: "save confirmed load".

The file carries its own corroboration, which is unusual for a save:

    43 41 4d 45 4c 4f 54 ...     ASCII "CAMELOT" at offset 0
    CAMELOT again at 0x1000, 0x2000, 0x3000, 0x4000, 0x5000
    84.7% zeros, 0.5% FF, 222 distinct byte values

Camelot Software Planning wrote Golden Sun, and that header repeats once per
4 KB save slot. But the emulator is what proves it, as always: a save carries
no checksum, so nothing short of the game loading its own state counts.

**The assumption held.** A GBA Flash chip answers plain reads with no command
first. That was the load bearing guess behind accepting Flash at all, it is
now measured rather than assumed, and it means **a 64 KiB Flash save needs no
write to the cartridge.** `bus_wr` stayed tied low throughout.

**What is verified, precisely:**

| | |
|---|---|
| Save type scan on hardware | **yes**, EEPROM refused on two cartridges, Flash accepted on one |
| Flash 64 KiB backup | **yes**, Golden Sun, loaded in an emulator |
| SRAM 32 KiB backup | **no**. Same code path, never run: no SRAM cartridge to hand |
| 128 KiB Flash, EEPROM | refused, both need a write |

## Two defects the Golden Sun run exposed

**1. The evidence rows lie about a GBA save, and they lie in the dangerous
direction.** The screen said `SAVE RAM DID NOT ANSWER` and `first 00000000`
over a read that had just worked. `save_responded`, `save_blank_ff`,
`save_blank_00` and `save_first` are wired in `dump_engine` from
`cart_save_gb`, which never runs for a GBA save, so the screen was showing a
stale Game Boy verdict about a Game Boy Advance read. `cart_save_gba` was
built without any of the evidence outputs its GB counterpart has, and nothing
caught it because nothing had ever run it. **A save path that reports failure
on success is worse than one that reports nothing**, because the next person
re-dumps a good save chasing a fault that is not there.

**2. Y disappears for a second after a ROM dump.** A finished dump releases
`dump_want_mode`, the connector mode drops, and that is indistinguishable from
a cartridge being removed, so `scan_start` fires, `save_scan_valid` clears and
the whole ROM is scanned again to rediscover a save type that cannot have
changed. It comes back on its own, so nothing is stuck, but it is a needless
8 MB read and a confusing gap. The result should survive a dump of the same
cartridge and clear only on a real removal or on A.

## Flash 64 KiB, which needs no writes at all, 2026-09-01

Golden Sun, 8 MB, came back `save RAM here is not supported`. It is a Flash
cartridge, and refusing it was leaving an easy case on the floor.

**A GBA Flash chip powers up in read array mode and sits in the same
`0x0E000000` window as SRAM.** Commands are needed for chip ID, erase, program
and bank select. A backup does none of those, so **reading a 64 KiB Flash is
the same plain byte read `cart_save_gba` already does.** The change is the
accept condition in `core_top` and a size, not a new module and not a write
path. `tb_gba_save_write_protect` still holds at the pins.

    SRAM_V, SRAM_F_V      32 KiB   accepted
    FLASH_V, FLASH512_V   64 KiB   accepted, new
    FLASH1M_V                      refused: its first bank would read, but the
                                   second needs 0xB0 and a bank number written
                                   to 0x0E000000, and half a save is worse
                                   than none
    EEPROM_V                       refused: the address is clocked in, so
                                   reading starts with writing, and the string
                                   does not say 512 B or 8 KiB

`tb_cart_save_gba` gains a 64 KiB read, which is the largest this module can
be asked for and the one that runs the save window's 16 bit address to its
last value. An offset that wrapped would re-read the head of the chip and the
content check catches it.

**The assumption worth naming:** that Flash answers reads with no command
first. It is standard behaviour and it is why this works, but it is not
verified against a cartridge. Golden Sun settles it in one test, and this is
the change that lets that test happen.

## The GBA save scan works on hardware, 2026-09-01

**Verified.** Stamp `141B`, seed 5. Two GBA cartridges, nothing pressed, both
showing `save RAM here is not supported` on their own:

    GBAZELDA MC    16 MB    EEPROM    refused, correctly
    SUPER MARIOA    4 MB    EEPROM    refused, correctly

That row can only come from `gba_save_refused`, which needs `save_scan_valid`,
which needs `complete`. So the scan started after the size probe, waited for
the connector to turn round, read **every byte of a 16 MB cartridge**, found
the `EEPROM_V` signature and reported it. The whole path is exercised except
the part that reads a save.

**What this does not prove.** `cart_save_gba` has never run. No cartridge here
is SRAM, so the reader itself is still simulation only, and so is every
refusal other than EEPROM. Ambiguity has never been seen on a cartridge.

**What to try next:** a GBA cartridge that is actually SRAM, which is the
minority of the platform. Until one turns up, the reader stays unverified no
matter how many EEPROM cartridges are correctly refused.

## The same defect, twice, and what it should have been copied from

**Second hardware run.** The freeze was gone: Minish Cap at 16 MB, Super Mario
Advance at 4 MB and ZELDA all dumped clean on stamp `3AC8`. But both GBA
cartridges showed `A scan  X dump` with no save row at all, and a five second
wait with no button pressed changed nothing. Both are EEPROM cartridges, so a
refusal row was owed and never came.

**The scan was hanging, and for the reason the first fix should have found.**
`cart_probe` parks the mode. `gba_size_probe` drops `want_gba` in the same
cycle it raises `done`. `cart_pins` takes sixteen cycles to turn the connector
round. So `cart_mode` is low exactly when the scan starts, and
`gba_cart_bus` ignores requests while it is low and never raises `done`.

`gba_size_probe` already had all three defences, with comments saying why, and
`gba_save_scan` had none of them:

| | `gba_size_probe` | `gba_save_scan`, as shipped |
|---|---|---|
| `cart_mode` input | yes | absent |
| `ST_MODE` wait, with a timeout | yes | absent |
| Abandon guard if the mode drops | yes | absent |

That module's own comment records the abandon guard hanging it once and being
caught by case 11 of `tb_gba_size_probe`. **The lesson is narrow and worth
keeping: this module was written from `cart_dump_gba`'s shape, and the parts
that matter were in `gba_size_probe`'s scars.** A new bus master gets read
against the most bruised master on the same bus, not the tidiest.

**The fix.** `cart_mode` input, `ST_MODE` with the same 4096 cycle timeout, and
the abandon guard in the same shape. A new `complete` output, because without
it an abandoned scan and a ROM carrying no save string are the same answer and
only one of them means the cartridge has no save; `core_top` sets
`save_scan_valid` only when `complete` is set. And `save_scan_start` now holds
the mode as well, closing a one cycle gap where the request fell back to
parked idle between the size probe finishing and the scan asking.

**Four new cases in `tb_gba_save_scan`:** the mode arriving late, never
arriving, dropping mid-scan, and the next cartridge scanning normally
afterwards. Mutation checked: removing the `ST_MODE` wait or the abandon guard
makes the testbench **hang**, which is the hardware symptom reproduced in
simulation rather than described in a comment.

**Known and deliberately left:** pressing X while a scan is running abandons it
and nothing restarts it, so that cartridge shows no save row until A is
pressed. Worth fixing separately rather than bundled into a third emergency
build.

## The GBA save scan froze the core, 2026-09-01

**Shipped to the card, ran on hardware, broke it.** Kroy: "All the dumping
options disappeared and it froze up trying to dump both minish cap and super
mario advance", both cartridges that had dumped fine before. Two defects, one
cause each, and the fix is in `a624443`'s successor.

**1. The scan never asked for the connector.** `cart_probe` parks the mode at
idle when it finishes identifying. `gba_size_probe` already knows this and
raises `want_gba` for its whole run; its comment says so in as many words.
`gba_save_scan` had no such output, so it started after the mode was parked,
`gba_cart_bus` held its FSM in `ST_IDLE` because `cart_mode` was low - line
118, `if (reset || !cart_mode)` - and never raised `done`. The scan waited
forever with `busy` high.

**2. That stuck flag was wired into `cart_engine_busy`**, which `dump_ready`
gates on, so every dump option vanished and never came back. Only a core
reload recovered it.

Either alone would have been survivable. The first is a hang in a module
nobody has to press a button to reach; the second turned it into a dead core.

**The fixes.**

- `gba_save_scan` has a `want_gba` output, held for exactly as long as `busy`,
  and `core_top`'s mode mux honours it beside `sz_want_gba`.
- The scan is **out of `cart_engine_busy`**. It runs for seconds on a large
  cartridge and a ROM dump must stay available throughout, which was a
  regression in its own right even without the hang.
- The scanner is reset by `dump_busy` and by `scan_start`. Both take the bus
  through the mux, so it is abandoned rather than left waiting. Its result
  never becomes valid, so Y is absent rather than offering a read from a scan
  that never finished.

**What the tests did and did not do.** All 29 passed before the fix and all 29
pass after, which is the whole lesson: the invariant was never stated, so
nothing could check it. `tb_gba_save_scan` now asserts `want_gba == busy`
every cycle, and it is mutation checked both ways - removing the request
entirely, which is the bug as shipped, and dropping the hold one state early.
Both fail the run.

**The half that is still not covered.** Nothing here tests that `core_top`
honours `want_gba`. There is no core_top level testbench in this tree and this
change did not add one, so the integration half of both defects rests on
reading the mode mux rather than on a test.

## GBA save backup, started 2026-09-01

**In simulation only. Nothing here has seen a cartridge and nothing on the
device can reach it yet.**

Two new modules, both read-only, both in `ap_core.qsf`, neither instantiated
in `core_top`:

| Module | What it does |
|---|---|
| `src/fpga/services/identify/gba_save_scan.sv` | reads the ROM and reports which of the six SDK save library strings it saw, plus `ambiguous` when two families are present |
| `src/fpga/services/dump/cart_save_gba.sv` | reads SRAM out of the save window a byte at a time and emits the same byte stream `cart_dump_gba` does |

`make test` is 29 of 29, up from 26.

**Why SRAM only.** Of the five GBA save technologies, SRAM is the only one
that can be read without writing to the cartridge. Flash is identified by a
command sequence, 128 KiB Flash needs a bank select, and EEPROM is addressed
by clocking the address in. All three are writes, and **writes to a GBA
cartridge are blocked** by the open defect in `gba_cart_bus`: aborting inside
`ST_WRITE` raises WR# and releases the data pins on the same instant, so the
cartridge latches whatever the bus settles to. It is asserted in its real form
in `tb_gba_cart_async` under a KNOWN DEFECT heading. That defect is the gate
on v0.8 and v0.9, not a shortage of code.

**Why the type comes from a string and not a probe.** Same reason. The scan
reads the ROM, which costs time and nothing else. It reports what it saw
rather than resolving a winner, because a cartridge carrying two families of
string is a real thing and `plan.md` Phase 12 says ambiguous cases are
reported as ambiguous.

**One defect was found and fixed while writing the tests.** `gba_save_scan`
first compared the registered ten-byte window, which evaluates one byte
behind, so a signature ending on the final byte of the ROM was never tested:
the scan finishes on the same cycle that byte is fed. The window now includes
the byte being fed. `tb_gba_save_scan` covers it, and reverting the fix fails
exactly those two cases and no others.

**Every new test was mutation checked**, and each was watched to fail:

- stuck address, and a widened access, against `tb_cart_save_gba`
- a reader asserting `bus_wr` on one byte, against `tb_gba_save_write_protect`,
  which tripped four separate checks
- the registered-window defect, and a reversed byte order, against
  `tb_gba_save_scan`

`tb_gba_save_write_protect` also carries the built-in mutation `cart_save_gb`'s
does: phase 2 takes the bus off the reader and drives a deliberate write into
the save window, so a monitor that has quietly stopped working takes the run
down with it.

**Wired up, and it fits.** `dump_engine` has a fourth reader and the GBA bus
has a two master mux, the same shape the GB bus already had. `core_top` has
the scanner as a fourth bus master, ordered dump, scan, size probe, identify,
with `save_scan_busy` and `save_scan_start` both in `cart_engine_busy` so a
dump started underneath a scan cannot strand it waiting for a `done` the mux
took away. `save_scan_valid` clears on `scan_start`, so a scan result cannot
outlive the cartridge it describes.

**Nothing new reaches `ui_screen`.** A refused GBA save drives the
`ROW_NO_SAVE` row a refused GB save already drives.

**`scan_start` was already taken**, by `cart_probe`, which is the A button.
The save scan's signals are `save_scan_*` and the scanner's own results are
`svs_*`.

**A/B on `quartus-build`, sisko, identical conditions, scratch wiped between
runs.**

| | `9530316` baseline | `a94d78e` this branch | delta |
|---|---|---|---|
| Setup slack | 0.856 ns | 0.496 ns | **-0.360 ns** |
| Hold slack | 0.123 ns | 0.122 ns | -0.001 ns |
| ALMs | 3,391, 18% | 3,549, 19% | +158 |
| Registers | 4,466 | 4,761 | +295 |
| RAM blocks | 99 | 99 | 0 |
| Elapsed | 280 s | 299 s | |

Timing is met on every corner. **The worst setup path is the PLL output
counter in both builds, not `ui_screen` and not any of this**, so what changed
is congestion rather than a new critical path.

**The -0.360 ns was noise, and the sweep is what proved it.** Five seeds per
commit, ten builds, scratch wiped between every one, all rc=0 and all met
timing:

    setup slack, ns

    9530316   0.381  0.736  0.789  0.873  0.996    mean 0.755  spread 0.615
    a94d78e   0.667  0.702  0.883  0.888  0.979    mean 0.824  spread 0.312

The branch's mean setup slack is **0.069 ns higher**, not lower, and its worst
seed beats the baseline's worst seed. The baseline's own spread across seeds,
0.615 ns, is wider than the regression a single pair appeared to show. The
worst build in the sweep is the baseline on seed 3.

Hold is the same: baseline 0.028 to 0.124, branch 0.045 to 0.117, both dipping
on seed 5, so that dip belongs to the seed rather than to this change.

**Area is the real cost, and it is measurable precisely because ALMs barely
move with seed:** baseline 3383 to 3394, branch 3547 to 3554. **+164 ALMs,
about 4.8%**, 18% to 19% utilisation, +295 registers, no change in RAM.

Two things fell out of it. The default seed is a poor one for this design:
`a94d78e` first fitted at 0.496 ns, near the bottom of its own range. And
**`scripts/seed_sweep.sh` is stale** - it shells out to `docker` and writes a
`build_output/` layout this repo no longer has. The sweep ran on
`make cart SEED=n` instead, which is the maintained path.

**What is left:**
1. A cartridge to test on. Nothing in the set here is known to be GBA SRAM,
   and the type cannot be known until the scan runs on hardware.
2. EEPROM's string does not say whether it is 512 B or 8 KiB, so even were
   EEPROM readable the size would still be undetermined.
3. The write defect, if Flash or EEPROM is ever wanted.
4. `scripts/seed_sweep.sh` needs rewriting onto the current harness or
   removing. It cannot run as it stands.

## Where this was left, 2026-08-31

**Six new GB/GBC cartridges are on the card, structurally clean.** Written by
the core to `/Assets/carttools/common/`, five of them with a save beside the
ROM. Every ROM passes its Nintendo logo byte for byte, its header checksum,
its global checksum and the size its header declares. Every save is the
length `0x0149` declares, is not blank, and where it has four banks the four
banks differ. `scripts/verify_dump.py` on all thirteen files: `all checks
passed`.

| File | Bytes | Type | RAM | CGB | CRC32 | Save CRC32 |
|---|---|---|---|---|---|---|
| `DQM2_R_____BQLJ.gbc` | 4,194,304 | `1B` MBC5+RAM+bat | `03` 32 KB, 4 banks | `80` | `2C428A87` | `08BE7E23` |
| `YUGIOUDM4J_BY6J.gbc` | 4,194,304 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `C0` | `298BD054` | `6646D2D7` |
| `HAMUPARA2__BHMJ.gbc` | 2,097,152 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `C0` | `542C78B6` | `D29428FB` |
| `JINSEI_TOMOACJJ.gbc` | 1,048,576 | `1B` MBC5+RAM+bat | `02` 8 KB, 1 bank | `80` | `C8D46E99` | `A6F62B50` |
| `PNBALFRENZYVM2E.gbc` | 1,048,576 | `1E` MBC5+RUMBLE+RAM+bat | `02` 8 KB, 1 bank | `C0` | `364F9CCD` | `D6A21D0D` |
| `TYCORAT1___BTIE.gbc` | 1,048,576 | `19` MBC5 | `00` none | `C0` | `D6881014` | none |

**What these cartridges actually are.** The stem is the header's 11-character
title field, not a name: a cartridge whose retail title is longer spends those
characters on whichever part of it fits, so the stem cannot be expanded back
into a title by reading it.

**Resolved 2026-09-02, and not by reading the stem.** Each image was matched
by CRC32 against the No-Intro DATs, with `scripts/match_dats.py`. The identity
comes from the hash of the whole image; the stem played no part in it, which
is the only way this table is allowed to be filled.

| Stem | Game code | Cartridge | Matched by |
|---|---|---|---|
| `PNBALFRENZY` | `VM2E` | Disney's The Little Mermaid II: Pinball Frenzy | `364F9CCD` |
| `DQM2_R` | `BQLJ` | Dragon Quest Monsters 2: Maruta no Fushigina Kagi, Ruka no Tabidachi (Japan) | `2C428A87` |
| `YUGIOUDM4J` | `BY6J` | Yu-Gi-Oh! Duel Monsters 4: Battle of Great Duelist, Jounouchi Deck (Japan) | `298BD054` |
| `HAMUPARA2` | `BHMJ` | Hamster Paradise 2 (Japan) | `542C78B6` |
| `JINSEI_TOMOA` | `CJJ` | Jinsei Game: Tomodachi Takusan Tsukurou yo! (Japan) | `C8D46E99` |
| `TYCORAT1` | `BTIE` | Racin' Ratz (USA) | `D6881014` |

`TYCORAT1` is the one that shows why the rule exists. Nothing in that stem
says Racin' Ratz, and no amount of staring at it would have produced the
answer that one hash lookup did.

**What this closes.** `docs/STATUS.md`'s hardware coverage table stopped at
1 MB for MBC5 and at one save size.

| Gap | Closed by |
|---|---|
| MBC5 ROM above 1 MB | 2 MB, and 4 MB twice. 4 MB is 256 banks, so the ninth bank bit at `0x3000` is exercised on hardware for the first time |
| Cartridge type `1E`, MBC5+RUMBLE+RAM+battery | `PNBALFRENZYVM2E` |
| Cartridge type `19`, MBC5 with no RAM, at 1 MB | `TYCORAT1___BTIE`, and `Y` is correctly absent on it |
| RAM size code `02`, 8 KB, single bank | four cartridges. Only `03` had been read on hardware |
| A second cartridge through the four-bank save path | `DQM2_R_____BQLJ` |

**What is still open after them.** MBC2, MBC3 and MBC3 RTC. MBC1 above
512 KB, which is the case `cart_dump_gb.sv` expects to differ. RAM size codes
`01` (2 KB), `04` (128 KB) and `05` (64 KB). GBA saves, which are not started.
None of these six is a cartridge that could have covered any of them.

**Loaded in mGBA, 2026-08-31.** A save carries no checksum, so this is the
only check that can prove one. `tools/podman/play-dump.sh`, one cartridge at a
time, `ZELDA` first as a control and it came up intact. Screenshots were
kept locally in `screenshot_proofs/` and are gitignored.

| Cartridge | ROM | Save | Evidence |
|---|---|---|---|
| `DQM2_R_____BQLJ` | pass | **pass** | file select gives master name, `031:17` played, three monsters at Lv99/54/50, location. In world afterwards with gold and party HP/MP, which is what proves 4 MB high banks rather than a menu |
| `YUGIOUDM4J_BY6J` | pass | **pass** | records screen reads Duelist Level 255, Deck Capacity 2728. `2728` is `a8 0a` little endian at `0x4b7` and `0x11af` in the dumped file, stored twice and both copies identical |
| `JINSEI_TOMOACJJ` | pass | **pass** | character file holds five player entered names, slot 1/10, portrait rendered |
| `HAMUPARA2__BHMJ` | pass | **fail** | game refuses to let the cursor reach Continue. See below |
| `PNBALFRENZYVM2E` | pass | **pass** | the save reads correctly. Its battery was flat, measured 0 V and replaced, but the content differed between rips because the game was played between them, not because of the battery. See below |
| `TYCORAT1___BTIE` | pass | none | boots and plays. Type `19`, no save RAM, so `play-dump.sh` correctly reports no save rather than failing |

**Two cartridges are flagged as suspected battery failures, to be re-ripped
before anything is concluded from them.** Neither is evidence against the save
path: three saves of two sizes read correctly in the same session on the same
build.

`HAMUPARA2__BHMJ.sav` is noise. All 256 byte values present, no run of zeros
longer than 4, `0xFF` on 26.8% of bytes and alternating with data:

    80 ef 06 ff a6 ff e1 ff 8e ff 53 ff 25 ff 35 bf

The game's own checksum rejects it, which is the correct behaviour and not a
symptom of this core.

`PNBALFRENZYVM2E` had **two separate things going on, and treating them as one
answer is what took four rounds to unpick.**

**The battery was dead.** Measured at 0 V and since replaced. That is settled
by a multimeter, not by inference from bytes.

**The save read was correct throughout, and is not a core fault.** The ROM read
three times byte identical. Across four save rips the header
`44 41 56 45 dd ca ba aa` and the high score initials `BRO` were constant
while the six score digit bytes differed every time.

**Those digits changed because the game was being played between rips.** Every
digit in every rip was in the range 0 to 9 because they were scores. The table
read empty early on because it had not been played yet. And the contents
survived from one rip to the next despite the flat battery **because the
cartridge stayed powered in the slot** - it held the save until it was
unplugged, which is exactly what a dead cell with continuous power looks like.

**The mistakes, both worth keeping.** The first call, that the battery was
fine, came from a single rip whose byte 0 read `FAVE`; every rip since reads
`DAVE`, so one bit error carried a hardware recommendation and nobody said out
loud that it rested on one sample. Then, told the scores varied, the swing was
all the way to "nothing was wrong with the cartridge", which was equally
wrong.

**Proven, and to the byte.** The save loaded in mGBA and the high score screen
reads `1. BRO 1,009,441`. That number is in the file:

    0x37..0x3d   01 00 00 09 04 04 01     one digit per byte, high digit first
    0x3e..0x40   42 52 4f                 "BRO"

Seven digit bytes then three initials. Worth recording because the record
starts at `0x37`, not `0x38`: every round of analysis above read it as six
digits from `0x38`, which silently dropped the leading digit of every score
and then treated the remainder as evidence of instability.

**Three rules out of it.** Before theorising about data that changes between
reads, ask what the human did between the reads: a cartridge that has been
played is not a cartridge at rest and no byte pattern will tell you that. A
dead battery and a correct read are not competing explanations, they are both
true here, and a single answer that tidily covers every symptom is a reason
for suspicion rather than confidence. And **find where a record actually
starts before reading meaning into its contents**, because an off-by-one at
the front turns real data into noise and noise is what invites the theories.

`HAMUPARA2__BHMJ` is a different case and still looks genuinely dead: all 256
byte values present, `0xFF` alternating with data, longest zero run of 4, and
the game's own checksum refuses it. That claim now stands on one cartridge
with a poor track record behind it, and it has still not been dumped twice.

**One item belongs to `pocket-tools`, not here**, and is carried as open
item 5 in `pocket-dev/docs/HANDOFF.md`. `DQM2-R` is the first
cartridge on a real card whose title holds a character outside `A-Z0-9`.
`dump_path_gen.sv`'s `sanitize` turns it into `_` and the card says
`DQM2_R_____BQLJ.gbc`. `cheatgui/dumps.py`'s `core_stem` keeps `-`, so it
derives `DQM2-R_____BQLJ` and its `Dump.renamed` reports the file as renamed
by hand. The divergence is already written down in `docs/FILE-FORMATS.md`,
the row reading "basename may contain spaces, `-`, mixed case | uppercased;
everything outside `A-Z0-9` becomes `_` | differs". The core follows the core;
the app follows the spec. `core_stem` also does not uppercase, which no
cartridge on the card exercises yet. Route to the picker's session: the six
files here are the fixtures its `tests/test_dumps.py` was meant to be pinned
against, and `cart-dumps/`, `roms/` and `saves/` in that repo are still empty.

## Where this was left, 2026-08-26

Committed and clean on branch `hardware-bringup`, not merged to `main`.
`make test` is 20 of 20. The card carries `ec566cd`, stamp `EC56` on the
title row.

**GBA dumping is verified on hardware, and reproduces.** `gba_size_probe.sv`,
`cart_dump_gba.sv` and `dump_crc32.sv`, wired through `dump_engine` and
`core_top`. Twelve images at 4, 8 and 16 MB, every one passing the Nintendo
logo byte for byte, the header checksum, the `0x96` fixed byte and an entry
point that is a real ARM branch. Two are matched against published records.
Golden Sun and Minish Cap have each been dumped twice and are byte identical,
so the single-attempt caveat no longer applies to the GBA path.

`dump_crc32` agrees with `zlib` on hardware, and `dump_checksum` has now
caught a real bad dump rather than only agreeing with good ones - see
`docs/STATUS.md`.

The card holds `be33725`, stamp `BE33`, with `.gb`, `.gbc` and `.gba` naming
confirmed in the wild. The repository is at
<https://github.com/kroy-the-rabbit/openfpga-carttools>, first release tagged
`v0.1.0-alpha.1`.

**GB/GBC dumping works and is verified.** Eighteen cartridges dumped by the
core, from 32 KB to 1 MB across ROM-only, MBC1 and MBC5, plus four Game Boy
Color images. Every one passes its own logo, header checksum, global checksum
and size byte, except `TENNIS.gb` - see below. One is matched to a No-Intro
record by CRC32. `docs/STATUS.md` has the tables. The images are not in the
repo; they are on the card under `/Assets/carttools/common/`, except Link's
Awakening DX, which is off the card because a second Zelda cartridge
overwrote it and survives only in a copy.

**The on-device checksum has caught a real bad dump.** `TENNIS.gb` came back
corrupt and the screen said `image sum BB29 want E047`; both numbers were
confirmed independently on a PC. The header checksum on the row above it
passed, which is the same blind spot that let MarioLand2 through. This is the
first time that check has found something rather than agreeing with a good
cartridge. The re-dump is clean (`5009215F`), so the fault is intermittent;
what it correlates with is item 1 below.

**`TETRIS.gb` and `OTHELLO.gb` are resolved, and the earlier conclusion was
wrong.** This file previously recorded them as cartridges that probably ship
an incorrect global checksum. They do not: re-dumped on `ec566cd` both verify
completely, with different CRC32s (`46DF91AD` and `C17A002E`). The old files
were corrupt, in a way that is structured rather than random — the head of
each 1 KB window holding the head of a different window, with the same
relocation map in both cartridges. The mechanism is not identified; it has
not reproduced on `ec566cd`, and Tetris has since dumped identically four
times, but nothing in the difference between the two bitstreams plausibly
touches the chunk path. `docs/STATUS.md` has the evidence.

That caution has since been answered. Twelve cartridges were re-dumped in one
session, including all three that have ever failed, and every one came back
byte for byte identical. The dump path reproduces; what does not is the
connection to the cartridge. See item 1.

`MARIOLAND2.gb` was a bad contact and its re-dump verifies clean; the two
attempts differ in 105,121 bytes and every difference is bit 7 alone, which
is one data line reading randomly.

The diagnostic artifacts (`PROBE.gb`, `CARTDUMP.gb`, `SELFTEST.bin`) have
been removed from the card. `CARTDUMP.gb` was for the fallback that writes
into the slot's own file when `0x0192` is refused; that path still exists and
is tested, but `0x0192` works now and it has never been used on hardware.

## Position

Subtracted from Rai's cartridge-support branch of the Pocket GBA core, the
v0.4.0 lineage rather than mincer-ray's `master` (`docs/PROVENANCE.md`; the
abandoned first attempt is on branch `abandoned-master-base`). The emulator is
gone.

Identification is **verified on hardware** for both platforms: five cartridges
across two GB mappers, all three CGB flag values, both GB header layouts, and
two GBA cartridges. `plan.md`'s First Hard Stop is cleared.

Dumping is **verified on hardware** for both platforms: twenty GB/GBC
cartridges across ROM-only, MBC1, MBC1+RAM+battery and MBC5, and fourteen GBA
cartridges at 4, 8 and 16 MB. The core computes the GB global checksum itself
while dumping and a CRC32 on both platforms.

## Inherited code

`src/fpga/core/gba_cart_bus.sv` is unchanged from the fork, byte for byte, and
is the only module allowed to touch GBA-mode cartridge pins.
`tools/sim/check_pin_isolation.py` enforces that in the test suite.

Any `tools/sim/check_*.py` joins `make test` automatically - they run before
the testbenches and are reported the same way. `check_qsf_sources.py` is the
second: every `.sv` under the synthesised directories must appear in
`ap_core.qsf`. It exists because each testbench names its own sources in a
`// SOURCES:` header, so a new module compiles under Icarus the moment a
testbench asks for it and the whole suite goes green while Quartus has never
heard of the file. `cart_save_gb.sv` did exactly that: three testbenches
passing, and `Error (12006): instantiates undefined entity` on the runner.

Its author's own commit message is "Initial WIP on cart support. Not all save
types have been tested!". Specifically:

- Its testbench had never passed. It failed its own assertion 146 ns in, and
  the assertion was wrong rather than the module.
- That testbench overrode all six timing parameters to 1 or 2, so the numbers
  that reach a cartridge were never simulated. The suite now covers the
  defaults.
- Its `physical_cart_id` probe never worked: it drove request signals nothing
  was connected to, and captured whatever the emulator's ROM cache was
  fetching at the time.

## The traps

**A Game Boy cartridge in this slot will contend with the GBA bus.** On a GB
cartridge, `bank1` carries D0-D7 and the cartridge drives them on any read in
ROM space. `gba_cart_bus` holds `bank1` as an output for the whole
transaction, read window included. `cart_probe` is what keeps this from
happening: it probes GB first and escalates to GBA only when the GB probe
found nothing at all. Never reorder that. Established in
`docs/HARDWARE-NOTES.md`, asserted in `tb_cart_probe`.

**The core cannot tell you why an SD write failed.** From
`docs/APF-NOTES.md`: a full card, a write-protected card and a filesystem
error all return `target_dataslot_err` 5. `0x0188` flush is now implemented
and `apf_file_writer` checks every command rather than the last one, which is
the most that can be done. The error codes and what they narrow to are
tabulated in `docs/BRINGUP.md`.

**Aborting a write mid-pulse corrupts what the cartridge latches. Fixed for
the mode-change case; still open for slot power loss.** `e_ctl_out` and
`e_hi_oe` in `gb_cart_bus` are both gated by `gb_mode` combinationally, so
the instant the connector mode goes away `/WR` rises and the data pins
release together, on the edge a cartridge latches a mapper register on. The
strobe cannot defend itself, because `cart_pins` owns the pins and honours
the mode immediately.

So whoever changes the mode must wait for `gb_cart_bus`'s `busy` to fall
first, and `dump_engine` now does, including on an abort: the reader is
reset but the transaction it left in flight still completes on its own,
because `req` is only sampled in `ST_IDLE`. Bounded by one transaction, with
a counter as a backstop.

`tb_dump_engine` watches `want_gb` continuously and fails if it ever falls
while the bus is busy. That test was vacuous when first written — at a
three-cycle bus transaction an abort always arrived after the transaction
had finished, so it passed with or without the fix. It only became real once
the modelled transaction was made long enough for an abort to land inside
one. A monitor for a one-cycle window has to be shown to fire.

Still open: losing **slot power** mid-write does the same thing and nothing
here can prevent it, because `cart_mode_s` is the Pocket's decision. If VCC
is going away the cartridge has other problems, but the window during the
fall is real.

**A cartridge pulled mid-dump used to hang the core.** `gb_cart_bus` drops a
transaction when `gb_mode` goes away and never asserts `done`, so the reader
waited forever and so did everything above it, with `dump_busy` stuck high
blocking the probe. Recovery needed exiting the core. `dump_engine` now
watches `cart_powered` and turns it into a failure with error code 7, which is
outside the 0 to 5 APF returns. Covered by `tb_dump_engine` and
`tb_apf_file_writer`, including that the next dump still works.

## APF's file interface, measured

All of this is measured. Where an earlier version of this file stated
something confidently that had not been, it is called out below, because
that pattern cost four sessions.

**The read window is pipelined and both halves are required.**
`io_bridge_peripheral.v` holds the address from the SPI phase, waits four
clocks, samples `bridge_rd_data`, then pulses `bridge_rd`. So the address
must free-run: a window that waits for `bridge_rd` looks too late. And the
value the host keeps is the one presented during the **previous**
transaction, exactly as `core_bridge_cmd.v` does with the datatable. Free-run
the address, latch the data on `bridge_rd`. Getting only the first half right
makes every read arrive one word early, which reads as a malformed path, a
wrong byte order, a wrong struct layout, or anything else you happen to be
varying at the time.

**Byte order differs by direction.** On reads, byte 0 of an array is the low
byte of the word the core presents. On writes, `0x0190`'s reply put byte 0 in
the high byte. Do not reason from one to the other; that produced the wrong
answer twice.

**Paths are absolute from the card root.** `/Assets/carttools/common/NAME`.
APF confirmed it by describing its own output slot via `0x0190`.

**`0x0188` flush is not answered and must not be issued.**
`core_bridge_cmd`'s target state machine waits in `TARG_ST_WAITRESULT_DSO`
forever, so one stalled flush blocks every target command after it. It is off
behind `USE_FLUSH`. Writes commit without it. An earlier version of this file
called its absence a defect, on the grounds that it is documented. Being
documented turned out not to mean it is answered.

**Every command has a deadline.** There is no cancel and no documented upper
bound, so `apf_file_writer` gives each command about 1.8 seconds and reports
`err 6` with `stall_at` naming open, write or flush. Without that a core can
wait forever, and two sessions did.

**How to diagnose the next one in one screenshot.** On the diagnostics page, when it existed,
`<` cycles the four text rows between the cartridge header, APF's reply to
`0x0190` for slot 0, the same for slot 20, and the first 128 bytes this core
last handed APF. Reading what the far side received next to what this side
sent is what finally worked; everything before that compared a screen against
an intention. `0x0190` needs a file assigned to slot 0, so launch by browsing
to one rather than by Play Cartridge.

## Driving the bus

`req` is a level sampled in the bus's idle state, and its done state returns
to idle the cycle after raising `done`. A caller that holds `req` until it
sees `done` is one cycle too late and gets a second transaction. Drop `req`
the cycle after raising it, as `cart_identify_gba` does. Nothing in the module
enforces this.

## The cartridge is asleep for about two seconds after slot power

`cart_pins` only releases pin 30, which is `/RES` on a GB cartridge, once
`mode_ready` asserts. Read it any sooner and the first identification after
launch fails while every rescan succeeds, because a rescan follows a cartridge
that was awake moments earlier. `cart_probe`'s `WAKE_CYCLES` is 2 s and so is
`dump_engine`'s, for the same reason: `cart_probe` parks the mode at idle when
it finishes, so a dump starting afterwards is starting from reset again.

The constant works and is not explained. It may vary with cartridge or battery
level. Both modules parameterise it so testbenches can set it to a handful of
cycles.

## Timing hazards found in synthesis

Neither was visible in simulation. Both cost a failed build.

- **Constant division is not free.** `row = cell / 30` in the screen painter
  became an `lpm_divide`, an 11.4 ns path against a 9.93 ns clock, failing
  setup by 2.3 ns. Use counters that advance together. This is why the dump
  progress counter is displayed in hexadecimal.
- **The column path is walked six hundred times a repaint.** This failed
  setup three times: a divide by 30, then the dump bar and filename fields on
  top of an already deep mux, then a 128-byte text index with a multiply in
  it. The rule is not "avoid division"; it is that anything the screen
  selects per cell must come from a row chosen and registered in the cycle
  before.
- **Wide combinational reductions become the critical path even when they run
  once.** The header checksum summed 29 bytes in one block. Accumulating as
  the words arrive is two adds deep instead of twenty-nine. The same reasoning
  keeps `ui_screen`'s repaint comparator to 35 bits: only the low eight bits
  of the chunk count are in it.

Every milestone must build before moving forward.

## Tests

`make test` runs the suite in a container. Every testbench declares its
sources in a `// SOURCES:` header and must print `TB PASS: <name>` before
finishing: `vvp` exits 0 for a testbench that printed nothing, one that
stopped half way, and one that only called `$error`. Silence is failure.

`tb_dump_engine` is the one that matters for dumping. It reads a modelled
32 KB cartridge, crosses the payload into the bridge domain, answers the
target commands the way APF does, reassembles the file the way a little-endian
host would, and compares it byte for byte. It also covers a short trailing
chunk and a partial bridge word, which no cartridge size can produce, a failed
open, and a cartridge pulled at chunk 4 followed by a clean dump.

`tb_gb_save_write_protect` is the one that matters for saves, and it is the
first test here that **carries its own mutation**: phase 1 runs the real
reader and must be clean, phase 2 drives a deliberate write into the RAM
window through the same bus and the run fails unless the monitor catches it.
A monitor for a condition that never occurs passes whether or not it works,
which is how two earlier monitors in this tree passed with their fixes
removed. Copy the shape rather than the note.

Mutation-test anything that matters. The header checksum test once passed with
a mutation that dropped the last reserved word from the sum, because the
fixture had zeros there; there is now a fixture with a non-zero byte in all 29
checksummed positions.

`ui_screen`'s combinational logic is written as functions behind continuous
assignments, not `always @(*)`, to avoid a simulation and synthesis mismatch
on a cold boot with an empty slot. See `docs/UI.md`.

## What to do next, in order

1. **Probably dirty contacts, and downgraded accordingly.** Three cartridges
   have ever produced a corrupt dump - `TETRIS.gb`, `OTHELLO.gb`, `TENNIS.gb`
   - and all three are cartridge type `00`, ROM only, which looked like a
   sharp correlation. Then twelve cartridges were re-dumped in one session,
   including all three of those, and **every one came back byte for byte
   identical**. Tennis had been corrupt hours earlier, with no code change in
   between.

   That makes intermittent contact the better explanation and the mapper
   correlation a coincidence: the three suspects are the three smallest
   cartridges, hence the oldest and most handled. It also fits the shape of
   the corruption, which had no structure that maps to the RTL - two runs
   holding data from sixteen bytes higher, early in bank 0, not at a bank
   boundary, not chunk aligned, not on a byte lane.

   **It is not proven.** Twelve clean dumps are equally consistent with a rare
   logic defect that did not fire. What settles it is unchanged and still not
   done: **when a dump fails, copy the bad image off before re-dumping it.**
   There has still never been a corrupt-and-clean pair of the same cartridge
   to diff, because Tennis's bad file was overwritten by its own re-dump.

   The practical handling is already right: `dump_checksum` turns a silent bad
   file into a loud one, and the answer to a mismatch is to clean the contacts
   and dump again. `docs/STATUS.md` has the counts and the byte map.

2. **Fix the filename: the two halves that are left.** The extension half is
   done in `47bcd54` - `.gb`, `.gbc`, `.gba`. Still outstanding: `dump_path_gen`
   takes fifteen bytes from `0x134`, which is the old title field, so on a CGB
   cartridge the four-byte manufacturer code at `0x13F`-`0x142` lands in the
   name and `ZELDA_DIN__AZ7E.gbc` should be `ZELDA_DIN.gbc`. And nothing
   checks whether the chosen name is taken: Link's Awakening and Link's
   Awakening DX both title themselves `ZELDA`, and the second dump silently
   destroyed the first. See the collision entry under *Deliberately not done*
   for why overwriting was thought correct, and why that reasoning does not
   cover two different cartridges.

3. **Close the gap between `docs/FILE-FORMATS.md` and what the core writes.**
   That document specifies a `Dumps/`/`Saves/`/`Metadata/`/`Restore/` tree and
   a `.cart.json` sidecar; the core writes flat files and no sidecar. Decide
   which is right and move one of them - the companion app in
   `docs/COMPANION-APP-PLAN.md` is already written against the spec, so
   leaving them apart means the app is built against fiction. The sidecar is
   also where the MBC1 large-cartridge caveat belongs, which
   `cart_dump_gb.sv` has wanted somewhere since it was written.
4. **Add the double read to the save path.** The save backup itself is
   **done and verified**: a 32 KB four-bank GBC save was dumped, loaded in
   mGBA beside its own ROM, and the game came up with everything intact. See
   `docs/STATUS.md`. What is left is the check the plan calls mandatory and
   the core still does not do.

   - **The double read.** Read twice, compare, and do not write the file on a
     mismatch. A save has no checksum, no logo and no length, so a second
     pass is the only check available to it at all - and unlike a ROM dump, a
     bad one cannot be fetched from anywhere else. It needs the buffering in
     `docs/DUMP-VERIFY-PLAN.md`; 32 KB fits in block RAM with room to spare,
     which is what makes "do not write the file on a mismatch" achievable
     here and not for a 16 MB ROM. Until it lands, the second opinion is
     dumping twice and running `scripts/verify_dump.py --compare`.

   - **More cartridges, and specifically an MBC1 one.** One cartridge proves
     one path. The verified one is MBC5, which has no mode register, so
     **MBC1's mode-1 trap is still simulation only** - and it is the trap
     that produces a plausible file rather than an obvious failure. Seven
     MBC1 cartridges here have 8 KB saves; any of them exercises the mode
     write, none exercises banking. 64 KB and 128 KB have no cartridge at all.

   - **The collision bites hardest here.** Link's Awakening and Link's
     Awakening DX both title themselves `ZELDA`, so their `.sav` files land
     on the same name and the second destroys the first. For a ROM that means
     a re-dump; for a save it means the backup is gone. Item 2 should land
     before anyone backs up two cartridges with the same title.

   Also open: **GBA saves.** `gba_cart_bus.sv` already implements the save
   window - `save_space`, `/CS2`, the 16-bit address on AD, the byte off the
   high bus - so SRAM needs no bus work either, and unlike GB it needs no
   write to the cartridge at all. Two cartridges here use SRAM (Kirby:
   Nightmare in Dream Land, Metroid: Zero Mission), one uses Flash (Golden
   Sun) and seven use EEPROM, read out of each ROM's SDK id string. SRAM
   first: it is a plain 32 KB read window with no command sequence.

5. **Cover the mappers that still have no cartridge.** ROM-only, MBC1 to
   512 KB, MBC1+RAM+battery and MBC5 to 1 MB are proven on hardware. MBC2,
   MBC3 and MBC1 **above** 512 KB are simulation only, and GBA above 16 MB is
   untested.

   MBC1 above 512 KB is the interesting one: the mapper forces the low five
   bits of the bank register to 1 when written as 0, so banks `0x20`, `0x40`
   and `0x60` cannot be selected at all. A real dump will contain duplicates
   and will not match a published hash - documented behaviour that has never
   been watched to happen. `DONKEY_KONG.gb` at 512 KB is the largest MBC1
   tested and sits one size below it.

   Cartridges that would settle each: Donkey Kong Land, Kirby's Dream Land 2
   or Wario Land II for MBC1 at 1 MB; Kid Icarus or Golf for MBC2; Pokemon
   Gold or Crystal for MBC3, and Crystal also has 32 KB of save RAM, which is
   the only way to exercise the save banking path in `docs/GB-SAVE-PLAN.md`.

## Deliberately not done

- **No cartridge bus HAL layer.** The bus that exists is the HAL.
- **No flush, so no commit confirmation.** `0x0188` is unanswered and
  issuing it wedges the target command path. Writes land; nothing verifies
  they reached the card. `dump_checksum` covers the read path but not this
  one: it sums the bytes on their way out of the core, so a byte lost after
  that point would still report `image checksum ok`.
- **The slot-file fallback has never run on hardware.** If every `0x0192`
  open is refused, `dump_engine` writes into the file `data.json` names for
  slot 20 instead. Tested in simulation, never needed since `0x0192` started
  working.
- **No read-back verification pass.** `dump_checksum` checks the image
  against the cartridge's own value as it streams, which catches a misread,
  but it never re-reads the file from the card, so it cannot catch a bad
  write. A dump that needs that level of trust still gets it from a hash
  comparison on a PC.
- **No collision handling on filenames**, and this has now cost something.
  The reasoning was that two dumps of the same cartridge should overwrite:
  there is no directory listing command, so uniquifying would mean probing
  names one round trip at a time, and a dump that silently became
  `POKEMON_3.gb` is worse than one that replaced `POKEMON.gb`. The resize
  flag is set so a shorter dump does not leave the tail of a longer one
  behind.

  What that missed is that two *different* cartridges can produce the same
  name — Link's Awakening and Link's Awakening DX both title themselves
  `ZELDA` — and the second silently destroyed the first. Overwriting a
  re-dump is fine; overwriting a different cartridge is not, and the core
  cannot currently tell the two cases apart. Item 2 above.
- **No sidecar metadata, and no `Dumps/` tree.** `docs/FILE-FORMATS.md`
  specifies both in full - subdirectories for dumps, saves, metadata and
  restore, plus a `<basename>.cart.json` next to every image with hashes,
  header judgements and a `verified` field. The core writes flat into
  `/Assets/carttools/common/` and writes no sidecar at all. That document now
  carries a table of what is specified against what exists, because for two
  days it read as a contract while describing nothing that had been built.
- **The engine's introspection ports have no consumer.** `dump_engine` still
  drives `dbg_reads`, `dbg_struct_reads`, `dbg_last_addr`, `dbg_first_word`,
  `dbg_flags_word`, `dbg_size_word`, `probe_err`, `resp_words` and
  `sent_words`, and `core_top` no longer reads any of them, so Quartus strips
  them. They were how the APF path search was diagnosed and they are worth
  keeping until the save path has been through its own bring-up; after that,
  either delete them or give them somewhere to go.
- **No companion app.** `docs/COMPANION-APP-PLAN.md` plans the desktop side.
  It waits on a core that has written files to a real card.
