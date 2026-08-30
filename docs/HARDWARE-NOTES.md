# Pocket cartridge slot: hardware notes

Research notes for driving the Analogue Pocket's physical cartridge slot from an
openFPGA core. Every claim below is labelled **VERIFIED** (found stated in code
or documentation, with the citation) or **ASSUMED** (inference, with the
reasoning and what would falsify it). Nothing here has been checked against real
hardware by the author of this file.

Repo-relative paths are relative to the root of this repository
unless an absolute path is given.

Primary sources used:

| Tag | Source |
| --- | --- |
| `S1` | `git show carttools-donor-base:src/fpga/core/core_top.sv` (this repo, **stock GBA core as forked**). The working-tree copy of this file is being rewritten by the cartridge work, so all `S1` line numbers are cited against the `carttools-donor-base` tag, where they are stable. The identical text is also at `the pocket-gba checkout: src/fpga/core/core_top.sv` at the same line numbers. |
| `S2` | `src/fpga/apf/apf_top.v` (this repo, Analogue template HDL) |
| `S3` | `src/fpga/build/ap_core.qsf` (this repo, pin and I/O standard assignments) |
| `S4` | `git show donor-rai/cartridge-support:src/fpga/core/gba_cart_bus.sv` |
| `S5` | `git show donor-rai/cartridge-support:src/fpga/core/gba_cart_bus_tb.sv` |
| `S6` | `git show donor-rai/cartridge-support:src/fpga/core/core_top.sv` |
| `S7` | `git show donor-rai/cartridge-support:src/fpga/core/core_bridge_cmd.v` |
| `S8` | `the pocket-gbc checkout: src/core/core_top.sv` (budude2 GBC core fork, **has a working physical Game Boy cartridge driver**) |
| `S9` | https://www.analogue.co/developer/docs/external-hardware |
| `S10` | https://www.analogue.co/developer/docs/core-boot-process |
| `S11` | https://www.analogue.co/developer/docs/host-target-commands |
| `S12` | https://www.analogue.co/developer/docs/core-definition-files/core-json |
| `S13` | https://old.pinouts.ru/Game/CartridgeGameBoy_pinout.shtml (Game Boy 32-pin pinout) |
| `S14` | https://github.com/jojolebarjos/gba-cartridge/blob/master/README.md (GBA 32-pin pinout and bus protocol) |

---

## 1. Pin mapping of the cartridge connector as seen by the FPGA

**VERIFIED.** The port declarations and their GBA meanings are in the Analogue
template HDL and copied verbatim into the core:

- `S2` `src/fpga/apf/apf_top.v:52-87`
- `S1` lines 22-54

| FPGA signal | GBA signal | Connector pin(s) | Evidence |
| --- | --- | --- | --- |
| `cart_tran_bank3[7:0]` | AD[7:0] | 6-13 | `S1:31-33`, `S2:60-62` |
| `cart_tran_bank2[7:0]` | AD[15:8] | 14-21 | `S1:27-29`, `S2:56-58` |
| `cart_tran_bank1[7:0]` | A[23:16] | 22-29 | `S1:35-37`, `S2:64-66` |
| `cart_tran_bank0[7]` | PHI# (cartridge clock) | 2 | `S1:39`, `S2:68` |
| `cart_tran_bank0[6]` | WR# | 3 | `S1:40`, `S2:69` |
| `cart_tran_bank0[5]` | RD# | 4 | `S1:41`, `S2:70` |
| `cart_tran_bank0[4]` | CS1# / CS# (ROM select) | 5 | `S1:42`, `S2:71` |
| `cart_tran_bank0[3:0]` | not wired | n/a | `S1:43`, `S2:72` (the port is declared `[7:4]`) |
| `cart_tran_pin30` | CS2# (SRAM select) / RES# | 30 | `S1:47-48`, `S2:76-77` |
| `cart_tran_pin31` | IRQ / DRQ | 31 | `S1:52-53`, `S2:85` |
| `cart_pin30_pwroff_reset` | not a connector pin, it is a control line into a clamp circuit on pin 30 | n/a | `S2:79-83` |

Bit ordering inside each bank is **VERIFIED** by the donor implementation, not
just by the comments:

- `S4:71` `wire [15:0] ad_in = {cart_tran_bank2, cart_tran_bank3};` so
  `bank2[7]` is AD15 and `bank3[0]` is AD0.
- `S4:106` and `S4:114` drive `addr_high = rom_word_addr[23:16]` onto
  `cart_tran_bank1`, so `bank1[7]` is A23 and `bank1[0]` is A16.
- `S4:117` `assign cart_tran_bank0 = cart_mode ? {1'b0, wr_n_pin, rd_n, cs1_n} : 4'hf;`
  so `bank0[7]`=PHI, `[6]`=WR#, `[5]`=RD#, `[4]`=CS1#. The testbench asserts on
  exactly those bit indices (`S5:35` reads `bank0[5]` as RD#, `S5:75` reads
  `bank0[6]` as WR#, `S5:47` reads `bank0[4]` as CS1#).

Connector pin numbers in the table above are **VERIFIED against the public GBA
pinout** (`S14`: pin 1 VCC 3.3 V, pin 2 PHI, pin 3 ~WR, pin 4 ~RD, pin 5 ~CS,
pins 6-21 AD0-AD15, pins 22-29 A16-A23, pin 30 CS2, pin 31 IRQ, pin 32 GND).

**VERIFIED, and important:** `cart_tran_pin30` and `cart_tran_pin31` are not in
the same FPGA I/O bank as banks 0-3. `S3` `src/fpga/build/ap_core.qsf:563-564`
and `:651` set `cart_tran_pin30`, `cart_tran_pin31` and
`cart_pin30_pwroff_reset` to the `"1.8 V"` I/O standard, while all of
`cart_tran_bank0..3` and their `_dir` signals are `"3.3-V LVCMOS"`
(`ap_core.qsf:357, 378-388, 416-436`). Pin locations are at `ap_core.qsf:55-89`
and `:272-273`.

---

## 2. Meaning of the `*_dir` signals

**VERIFIED. `1` = FPGA drives the pin (translator in output mode). `0` = FPGA
listens (translator in input mode).**

Two independent citations:

- `S1` line 234: `// directions are 0:IN, 1:OUT`.
- `S4` `src/fpga/core/gba_cart_bus.sv:111-115`: `cart_tran_bank3_dir` and
  `cart_tran_bank2_dir` are both assigned `cart_mode && ad_drive`, and the same
  `ad_drive` term gates whether the bank is driven with `ad_out` or released to
  `8'hzz` at `S4:109-110`. `cart_tran_bank1_dir = a_hi_drive` at `S4:115`, with
  `a_hi_drive` high exactly when bank1 carries an outgoing address or write byte
  (`S4:94`).

The testbench treats it the same way. `S5:35`:
`wire cart_read_active = cart_mode && !bank3_dir && !bank2_dir && (bank0[5] == 1'b0);`
so the simulated cartridge only drives data back when the direction bits are
low. `S5:151-152` and `S5:233-235` fail the test if `*_dir` is anything other
than `0` while the bus is idle.

**VERIFIED constraint:** direction is per-bank, not per-pin. `S9`: "All pins are
run through level translators and their direction can only be input or output.
Most I/O pin directions are controlled in groups." That is why `bank0`,
`bank1`, `bank2` and `bank3` each have a single `_dir` bit for eight (or four)
pins.

---

## 3. Safe idle state

### What the stock GBA core assigns

**VERIFIED**, `S1` lines **233-247** (`git show carttools-donor-base:src/fpga/core/core_top.sv`,
byte-identical to `the pocket-gba checkout: src/fpga/core/core_top.sv:233-247`):

```
// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31 = 1'bz;
assign cart_tran_pin31_dir = 1'b0;
```

This block is the Analogue template default. `S9` says explicitly: "Leave all
cartridge pins in the default settings per the template HDL unless actively
using the port."

### Why it is safe

**VERIFIED reasoning for banks 1-3:** direction `0` puts the translators in
input mode, so the FPGA physically cannot source current into the cartridge's
address, data or AD pins. Whatever a cartridge drives, the Pocket only listens.

**VERIFIED reasoning for bank0:** these four are the strobes. They are driven
(`_dir = 1`) with the value `4'hf`, which is PHI=1, WR#=1, RD#=1, CS1#=1, that
is every active-low strobe deasserted and the clock parked static high. Driving
them is safer than floating them: a floating strobe behind a translator can
drift or glitch low and latch a write into a cartridge. This is the same reason
`S9` warns about the level translators being "improperly configured while
cartridge power is turned on".

**VERIFIED reasoning for pin30 and `cart_pin30_pwroff_reset`:** `S2:79-83` says
"when GBC cart is inserted, this signal when low or weak will pull GBC /RES low
with a special circuit. The goal is that when unconfigured, the FPGA weak
pullups won't interfere. Thus, if GBC cart is inserted, FPGA must drive this
high in order to let the level translators and general IO drive this pin."
So the template default `cart_pin30_pwroff_reset = 1'b0` holds a Game Boy or
Game Boy Color cartridge in **hardware reset**. A cartridge held in reset does
not drive its data bus and does not respond to strobes, which is the strongest
possible safe state.

**ASSUMED (noted as an oddity, not a recommendation to change it):**
`cart_tran_pin30_dir` is declared `output wire` yet assigned `1'bz` at
`S1:244`. A top-level output driven with `z` synthesises to a tri-stated device
pin, so the board's own bias resistor decides the translator direction. This is
the shipped template value and should be copied verbatim rather than
"corrected". What would falsify a different reading: an Analogue schematic or a
statement about the bias on that net. I could not find one.

**VERIFIED, the two working implementations diverge here:**

- The GBA cart driver (`S4:120-122`) takes ownership when `cart_mode` is set:
  `cart_tran_pin30 = cs2_n`, `cart_tran_pin30_dir = 1'b1`,
  `cart_pin30_pwroff_reset = cart_mode`. Outside `cart_mode` it falls back to
  `1'bz` / `1'b0` / `1'b0`, matching the template.
- The Game Boy driver (`S8` `pocket-gbc/src/core/core_top.sv:1028-1030`) does
  the opposite for the pin itself: `cart_tran_pin30 = 1'b0`,
  `cart_tran_pin30_dir = 1'b0` (input, never driven), but
  `cart_pin30_pwroff_reset = 1'b1` unconditionally. That releases the clamp and
  lets the cartridge's own pull-up bring /RES high, without the FPGA ever
  driving the reset line.

**Recommended idle for a core that touches the slot (ASSUMED, derived from the
two verified implementations):** banks 1-3 direction `0` and value `8'hzz`;
bank0 direction `1` and value `4'hf`; pin31 `1'bz` with direction `0`;
`cart_pin30_pwroff_reset` low and pin30 in the template posture until you have
positively decided you are talking to the cartridge.

---

## 4. GBA cartridge bus protocol as implemented in `gba_cart_bus.sv`

All line numbers in this section refer to `S4`
(`git show donor-rai/cartridge-support:src/fpga/core/gba_cart_bus.sv`).

### Clock domain

**VERIFIED.** `S6:589` instantiates the module with `.clk( clk_sys )`, and
`S6:264` documents `clk_sys` as approximately **100.663296 MHz**
(`.CLOCK_SPEED ( 100.66 )  // clk_sys ~ 100.663296 MHz`). One `clk_sys` cycle is
about **9.934 ns**. Every cycle count below is in `clk_sys` cycles.

### Timing parameters

**VERIFIED**, `S4:3-9` (defaults) and `S4:53-58` (turned into 8-bit counts).

| Parameter | Default | State it controls | Actual state length | Approx. wall time |
| --- | --- | --- | --- | --- |
| `ADDR_HOLD_CYCLES` | 2 | `ST_ADDR_SETUP` (address on AD and A16-23, all strobes high) | 3 cycles | ~29.8 ns |
| `ADDR_LATCH_CYCLES` | 4 | `ST_ADDR_LATCH` (CS1# or CS2# falls, address latched by the cart) | 5 cycles | ~49.7 ns |
| `READ_TURNAROUND_CYCLES` | 4 | `ST_READ_TURN`, and the gap in `ST_READ_SEQ` between burst beats | 5 cycles | ~49.7 ns |
| `READ_SETUP_CYCLES` | 14 | `ST_READ_SETUP`, the RD#-low window | 15 cycles | ~149 ns |
| `WRITE_SETUP_CYCLES` | 12 | `ST_WRITE`, the WR#-low window | 13 cycles | ~129 ns |
| `WRITE_HOLD_CYCLES` | 8 | `ST_WRITE_HOLD`, quiet time after WR# rises | 9 cycles | ~89 ns |

**VERIFIED on the off-by-one:** the counter is loaded with `N`, decremented once
per cycle in the `else` branch, and the state exits on the cycle where
`wait_count == 8'd0` (for example `S4:192-197`). So a state parameterised `N`
occupies `N+1` clock cycles. The testbench overrides all six to 1 or 2 (`S5:100-106`)
purely to keep simulation short.

Note that `ST_WRITE_SETUP` (`S4:291-300`) is unconditionally exactly **one**
cycle: it puts write data on AD with WR# still high, reloads the counter, and
falls through to `ST_WRITE`. Its comment explains why it exists: "EEPROM samples
a serial bit on AD0, so data and WR# must not change together."

### Transaction request interface

**VERIFIED**, `S4:15-22` and `S4:39-40`. `acc` encodes the access width:
`2'b00` = 8-bit, `2'b01` = 16-bit, anything else (`2'b10`, `2'b11`) = 32-bit and
triggers the two-beat path (`need_second_beat`, `S4:92`). `addr` is a 28-bit
GBA system address; the module converts it to a 24-bit halfword address at
`S4:104` (`rom_word_addr = latched_addr[24:1] + beat[0]`).

### Address latch phase

**VERIFIED**, `S4:184-220`.

1. `ST_ADDR_SETUP`: `ad_drive` goes high, AD carries `addr_word` (the low 16
   bits of the halfword address), bank1 carries `addr_high` = A23..A16, and
   CS1#, CS2#, RD#, WR# are all held high. This is a setup window only.
2. `ST_ADDR_LATCH`: the address is still held, and now the chip select falls:
   `cs1_n <= save_space` and `cs2_n <= !save_space` (`S4:204-205`). For a ROM
   access (`save_space` false) CS1# goes low and CS2# stays high; for an SRAM
   or Flash save access (`addr[27:24]` is `0xE` or `0xF`, `S4:86`) CS2# goes low
   and CS1# stays high. On the CS falling edge the cartridge latches all 24
   address bits. This matches the published protocol (`S14`: "On `~CS`
   falling-edge, the cartridge latches A0-A23 as address").

EEPROM space (`addr[27:24] == 0xD`, `S4:83`) is special: CS1# is asserted early
in `ST_ADDR_SETUP` (`S4:188`) and then held low across consecutive EEPROM bits
by the `eeprom_selected` latch (`S4:167`, `S4:336-341`), released only on a
direction change or a non-EEPROM access (`S4:170-173`).

### When the AD bus reverses direction

**VERIFIED**, `S4:222-241`. AD stays an **output** through `ST_READ_TURN`, which
exists purely for this: the comment at `S4:223-225` reads "Retail carts latch
the multiplexed ROM address during the CS-low/RD-high phase. Keep AD driven
until RD asserts, then release it for ROM data."

The reversal happens on the clock edge that enters `ST_READ_SETUP`, where
`ad_drive <= save_space` (`S4:239`). For a ROM read `save_space` is 0, so AD
turns around to input on the same edge that RD# is asserted low (`S4:241`). For
a save-space read AD keeps driving the 16-bit address the whole time, because
on a GBA SRAM access the data comes back on **A16-A23** (bank1), not on AD
(`S4:95`: `wire [7:0] save_data_in = cart_tran_bank1;`, sampled at `S4:246`).

The testbench enforces this exact contract at `S5:92-98`: while `cart_mode &&
busy && pin30 === 1 && bank0[4] === 0 && bank0[5] === 1` (CS1# low, RD# high) it
`$fatal`s with "ROM address bus released before RD# asserted" unless both
`bank3_dir` and `bank2_dir` are still `1`.

Data is sampled on the last cycle of `ST_READ_SETUP`, at the same moment RD# is
released back high (`S4:243-249`).

### Sequential-read burst

**VERIFIED**, `S4:248-289`. For a 32-bit access, after beat 0 the FSM enters
`ST_READ_SEQ`, whose comment reads "Sequential ROM halfword: keep CS low and let
the cart advance internally, matching the GBA burst path." Concretely
(`S4:278-282`): AD is released (`ad_drive <= 0`), **CS1# is held low**, CS2#
high, RD# and WR# high for `READ_TURNAROUND_CYCLES + 1` cycles, then it re-enters
`ST_READ_SETUP` to pulse RD# again. No new address is transmitted. The cartridge
increments its own latched address on the RD# rising edge, which is the
documented behaviour (`S14`: "On `~RD` rising-edge, the cartridge increments
latched address by one").

The testbench proves the burst is a real burst: `S5:170-177` issues one 32-bit
read, checks the result is `32'h33441122` (two different halfwords from two RD#
pulses), checks `rom_rd_count == 2`, and `$fatal`s with "CS# rose between
sequential ROM word beats" if `bank0[4]` ever went high mid-transaction
(monitored at `S5:57-63`).

### ROM page boundary behaviour

**VERIFIED**, `S4:107` and `S4:252-258`.

```
wire rom_page_end = rom_word_addr[15:0] == 16'hFFFF;
```

The cartridge's internal auto-increment counter only carries within the low 16
halfword-address bits, so a burst cannot cross a 64K-halfword (128 KB) page. If
beat 0 of a 32-bit read lands on halfword offset `0xFFFF` within a page, the FSM
does **not** go to `ST_READ_SEQ`. It goes back to `ST_ADDR_SETUP` and issues a
complete fresh address cycle for beat 1:

```
if (rom_page_end) begin
    wait_count <= ADDR_HOLD_COUNT;
    state <= ST_ADDR_SETUP;
end else begin
    wait_count <= READ_TURN_COUNT;
    state <= ST_READ_SEQ;
end
```

### Write path and its write-protection

**VERIFIED**, `S4:87-91`. WR# is only allowed to reach the pin for three address
regions:

```
wire gpio_space = latched_addr[27:24] == 4'h8 &&
                  latched_addr[23:0] >= 24'h0000C4 &&
                  latched_addr[23:0] <= 24'h0000C8;
wire cart_write_enable = latched_wr && (eeprom_space || save_space || gpio_space);
wire wr_n_pin = (state == ST_WRITE && cart_write_enable) ? wr_n : 1'b1;
```

Any other write is silently swallowed: the FSM runs, but the WR# pin is forced
high. This is a deliberate safety interlock and worth keeping.

### PHI

**VERIFIED and worth flagging as a bug or dead code.** `S4:80-81` and
`S4:127-137` build a PHI divider: `phi_div` counts 0,1,2 and toggles `phi_clk`
on the count of 2, giving a period of 6 `clk_sys` cycles, that is
100.663 / 6 = **16.78 MHz**, the GBA's maximum PHI setting. But `phi_clk` is
never used. `S4:117` hardwires `bank0[7]` to `1'b0`, so in cartridge mode the
core drives **PHI constantly low**, whereas the template idle drives it high
(`S1:241`, `4'hf`). This is benign for retail GBA carts (the GBA can disable PHI
entirely) but it is not what the divider was written to do.

Also cosmetic: `S4:118` reads `assign cart_tran_bank0_dir = cart_mode ? 1'b1 : 1'b1;`,
a ternary with identical arms.

---

## 5. How a DMG / Game Boy Color cartridge maps onto these pins

### This one is VERIFIED, from a working implementation

There is a shipped, working Game Boy cartridge driver on this machine:
`S8` = `the pocket-gbc checkout: src/core/core_top.sv` lines
**1008-1033** (a fork of budude2's openFPGA GBC core, which gained external
cartridge support in v1.4.0). The mapping is not a guess:

| Pocket signal | Game Boy signal | Connector pin(s) | Citation |
| --- | --- | --- | --- |
| `cart_tran_bank3[7:0]` | **A0-A7** | 6-13 | `S8:1011` `assign cart_tran_bank3 = cart_access ? cart_addr[7:0] : ...` |
| `cart_tran_bank2[6:0]` | **A8-A14** | 14-20 | `S8:1014` `assign cart_tran_bank2 = cart_physical_mode ? {cart_a15, cart_addr[14:8]} : 8'hzz;` |
| `cart_tran_bank2[7]` | **A15** | 21 | same line, `cart_a15` is the MSB of the concatenation |
| `cart_tran_bank1[7:0]` | **D0-D7** (bidirectional) | 22-29 | `S8:1017` writes `cart_di` out, `S8:1008` `assign cart_do = cart_physical_mode ? cart_tran_bank1 : cart_do_backend;` reads it back |
| `cart_tran_bank0[7]` | **PHI / CLK** | 2 | `S8:1020-1021`, driven by the `cart_phi` divider at `S8:1141-1161` |
| `cart_tran_bank0[6]` | **/WR** | 3 | `S8:1022` `cart_access ? ~cart_wr : rumble_cart_wr` (low when writing) |
| `cart_tran_bank0[5]` | **/RD** | 4 | `S8:1023` `cart_access ? cart_wr : 1'b1` (low when reading) |
| `cart_tran_bank0[4]` | **/CS** (SRAM select, sometimes called MREQ) | 5 | `S8:1024` `cart_access ? nCS : 1'b1` |
| `cart_tran_pin30` | **/RESET** | 30 | `S2:79-83` calls it "GBC /RES" by name; `S8:1028-1030` leaves it as an input and asserts `cart_pin30_pwroff_reset` |
| `cart_tran_pin31` | **VIN** (cartridge audio input, analogue) | 31 | `S13`; `S8:1032-1033` leaves it `1'bz` with direction `0` |

### Why this mapping is what it is

**VERIFIED.** The two connectors are pin-for-pin the same physical 32-pin edge
connector, and the signals line up positionally:

| Pin | Game Boy (`S13`) | GBA (`S14`) |
| --- | --- | --- |
| 1 | VCC (+5 V) | VCC (3.3 V) |
| 2 | PHI (CPU clock) | PHI |
| 3 | /WR | ~WR |
| 4 | /RD | ~RD |
| 5 | /CS (SRAM select) | ~CS (ROM select) |
| 6-21 | A0-A15 | AD0-AD15 |
| 22-29 | D0-D7 | A16-A23 |
| 30 | /RST | CS2 (SRAM select) |
| 31 | VIN (audio in) | IRQ |
| 32 | GND | GND |

So `bank3` + `bank2` (the GBA's 16 multiplexed AD lines) are exactly the Game
Boy's 16 address lines, and `bank1` (the GBA's 8 high address lines) is exactly
the Game Boy's 8 data lines. `bank0` is identical between the two.

**Independent corroboration, VERIFIED:** the GBA itself already uses pins 22-29
as an 8-bit **data** bus for save-RAM accesses, which is the same reuse the Game
Boy makes of them. `S14`: "When doing RAM access, the `AD` bus is used for the
16-bits address, and the 8-bits data is returned through `A16..23`. `~CS2` is
used instead of `~CS`." The donor GBA driver implements exactly that at `S4:95`
(`wire [7:0] save_data_in = cart_tran_bank1;`) and `S4:96`
(`a_hi_pin_out = save_space ? latched_wdata[7:0] : a_hi_out;`). So the
electrical capability of `bank1` to be an input is already exercised on GBA
hardware, not something that has to be assumed for Game Boy carts.

### Behavioural differences you must not carry over from the GBA

**VERIFIED:** on a Game Boy cartridge, `/CS` (pin 5) is **not** the ROM select.
`S13` labels pin 5 "SRAM select". Gekkio's cartridge-types writeup describes
pin 5 as "Chip select (used for SRAM). Sometimes called MREQ", and describes ROM
being addressed directly by the address lines. The Game Boy core's own naming
agrees: the signal driven onto `bank0[4]` is called `nCS` and is separate from
the ROM path, while `cart_a15` is carried on `bank2[7]` as an ordinary address
bit. **A Game Boy cartridge will drive D0-D7 (that is, `bank1`) on any /RD-low
cycle in ROM space, without /CS ever being asserted.** That is the single most
dangerous difference from the GBA, see question 8.

**VERIFIED:** the address bus on a Game Boy cartridge is **not** multiplexed and
is not latched. There is no address-latch phase, no CS falling-edge latch, and
no sequential burst. `S8` drives the full address flat on `bank3`+`bank2` and
strobes /RD or /WR.

**VERIFIED:** unlike the GBA, `bank2` and `bank3` are output-only in Game Boy
mode (`S8:1012` `cart_tran_bank3_dir = 1'b1;`, `S8:1015`
`cart_tran_bank2_dir = cart_physical_mode;`) and only `bank1` reverses
(`S8:1018` `cart_tran_bank1_dir = cart_write_access;`).

**VERIFIED, PHI timing:** `S8:954-957` sets `cart_phi_period_m1 = 31` at normal
speed and `15` in CGB double speed, off a `clk_sys` that the same file documents
as 33.55 MHz (`S8:599`). 33.55 / 32 = **1.048 MHz**, the Game Boy's cartridge
clock. Duty cycle is 24 high / 8 low (`cart_phi_high_m1 = 23`, `S8:955`).

**ASSUMED:** the template comment calls `bank0[7]` "PHI**#**" (`S1:39`,
`S2:68`), implying an inversion, but the Game Boy core drives a non-inverted
`cart_phi` there and the GBA driver ties it to `0`. Nothing in either
implementation resolves whether the `#` in the comment is meaningful or a typo.
Falsified by: a scope on pin 2 with a cartridge inserted, or an Analogue
schematic. Practical impact is probably nil, since almost no cartridge uses PHI,
but a cartridge with an RTC or an audio expansion could care.

---


## 5a. Probe order for a shared bus

**ASSUMED**, from the verified pin table in section 5. Needs hardware.

One bus with a mode switch serves all three systems. The connectors are
identical; only the signal meaning changes. The constraint is which protocol
is safe to run against an unknown cartridge.

**A GB-mode read is safe against a GBA cartridge.** Drive A0-A15 on
`bank2`/`bank3`, hold `bank0[4]` (/CS) high, pulse `bank0[5]` (/RD) low,
release `bank1`, hold `pin30` high.

| Pin | GB mode does | A GBA cartridge sees | Drives back |
| --- | --- | --- | --- |
| 6-21 | address out | AD0-15 driven in | no |
| 5 | /CS high | ~CS high, ROM not selected | no |
| 4 | /RD low | ~RD low, but not selected | no |
| 22-29 | released, input | A16-23, input on the cart | no |
| 30 | high | ~CS2 high, SRAM not selected | no |

**A GBA-mode read against a GB cartridge is a bus fight.** GBA mode drives
`bank1` (A16-23) as an output for the whole transaction. A GB cartridge drives
D0-D7 on those same pins on any /RD low in ROM space, and GB ROM reads do not
use /CS at all, so nothing gates it.

### Rule

1. Probe GB first.
2. Escalate to a GBA probe only when the GB probe read all 0x00 or all 0xFF.
   A GB cartridge with a bad header checksum must not reach the GBA probe.

`plan.md` states the opposite order. It is wrong.

### Open

`cart_adapter_id` from APF command `0x00B1` may already identify the cartridge
type before anything is driven. Unverified, and now harder to check: the
diagnostics page displayed it and that page has been removed. `core_top` still
synchronises the field, so answering this means putting it back on screen for
one build with a GB cartridge and a GBA cartridge to hand.

## 6. Cartridge power

**VERIFIED: the FPGA does not control slot power.** Power is controlled by the
Pocket's firmware (the PIC32 mentioned in `S2:54`, "output enable for multibit
translators controlled by PIC32"), driven by a field in `core.json`.

`S9`: "Cart power is enabled with the appropriate setting in core.json"

**VERIFIED, `core.json` bitfield** (`S12`, `framework.hardware.cartridge_adapter`):

- bit 31 set: leave cart power off
- bit 30 set: turn cart power on always
- bit 24 set: enable the "Play Cartridge" option in the asset browser; if the
  user picks it, data slot 0 and any slot deriving its filename from slot 0 are
  not loaded
- bit 17 set: strict adapter ID check, core load fails on mismatch
- bit 16 set: soft adapter ID check
- bits 7:0: the adapter ID code
- value `0`: turn cart power on and bypass all other checks (backwards
  compatible default)

**VERIFIED, what this repo currently declares:** `pkg/Cores/kroy.CartTools/core.json`
has `"cartridge_adapter": 0` and `"version_required": "1.1"`. Value `0` means
**cart power is on and all checks are bypassed**, with no "Play Cartridge"
option in the browser. The donor branch instead declares
`"cartridge_adapter": "0x01000000"` (bit 24, Play Cartridge) with
`"version_required": "1.2"`
(`git show donor-rai/cartridge-support:pkg/Cores/mincer_ray.GBA/core.json`), and
the Game Boy core does the same. Consequence: **as this repo stands, a cartridge
is powered up while the core is running the stock idle assignments.** That is
the configuration the template idle was designed for, so it is safe, but it is
not "power off".

**VERIFIED, boot sequence** (`S10`):

- "Pocket checks for any cartridge adapters by briefly turning on cart power.
  Cartridge I/O should be put in a safe state by the core."
- "Pocket turns on power to the cartridge slot if needed", occurring after data
  slot operations complete and before the reset-exit command that starts
  execution.

**VERIFIED, how the core learns about it:** APF command **0x00B1, "OS Notify:
Cartridge Adapter"** (`S11`), one parameter:

- `[24]` user selected "Play Cartridge"
- `[16]` "If cart power will be turned on immediately after reset exit"
- `[7:0]` value of the detected cartridge adapter during boot, valid values
  `0x01` to `0x04`

The donor decodes exactly this at `S7`
`src/fpga/core/core_bridge_cmd.v:410-418`, and gates everything on
`cart_mode_74a = cart_play & cart_power` (`S6:1294`), synchronised into
`clk_sys` as `cart_mode_s` (`S6:1545-1546`) and fed to the bus module's
`cart_mode` input (`S6:591`). The Game Boy core uses only bit 24
(`osnotify_adapter_play`, `S8:411`, `:533`).

Note a small semantic slip in the donor: `S7:414-416` comments bit 16 as "cart
power enabled", but Analogue documents it as "cart power **will be** turned on
immediately after reset exit". These are not the same thing at the instant the
command arrives.

### `cart_pin30_pwroff_reset`

**VERIFIED**, `S2:79-83` (the template's own comment) and `S9`:

> when GBC cart is inserted, this signal when low or weak will pull GBC /RES low
> with a special circuit. the goal is that when unconfigured, the FPGA weak
> pullups won't interfere. thus, if GBC cart is inserted, FPGA must drive this
> high in order to let the level translators and general IO drive this pin.

and `S9`: "In 5v mode, pin30 is clamped low until a particular control pin is
asserted. A core using pin30 should assert this pin (view the template HDL)."
`S9` also notes "additional circuitry is present to prevent reset glitching."

So: it is a 1.8 V FPGA output (`S3:651`, PIN_L17 at `S3:273`) that **releases a
clamp holding connector pin 30 low**. Low or floating means a Game Boy cartridge
is held in reset. High means pin 30 becomes usable, either as GBA CS2# or as a
released Game Boy /RES. The name "pwroff_reset" reflects that when the FPGA is
unconfigured or unpowered, the clamp defaults to asserting cartridge reset.

### Hot insertion and removal

**ASSUMED, and this is the weakest area in this document.** Nothing in the
Analogue documentation, the template HDL, or either working core describes a
hot-swap sequence. The Pocket's documented model is: power is applied once
during boot, based on `core.json`, and the core is told about it via 0x00B1.
There is no core-visible cartridge-detect signal and no core-controllable power
switch.

The only sequence the core can actually influence, in the order it should
happen:

1. Stop issuing bus transactions and let any in-flight one complete
   (`busy` low, `S4:97`).
2. Set `bank1_dir`, `bank2_dir`, `bank3_dir` to `0` and their values to `8'hzz`.
3. Hold `bank0` at `4'hf` with `bank0_dir = 1` so no strobe can glitch low.
4. Drive `cart_pin30_pwroff_reset` low, which asserts /RES on a Game Boy
   cartridge before anything else changes.
5. Only then allow the cartridge to be physically moved.

What would falsify or extend this: an Analogue statement on hot-swap, or a
schematic showing sequencing on the slot's VCC switch. **Until then, treat
insertion and removal as a power-off operation.**

---

## 7. Voltage: 3.3 V versus 5 V

**VERIFIED, what decides it:** a mechanical switch in the slot, not the FPGA and
not firmware. `S9`: "Cartridge voltage is determined in hardware by a mechanical
voltage selection switch (5v when the switch is depressed, 3.3v when not)."
`S2:53` and `S1:24` say the same in one line: "switches between 3.3v and 5v
mechanically".

`S9` also gives the slot's electrical envelope: a 32-pin interface supporting
200 mA, with 3.3 V and 5 V switch-selectable VCC, and all pins run through level
translators.

**VERIFIED, what the FPGA sees: never the cartridge voltage.** The FPGA sits
behind the translators. `S3` pins the cart banks to `"3.3-V LVCMOS"`
(`ap_core.qsf:357, 378-388, 416-436`) and pin30, pin31 and
`cart_pin30_pwroff_reset` to `"1.8 V"` (`ap_core.qsf:563-564, 651`). Those
numbers do not change when the slot switches to 5 V. The translators absorb the
difference, which is exactly why the `_dir` bits matter so much: they are the
only thing telling the translator which way to shift.

**ASSUMED, what actuates the switch:** the cartridge shell. A Game Boy or Game
Boy Color cartridge, which needs 5 V, is the deeper shell and depresses the
switch; a GBA cartridge, which needs 3.3 V, does not. This is consistent with
the documented polarity ("5v when depressed") and with the fact that Game Boy
cartridges are 5 V parts and GBA cartridges are 3.3 V parts (`S13` pin 1 "+5
VDC", `S14` pin 1 "3.3V power"). Falsified by: a teardown photo or schematic of
the slot showing the switch actuator, or a report of a GBA cart in a shell
modification behaving differently.

**VERIFIED, the FPGA cannot read the switch.** There is no port in `S2` that
reports it. The only cartridge-related information the core receives is the
0x00B1 adapter ID (`S11`), and that reports Analogue's own **adapter**
accessories, values `0x01` to `0x04`, not whether a Game Boy or GBA game
cartridge is inserted.

**Risk of getting it wrong.** The physical voltage is handled by hardware, so a
Game Boy cartridge will always get 5 V and will not be over-volted by a wrong
software assumption. The damage is protocol-level, not level-level:

- **VERIFIED mechanism:** a GBA-mode core drives `bank1` as an **output**
  during ROM reads. `S4:94`:
  `wire a_hi_drive = cart_mode && transaction_active && (!save_space || latched_wr);`
  For a ROM read `save_space` is false, so `a_hi_drive` is high for the whole
  transaction including the RD#-low window. On a Game Boy cartridge `bank1` is
  **D0-D7** (question 5), and the cartridge drives D0-D7 whenever /RD is low in
  ROM space. Both ends drive the same eight nets at once, at 5 V, through a
  translator configured to output. **ASSUMED consequence:** contention current
  through the cartridge's ROM or MBC output buffers and through the Pocket's
  translator, sustained for the ~149 ns of `READ_SETUP_CYCLES` on every single
  read. Whether that is merely hot or actually destructive is not something the
  documentation settles.
- **VERIFIED mechanism:** the GBA driver asserts WR# for EEPROM, save and GPIO
  address spaces (`S4:90-91`). Those GBA address decodes mean nothing on a Game
  Boy cartridge; the address that reaches the pins will land somewhere in the
  Game Boy's flat 64K map, quite possibly on MBC bank-select or RAM-enable
  registers, or on cartridge SRAM. **ASSUMED consequence:** corrupted save data
  or a scrambled bank state.

`S9`'s warning is the documented form of this: "If the level translators are
improperly configured while cartridge power is turned on, a user may lose data
from an inserted cartridge."

---

## 8. Documented hazards

**VERIFIED, Analogue's own warnings** (`S9`, external hardware docs):

1. "Leave all cartridge pins in the default settings per the template HDL unless
   actively using the port. **If the level translators are improperly configured
   while cartridge power is turned on, a user may lose data from an inserted
   cartridge.**"
2. "In 5v mode, pin30 is clamped low until a particular control pin is asserted.
   A core using pin30 should assert this pin (view the template HDL)."
3. "additional circuitry is present to prevent reset glitching."
4. "All pins are run through level translators and their direction can only be
   input or output. Most I/O pin directions are controlled in groups." So you
   cannot make a single pin in a bank an input while the rest are outputs.

**VERIFIED, template HDL warning** (`S2:79-83`): if a GBC cartridge is inserted
and `cart_pin30_pwroff_reset` is not driven high, that cartridge is held in
reset. Conversely, driving it high releases reset, so a core that asserts it
without being ready to drive the bus correctly has just woken a cartridge it is
not prepared to talk to.

**VERIFIED, boot-time requirement** (`S10`): "Pocket checks for any cartridge
adapters by briefly turning on cart power. **Cartridge I/O should be put in a
safe state by the core.**" This happens during boot, before the core has been
told anything, which is why the reset-time assignments in question 3 have to be
correct from configuration onward, not just once the core is running.

**ASSUMED hazards, derived from the verified mappings above:**

- **Bank1 contention against a Game Boy data bus.** Detailed in question 7.
  Running the unmodified `gba_cart_bus.sv` with a Game Boy cartridge inserted
  produces a guaranteed drive-fight on pins 22-29 on every read. This is the
  single most likely way to damage something. Falsified only by measuring the
  contention current; do not run the experiment on a cartridge you care about.
- **Spurious writes from a mismatched address decode.** Detailed in question 7.
  The GBA driver's `cart_write_enable` interlock (`S4:90`) is a GBA-address
  decode and provides no protection at all for a Game Boy cartridge.
- **Driving pin 31.** On a Game Boy cartridge pin 31 is **VIN**, an analogue
  audio input into the console's mixer (`S13`). It is not a digital pin. Both
  the template (`S1:246-247`) and both working cores (`S4:124-125`, `S8:1032-1033`)
  leave it tri-stated with direction `0`. Never drive it. Falsified by: a
  documented use of pin 31 as an output; I found none.
- **Driving PHI into a cartridge that does not expect it.** GBA cartridges can
  have PHI disabled entirely. The donor drives it constantly low in cart mode
  (`S4:117`) while the template idle drives it high (`S1:241`). A DC level on a
  clock pin is not obviously safe for every mapper.
- **Leaving `bank0_dir = 1` with `z` values.** The Game Boy core assigns
  `cart_tran_bank3_dir = 1'b1` unconditionally (`S8:1012`) while putting `z` on
  most of `bank3` when not in physical-cart mode (`S8:1011`). That means the
  translator is in output mode driving whatever a tri-stated FPGA pin settles
  to. It ships and it evidently works, but it is not a pattern to copy into new
  code without understanding why it is there (it exists so `bank3[1]` can drive
  a rumble line outside cart mode).

---

## Open questions that need real hardware

These genuinely cannot be settled from source or documentation. Each one needs a
cartridge in the slot, and in most cases a logic analyser on the connector.

1. **Does the mechanical voltage switch actually track cartridge type the way
   assumed?** Verify with a multimeter on pin 1 that a Game Boy cartridge yields
   5 V and a GBA cartridge yields 3.3 V. Everything in question 7 depends on it.
2. **Is `bank0[7]` inverted?** The template calls it "PHI#" but the working Game
   Boy core drives a non-inverted 1.048 MHz clock onto it. Scope pin 2 with the
   Game Boy core running and compare polarity against the FPGA-side signal.
3. **What is the real state of `cart_tran_pin30_dir` when driven with `1'bz`?**
   The template does this and it must be safe, but nothing says whether the net
   biases to input or output. Needs a scope or a schematic.
4. **Does a Game Boy cartridge tolerate the GBA driver's bus contention on
   pins 22-29 at all, or does it damage the cartridge?** Do not test this on a
   cartridge that matters. If tested, current-limit the slot and measure.
5. **Timing margins with real cartridges.** The donor's `READ_SETUP_CYCLES = 14`
   (~149 ns of RD# low) and `ADDR_LATCH_CYCLES = 4` (~49.7 ns of CS-low setup)
   are numbers that were tuned, not derived from a datasheet. Slow or
   flash-based cartridges, reproduction cartridges, and cartridges with an
   FPGA or CPLD mapper may need more. Only a real read of known-good data can
   confirm.
6. **Hot insertion and removal.** No documented sequence exists. Whether the
   Pocket tolerates a cartridge being removed while power is applied, and
   whether the described soft sequence in question 6 is sufficient, is unknown.
7. **Whether `"cartridge_adapter": 0` in this repo's `core.json` is the right
   choice.** It powers the slot unconditionally with no "Play Cartridge"
   browser option. Whether the Pocket's 0x00B1 notification still arrives with
   useful bits under value `0` (rather than bit 24) needs to be observed on
   hardware.
8. **What the 0x00B1 adapter ID values `0x01` to `0x04` actually correspond
   to.** Analogue documents the range but not the meaning of each value, and no
   local source enumerates them.
9. **Whether a Game Boy cartridge's /CS behaviour matches the assumption that
   it never gates the ROM data output.** This drives the contention analysis in
   question 8. Confirmable with a logic analyser on pins 4, 5 and 22-29 during
   a ROM read.
10. **Whether the donor's dead PHI divider was ever meant to reach the pin, and
    whether real GBA cartridges in the Pocket slot care that PHI is held low.**
