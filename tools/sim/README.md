# Simulation and structural checks

The hardware this core drives cannot be put in CI, and a wrong write to a
cartridge is not recoverable. This directory is where anything cartridge-facing
gets checked before a bitstream exists.

## Running it

```
make sim-image          build the Icarus Verilog container (once, about a minute)
make test               everything
make test ARGS="-k cart"    only names containing "cart"
make test ARGS="-v"     print output from passing runs too
make sim-shell          a shell in the container with the repo at /work
```

`make test` exits non-zero if anything fails. Failures always print their full
output; passes print one line unless `-v` is given.

Everything runs inside `localhost/carttools-sim:1`, so no host toolchain is
needed and no host Python is involved.

## What runs

| | |
|---|---|
| `check_*.py` | structural checks over the source tree, no simulation |
| `tb_*.sv` | Icarus testbenches, compiled with `iverilog -g2012` and run under `vvp` |

`run_all.py` discovers both by filename. There is no list to keep in sync: drop
a file in, it runs.

## The SOURCES convention

Each testbench names the RTL it compiles against, in its own header:

```systemverilog
// SOURCES: src/fpga/core/gba_cart_bus.sv
```

Exactly one such line, paths relative to the repo root, space separated. The
runner refuses to guess. A testbench with no SOURCES line is a failure that
names the file, because a runner that guessed would eventually guess a stale
file and report a pass for RTL nobody was testing.

## The pass-line convention

A testbench passes only by saying so, as the last thing it does:

```systemverilog
$display("TB PASS: tb_gba_cart_bus");
$finish;
```

The runner fails the testbench unless it sees a line starting `TB PASS:`. This
matters because `vvp` exits 0 for a testbench that printed nothing, for one that
hit `$finish` halfway through its checks, and for one that only issued `$error`.
None of those are passes. Silence is failure, so a half-written testbench cannot
look like a green run.

On top of the pass line, a run fails on a non-zero exit from `iverilog` or
`vvp`, and on `$error`, `ERROR`, `FATAL` or `$fatal` appearing anywhere in the
output, which is how the severity tasks report while letting simulation
continue.

## Adding a testbench

1. `tools/sim/tb_<thing>.sv`, module named to match the file.
2. A `// SOURCES:` line naming its RTL.
3. `$display("TB PASS: tb_<thing>");` immediately before `$finish`, after the
   last check, and nowhere else.
4. `$fatal(1, "...")` for a failed check. Say what was wrong, not that
   something was wrong.
5. A watchdog `initial` block that `$fatal`s after a generous multiple of the
   expected run length. A testbench that deadlocks otherwise stalls until
   `run_all.py`'s own 300 second timeout, and a dead process explains nothing.
6. `make test ARGS="-k <thing>"`.

A testbench that instantiates `gba_cart_bus` should also instantiate
`gba_cart_model` and name it in SOURCES. The model watches for the bus being
driven from both ends, so getting it for free is worth the four extra port
connections.

Testbenches live here and not next to the RTL so the synthesis tool never sees
them. `tb_gba_cart_bus.sv` was moved out of `src/fpga/core/` for that reason.

## Adding a structural check

`tools/sim/check_<thing>.py`, stdlib only, exit non-zero and explain the failure
on stderr. The runner picks it up automatically.

## What this suite proves, and what it does not

`check_pin_isolation.py` proves that only `cart_pins.sv` names the cartridge
pins, and that `core_top.sv` and `apf_top.v` only declare and forward them
rather than reading or driving them. Protocol engines, `gba_cart_bus.sv`
included, sit below `cart_pins` behind a flat interface and fail the check if
they name a pin. It is a grep, so it holds for code no testbench reaches. It
proves nothing about whether `cart_pins` drives those pins correctly, and its
allowlist is three files wide, at the top of the script, so widening it is a
visible edit.

### The cartridge model

`gba_cart_model.sv` is not a testbench and has no SOURCES or pass line. It is a
behavioural GBA cartridge that the bus testbenches instantiate, and it exists
because the cartridge stub inside `tb_gba_cart_bus.sv` only drives AD when the
module has already released it. That stub agrees with the module by
construction, so a pin-direction bug cannot be observed through it.

The model decides what to drive from the protocol alone: CS1# falling latches
24 address bits, RD# rising increments the latched address carrying only within
the low 16 bits, ROM data returns on AD, CS2# selects an 8-bit save bus on
bank1, WR# rising latches write data. When it is driving and the module is
driving the same bank, it reports contention and stops the run. The memory
behind it belongs to the testbench, supplied through `rom_rdata` and
`save_rdata`, so each testbench can predict what it should read back.

`tb_gba_cart_model.sv` includes a negative control for the detector: a stub bus
is driven into each of the three collisions by hand, against a model built with
`CONTENTION_FATAL(0)`, and the run fails if the flag does not rise. A detector
that never fires would make every other testbench weaker than it looks.

### What each testbench covers

| | |
|---|---|
| `tb_gba_cart_bus` | Inherited from Rai's fork with the module, at the shortened timing parameters. State machine reaches its states, read data comes back, a 32-bit ROM read uses two RD pulses without lifting CS between them, EEPROM chip select is held across serial bits and dropped on a direction change, EEPROM write data settles before WR# falls, no bidirectional pin is driven outside `cart_mode`. |
| `tb_gba_cart_timing` | The shipped defaults (2, 4, 4, 14, 12, 8), plus a second rig on a different parameter set and a third on that set plus 256. Every state's duration is asserted in clk cycles, and RD# and WR# low widths are asserted at the pins. |
| `tb_gba_cart_write_protect` | 62 writes that must not reach WR#, at three access widths, and 9 that must. |
| `tb_gba_cart_wide` | 32-bit reads and writes, the second write beat, the inter-beat address re-presentation, and the ROM page boundary. |
| `tb_gba_cart_async` | Reset and `cart_mode` swept across every cycle of a transaction, and `req` raised while `busy`. |
| `tb_gba_cart_model` | The contention detector's negative control, both quarters of save space, and ROM addresses with a non-zero A16-A23. |

Every one of those except `tb_gba_cart_bus` runs at the shipped default timing,
and every one carries a watchdog `initial` block that `$fatal`s if the run stops
making progress, so a hang is a named failure rather than a stall against
`run_all.py`'s own timeout.

Specifically, the following now hold:

- **The timing that ships is simulated.** `tb_gba_cart_timing` instantiates the
  module three times: once with no parameter overrides at all, once with a
  deliberately different set, and once with that set plus 256. Each state's
  length is asserted in clk cycles against its own rig, so a parameter that
  stopped being honoured, or was quietly hardwired to the default, fails on the
  second rig even though it would pass on the first. The third rig pins the
  `% 256` reduction the module applies to every parameter.

  Measured, not assumed. A state loaded with N occupies N+1 clocks: 3, 5, 5, 15,
  13, 9 for ADDR_SETUP, ADDR_LATCH, READ_TURN, READ_SETUP, WRITE, WRITE_HOLD at
  the defaults, with ST_WRITE_SETUP and ST_DONE at 1 each. The strobe pulses are
  one clock shorter again: RD# is low for 14 and WR# for 12, because the first
  cycle of ST_READ_SETUP and of ST_WRITE still carries the strobe value the
  previous state left behind. Those numbers are the module's real behaviour and
  are pinned as such.

  Separating ADDR_LATCH from READ_TURN is only possible from inside the module,
  since both hold CS1 low with RD# high and AD driven, so the duration checks
  read `state` through a hierarchical port connection. The pulse-width checks
  are pin-level and survive a change of state encoding.

- **Write suppression is proved in both directions.** `tb_gba_cart_write_protect`
  issues writes to 20 addresses outside EEPROM, save and GPIO space, at 8-, 16-
  and 32-bit widths, including address 0, the top of each quarter, the base of
  ROM space, and both halfword neighbours of the GPIO window. A WR# falling edge
  anywhere the testbench has not explicitly permitted one fails the run, and the
  monitor is armed for the whole simulation rather than only around a
  transaction. The suppressed writes still have to reach `done` with the bus
  idle and CS2# high, so a module that protected the cartridge by hanging would
  also fail. The positive half writes to EEPROM, both save quarters, all three
  GPIO offsets and a 32-bit GPIO write, and requires the expected number of WR#
  pulses each time.

- **32-bit accesses execute.** `tb_gba_cart_wide` covers 32-bit ROM reads at
  both `acc` encodings that select them, a 32-bit GPIO write checked beat by
  beat for address and data, a 32-bit ROM-space write that must run both beats
  with no WR# pulse, and 32-bit save reads and writes.

- **The ROM page boundary is hit.** A 32-bit read of halfword 0x7AFFFF, which is
  also the only place a non-zero A16-A23 is exercised across a page change. The
  model's counter wraps within the page exactly as a cartridge's does, so if the
  module bursted instead of re-presenting the address the data check would fail,
  not just the address-phase count.

- **Asynchronous events are swept, not sampled.** `tb_gba_cart_async` asserts
  reset at every cycle from 1 to 66 of a 32-bit save write and 1 to 55 of a
  32-bit ROM read, then does the same for `cart_mode` dropping, and after each
  one requires that every pin is released or driven inactive, that no strobe is
  left asserted, that no new WR# edge appears, that `busy` is clear, and that a
  following ordinary transaction still works. It also raises `req` for three
  cycles at every offset from 1 to 40 of a busy 32-bit read, with a save-space
  write that would be visible as a WR# pulse if it were ever latched.

### Two behaviours pinned as they are, not as they should be

Both are asserted in their real form so the suite stays green and stays honest.
If either is ever changed in the module, the assertion fails and points at
itself.

**A 32-bit write to save space writes one byte twice.** For save space the
module holds AD at `latched_addr[15:0]` and bank1 at `latched_wdata[7:0]`, and
neither depends on `beat`, so both beats write `wdata[7:0]` to the same address.
That matches how a real GBA 32-bit SRAM write moves only the low byte, so it is
redundant rather than wrong, but a caller expecting four bytes to land will not
get them. Asserted in `tb_gba_cart_wide`.

**Aborting inside ST_WRITE truncates the WR# pulse and drops the data on the
same edge.** A reset landing two cycles into WR# low leaves a 3-clock WR# pulse
instead of 12, and raises WR# on the same edge that releases CS2# and bank1. A
`cart_mode` drop does the same with no clock edge involved at all, because those
pin assignments are combinational in `cart_mode`. A cartridge latches write data
on the WR# rising edge, so what it captures is whatever the released bus settles
to. This only happens for a write that was already permitted, that is in EEPROM,
save or GPIO space, because everywhere else `wr_n_pin` holds the pin high
regardless. Asserted in `tb_gba_cart_async`, in the section marked KNOWN DEFECT.

### Still not covered

- **Save technologies.** There is no Flash, SRAM or EEPROM device model here.
  `gba_cart_model` speaks the bus protocol, not any save protocol, so none of
  Rai's untested save types are tested by their own rules. Nothing checks a
  Flash command sequence, a bank switch, or an EEPROM 6-bit versus 14-bit
  address stream.
- **EEPROM read data.** EEPROM accesses are still checked for chip-select and
  write-setup behaviour only. What lands in `rdata` after an EEPROM read is
  never inspected, and the model does not re-latch an address while CS1 is held
  low across serial bits, which is the case EEPROM actually lives in.
- **Address bits 27:25.** The module ignores them, so addresses above
  `0x1FFFFFF` alias silently. `tb_gba_cart_write_protect` walks those aliases
  for the write interlock, but nothing asserts what a read from an alias
  returns.
- **`phi_clk`.** The module still generates a divided clock and connects it to
  nothing, and drives `bank0[7]` constantly low in cart mode where the template
  idle drives it high. No testbench notices, because there is nothing on the pin
  to notice.
- **Setup time into the EEPROM chip select.** For EEPROM space CS1# falls on the
  same clock edge that first drives AD, so the address has no setup time before
  the latching edge. It does not matter for a serial EEPROM, and the model
  therefore samples after the edge rather than before it, but a cartridge that
  latched a parallel address there would not see one.
- **Anything electrical.** Contention is detected as a logical condition, not
  measured. Timing margins against a real cartridge's datasheet, the mechanical
  voltage switch, and the PHI polarity question are all in
  `docs/HARDWARE-NOTES.md` under open questions that need hardware.
- **Game Boy cartridges.** Out of scope by construction: `docs/STATUS.md`
  records that running this bus against a GB cartridge is a guaranteed
  contention on eight pins, and the answer is a different bus, not a test.

### The one testbench change

The inherited assertion "ROM address bus released before RD# asserted" fired on
every run, including on the first plain 16-bit read. It asserted that AD must be
driven whenever CS1 is low and RD# is high, which is true only during the
address latch window. AD is legitimately undriven in three other places that
match that condition: after RD# rises at the end of a beat, throughout a
sequential burst beat, where the cart advances the address itself and the host
must stay off the bus, and between EEPROM serial bits, where CS1 is held low
across transactions on purpose.

The fix arms the check when AD is actually driven with CS1 low, and disarms it
on RD# falling, on CS1 releasing, or on the transaction ending. That is the
latch window and only the latch window. `gba_cart_bus.sv` was not changed, and
has not been changed by anything in this directory since.
