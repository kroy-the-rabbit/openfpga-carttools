# APF host interface notes: getting bytes onto the SD card

Research notes for the CartTools core. Every claim is tagged **VERIFIED** (found in
code or in Analogue's published docs, with a citation) or **ASSUMED** (inference,
with the reasoning stated).

Primary local sources:

* `src/fpga/core/core_bridge_cmd.v`
* `src/fpga/core/core_top.sv`
* `src/fpga/pocket/data_loader.sv`
* `src/fpga/pocket/data_unloader.sv`
* `pkg/Cores/kroy.CartTools/data.json`

Primary public sources:

* Host/Target Commands: <https://www.analogue.co/developer/docs/host-target-commands>
* data.json: <https://www.analogue.co/developer/docs/core-definition-files/data-json>
* Core Boot Process: <https://www.analogue.co/developer/docs/core-boot-process>
* Bus Communication: <https://www.analogue.co/developer/docs/bus-communication>
* Directories and SD Folder Structure: <https://www.analogue.co/developer/docs/directories-and-sd-folder-structure>

---

## 1. Complete command list in core_bridge_cmd.v

### 1a. Transport and completion protocol

**VERIFIED.** Two independent register files live in the framework-reserved
`0xF8xxxxxx` bridge region (`core_bridge_cmd.v:6`, and Bus Communication doc:
"the framework reserves 0xF8xxxxxx"). Address decode is at
`core_bridge_cmd.v:241-305`:

| Region | Purpose |
| --- | --- |
| `0xF8xx00xx` | host to target: `+0x00` command/status semaphore, `+0x04` param pointer (0x20), `+0x08` response pointer (0x40), `+0x20..0x2C` params, `+0x40..0x4C` responses |
| `0xF8xx10xx` | target to host: same layout, roles reversed |
| `0xF8xx2xxx` | the Dataslot ID/Size Table BRAM (`mf_datatable`, `core_bridge_cmd.v:566-577`) |

**Host to target handshake, VERIFIED** (`core_bridge_cmd.v:246-252, 333, 460-471`):

1. Host writes `{16'h434D, cmd}` to `host_0`. `0x434D` is ASCII "CM".
   The write sets `host_cmd_start` (`:248-252`).
2. Core overwrites `host_0` with `{16'h4255, cmd}`, ASCII "BU" = busy (`:333`).
3. Core finishes by writing `{16'h4F4B, resultcode}`, ASCII "OK" (`:461, :465`).
   Unknown command yields `0x4F4BFFFF` (`:469`).

There is no queueing; the comment at `:321-322` states Pocket always finishes an
outstanding host command before issuing another.

**Target to host handshake, VERIFIED** (`core_bridge_cmd.v:530-548`):

1. Core writes `{16'h636D, cmd}` to `target_0`, ASCII "cm" (`:531`, cmd id set
   at `:487/:498/:509/:518`).
2. Host acknowledges by writing `0x6275xxxx`, ASCII "bu"; the core raises
   `target_dataslot_ack` (`:538-540`).
3. Host completes by writing `0x6F6Bxxxx`, ASCII "ok"; the core latches
   `target_dataslot_err <= target_0[2:0]` and raises `target_dataslot_done`
   (`:541-548`). `target_dataslot_done` stays asserted until the next command
   (`:83`, `:533`).

So: **the core signals completion of a host command by writing the "OK" semaphore;
the host signals completion of a target command by writing the "ok" semaphore, and
the only failure channel back into the core is the 3-bit `target_dataslot_err`.**

### 1b. Host to target commands implemented in this file

All **VERIFIED**, `core_bridge_cmd.v:335-455`.

| ID | Name | Lines | What it does in this module |
| --- | --- | --- | --- |
| `0x0000` | Request Status | `:336-348` | Returns result 1 booting, 2 setup, 3 idle, 4 running, derived from `status_boot_done` / `status_setup_done` / `status_running` |
| `0x0010` | Reset Enter | `:349-353` | `reset_n <= 0` |
| `0x0011` | Reset Exit | `:354-358` | `reset_n <= 1` |
| `0x0080` | Data slot request read | `:359-369` | Clears `dataslot_allcomplete`, asserts `dataslot_requestread` + id, waits for `_ack`, returns 0 if `_ok` else 2. This is the command sent before APF **reads bytes out of the core**, including nonvolatile writeback |
| `0x0082` | Data slot request write | `:370-381` | Same shape, plus `dataslot_requestwrite_size`. Sent before APF **writes bytes into the core** |
| `0x008A` | Data slot update | `:382-388` | Reports a new size for a slot; per the docs only sent for `deferload` slots. Drives `dataslot_update{,_id,_size}` |
| `0x008F` | Data slot access all complete | `:389-393` | Raises `dataslot_allcomplete` |
| `0x0090` | Real-time Clock Data | `:394-402` | Latches epoch seconds, BCD date, BCD time; pulses `rtc_valid` |
| `0x00A0` | Savestate Start/Query | `:403-424` | Returns supported/addr/size in `host_40/44/48`; `host_20[0]` requests a start; result 0 idle, 1 busy, 2 ok, 3 err |
| `0x00A4` | Savestate Load/Query | `:425-446` | Mirror of the above for loading |
| `0x00B0` | OS Notify: Menu State | `:447-451` | `osnotify_inmenu <= host_20[0]` |
| default | | `:452-454, :469` | Returns `0xFFFF` unknown command |

**Correction, checked against the file after this note was first written.**
`0x00B1` OS Notify Cartridge Adapter IS implemented here, at
`core_bridge_cmd.v:410-419`. It is the single most important command in this
core: `host_20[24]` is the user having selected Play Cartridge, `host_20[16]`
is the slot being powered, and `host_20[7:0]` is the adapter id. Those drive
`cart_play`, `cart_power` and `cart_adapter_id`, and `core_top.sv` gates the
whole cartridge bus on `cart_play & cart_power`. It was added by the branch
this repository forked from, which is why it is absent from the upstream GBA
core and from Analogue's older reference listings.

**VERIFIED** that Analogue documents three further host commands this file does
not implement: `0x00B2` OS Notify Docked State, `0x00B8` OS Notify Display Mode
(Host/Target Commands doc), plus `0x0182` Data slot copy referenced in the Core
Boot Process doc. None of the three matter to a cartridge utility.

### 1c. Target to host commands implemented in this file

All **VERIFIED**, `core_bridge_cmd.v:477-548`. Each is edge triggered on its input
strobe (`:223-234` builds the rising-edge queues).

| ID | Name | Lines | Parameters written to `target_20..2C` |
| --- | --- | --- | --- |
| `0x0140` | Ready to run | `:481-484, :526-529` | none; fired on the rising edge of `status_setup_done` |
| `0x0180` | Data slot read | `:485-494` | id, slot offset, bridge address, length |
| `0x0184` | Data slot write | `:496-505` | id, slot offset, bridge address, length |
| `0x0190` | Get filename of data slot | `:507-514` | id, pointer to `target_buffer_resp_struct` |
| `0x0192` | Open new file into data slot | `:516-524` | id, pointer to `target_buffer_param_struct` |

Documented result codes (Host/Target Commands doc), landing in
`target_dataslot_err`:

* `0x0180` / `0x0184`: 0 = all bytes ok, 1 = slot not defined, 2 = error or out of
  range. A length of `0xFFFFFFFF` is clamped to the maximum legal value.
* `0x0190`: 0 = ok, 1 = slot not defined.
* `0x0192`: 0 = opened ok, 1 = created and opened ok (not an error), 2 = slot not
  defined, 3 = file not found, 4 = malformed path, 5 = general error.

**VERIFIED** that Analogue documents three more target commands absent from this
file: `0x0152` Debug Event Log, `0x0181`/`0x0185` 48-bit-offset read/write, and
`0x0188` Data slot flush (result 0 ok, 1 slot not defined). **`0x0188` matters for a
dumper** and should be added.

### 1d. Gotcha in the current core_top wiring

**VERIFIED.** `core_top.sv:1149-1152` declares `target_dataslot_read`,
`target_dataslot_write`, `target_dataslot_getfile` and `target_dataslot_openfile`
as `reg` with no initial value, and nothing anywhere in the repo ever assigns them
(grep over `src/` finds only the declarations and the port connections at
`:1237-1240`). Likewise `target_buffer_param_struct` and `target_buffer_resp_struct`
(`core_top.sv:1163-1164`) are undriven wires. **The inherited GBA core has never
issued a single target command.** All of the target-side machinery is present but
dead, and the two struct buffers do not exist at all; `core_bridge_cmd.v:91-93`
says explicitly that "this should be mapped by the developer, the buffer is not
implemented in this file".

---

## 2. How bytes actually get onto the SD card today (the Save slot)

**VERIFIED end to end.** Today the core is a passive slave. It never asks for a
write. The sequence is:

1. **Declaration.** `pkg/Cores/kroy.CartTools/data.json:24-32` declares slot id 10,
   `"nonvolatile": true`, `"address": "0x20000000"`, `"size_maximum": "0x20010"`.
   `nonvolatile` is what enrolls the slot in exit writeback: "If `true`, slot will
   be both loaded and unloaded on core exit" (data.json doc).

2. **Size reporting.** The core continuously writes the runtime save size into the
   Dataslot ID/Size Table at word index `slot_index * 2 + 1`
   (`core_top.sv:1329-1340`, `datatable_addr_r <= 10'd5` for the Save slot at
   `data_slots` index 2, with the comment "save slot index 2: 2*2+1 = 5"). The same
   convention appears in the sibling GBC core at
   `the pocket-gbc checkout: src/gb/save_handler.sv:99` (`datatable_addr
   <= 1 * 2 + 1;` with the comment "Data slot index 1, not id 1"). That BRAM is
   `mf_datatable`, 256 words by 32 bits (`src/fpga/apf/mf_datatable.v:111-123`),
   dual ported: port A is the core, port B is the bridge at `0xF8xx2xxx`
   (`core_bridge_cmd.v:271-273, 300-303, 566-577`).

   **VERIFIED** that this is the mechanism the OS honours: the Core Boot Process doc
   says on exit "Pocket sends `[0080 Data slot request read]` to read out any
   nonvolatile data, taking into account any changes the core may have written to
   the Dataslot ID/Size Table, in case the file size should be expanded or shrunk."

   Note the comment at `core_top.sv:1321-1328`: the write is deliberately continuous
   rather than one-shot, because the OS may clobber the same word via port B.

3. **The trigger.** On core exit the host sends host command `0x0080` for slot 10.
   The core's handler (`core_bridge_cmd.v:359-369`) asserts `dataslot_requestread`
   and waits for `dataslot_requestread_ack`. In this core those are **hardwired to
   1** (`core_top.sv:1110-1111`, `dataslot_requestread_ack = 1`,
   `dataslot_requestread_ok = 1`), so permission is granted unconditionally and
   immediately.

4. **The data path.** The host then simply performs ordinary BRIDGE **reads** at
   `0x20000000 + offset` for `size` bytes. The core answers them:
   * `core_top.sv:1262-1280` muxes `bridge_rd_data` so `32'h2xxxxxxx` returns
     `save_read_bridge_data`.
   * That comes from `data_unloader` instanced at `core_top.sv:382-399` with
     `ADDRESS_MASK_UPPER_4 = 2`, which matches on `bridge_addr[31:28]`
     (`data_unloader.sv:133`), pushes `bridge_addr[27:0]` through a dcfifo into the
     memory clock domain, issues `read_en`/`read_addr`, collects two 16-bit words
     and returns one 32-bit `bridge_rd_data` (`data_unloader.sv:130-255`).
   * `read_data` is fed from PSRAM die 1 (`core_top.sv:441-459`, the
     `save_unload_pending` register plus the `psram_data_out` capture), or from the
     RTC shadow registers for addresses past the save size
     (`core_top.sv:424-439`).
   * Bytes physically flow: PSRAM cram0 die 1 -> `data_unloader` -> BRIDGE ->
     Pocket's ARM host -> FAT filesystem on the SD card.

5. **The file name.** No filename appears in the JSON for slot 10. `parameters`
   is `0x84`, which sets bit 2 "Nonvolatile filename" = "Filename cloned from slot
   0, with this slot's extension appended" (data.json doc). So the output is
   `<name of the loaded ROM>.sav` under `/Saves/<platform>/<Author.Core>/`
   (Directories doc: "Data slots flagged as `nonvolatile` are placed here").

6. **How the core knows it finished. It does not.** There is no completion or error
   signal for this path anywhere in `core_bridge_cmd.v`. The core sees `0x0080`
   arrive and answers it; after that, the read burst is indistinguishable from any
   other bridge traffic, and the FPGA is reset shortly afterwards. **VERIFIED** by
   the absence of any writeback-status port in the module header
   (`core_bridge_cmd.v:18-100`).

**Throughput, VERIFIED.** `data_loader.sv:36` states "APF sends data every ~75
74MHz cycles", i.e. about 990k bus transactions per second, about 4 MB/s ceiling.
The Bus Communication doc agrees: "Reads ands writes are relatively slow at only a
few megabytes per second". A 32 MiB transfer therefore costs **8 to 15 seconds
minimum** on the bridge alone, before any cartridge-side read time.

---

## 3. Can the core choose the filename at runtime?

**Definitive answer: YES, but only via target command `0x0192`, which this core
does not currently implement. Via the nonvolatile writeback path used today, NO.**

**VERIFIED (nonvolatile path is fixed).** For a nonvolatile slot the name comes from
either the slot's `filename` key ("Expected filename for the slot. Maximum length of
31 characters.") or, with `parameters` bit 2 set, is "cloned from slot 0, with this
slot's extension appended" (data.json doc). Both are decided before the core runs.
Nothing in `core_bridge_cmd.v` carries a filename in that direction.

**VERIFIED (0x0192 gives runtime naming).** Host/Target Commands doc, command
`0x0192` "Open new file into data slot", parameters are the slot id plus a pointer
to an `open_dataslot_file_t` struct the host reads out of core memory when the
command starts:

| Byte offset | Length | Field |
| --- | --- | --- |
| `0x000` | 256 | "Full path and file" as a null-terminated string, in the Assets or Saves folder |
| `0x100` | 4 | Operation flags: bit 0 "Create if it doesn't exist (slot must not be read-only)", bit 1 "Resize/truncate the file (slot must not be read-only)", bits 2-31 reserved |
| `0x104` | 4 | "Desired file size" for resize/truncate |

Result codes: 0 opened ok, **1 created and opened ok (explicitly not an error)**,
2 slot not defined, 3 file not found, 4 malformed path, 5 general error.

The mirror command `0x0190` "Get filename of data slot" returns, via a
`get_dataslot_file_t` struct, "Full path including filename" as a 256-byte
null-terminated string at offset 0. This is how you learn where the ROM the user
picked came from, so you can put the dump next to it.

**Implication for CartTools:** the core reads the cartridge header, synthesises a
name such as `/Assets/carttools/common/POKEMON_RED.gb`, writes those bytes
plus flags into a core-implemented BRAM, points `target_buffer_param_struct` at it,
pulses `target_dataslot_openfile`, and then streams with `0x0184`. **This is the
correct architecture for a dumper.**

**ASSUMED, moderate confidence:** because there is no directory enumeration command,
collision handling has to be done by probing. Issue `0x0192` with the create bit
**clear**; result 3 "file not found" means the name is free, result 0 means it is
taken, so retry with `_1`, `_2` and so on. This is inference from the documented
result codes, not from any statement in the docs, and it costs one command round
trip per probe.

**Caveats, VERIFIED from changelogs via search:** `0x0190` and `0x0192` "were added
for cores to open additional files" in openFPGA 1.1, and openFPGA 2.3 records a fix
so that "Target command [0192 Open new file] was fixed to properly update dataslot
size fields". So this path needs reasonably current Pocket firmware and had real
bugs in the size bookkeeping. Sources:
<https://www.analogue.co/developer/docs/changelog/1-1>,
<https://www.analogue.co/developer/docs/changelog/2-3>.

---

## 4. Size limits

* **Number of slots. VERIFIED:** "A maximum of 32 data slots is permitted"
  (data.json doc).
* **Slot size fields. VERIFIED:** `size_exact` and `size_maximum` are both
  "integer or hex string (32-bit unsigned)", so the JSON ceiling is 4 GiB minus 1.
  `address` is likewise 32-bit.
* **Is `size_maximum` a hard cap? VERIFIED that it is a *load-side* gate, not a
  runtime cap.** The doc wording is precise: "If specified, or non-zero, the file
  will not load unless it is equal or smaller in size than this value." And in the
  Additional Constraints: "Files exceeding size_maximum will not load."
* **Overflow behaviour on load. VERIFIED:** the file simply does not load. There is
  no truncation and no error command to the core. For a `required: false` slot the
  doc says Pocket "will try to load the file if it exists, otherwise it will be
  silently be skipped", so an oversized file is silently absent and the core sees no
  writes and no `0x0082`.
* **Target command range. VERIFIED:** `0x0180`/`0x0184` carry a 32-bit slot offset
  and a 32-bit length; `0x0181`/`0x0185` extend the offset to 48 bits for files past
  4 GB. Out-of-range yields result code 2. A length of `0xFFFFFFFF` is clamped to
  the maximum legal value.
* **VERIFIED via changelog search:** the target read/write commands "were added for
  access of very large files ... up to 4GByte in size, and should be used with data
  slots marked with deferload set".
* **Bridge address window. VERIFIED:** `data_loader`/`data_unloader` match only on
  `bridge_addr[31:28]` and use `bridge_addr[27:0]` (`data_loader.sv:65-66, 116, 126`;
  `data_unloader.sv:133, 139`), so each top nibble is a 256 MiB window. 32 MiB fits
  comfortably; a slot cannot straddle two windows without extra decode.
* **ASSUMED:** the nonvolatile exit writeback size is `min(datatable value,
  size_maximum)`. The doc confirms the datatable value is honoured for expand and
  shrink but never states the clamp. Declaring `size_maximum` at least as large as
  any size you will ever put in the datatable is the safe move; the current Save
  slot already does this (`0x20010` vs a maximum datatable value of `0x20010`, from
  `core_top.sv:1320-1322`).

---

## 5. Streaming versus whole-file addressability, and where 32 MiB lives

### Can a slot be written in pieces?

**Yes, VERIFIED, by chunking `0x0184`.** Each `0x0184` carries an independent
`{slot offset, bridge address, length}` triple (`core_bridge_cmd.v:500-503`, and
the Host/Target Commands parameter list). Nothing ties the bridge address to the
slot offset. So the core can loop:

```
for chunk in 0 .. N-1:
    fill buffer B from the cartridge
    target_dataslot_slotoffset  = chunk * CHUNK
    target_dataslot_bridgeaddr  = BUFFER_BASE          // constant
    target_dataslot_length      = CHUNK
    pulse target_dataslot_write; wait target_dataslot_done; check err
issue 0x0188 flush
```

The core only ever needs `CHUNK` bytes addressable at once. **ASSUMED** (strongly
implied by the existence of `0x0188` Data slot flush and by the 1.2 changelog note
that `0x0184` "utilizes open/seek caching when accessing a slot repeatedly") that
consecutive chunk writes to the same slot keep the file handle open and are cheap.

The nonvolatile exit-writeback path, by contrast, is **not** chunkable from the
core's side: APF walks the whole declared size in one burst of bridge reads and the
core must answer every address in `[address, address+size)`.

### What does data_unloader actually read from?

**VERIFIED.** `data_unloader.sv` is backing-store agnostic. Its memory side is just
`read_en` / `read_addr[ADDRESS_SIZE-1:0]` / `read_data`, with a fixed
`READ_MEM_CLOCK_DELAY` latency parameter (`data_unloader.sv:34-51, 223-255`). It
holds no storage of its own beyond two 4-deep `dcfifo`s for clock crossing
(`:64-118`, `lpm_numwords = 4`). Whatever the integrator wires to `read_data` is the
backing store. In this core that is PSRAM cram0 die 1 plus the RTC registers
(`core_top.sv:382-459`).

Consequence: **there is no flow control.** `data_unloader` assumes the memory can
answer within `READ_MEM_CLOCK_DELAY` and that APF's ~75-cycle pacing
(`data_loader.sv:36`) leaves enough slack. A backing store with variable latency,
such as raw PSRAM or a cartridge bus, must be buffered behind a BRAM, not wired
straight in.

### Where do 32 MiB live on a Pocket?

| Store | Evidence | Capacity | Verdict for a 32 MiB dump |
| --- | --- | --- | --- |
| SDRAM | `core_top.sv:101` comment "sdram, 512mbit 16bit"; `dram_a[12:0]`, `dram_ba[1:0]`, `dram_dq[15:0]` (`:103-106`) | 64 MB | **VERIFIED viable.** The existing ROM slot already declares `size_maximum: 0x2000000` (32 MiB) at `address 0x10000000` and loads it straight into SDRAM via `rom_data_loader` (`core_top.sv:803-834`, `data.json:5-13`) |
| PSRAM | `cram0_a[21:16]` + 16 muxed bits gives a 22-bit word address (`core_top.sv:74-98`, `psram_addr[21:0]` at `:290`); two chip selects per chip (`ce0_n`, `ce1_n`), two chips | 8 MB per die, so 32 MB total across cram0+cram1 (**ASSUMED** from the address width and chip-select count) | Possible but wasteful, and `cram1` is currently tied off (`core_top.sv:328-338`) |
| BRAM | Cyclone V on-chip | tens of KB realistically | Only as a chunk buffer |
| Streamed straight out | `0x0184` chunking, see above | n/a | **Recommended** |

**Recommendation, ASSUMED but well supported:** stream. Use a ping-pong pair of
BRAM buffers of 32 KB or 64 KB each. The cartridge reader fills buffer A while
`0x0184` drains buffer B over the bridge. Peak BRAM cost is around 64 to 128 KB and
the design scales to any cartridge size without touching SDRAM. Reasons to prefer
this over "dump to SDRAM then write once":

* No 32 MiB staging step, so no doubled wall-clock time.
* SDRAM stays free for whatever else the core needs.
* Partial dumps are recoverable: the file on disk already holds every chunk that
  succeeded.
* The cartridge read rate and the roughly 4 MB/s bridge rate are close enough that
  buffering smooths them without a big FIFO.

The one reason to stage in SDRAM instead is if you want to checksum or verify the
whole image before committing a filename. That can also be done with a running
CRC over the stream.

---

## 6. The `parameters` bitfield

**VERIFIED**, reproduced from the data.json doc's bitmap table:

| Bit | Name | Cleared | Set |
| --- | --- | --- | --- |
| 0 | User-reloadable | not reloadable | "Slot is reloadable in Core UI" |
| 1 | Core-specific file | "File common to platform, not any core" | "File specific to this core only" |
| 2 | Nonvolatile filename | "Filename as written in the slot" | "Filename cloned from slot 0, with this slot's extension appended" |
| 3 | Read-only | "File may be modified" | "File is read-only" |
| 4 | Instance JSON | "Normal asset" | "Treat a JSON loaded into this slot as an instance description. Must also be flagged as core-specific file, and only valid in first slot." |
| 5 | Initialize nonvolatile data on load | "Data is loaded if it exists, otherwise nothing is written to this nonvolatile slot" | "Data is loaded if it exists, otherwise the slot's memory is overwritten with 0xFF's up to size_maximum" |
| 6 | Reset core while loading | "[0082 Data slot request write] command is sent before load, and [008F Data slot access all complete] sent after" | "[0010 Reset Enter] before executing the same data slot access/complete sequence, and additionally [0011 Reset Exit] after" |
| 7 | Restart of core before/after loading | same as above | "Entire core is unloaded via the normal process, saving any nonvolatile slots. Then a full restart of the core is done, using the new data along with other already-defined assets" |
| 8 | Full reload of core | same as above | "Same as above, but the bitstream is also reloaded before the restart process" |
| 9 | Persist browsed filename | "File for slot may be chosen by user, at core boot (if required), or during runtime through Interact menu (if marked User-reloadable)" | "Filenames picked via the browser will be persisted, and the next time the core is loaded, the slot will be reloaded with the same file, overriding any definition or instance filename. The browser cache ... is cleared when a user uses Reset All to Defaults" |
| 25:24 | Platform index | platform 0, "the first or only platform supported by the core" | "load a required asset from another platform's Assets folder, so long as that platform is listed in the platform_ids array" |

Bits 10 through 23 and 26 through 31 are not documented; treat as reserved zero.

**Decoding what this repo and its siblings currently ship (VERIFIED arithmetic):**

| Slot | Value | Bits set | Meaning |
| --- | --- | --- | --- |
| ROM, `data.json:9` | `0x109` | 0, 3, 8 | user-reloadable, read-only, full bitstream reload on change |
| BIOS, `data.json:17` | `0x88` | 3, 7 | read-only, core restart on change |
| Save, `data.json:27` | `0x84` | 2, 7 | filename cloned from slot 0, core restart on change |
| GBC Cheats (sibling, `the pocket-gbc checkout: pkg/gbc/Cores/kroy.GBC/data.json`) | `0x205` | 0, 2, 9 | user-reloadable, cloned filename, browsed filename persisted |

**The right combination for a core-written output file:**

* **Bit 3 (read-only) MUST be clear.** The `0x0192` flag documentation says outright
  that create and resize each require "slot must not be read-only". **VERIFIED.**
* **Bit 1 (core-specific) set** if the output belongs in
  `/Assets/<platform>/<Author.Core>/` rather than the shared platform folder.
  **VERIFIED** semantics, **ASSUMED** that this is the preference for dumps.
* **Bit 0 (user-reloadable) set only on inputs** you want the user to be able to
  swap at runtime from the Interact menu. Setting it on an output slot just clutters
  the menu.
* **Bit 2 (cloned filename) clear** on any slot you drive with `0x0192`, since you
  are supplying the full path yourself. Set it only on a classic nonvolatile save.
* **Bits 5, 6, 7, 8 clear.** Bit 5 pre-fills memory with `0xFF`, which is wrong for a
  slot the core fills from a cartridge. Bits 6, 7 and 8 all restart or reload the
  core on a slot change, which would abort a dump in progress.
* **Bit 9 (persist browsed filename) set on the save-restore input** so the user does
  not have to re-browse every boot. **ASSUMED** as a usability call.

So an output slot written by the core is `parameters: "0x2"` (core-specific only),
or `"0x0"` for a platform-shared output.

---

## 7. Can a core enumerate, read back, or delete files?

* **Enumerate: NO. VERIFIED by absence.** There is no directory-listing command
  anywhere in the Host/Target Commands list. The only filename-shaped command in the
  core-to-host direction is `0x0190`, which returns the path of the file already
  bound to one slot, not a listing.
* **Read back: YES. VERIFIED.** `0x0180` Data slot read pulls `length` bytes from
  `slot offset` into a bridge address of the core's choosing. Combined with `0x0192`
  opening an arbitrary path, the core can open and read any file under Assets or
  Saves whose exact name it can construct. `0x0181` extends the offset to 48 bits.
* **Probe for existence: YES, indirectly. ASSUMED.** `0x0192` with the create bit
  clear returns result 3 "file not found" for a path that does not exist. That is an
  existence test, not enumeration: you must already know the name.
* **Delete: NO. VERIFIED by absence.** No delete, rename, or unlink command exists.
  The closest thing is `0x0192` with the resize bit set and a desired file size of 0,
  which truncates a file to nothing but leaves the directory entry. **ASSUMED** that
  this works as a "blank it" operation; the docs describe the flag as
  "Resize/truncate the file" with a "Desired file size" field, and do not forbid 0.

**Net: the core is blind to the filesystem.** It can write to a name it invents and
read from a name it knows, and that is all. Every "list my dumps" or "delete an old
dump" feature has to happen off-Pocket or through the Pocket OS file browser.

---

## 8. What if the SD write fails or the card is full?

**Two paths, two very different answers.**

**Nonvolatile exit writeback: the core learns nothing. VERIFIED.** The only signal
the core sees is host command `0x0080`, and the only thing the core does with it is
report *its own* readiness back to the host via `dataslot_requestread_ok`
(`core_bridge_cmd.v:364-368`). In this core those inputs are tied to constant 1
(`core_top.sv:1110-1111`). After the "OK" semaphore is written, the host performs
bridge reads and writes the file, and there is no return path in the module header
(`core_bridge_cmd.v:18-100`) for a write result. A full card during exit writeback
means the save is silently lost as far as the FPGA is concerned. This is a real,
verified hole in the current save design.

**Target command path: the core gets a 3-bit code, and that is it. VERIFIED.**
`target_dataslot_err <= target_0[2:0]` (`core_bridge_cmd.v:544`) latches the host's
result, valid while `target_dataslot_done` is high. For `0x0184` the documented codes
are 0 ok, 1 slot not defined, 2 "error or out of range". For `0x0192` there is a
slightly richer set including 5 "general error".

**ASSUMED, high confidence:** a full card, a write-protected card, or a filesystem
error all collapse into `0x0184` result 2 or `0x0192` result 5. The docs give no
distinct code for out-of-space and there is no free-space query command anywhere in
the interface, so **the core cannot check for room before starting a 32 MiB dump and
cannot tell "disk full" from "bad slot id" afterwards.**

Practical consequences for the dumper:

1. Check `target_dataslot_err != 0` after **every** chunk, not just at the end.
   Abort the loop on the first nonzero and surface it in the UI.
2. Issue `0x0188` Data slot flush at the end and check its result too, since
   buffered data may only fail at flush time. (This command must be added to
   `core_bridge_cmd.v`; it is not there today.)
3. **ASSUMED mitigation:** pre-allocate. Call `0x0192` with the resize bit set and
   the full expected dump size in the "Desired file size" field before writing
   anything. If the card cannot hold the dump, you find out in one command instead
   of ten seconds into a stream. This is inference from the flag semantics, not a
   documented technique, and it is worth testing on hardware.
4. Optionally verify with `0x0180` read-back and a CRC compare. At about 4 MB/s this
   roughly doubles the dump time for a 32 MiB cart, so make it opt-in.

---

## 9. Practical shape of a "dump to SD" design

### The architecture

The nonvolatile-writeback pattern this core inherited from the GBA core is the
wrong tool. It fixes the filename, fires only at core exit, requires the whole
payload to be addressable at once, and gives zero error feedback. Use the target
command path instead:

```
user selects "Dump ROM" in the Interact menu
  -> core reads the cartridge header, computes size and a candidate name
  -> [0190] on the ROM slot to learn where the user's files live (optional)
  -> [0192] on the dump slot: full path, create + resize flags, expected size
       result 3 with create clear = name is free
       result 0 or 1 = ready to write
  -> loop: fill BRAM buffer from cart, [0184] {slotoffset, bufferbase, chunk}
       check target_dataslot_err after each
  -> [0188] flush, check err
  -> report success or the failing chunk index on screen
```

Work required in this repo:

1. Add `0x0188` Data slot flush to `core_bridge_cmd.v` (and consider `0x0181`/
   `0x0185`).
2. Implement the `open_dataslot_file_t` and `get_dataslot_file_t` buffers. These are
   264-byte and 256-byte regions of core BRAM exposed on the bridge, whose base
   addresses feed `target_buffer_param_struct` and `target_buffer_resp_struct`.
   `core_bridge_cmd.v:91-93` states plainly that the developer must map these.
3. Build the string generator that turns cartridge header bytes into a legal FAT
   path, sanitising anything outside `[A-Za-z0-9_-. ]`.
4. Drive `target_dataslot_{read,write,getfile,openfile}` from a real FSM. They are
   currently undriven regs (`core_top.sv:1149-1152`).
5. Add the ping-pong chunk buffers and a `data_unloader` instance pointed at them.

### Recommended data.json slot declarations

**ASSUMED** design, built from the VERIFIED semantics in sections 3, 4 and 6.

```json
{
  "data": {
    "magic": "APF_VER_1",
    "data_slots": [
      {
        "name": "ROM Dump",
        "id": 20,
        "required": false,
        "parameters": "0x2",
        "deferload": true,
        "extensions": ["gb", "gbc", "gba"],
        "address": "0x60000000",
        "size_maximum": "0x2000000"
      },
      {
        "name": "Save Backup",
        "id": 21,
        "required": false,
        "parameters": "0x2",
        "deferload": true,
        "extensions": ["sav"],
        "address": "0x61000000",
        "size_maximum": "0x20000"
      },
      {
        "name": "Save Restore",
        "id": 22,
        "required": false,
        "parameters": "0x203",
        "deferload": true,
        "extensions": ["sav", "srm"],
        "address": "0x62000000",
        "size_maximum": "0x20000"
      },
      {
        "name": "Dump Info",
        "id": 23,
        "required": false,
        "parameters": "0x2",
        "deferload": true,
        "extensions": ["txt", "json"],
        "address": "0x63000000",
        "size_maximum": "0x1000"
      }
    ]
  }
}
```

Rationale, per slot:

* **ROM Dump (id 20).** `deferload: true` is the key: "slot will not be loaded, but
  its size and ID will still be communicated to the core, and the core may read/write
  it with Target commands" (data.json doc). That is exactly the contract a dumper
  wants, and the changelog says the target read/write commands "should be used with
  data slots marked with deferload set". `parameters: "0x2"` sets only bit 1
  core-specific; bit 3 read-only is deliberately clear so `0x0192` may create and
  resize. `size_maximum` of 32 MiB matches the largest cartridge. Distinct top
  nibbles for each slot's `address` keep the `data_loader`/`data_unloader`
  `ADDRESS_MASK_UPPER_4` decode trivial and avoid the existing `0x1`, `0x2`, `0x3`,
  `0x4`, `0x5` windows.
* **Save Backup (id 21).** Same pattern, sized for 128 KiB. Kept separate from the
  ROM dump so a failed dump does not lose the save.
* **Save Restore (id 22).** `parameters: "0x203"` = bit 0 user-reloadable (so the
  user can pick a `.sav` from the Interact menu while the core is running), bit 1
  core-specific, bit 9 persist browsed filename (so the choice survives a reboot).
  Because it is `deferload`, picking a file sends host command `0x008A` Data slot
  update with the new size (`core_bridge_cmd.v:382-388`), which is how the core
  learns how many bytes to push back to the cartridge. Then `0x0180` streams it in.
  Bit 3 read-only is left clear so the same slot can also be reused as a write
  target if you ever want that; set it if you want belt-and-braces protection.
* **Dump Info (id 23).** A small text or JSON sidecar: cartridge title, header
  checksum, mapper type, dump CRC32, size, RTC timestamp from host command `0x0090`.
  Cheap to write and it is the only place the user can see what actually happened.

### What will annoy the user

* **Nothing appears in the Pocket UI until they exit and re-enter the browser.**
  The core has no way to refresh the OS's view of the filesystem. **ASSUMED**, from
  the absence of any such command.
* **Names are as good as the header, and no better.** GB and GBA header titles are
  short, uppercase, sometimes blank, and not unique across regions or revisions.
  Appending the header checksum or a CRC32 is the difference between a usable
  library and a folder of `POKEMON.gb`, `POKEMON_1.gb`, `POKEMON_2.gb`. Renaming
  afterwards is a desktop chore.
* **Collision probing is the only defence against overwrites.** Get the probe order
  wrong and a dump silently clobbers a previous one. **ASSUMED** risk, from the lack
  of enumeration.
* **Dumps land under Assets or Saves, nowhere else. VERIFIED** from the `0x0192`
  struct documentation. Users who want their dumps in a top-level `/Dumps` folder
  cannot have it.
* **Roughly 4 MB/s means a 32 MiB cart takes on the order of 10 to 20 seconds** with
  no possibility of a faster path, and the progress indicator has to come from the
  core counting its own chunks.
* **A failure late in a long dump leaves a partial file on the card** with a name
  that looks legitimate. Either write to a `.part` name and rename via a second
  `0x0192`, or record the failure in the Dump Info sidecar. **ASSUMED**; note there
  is no rename command, so "rename" really means "reopen under the final name and
  copy", which doubles the transfer.
* **Firmware version sensitivity.** `0x0190`/`0x0192` arrived in openFPGA 1.1 and
  `0x0192`'s dataslot size bookkeeping was still being fixed in 2.3. Old firmware
  will fail in ways the core cannot distinguish from a bad path.

---

## Constraints this puts on the design

1. **The core cannot write a file without target command support, and this repo has
   none.** `target_dataslot_*` is declared and connected but never driven, and the
   two struct buffers do not exist. Building them is a prerequisite for every dump
   feature, not an optimisation. (`core_top.sv:1149-1164`, `core_bridge_cmd.v:91-93`)
2. **`core_bridge_cmd.v` needs extending.** `0x0188` Data slot flush is missing and
   is the only way to know a write actually committed. `0x00B1` OS Notify Cartridge
   Adapter is already there, added by the fork this repository is based on.
3. **Runtime filenames are available but only through `0x0192`, and only under
   `/Assets/...` or `/Saves/...`.** The core owns the whole 256-byte path string,
   which means the core also owns FAT name sanitisation, length limits, and
   collision avoidance. There is no library to lean on.
4. **The filesystem is write-mostly.** No enumeration, no delete, no rename, no free
   space query. Any feature that depends on knowing what is already on the card must
   be redesigned around a sidecar file the core itself maintains, or dropped.
5. **Error reporting is 3 bits wide and arrives per command.** Design the dump FSM to
   check after every chunk and to fail loudly on screen, because nothing else will
   tell the user. The classic nonvolatile writeback path reports nothing at all, so
   do not use it for anything the user would miss.
6. **Budget about 4 MB/s on the bridge and treat it as the hard ceiling.** A 32 MiB
   dump is a ten-plus second operation with a visible progress bar, and verification
   read-back doubles it. Do not design any interaction that assumes a dump is quick.
7. **Stream, do not stage.** Chunked `0x0184` with a BRAM ping-pong buffer needs
   about 64 to 128 KB of BRAM and no external memory, keeps SDRAM free, and makes
   partial dumps recoverable. Reserve SDRAM staging for the case where a
   whole-image check must precede the first byte written.
8. **`size_maximum` gates loads, not writes.** Set it generously on every slot the
   core will write, and keep the Dataslot ID/Size Table value at or below it. An
   oversized file simply never loads and the core is never told.
9. **Slot `address` values must occupy distinct top nibbles.** `data_loader` and
   `data_unloader` decode only `bridge_addr[31:28]` and use the low 28 bits, giving
   256 MiB per window. The existing core already consumes `0x1`, `0x2`, `0x3`, `0x4`
   and `0x5`; new slots should start at `0x6`.
10. **At most 32 slots exist, and the user-facing consequence of every slot is a row
    in the Interact menu.** Keep the count low and set bit 0 only where a runtime
    file swap genuinely makes sense.
11. **`pkg/Cores/kroy.CartTools/data.json` is still the GBA core's declaration**
    (slot 1 with a `gba` extension, a `gba_bios.bin` slot, a nonvolatile save at slot
    10). None of it is right for a cartridge tool and all of it needs replacing.
