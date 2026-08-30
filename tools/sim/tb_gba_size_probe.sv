// SOURCES: src/fpga/services/dump/gba_size_probe.sv src/fpga/services/identify/cart_identify_gba.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_cart_model.sv
//
// tb_gba_size_probe.sv - can the size probe be fooled?
//
// The probe runs through the real gba_cart_bus, the real cart_pins and the
// cartridge model, not against a stub of the bus. That matters more here than
// it does for cart_identify_gba, because the thing being measured is not a
// value the cartridge returns - it is the absence of a value. Open bus is
// this core's own address left standing on AD after it let go, so a stub that
// simply handed back "the address" would be the testbench agreeing with the
// probe about a mechanism neither of them had demonstrated.
//
// gba_cart_model is used with ROM_EXTENT(1), so the cartridge stops answering
// above the ROM that is fitted and the float is produced by a keeper holding
// what gba_cart_bus last drove. Nothing here hands the probe the address it
// expects; the address gets there the way it gets there on hardware.
//
// The connector mode is derived from the probe's own want_gba output, exactly
// as core_top derives gba_mode_s, so the mode handshake at the start of a
// probe is exercised rather than assumed.
//
// The cases, in the order they run:
//
//   1  empty slot                     no size at all, not a 1 MiB cartridge
//   2  1 MiB                          the smallest candidate
//   3  4 MiB                          a middle candidate
//   4  8 MiB
//   5  16 MiB                         the last candidate actually sampled;
//                                     its point 3 sits at 17.875 MiB, the
//                                     closest these offsets come to the top
//                                     of what latched_addr[24:1] can reach
//   6  32 MiB                         the ceiling, reached by never tripping
//   7  2 MiB, mirroring               end found by wrap rather than by float
//   8  1 MiB, mirroring
//   9  8 MiB, mirroring
//  10  16 MiB, mirroring
//  11  4 MiB, upper 3 MiB reads as
//      its own halfword address       the adversarial case, at its strongest
//  12  4 MiB, ascending run planted
//      at sample point 0              the adversarial case as the plan words it
//  13  the same run at point 1        a mutation that trusts the last point
//  14  the same run at point 2        fails only some of these, so all four
//  15  the same run at point 3        are planted and all four are asserted
//  16  8 MiB, blank upper half        0xFFFF is data, not the end
//  17  cartridge answering 0xFFFF
//      everywhere                     no size, and STATUS_CONSTANT rather
//                                     than STATUS_NO_CART
//  18  4 MiB with one live address
//      past the end                   over-reports rather than truncates, and
//                                     the evidence names the point that
//                                     dissented
//  19  4 MiB whose every 4 KiB block
//      starts with the same 0xB00
//      bytes                          a mirror impostor open bus cannot help with
//  20  three of four                  a trap one halfword short of complete:
//                                     data, with the hit count reading 3
//  21  2 MiB mirroring with a blank
//      run at a sample point          the price of refusing a constant run as
//                                     a mirror: it over-reports to the ceiling
//  22  512 KiB                        below the smallest candidate: reported
//                                     as 1 MiB. Also the one fixture that
//                                     reaches the state where a point's
//                                     wrapped reference is itself past the
//                                     end of ROM
//  23  1 MiB, float decays on the
//      second beat of a burst         the confirmation read's tolerance,
//                                     which nothing else asserts
//  24  1 MiB, float decays inside
//      the first read window          the failure the plan warns about: the
//                                     probe stops seeing open bus at all and
//                                     over-reports to the ceiling
//  25  16 MiB then 1 MiB              back to back, largest then smallest,
//                                     to catch state inherited between runs
//  26  slot not powered               refused with STATUS_NO_POWER, and not
//                                     one CS1# phase at the cartridge
//  27  power lost mid-probe           aborts rather than hangs
//  28  a probe whose sample offset
//      lands on a page end            a second instance, deliberately
//                                     misparameterised, watched to misclassify
//  29  identify then size, sharing
//      one bus mux                    Phase A's wiring: two masters, no
//                                     arbiter, one after the other
//
// What this testbench cannot see, and hardware still has to answer:
//
//   The keeper decays only when told to, and then to all-ones exactly. A real
//   float decays by capacitance into whatever the last driver left, and cases
//   23 and 24 are the two ends of that rather than a characterisation of it.
//
//   Every cartridge below answers a burst the same way it answers a single
//   read. One that did not would defeat the confirmation read, and there is
//   no way to model that as anything other than an assumption about a
//   cartridge nobody has met.
//
// Mutation checks, all four run and all four reverted:
//
//   Believe the 32-bit confirmation unconditionally (pt_conf <= 1'b1), which
//   is the plan's own 16-bit-only classifier:
//       ERROR: impostor to 4 MiB = 0x00100000, expected 0x00400000
//       ERROR: impostor point 0 class = 0x00000002, expected 0x00000001
//   A 4 MiB cartridge reported as 1 MiB - a dump three quarters short that
//   would have passed every other check there is.
//
//   Read the four halfwords of a point consecutively (strides 0, 2, 4, 6):
//       ERROR: blockwise repeat = 0x00100000, expected 0x00400000
//       ERROR: three of four: open hits = 0x00000004, expected 0x00000003
//   Case 12, the attack as docs/GBA-DUMP-PLAN.md words it, PASSED with this
//   mutation in place - the confirmation read kills that fixture whatever the
//   strides are - so case 19 exists because case 12 does not pin the strides
//   down on its own.
//
//   Trip a candidate on its first agreeing point instead of all four:
//       ERROR: 1 MiB points completed = 0x00000001, expected 0x00000004
//       ERROR: 4 MiB with a live hole = 0x00400000, expected 0x00800000
//   plus twenty read-count failures. The read counts are what caught most of
//   it: a probe can reach the right answer without doing the work, and only
//   the counts notice.
//
//   Drop the mirror arm's trust rule (see gba_size_probe.sv): THE SUITE
//   STAYED GREEN. That rule is an invariant guard with no case behind it, and
//   the RTL says so at the site rather than letting a green run imply cover
//   it does not have.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gba_size_probe;

localparam [31:0] KIB512 = 32'h00080000;
localparam [31:0] MIB1   = 32'h00100000;
localparam [31:0] MIB2   = 32'h00200000;
localparam [31:0] MIB4   = 32'h00400000;
localparam [31:0] MIB8   = 32'h00800000;
localparam [31:0] MIB16  = 32'h01000000;
localparam [31:0] MIB32  = 32'h02000000;

// The probe's own status codes, repeated here rather than imported, because a
// testbench that reads its expectations out of the module under test cannot
// disagree with it.
localparam [2:0] STATUS_IDLE     = 3'd0;
localparam [2:0] STATUS_SIZED    = 3'd1;
localparam [2:0] STATUS_CEILING  = 3'd2;
localparam [2:0] STATUS_NO_CART  = 3'd3;
localparam [2:0] STATUS_NO_POWER = 3'd4;
localparam [2:0] STATUS_CONSTANT = 3'd5;

localparam [1:0] CLS_UNSET  = 2'd0;
localparam [1:0] CLS_DATA   = 2'd1;
localparam [1:0] CLS_OPEN   = 2'd2;
localparam [1:0] CLS_MIRROR = 2'd3;

// The sample point offsets, as the probe is instantiated with them below.
localparam [23:0] OFF0 = 24'h000000;
localparam [23:0] OFF1 = 24'h0AAAA6;
localparam [23:0] OFF2 = 24'h13579C;
localparam [23:0] OFF3 = 24'h1E0006;

// Sentinel for "do not check the read count", used while a new case is being
// written. Every case below carries a real number.
localparam [31:0] ANY_READS = 32'hFFFFFFFF;

reg clk = 1'b0;
always #5 clk = ~clk;          // 100 MHz, close enough to clk_sys

reg reset = 1'b1;
reg powered = 1'b0;            // the slot has power: cart_mode_s in core_top
reg start = 1'b0;
reg clr = 1'b0;
reg use_bad = 1'b0;            // run the misparameterised probe instead
reg use_id  = 1'b0;            // hand the bus to cart_identify_gba instead
reg id_start = 1'b0;
reg mode_manual = 1'b0;        // hold GBA mode for a master that cannot ask

integer errors = 0;

// ---- The cartridge fixture ------------------------------------------------
//
// Everything the cases below vary. The model owns where the ROM stops; these
// registers decide what the content is inside it, and what faults are on top.

reg [27:0] rom_size;    // bytes, power of two. 0 means an empty slot.
reg        mirroring;   // high address lines undecoded: the ROM repeats
reg        all_blank;   // the whole cartridge answers 0xFFFF
reg [27:0] blank_lo, blank_hi;   // a byte range that answers 0xFFFF
reg [27:0] fake_lo, fake_hi;     // a byte range that answers its own address
reg        hole_en;              // one address past the end answers anyway
reg [27:0] hole_addr;
reg [11:0] period_win;  // block offsets below this repeat in every 4 KiB block
reg [1:0]  decay;       // float decay: 0 never, 1 first read, 2 second beat

// Ordinary ROM content. Two properties are load bearing and both are by
// construction rather than by luck:
//
//   It can never equal its own halfword address, because the value it is
//   xored with always has bit 8 set. Otherwise real data could read as open
//   bus and a case would pass or fail for a reason nobody had chosen.
//
//   Two addresses that differ only above bit 16 give different content,
//   because a[24:17] is xored in. Every candidate boundary from 1 to 16 MiB
//   is a bit in that range, so a probe address and its mirror image never
//   agree by accident on a cartridge that does not mirror.
function [15:0] rom_content(input [27:0] a);
    reg [15:0] mask;
begin
    mask = {a[8:1], a[24:17]} | 16'h0100;
    if (all_blank)
        rom_content = 16'hFFFF;
    else if (a >= blank_lo && a < blank_hi)
        rom_content = 16'hFFFF;
    else if (a >= fake_lo && a < fake_hi)
        rom_content = a[16:1];      // the perfect open-bus impostor
    else if (period_win != 12'd0 && a[11:0] < period_win)
        // Content that depends on the offset within a 4 KiB block and on
        // nothing else, so it is identical at every 4 KiB block in the
        // cartridge - and therefore identical at a probe address and at its
        // mirror image, which is what makes it look like a wrap.
        rom_content = 16'h9000 ^ {4'd0, a[11:0]};
    else
        rom_content = a[16:1] ^ mask;
end
endfunction

task clear_fixture;
begin
    rom_size   = 28'd0;
    mirroring  = 1'b0;
    all_blank  = 1'b0;
    blank_lo   = 28'd0;
    blank_hi   = 28'd0;
    fake_lo    = 28'd0;
    fake_hi    = 28'd0;
    hole_en    = 1'b0;
    hole_addr  = 28'd0;
    period_win = 12'd0;
    decay      = 2'd0;
end
endtask

// ---- Wiring ---------------------------------------------------------------

wire        p_busy, p_done, p_want;
wire [31:0] p_size;
wire        p_valid;
wire [2:0]  p_status;
wire [39:0]  p_class;
wire [239:0] p_hits;
wire [63:0]  p_words;
wire [27:0]  p_addr_dbg;
wire [63:0]  p_base;
wire [95:0]  p_pres;
wire [4:0]   p_points;

wire        g_req, g_wr;
wire [27:0] g_addr;
wire [1:0]  g_acc;
wire [31:0] g_wdata;

wire        b_busy, b_done, b_want;
wire [31:0] b_size;
wire        b_valid;
wire [2:0]  b_status;
wire        b_req, b_wr;
wire [27:0] b_addr;
wire [1:0]  b_acc;
wire [31:0] b_wdata;

wire [31:0] bus_rdata;
wire        bus_done, bus_busy;

// The mode the connector is asked for, from whichever probe is running. This
// is core_top's gba_mode_s in miniature: the probe asks, cart_pins turns the
// connector round, and only then does the bus engine see cart_mode.
wire        want_mux  = mode_manual || (use_bad ? b_want : p_want);
wire        cart_mode = powered && want_mux && mode_ready;

gba_size_probe #(.MODE_WAIT_CYCLES (200)) dut (
    .clk        ( clk ),
    .reset      ( reset ),
    .cart_mode  ( cart_mode ),
    .start      ( start & ~use_bad ),
    .busy       ( p_busy ),
    .done       ( p_done ),
    .want_gba   ( p_want ),
    .size_bytes ( p_size ),
    .size_valid ( p_valid ),
    .status     ( p_status ),
    .cart_req   ( g_req ),
    .cart_wr    ( g_wr ),
    .cart_addr  ( g_addr ),
    .cart_acc   ( g_acc ),
    .cart_wdata ( g_wdata ),
    .cart_rdata ( bus_rdata ),
    .cart_done  ( bus_done ),
    .cart_busy  ( bus_busy ),
    .dbg_class  ( p_class ),
    .dbg_hits   ( p_hits ),
    .dbg_words  ( p_words ),
    .dbg_addr   ( p_addr_dbg ),
    .dbg_base   ( p_base ),
    .dbg_pres   ( p_pres ),
    .dbg_points ( p_points )
);

// The same module with one sample point moved onto a 128 KiB page end, which
// is the constraint the RTL documents and nothing else tests. gba_cart_bus
// re-runs the address phase for the second beat of a 32-bit read there, so it
// re-drives AD and open bus comes back as {A + 1, A} - the exact signature of
// a cartridge answering the burst. Case 28 watches what that does.
gba_size_probe #(
    .PT_OFF0           ( 24'h01FFFE ),
    .MODE_WAIT_CYCLES  ( 200 )
) bad (
    .clk        ( clk ),
    .reset      ( reset ),
    .cart_mode  ( cart_mode ),
    .start      ( start & use_bad ),
    .busy       ( b_busy ),
    .done       ( b_done ),
    .want_gba   ( b_want ),
    .size_bytes ( b_size ),
    .size_valid ( b_valid ),
    .status     ( b_status ),
    .cart_req   ( b_req ),
    .cart_wr    ( b_wr ),
    .cart_addr  ( b_addr ),
    .cart_acc   ( b_acc ),
    .cart_wdata ( b_wdata ),
    .cart_rdata ( bus_rdata ),
    .cart_done  ( bus_done ),
    .cart_busy  ( bus_busy ),
    .dbg_class  (  ),
    .dbg_hits   (  ),
    .dbg_words  (  ),
    .dbg_addr   (  ),
    .dbg_base   (  ),
    .dbg_pres   (  ),
    .dbg_points (  )
);

// One bus, three masters, and no arbiter for the same reason core_top needs
// none: only one of them is ever started. This is the shape core_top's own GBA
// bus mux has - cart_identify_gba, gba_size_probe, cart_dump_gba - and the
// identification master is here rather than only in core_top because that mux
// is Phase A's wiring and nothing else exercises it.
wire        m_req   = use_id ? id_req   : use_bad ? b_req   : g_req;
wire        m_wr    = use_id ? id_wr    : use_bad ? b_wr    : g_wr;
wire [27:0] m_addr  = use_id ? id_addr  : use_bad ? b_addr  : g_addr;
wire [1:0]  m_acc   = use_id ? id_acc   : use_bad ? b_acc   : g_acc;
wire [31:0] m_wdata = use_id ? id_wdata : use_bad ? b_wdata : g_wdata;

// The identification master, which shares the mux with the two probes. It has
// no mode request of its own - cart_probe holds the mode for it in the core -
// so the testbench holds the mode manually while it runs, which is exactly the
// arrangement core_top has.
wire        id_busy, id_done;
wire [2:0]  id_result;
wire        id_req, id_wr;
wire [27:0] id_addr;
wire [1:0]  id_acc;
wire [31:0] id_wdata;

cart_identify_gba ident (
    .clk        ( clk ),
    .reset      ( reset ),
    .cart_mode  ( cart_mode ),
    .start      ( id_start ),
    .busy       ( id_busy ),
    .done       ( id_done ),
    .cart_req   ( id_req ),
    .cart_wr    ( id_wr ),
    .cart_addr  ( id_addr ),
    .cart_acc   ( id_acc ),
    .cart_wdata ( id_wdata ),
    .cart_rdata ( bus_rdata ),
    .cart_done  ( bus_done ),
    .cart_busy  ( bus_busy ),
    .result     ( id_result ),
    .title      (  ), .game_code (  ), .maker_code (  ),
    .device_type(  ), .sw_version(  ),
    .fixed_ok   (  ), .checksum_ok (  ), .reserved_ok (  ),
    .raw_words  (  ), .checksum_read (  ), .checksum_calc (  )
);

wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

gba_cart_bus bus (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(m_req), .wr(m_wr), .addr(m_addr), .acc(m_acc), .wdata(m_wdata),
    .rdata(bus_rdata), .done(bus_done), .busy(bus_busy),
    .e_ad_out(e_ad_out), .e_ad_oe(e_ad_oe),
    .e_hi_out(e_hi_out), .e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),
    .e_p30_out(e_p30_out), .e_p30_oe(e_p30_oe),
    .e_ad_in(e_ad_in), .e_hi_in(e_hi_in)
);

tri  [7:0] bank2, bank3, bank1;
wire       bank2_dir, bank3_dir, bank1_dir;
tri  [7:4] bank0;
wire       bank0_dir;
tri        pin30;
wire       pin30_dir, pin30_pwroff;
tri        pin31;
wire       pin31_dir;

cart_pins pins (
    .clk(clk), .reset(reset),
    .mode((powered && want_mux) ? 2'b01 : 2'b00),
    .mode_ready(mode_ready),
    .gba_ad_out(e_ad_out), .gba_ad_oe(e_ad_oe),
    .gba_hi_out(e_hi_out), .gba_hi_oe(e_hi_oe),
    .gba_ctl_out(e_ctl_out),
    .gba_p30_out(e_p30_out), .gba_p30_oe(e_p30_oe),
    .gba_ad_in(e_ad_in), .gba_hi_in(e_hi_in),
    .gb_ad_out(16'd0), .gb_ad_oe(1'b0),
    .gb_hi_out(8'd0), .gb_hi_oe(1'b0),
    .gb_ctl_out(4'hf),
    .gb_p30_out(1'b0), .gb_p30_oe(1'b0),
    .gb_ad_in(), .gb_hi_in(),
    .cart_tran_bank2(bank2), .cart_tran_bank2_dir(bank2_dir),
    .cart_tran_bank3(bank3), .cart_tran_bank3_dir(bank3_dir),
    .cart_tran_bank1(bank1), .cart_tran_bank1_dir(bank1_dir),
    .cart_tran_bank0(bank0), .cart_tran_bank0_dir(bank0_dir),
    .cart_tran_pin30(pin30), .cart_tran_pin30_dir(pin30_dir),
    .cart_pin30_pwroff_reset(pin30_pwroff),
    .cart_tran_pin31(pin31), .cart_tran_pin31_dir(pin31_dir)
);

wire [23:0] rom_addr, rom_addr_raw;
wire [15:0] save_addr;
wire [31:0] cs1_latch_count, rom_rd_count, wr_pulse_count;

// The model owns the extent; the fixture only says how big it is.
wire [24:0] rom_words = rom_size[27:1];
// One address past the end that answers anyway. The content it returns is the
// wrapped one, because a high address line that is not decoded is exactly what
// makes a stray address answer, and the silicon behind it sees the wrapped
// address rather than the one the bus asked for.
wire        extra_answer = hole_en && ({rom_addr_raw, 1'b0} == hole_addr[24:0]);

// Spelled out rather than left to @* or to a function call in the port list:
// the content depends on fixture registers the address does not mention, and
// a case that changed one of them without moving the address would otherwise
// keep answering with the previous case's data.
wire [27:0] eff_addr = {3'd0, rom_addr, 1'b0};
reg [15:0] rom_val;
always @(eff_addr or all_blank or blank_lo or blank_hi or fake_lo or fake_hi
         or period_win)
    rom_val = rom_content(eff_addr);

gba_cart_model #(.ROM_EXTENT(1)) cart (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(bank3), .bank3_dir(bank3_dir),
    .bank2(bank2), .bank2_dir(bank2_dir),
    .bank1(bank1), .bank1_dir(bank1_dir),
    .bank0(bank0), .pin30(pin30),
    .rom_words(rom_words), .rom_mirrors(mirroring),
    .rom_extra_answer(extra_answer), .ad_decay_beat(decay),
    .rom_addr(rom_addr), .rom_addr_raw(rom_addr_raw), .rom_rdata(rom_val),
    .save_addr(save_addr), .save_rdata(8'h00),
    .cs1_latch_count(cs1_latch_count), .cs2_latch_count(),
    .rom_rd_count(rom_rd_count), .save_rd_count(),
    .wr_pulse_count(wr_pulse_count),
    .rom_wr_count(), .save_wr_count(),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

// ---- Standing assertions --------------------------------------------------
//
// The probe is read-only by construction and this is the connector-level
// proof of it, checked on every cycle of every case rather than once at the
// end. gba_cart_bus would refuse a ROM-space write anyway; that is a second
// line of defence and not a reason to leave the first one untested.
always @(posedge clk) begin
    if (!reset && (g_wr !== 1'b0 || b_wr !== 1'b0)) begin
        $display("ERROR: the probe raised cart_wr at %0t", $time);
        errors = errors + 1;
    end
end

// The handshake hazard, watched continuously. gba_cart_bus samples req only in
// its own idle state and has no refusal guard, so a req held for two cycles is
// a second transaction nobody asked for, and a req raised while the bus is
// busy is one that will be taken later at an address that has moved on.
reg req_d = 1'b0;
always @(posedge clk) begin
    if (!reset) begin
        if (m_req && req_d) begin
            $display("ERROR: req held for more than one cycle at %0t", $time);
            errors = errors + 1;
        end
        if (m_req && bus_busy) begin
            $display("ERROR: req raised while the bus was busy at %0t", $time);
            errors = errors + 1;
        end
    end
    req_d <= m_req;
end

// The model's own counters are zeroed between cases so each case can report
// its own read count, so the run-wide statement about writes is counted here
// instead, straight off the WR# pin.
// A reg, not an integer: Icarus will not let a bit-select be taken of an
// integer and chk takes a 32-bit value.
reg [31:0] wr_falls = 32'd0;
always @(negedge bank0[6]) if (cart_mode) wr_falls = wr_falls + 32'd1;

// Watchdog. A probe that stops making progress has to fail with a message
// naming itself rather than stall until run_all.py's own timeout, where the
// only evidence left is a dead process.
initial begin
    #30_000_000;
    $fatal(1, "%m: watchdog expired at %0t, state busy=%b done=%b",
           $time, p_busy, p_done);
end

// ---- Checks ---------------------------------------------------------------
//
// Named chk, not expect: expect is a reserved word in Icarus.
task chk(input [255:0] what, input [31:0] got, input [31:0] want);
begin
    if (got !== want) begin
        $display("ERROR: %0s = 0x%08x, expected 0x%08x", what, got, want);
        errors = errors + 1;
    end
end
endtask

// Evidence readers. dbg_hits carries three nibbles per sample point, and a
// point is cand * 4 + point.
function [3:0] open_of(input integer s);
    open_of = p_hits[12*s +: 4];
endfunction
function [3:0] mir_of(input integer s);
    mir_of = p_hits[12*s + 4 +: 4];
endfunction
function [3:0] base_of(input integer s);
    base_of = p_hits[12*s + 8 +: 4];
endfunction
function [1:0] class_of(input integer s);
    class_of = p_class[2*s +: 2];
endfunction

integer done_pulses;

task run_probe;
begin
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    @(posedge clk);
    done_pulses = 0;
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    #1;
    while (!(use_bad ? b_done : p_done)) begin
        @(posedge clk);
        #1;
        if (use_bad ? b_done : p_done) done_pulses = done_pulses + 1;
    end
    // One more cycle after done, to catch a module that pulses it twice.
    @(posedge clk);
    #1;
    if (use_bad ? b_done : p_done) done_pulses = done_pulses + 1;
    if (done_pulses != 1) begin
        $display("ERROR: %0d done pulses in one run, expected 1", done_pulses);
        errors = errors + 1;
    end
end
endtask

// One case: set the fixture first, then call this with what should come back.
task check_size(input [255:0] name, input want_valid, input [31:0] want_size,
                input [2:0] want_status, input [31:0] want_reads);
begin
    run_probe;
    if (p_valid !== want_valid) begin
        $display("ERROR: %0s: size_valid = %b, expected %b", name, p_valid,
                 want_valid);
        errors = errors + 1;
    end
    if (want_valid) chk(name, p_size, want_size);
    if (p_status !== want_status) begin
        $display("ERROR: %0s: status = %0d, expected %0d", name, p_status,
                 want_status);
        errors = errors + 1;
    end
    if (want_reads != ANY_READS && rom_rd_count !== want_reads) begin
        $display("ERROR: %0s: %0d ROM reads, expected %0d", name,
                 rom_rd_count, want_reads);
        errors = errors + 1;
    end
    if (wr_pulse_count != 32'd0) begin
        $display("ERROR: %0s: the cartridge saw %0d WR# pulses", name,
                 wr_pulse_count);
        errors = errors + 1;
    end
    $display("case %0s: valid=%b size=0x%08x status=%0d points=%0d reads=%0d",
             name, p_valid, p_size, p_status, p_points, rom_rd_count);
end
endtask

integer k;

// ---- Cases ----------------------------------------------------------------

initial begin
    clear_fixture;
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    @(posedge clk);
    powered <= 1'b1;
    repeat (4) @(posedge clk);

    // A static statement about the four sample offsets, which is the one thing
    // case 28 cannot make for the offsets actually shipped. The confirmation
    // read starts at the point base, so its halfword address must not be
    // 0xFFFF within a 128 KiB page: byte address & 0x1FFFF must not be
    // 0x1FFFE. A candidate size is a power of two of at least 1 MiB and
    // contributes nothing to those bits, so the offsets decide it alone.
    if ((OFF0 & 24'h1FFFF) == 24'h1FFFE ||
        (OFF1 & 24'h1FFFF) == 24'h1FFFE ||
        (OFF2 & 24'h1FFFF) == 24'h1FFFE ||
        (OFF3 & 24'h1FFFF) == 24'h1FFFE) begin
        $display("ERROR: a sample offset puts the 32-bit confirmation read on a page end");
        errors = errors + 1;
    end

    // 1. Nothing in the slot. Open bus at the very first candidate would be a
    //    1 MiB cartridge if the presence pass did not exist, and reporting a
    //    size for an empty slot is the one failure that would look normal.
    clear_fixture;
    check_size("empty slot", 1'b0, 32'd0, STATUS_NO_CART, 32'd6);
    // The evidence behind the refusal: every presence read came back as its
    // own halfword address.
    chk("empty slot presence read 0", {16'd0, p_pres[15:0]},   32'h00000000);
    chk("empty slot presence read 1", {16'd0, p_pres[31:16]},  32'h00000050);
    chk("empty slot presence read 5", {16'd0, p_pres[95:80]},  32'h0000891A);

    // 2 to 6. Straightforward cartridges at every candidate size.
    clear_fixture; rom_size = MIB1;
    check_size("1 MiB", 1'b1, MIB1, STATUS_SIZED, 32'd50);
    chk("1 MiB deciding point address", {4'd0, p_addr_dbg}, MIB1 + OFF3);
    chk("1 MiB points completed", {27'd0, p_points}, 32'd4);

    clear_fixture; rom_size = MIB4;
    check_size("4 MiB", 1'b1, MIB4, STATUS_SIZED, 32'd54);

    clear_fixture; rom_size = MIB8;
    check_size("8 MiB", 1'b1, MIB8, STATUS_SIZED, 32'd56);

    clear_fixture; rom_size = MIB16;
    check_size("16 MiB", 1'b1, MIB16, STATUS_SIZED, 32'd58);

    // The ceiling. Nothing trips anywhere, and 32 MiB is all that
    // latched_addr[24:1] can reach, so there is no candidate above it - which
    // makes this a weaker claim than a measured size, and the status says so.
    clear_fixture; rom_size = MIB32;
    check_size("32 MiB", 1'b1, MIB32, STATUS_CEILING, 32'd20);
    // Five, not twenty: a candidate is abandoned at its first dissenting
    // point, and on a cartridge this large every candidate dissents at point 0.
    chk("32 MiB points completed", {27'd0, p_points}, 32'd5);

    // 7 to 10. Cartridges that answer past their end by wrapping. The float
    //          never happens, so these exercise the mirror arm on its own.
    clear_fixture; rom_size = MIB2;  mirroring = 1'b1;
    check_size("2 MiB mirrored", 1'b1, MIB2, STATUS_SIZED, 32'd44);

    clear_fixture; rom_size = MIB1;  mirroring = 1'b1;
    check_size("1 MiB mirrored", 1'b1, MIB1, STATUS_SIZED, 32'd42);

    clear_fixture; rom_size = MIB8;  mirroring = 1'b1;
    check_size("8 MiB mirrored", 1'b1, MIB8, STATUS_SIZED, 32'd48);

    clear_fixture; rom_size = MIB16; mirroring = 1'b1;
    check_size("16 MiB mirrored", 1'b1, MIB16, STATUS_SIZED, 32'd50);

    // 11. The adversarial case at full strength: every halfword from 1 MiB to
    //     the real end reads back as its own halfword address, which is what
    //     open bus reads as. No 16-bit read anywhere in that range can tell
    //     the two apart, however many places it looks. Only the 32-bit
    //     confirmation read separates them, because a cartridge answering a
    //     burst returns the next halfword and a float returns the same one.
    clear_fixture; rom_size = MIB4; fake_lo = MIB1; fake_hi = MIB4;
    check_size("impostor to 4 MiB", 1'b1, MIB4, STATUS_SIZED, 32'd70);
    // And the evidence says WHY it was not fooled: candidate 1 MiB, point 0
    // is data with all four halfwords matching the open-bus prediction. A
    // class alone would look like an ordinary rejection.
    chk("impostor point 0 class", {30'd0, class_of(0)}, {30'd0, CLS_DATA});
    chk("impostor point 0 open hits", {28'd0, open_of(0)}, 32'd4);

    // 12 to 15. The same attack as docs/GBA-DUMP-PLAN.md words it - a short
    //     ascending run planted at a candidate boundary - planted at each of
    //     the four sample points in turn. A mutation that trusted only the
    //     first point, or only the last, would fail some of these and not
    //     others, so all four are here and all four are asserted.
    for (k = 0; k < 4; k = k + 1) begin
        clear_fixture;
        rom_size = MIB4;
        fake_lo  = MIB1 + ((k == 0) ? OFF0 : (k == 1) ? OFF1 :
                           (k == 2) ? OFF2 : OFF3);
        fake_hi  = fake_lo + 28'h80;
        case (k)
            0: check_size("planted run at point 0", 1'b1, MIB4, STATUS_SIZED, 32'd60);
            1: check_size("planted run at point 1", 1'b1, MIB4, STATUS_SIZED, 32'd54);
            2: check_size("planted run at point 2", 1'b1, MIB4, STATUS_SIZED, 32'd54);
            default: check_size("planted run at point 3", 1'b1, MIB4, STATUS_SIZED, 32'd54);
        endcase
    end

    // 16. A blank upper half that is genuine memory. All-0xFFFF at the probe
    //     matches all-0xFFFF at its mirror image and looks exactly like a
    //     wrap; only the requirement that a mirror contain more than one value
    //     keeps this from being called the end at 4 MiB.
    //
    //     Deliberately NOT solved by a rule that all-ones means the end: a
    //     16 MiB mask ROM holding an 8 MiB game padded with 0xFF is a real
    //     thing, and that rule would dump less than the silicon holds, which
    //     is the failure the plan exists to prevent. Left as a known gap that
    //     the evidence outputs make visible rather than as a rule that cannot
    //     be tested.
    clear_fixture; rom_size = MIB8; blank_lo = MIB4; blank_hi = MIB8;
    check_size("8 MiB, blank top", 1'b1, MIB8, STATUS_SIZED, 32'd56);

    // 17. A cartridge that answers 0xFFFF everywhere. There is no honest size
    //     to report: it is indistinguishable from a blank or half-inserted
    //     one, and every candidate would read as a mirror of every other. The
    //     probe says so rather than guessing 1 MiB - and says it with a
    //     different status from an empty slot, because a blank-looking
    //     cartridge with a good header is a different thing to be told about.
    clear_fixture; rom_size = MIB4; all_blank = 1'b1;
    check_size("all-FF cartridge", 1'b0, 32'd0, STATUS_CONSTANT, 32'd6);

    // 18. A 4 MiB cartridge with one address past the end still answering -
    //     a partly decoded high address line, or a marginal contact. The
    //     probe requires all four sample points to agree, so it declines to
    //     call 4 MiB the end and reports the next candidate up. That is the
    //     designed bias, asserted here so that a later change towards
    //     majority voting has to be a deliberate one: an over-long dump
    //     contains mirrors, a truncated one silently loses the cartridge.
    //
    //     The bias is only defensible if the screen can say which point
    //     dissented, so the evidence is asserted too.
    clear_fixture; rom_size = MIB4; hole_en = 1'b1;
    hole_addr = MIB4 + {4'd0, OFF2};        // sample point 2 of candidate 4 MiB
    check_size("4 MiB with a live hole", 1'b1, MIB8, STATUS_SIZED, 32'd78);
    // Candidate 4 MiB is cand 2, so its four points are slots 8 to 11.
    chk("live hole: point 0 of 4 MiB", {30'd0, class_of(8)},  {30'd0, CLS_OPEN});
    chk("live hole: point 1 of 4 MiB", {30'd0, class_of(9)},  {30'd0, CLS_OPEN});
    chk("live hole: the dissenting point", {30'd0, class_of(10)}, {30'd0, CLS_DATA});
    // And what the dissent looked like, which is the part a screen has to
    // carry: the live address answered with the content of its own wrapped
    // image, so the first halfword matched the mirror reference and nothing
    // matched the open-bus prediction. The second halfword, genuinely past the
    // end, matched open bus and not the mirror - one each, from two reads, and
    // the point was abandoned there.
    chk("live hole: mirror hits at the dissenting point",
        {28'd0, mir_of(10)}, 32'd1);
    chk("live hole: open hits at the dissenting point",
        {28'd0, open_of(10)}, 32'd1);

    // 19. A cartridge whose first 0xB00 bytes of every 4 KiB block are the
    //     same repeating pattern, with unique data in the rest of each block.
    //     Alignment padding and repeated stub tables do this. It is the
    //     nastiest mirror impostor there is, because the pattern is genuinely
    //     identical at a probe address and at that address wrapped by any
    //     candidate - every candidate boundary is 4 KiB aligned, so the block
    //     offset survives the wrap.
    //
    //     Nothing about open bus helps here: the cartridge is answering, and
    //     answering with the truth. The only thing that breaks the illusion is
    //     reading far enough out to leave the repeating part of the block, and
    //     the 0x402 stride is what does it. The window is 0xB00 rather than
    //     some rounder number precisely so that three of the four sample
    //     points start inside the repeat and have to walk out of it.
    clear_fixture; rom_size = MIB4; period_win = 12'hB00;
    check_size("blockwise repeat", 1'b1, MIB4, STATUS_SIZED, 32'd82);

    // 20. Three of four. The trap of case 12, one halfword short of complete:
    //     the first three strides read as open bus and the fourth does not.
    //     On hardware that is the difference between a dirty connector and an
    //     answer, and a class on its own cannot tell them apart - which is why
    //     the hit count is asserted and not just the size.
    clear_fixture; rom_size = MIB4; fake_lo = MIB1; fake_hi = MIB1 + 28'h41;
    check_size("three of four", 1'b1, MIB4, STATUS_SIZED, 32'd60);
    chk("three of four: class", {30'd0, class_of(0)}, {30'd0, CLS_DATA});
    chk("three of four: open hits", {28'd0, open_of(0)}, 32'd3);

    // 21. The price of refusing a constant run as a mirror. This cartridge
    //     genuinely mirrors at 2 MiB, but the four halfwords at sample point 0
    //     are all 0xFFFF, so the mirror is not believed, and every candidate
    //     wraps to the same blank point and is rejected the same way. The
    //     probe walks to the ceiling.
    //
    //     Over-reporting is the safe direction and this is what it costs. The
    //     case is here so that the cost is a measured number rather than a
    //     sentence in a comment, and so that a later attempt to "fix" the
    //     varied rule has to explain what it does to case 16 instead.
    clear_fixture; rom_size = MIB2; mirroring = 1'b1;
    blank_lo = 28'd0; blank_hi = 28'h1000;
    check_size("mirror with a blank point", 1'b1, MIB32, STATUS_CEILING, 32'd44);

    // 22. Below the smallest candidate. 1 MiB is the floor, so a 512 KiB
    //     cartridge is reported as 1 MiB and would be dumped with its upper
    //     half open bus. No retail GBA cartridge is that small; the limit is
    //     demonstrated rather than stated, in the habit of tb_dump_checksum.
    //
    //     It is also the fixture that reaches the state the mirror arm's
    //     trust rule exists for. At candidate 1 MiB, sample point 1 sits at
    //     1 MiB + 0x0AAAA6 and its wrapped image is 0x0AAAA6, which is past
    //     the end of a 512 KiB ROM: both the probe address and its reference
    //     are open bus, they agree because a candidate contributes nothing to
    //     the low 17 address bits, and the point would satisfy mirror without
    //     the 32-bit confirmation ever being consulted. The trust rule sends
    //     it back to the open arm, which is confirmed.
    clear_fixture; rom_size = KIB512;
    check_size("512 KiB", 1'b1, MIB1, STATUS_SIZED, 32'd50);
    chk("512 KiB: point 1 decided by the open arm",
        {30'd0, class_of(1)}, {30'd0, CLS_OPEN});
    chk("512 KiB: and its mirror evidence was 4/4 all the same",
        {28'd0, mir_of(1)}, 32'd4);

    // 23. A float that has decayed by the second beat of the confirmation
    //     read. That read holds AD undriven for about twice as long as a
    //     single read, which is the one place this probe is more exposed to
    //     decay than a 16-bit-only classifier would be. The rule tolerates it
    //     - only the exact ascending answer is rejected - and this is the
    //     case that says so.
    clear_fixture; rom_size = MIB1; decay = 2'd2;
    check_size("decay on the second beat", 1'b1, MIB1, STATUS_SIZED, 32'd50);

    // 24. The same decay one beat earlier, inside the first read window. Now
    //     the probe cannot see open bus at all: every past-the-end read is
    //     0xFFFF, which is neither the address nor the mirror, so every
    //     candidate reads as data and the answer is the ceiling.
    //
    //     This is the failure docs/GBA-DUMP-PLAN.md names as the one risk
    //     simulation cannot settle. It fails towards a 32 MiB dump of a 1 MiB
    //     cartridge - slow and mostly mirror, but not a truncated image - and
    //     the deciding evidence reads FFFF rather than an address ramp, which
    //     names the fault on sight.
    clear_fixture; rom_size = MIB1; decay = 2'd1;
    check_size("decay inside the first read", 1'b1, MIB32, STATUS_CEILING, 32'd20);
    chk("decayed: the deciding halfword", {16'd0, p_words[15:0]}, 32'h0000FFFF);

    // 25. Back to back, largest then smallest, with nothing in between. Every
    //     other case here follows a fixture change; this one is about state
    //     inherited from the run before it.
    clear_fixture; rom_size = MIB16;
    check_size("16 MiB before", 1'b1, MIB16, STATUS_SIZED, 32'd58);
    clear_fixture; rom_size = MIB1;
    check_size("1 MiB straight after", 1'b1, MIB1, STATUS_SIZED, 32'd50);
    // Nothing from the 16 MiB run may still be showing under this verdict.
    chk("after a big cartridge: points completed", {27'd0, p_points}, 32'd4);
    chk("after a big cartridge: slot 19 class", {30'd0, class_of(19)},
        {30'd0, CLS_UNSET});

    // 26. The slot is not powered. The probe asks for GBA mode, cart_pins
    //     never carries it, and gba_cart_bus would ignore a request anyway and
    //     never raise done - so the probe must give up and say so rather than
    //     wait for an answer that cannot come.
    clear_fixture;
    rom_size = MIB4;
    powered <= 1'b0;
    repeat (40) @(posedge clk);
    check_size("no slot power", 1'b0, 32'd0, STATUS_NO_POWER, 32'd0);
    chk("no slot power: CS1 latches", cs1_latch_count, 32'd0);
    powered <= 1'b1;
    repeat (40) @(posedge clk);

    // 27. Power lost mid-probe. The bus resets under the probe and the
    //     outstanding transaction never completes.
    clear_fixture;
    rom_size = MIB16;
    clr <= 1'b1; @(posedge clk); clr <= 1'b0; @(posedge clk);
    start <= 1'b1; @(posedge clk); start <= 1'b0;
    repeat (300) @(posedge clk);      // well into the presence pass
    powered <= 1'b0;
    #1;
    while (!p_done) begin @(posedge clk); #1; end
    if (p_valid !== 1'b0) begin
        $display("ERROR: power lost mid-probe: size_valid = %b, expected 0",
                 p_valid);
        errors = errors + 1;
    end
    chk("power lost mid-probe: status", {29'd0, p_status},
        {29'd0, STATUS_NO_POWER});
    powered <= 1'b1;
    repeat (40) @(posedge clk);

    // 28. And the constraint the offsets are chosen under, demonstrated on a
    //     probe that violates it. PT_OFF0 is moved to 0x01FFFE, which puts the
    //     32-bit confirmation read at halfword 0xFFFF of a 128 KiB page for
    //     every candidate, because a candidate size contributes nothing to
    //     those bits. gba_cart_bus re-runs the address phase for the second
    //     beat there, re-driving AD, so genuinely empty space answers {A+1, A}
    //     - the signature of a cartridge - and no candidate can ever trip.
    //
    //     A 1 MiB cartridge is reported as 32 MiB. Nothing else in this file
    //     would catch an edit to those constants.
    clear_fixture;
    rom_size = MIB1;
    use_bad <= 1'b1;
    repeat (4) @(posedge clk);
    run_probe;
    if (b_valid !== 1'b1 || b_size !== MIB32 || b_status !== STATUS_CEILING) begin
        $display("ERROR: page-end offset: valid=%b size=0x%08x status=%0d, expected 1 0x%08x %0d",
                 b_valid, b_size, b_status, MIB32, STATUS_CEILING);
        errors = errors + 1;
    end
    $display("case page-end offset: a 1 MiB cartridge reported 0x%08x", b_size);
    use_bad <= 1'b0;
    repeat (4) @(posedge clk);

    // 29. The bus mux, which is Phase A's wiring and which nothing else
    //     exercises. cart_identify_gba and gba_size_probe are two masters on
    //     one gba_cart_bus with no arbiter, on the argument that they cannot
    //     run at the same time. Here they run one after the other on the same
    //     connector, in the order the core runs them, and both have to reach
    //     the cartridge and hand the bus back clean.
    clear_fixture;
    rom_size = MIB4;
    mode_manual <= 1'b1;
    use_id      <= 1'b1;
    repeat (4) @(posedge clk);
    while (!mode_ready) @(posedge clk);
    clr <= 1'b1; @(posedge clk); clr <= 1'b0; @(posedge clk);
    id_start <= 1'b1; @(posedge clk); id_start <= 1'b0;
    #1;
    while (!id_done) begin @(posedge clk); #1; end
    // Sixteen header halfwords, read twice: cart_identify_gba reads the header
    // a second time and compares, so a marginal contact cannot pass as a
    // cartridge. Thirty-two reads is the evidence that its transactions
    // actually reached the connector through the mux rather than being muxed
    // into nothing.
    chk("identify reads through the mux", rom_rd_count, 32'd32);
    use_id      <= 1'b0;
    mode_manual <= 1'b0;
    repeat (4) @(posedge clk);
    // And now the probe, on the same cartridge, through the same bus. Its own
    // read count is the one this file asserts everywhere else, so anything
    // left in flight from the identification would show up as an extra.
    // The name is short because chk and check_size take 32 characters and a
    // longer one is silently truncated in the report.
    check_size("size probe after identify", 1'b1, MIB4, STATUS_SIZED, 32'd54);

    // The connector-level statement of the whole point: over every case above
    // and every address they touched, WR# never once went low.
    chk("WR# falling edges over the whole run", wr_falls, 32'd0);

    if (errors != 0)
        $fatal(1, "tb_gba_size_probe: %0d checks failed", errors);

    $display("TB PASS: tb_gba_size_probe");
    $finish;
end

endmodule

`default_nettype wire
