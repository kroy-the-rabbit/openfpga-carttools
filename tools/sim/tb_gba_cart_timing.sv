// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv tools/sim/gba_cart_model.sv
//
// tb_gba_cart_timing.sv - the timing that actually ships.
//
// tb_gba_cart_bus.sv overrides all six cycle-count parameters down to 1 or 2 to
// keep its run short, so the numbers core_top instantiates the module with
// (2, 4, 4, 14, 12, 8) have never been simulated. This testbench runs the bus
// at those defaults and pins how long every state lasts, in clk cycles.
//
// Three rigs, driven from one set of stimulus:
//
//   rig_ship   the shipped defaults, taken by omitting every override.
//   rig_alt    a deliberately different set. Its durations have to move with
//              it, otherwise a parameter that stopped being honoured, or was
//              quietly hardwired, would still look correct against rig_ship.
//   rig_wrap   rig_alt's numbers plus 256. The module reduces every parameter
//              with `% 256` before use, so this must behave identically to
//              rig_alt; nothing tested that truncation before.
//
// The expected durations below are measured, not derived. A state loaded with
// N runs N+1 clocks, because the counter is loaded with N, decremented in the
// else branch and exits on the cycle where it reads zero (docs/HARDWARE-NOTES.md
// section 4). The strobe pulse widths are one clock shorter again, N not N+1,
// because the first cycle of ST_WRITE and of ST_READ_SETUP still carries the
// strobe value the previous state left behind. That asymmetry is the real
// behaviour and is pinned here as such, not corrected to what a reader might
// assume.
//
// The state duration checks read `state` out of the DUT through a hierarchical
// port connection. That is a deliberate coupling to the RTL's state encoding:
// no combination of pin observations can separate ST_ADDR_LATCH from
// ST_READ_TURN, since both hold CS1 low with RD# high and AD driven, so
// checking ADDR_LATCH_CYCLES and READ_TURNAROUND_CYCLES apart from each other
// is only possible from the inside. The pulse-width checks are pin-level and
// hold regardless of how the states are encoded.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// Duration checker. Lives with the data it collects so no testbench has to
// reach into an array across a hierarchy boundary.
// ---------------------------------------------------------------------------
module cart_state_probe #(
    parameter integer EXP_ADDR_SETUP  = 3,
    parameter integer EXP_ADDR_LATCH  = 5,
    parameter integer EXP_READ_TURN   = 5,
    parameter integer EXP_READ_SETUP  = 15,
    parameter integer EXP_WRITE       = 13,
    parameter integer EXP_WRITE_HOLD  = 9,
    parameter integer EXP_DONE        = 1,
    parameter integer EXP_READ_SEQ    = 5,
    parameter integer EXP_WRITE_SETUP = 1,
    parameter integer EXP_RD_LOW      = 14,
    parameter integer EXP_WR_LOW      = 12
) (
    input  wire        clk,
    input  wire        enable,
    input  wire [3:0]  state,
    input  wire        rd_n,
    input  wire        wr_n,
    output reg  [9:0]  seen_mask,
    output reg  [31:0] rd_pulses,
    output reg  [31:0] wr_pulses
);

reg [3:0] prev_state;
integer   len;
integer   rd_len;
integer   wr_len;

initial begin
    prev_state = 4'd0;
    len = 0;
    rd_len = 0;
    wr_len = 0;
    seen_mask = 10'd0;
    rd_pulses = 32'd0;
    wr_pulses = 32'd0;
end

// -1 means "variable, do not check". ST_IDLE is as long as the testbench
// leaves it idle, and the default arm catches an encoding that grew a state.
function integer want_cycles(input [3:0] st);
begin
    case (st)
        4'd0: want_cycles = -1;
        4'd1: want_cycles = EXP_ADDR_SETUP;
        4'd2: want_cycles = EXP_ADDR_LATCH;
        4'd3: want_cycles = EXP_READ_TURN;
        4'd4: want_cycles = EXP_READ_SETUP;
        4'd5: want_cycles = EXP_WRITE;
        4'd6: want_cycles = EXP_WRITE_HOLD;
        4'd7: want_cycles = EXP_DONE;
        4'd8: want_cycles = EXP_READ_SEQ;
        4'd9: want_cycles = EXP_WRITE_SETUP;
        default: want_cycles = -2;
    endcase
end
endfunction

task check_state(input [3:0] st, input integer got);
    integer want;
begin
    want = want_cycles(st);
    if (want == -2)
        $fatal(1, "%m: entered undefined state %0d", st);
    if (want >= 0) begin
        seen_mask[st] = 1'b1;
        if (got != want)
            $fatal(1, "%m: state %0d lasted %0d clk, expected %0d",
                   st, got, want);
    end
end
endtask

// Sampled a nanosecond after the edge so `state` is the value the DUT just
// clocked in, not the one it is leaving.
always @(posedge clk) begin
    #1;
    if (!enable) begin
        prev_state = state;
        len = 1;
    end else if (state !== prev_state) begin
        check_state(prev_state, len);
        prev_state = state;
        len = 1;
    end else begin
        len = len + 1;
    end
end

always @(posedge clk) begin
    #1;
    if (!enable) begin
        rd_len = 0;
        wr_len = 0;
    end else begin
        if (rd_n === 1'b0) begin
            rd_len = rd_len + 1;
        end else if (rd_len != 0) begin
            if (rd_len != EXP_RD_LOW)
                $fatal(1, "%m: RD# was low for %0d clk, expected %0d",
                       rd_len, EXP_RD_LOW);
            rd_pulses = rd_pulses + 32'd1;
            rd_len = 0;
        end
        if (wr_n === 1'b0) begin
            wr_len = wr_len + 1;
        end else if (wr_len != 0) begin
            if (wr_len != EXP_WR_LOW)
                $fatal(1, "%m: WR# was low for %0d clk, expected %0d",
                       wr_len, EXP_WR_LOW);
            wr_pulses = wr_pulses + 32'd1;
            wr_len = 0;
        end
    end
end

endmodule


module tb_gba_cart_timing;

reg clk = 1'b0;
always #5 clk = ~clk;

reg        reset = 1'b1;
reg        cart_mode = 1'b0;
reg        req = 1'b0;
reg        wr = 1'b0;
reg [27:0] addr = 28'd0;
reg [1:0]  acc = 2'b01;
reg [31:0] wdata = 32'd0;
reg        probe_en = 1'b0;
reg        clr = 1'b0;

// A ROM image the testbench can predict, sensitive to every latched address
// bit so a wrong A16-A23 shows up as wrong data rather than as nothing.
function [15:0] rom_word(input [23:0] a);
begin
    rom_word = {a[7:0] ^ a[23:16], a[15:8] + 8'h5A};
end
endfunction

// Watchdog. A testbench that stops making progress has to fail with a message
// naming itself, not stall until run_all.py's own timeout, where the only
// evidence left is a dead process.
initial begin
    #200_000;
    $fatal(1, "%m: watchdog expired at %0t with busy=%b; the run never reached its end",
           $time, s_busy);
end

// --- rig: shipped defaults -------------------------------------------------

tri  [7:0] s_bank2, s_bank3, s_bank1;
wire       s_bank2_dir, s_bank3_dir, s_bank1_dir;
tri  [7:4] s_bank0;
wire       s_bank0_dir;
tri        s_pin30;
wire       s_pin30_dir, s_pin30_pwroff;
tri        s_pin31;
wire       s_pin31_dir;
wire [31:0] s_rdata;
wire        s_done, s_busy;
wire [23:0] s_rom_addr;
wire [15:0] s_save_addr;

// gba_cart_bus presents a flat engine interface; cart_pins owns the pins and
// every assertion below still reads them.
wire [15:0] s_e_ad_out, s_e_ad_in;
wire        s_e_ad_oe;
wire [7:0]  s_e_hi_out, s_e_hi_in;
wire        s_e_hi_oe;
wire [3:0]  s_e_ctl_out;
wire        s_e_p30_out, s_e_p30_oe;
wire        s_mode_ready;
wire [15:0] a_e_ad_out, a_e_ad_in;
wire        a_e_ad_oe;
wire [7:0]  a_e_hi_out, a_e_hi_in;
wire        a_e_hi_oe;
wire [3:0]  a_e_ctl_out;
wire        a_e_p30_out, a_e_p30_oe;
wire        a_mode_ready;
wire [15:0] w_e_ad_out, w_e_ad_in;
wire        w_e_ad_oe;
wire [7:0]  w_e_hi_out, w_e_hi_in;
wire        w_e_hi_oe;
wire [3:0]  w_e_ctl_out;
wire        w_e_p30_out, w_e_p30_oe;
wire        w_mode_ready;

gba_cart_bus dut_ship (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(req), .wr(wr), .addr(addr), .acc(acc), .wdata(wdata),
    .rdata(s_rdata), .done(s_done), .busy(s_busy),
    .e_ad_out(s_e_ad_out), .e_ad_oe(s_e_ad_oe),
    .e_hi_out(s_e_hi_out), .e_hi_oe(s_e_hi_oe),
    .e_ctl_out(s_e_ctl_out),
    .e_p30_out(s_e_p30_out), .e_p30_oe(s_e_p30_oe),
    .e_ad_in(s_e_ad_in), .e_hi_in(s_e_hi_in)
);

cart_pins s_pins (
    .clk(clk), .reset(reset), .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(s_mode_ready),
    .gba_ad_out(s_e_ad_out), .gba_ad_oe(s_e_ad_oe),
    .gba_hi_out(s_e_hi_out), .gba_hi_oe(s_e_hi_oe),
    .gba_ctl_out(s_e_ctl_out),
    .gba_p30_out(s_e_p30_out), .gba_p30_oe(s_e_p30_oe),
    .gba_ad_in(s_e_ad_in), .gba_hi_in(s_e_hi_in),
    .cart_tran_bank2(s_bank2), .cart_tran_bank2_dir(s_bank2_dir),
    .cart_tran_bank3(s_bank3), .cart_tran_bank3_dir(s_bank3_dir),
    .cart_tran_bank1(s_bank1), .cart_tran_bank1_dir(s_bank1_dir),
    .cart_tran_bank0(s_bank0), .cart_tran_bank0_dir(s_bank0_dir),
    .cart_tran_pin30(s_pin30), .cart_tran_pin30_dir(s_pin30_dir),
    .cart_pin30_pwroff_reset(s_pin30_pwroff),
    .cart_tran_pin31(s_pin31), .cart_tran_pin31_dir(s_pin31_dir)
);

gba_cart_model cart_ship (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(s_bank3), .bank3_dir(s_bank3_dir),
    .bank2(s_bank2), .bank2_dir(s_bank2_dir),
    .bank1(s_bank1), .bank1_dir(s_bank1_dir),
    .bank0(s_bank0), .pin30(s_pin30),
    .rom_addr(s_rom_addr), .rom_rdata(rom_word(s_rom_addr)),
    .save_addr(s_save_addr), .save_rdata(8'hA5),
    .cs1_latch_count(), .cs2_latch_count(),
    .rom_rd_count(), .save_rd_count(), .wr_pulse_count(),
    .rom_wr_count(), .save_wr_count(),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

wire [9:0]  s_seen;
wire [31:0] s_rd_pulses, s_wr_pulses;
cart_state_probe #(
    .EXP_ADDR_SETUP(3), .EXP_ADDR_LATCH(5), .EXP_READ_TURN(5),
    .EXP_READ_SETUP(15), .EXP_WRITE(13), .EXP_WRITE_HOLD(9),
    .EXP_DONE(1), .EXP_READ_SEQ(5), .EXP_WRITE_SETUP(1),
    .EXP_RD_LOW(14), .EXP_WR_LOW(12)
) probe_ship (
    .clk(clk), .enable(probe_en), .state(dut_ship.state),
    .rd_n(s_bank0[5]), .wr_n(s_bank0[6]),
    .seen_mask(s_seen), .rd_pulses(s_rd_pulses), .wr_pulses(s_wr_pulses)
);

// --- rig: a different parameter set ---------------------------------------

tri  [7:0] a_bank2, a_bank3, a_bank1;
wire       a_bank2_dir, a_bank3_dir, a_bank1_dir;
tri  [7:4] a_bank0;
wire       a_bank0_dir;
tri        a_pin30;
wire       a_pin30_dir, a_pin30_pwroff;
tri        a_pin31;
wire       a_pin31_dir;
wire [31:0] a_rdata;
wire        a_done, a_busy;
wire [23:0] a_rom_addr;
wire [15:0] a_save_addr;

gba_cart_bus #(
    .ADDR_HOLD_CYCLES(5),
    .ADDR_LATCH_CYCLES(3),
    .READ_TURNAROUND_CYCLES(2),
    .READ_SETUP_CYCLES(7),
    .WRITE_SETUP_CYCLES(4),
    .WRITE_HOLD_CYCLES(6)
) dut_alt (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(req), .wr(wr), .addr(addr), .acc(acc), .wdata(wdata),
    .rdata(a_rdata), .done(a_done), .busy(a_busy),
    .e_ad_out(a_e_ad_out), .e_ad_oe(a_e_ad_oe),
    .e_hi_out(a_e_hi_out), .e_hi_oe(a_e_hi_oe),
    .e_ctl_out(a_e_ctl_out),
    .e_p30_out(a_e_p30_out), .e_p30_oe(a_e_p30_oe),
    .e_ad_in(a_e_ad_in), .e_hi_in(a_e_hi_in)
);

cart_pins a_pins (
    .clk(clk), .reset(reset), .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(a_mode_ready),
    .gba_ad_out(a_e_ad_out), .gba_ad_oe(a_e_ad_oe),
    .gba_hi_out(a_e_hi_out), .gba_hi_oe(a_e_hi_oe),
    .gba_ctl_out(a_e_ctl_out),
    .gba_p30_out(a_e_p30_out), .gba_p30_oe(a_e_p30_oe),
    .gba_ad_in(a_e_ad_in), .gba_hi_in(a_e_hi_in),
    .cart_tran_bank2(a_bank2), .cart_tran_bank2_dir(a_bank2_dir),
    .cart_tran_bank3(a_bank3), .cart_tran_bank3_dir(a_bank3_dir),
    .cart_tran_bank1(a_bank1), .cart_tran_bank1_dir(a_bank1_dir),
    .cart_tran_bank0(a_bank0), .cart_tran_bank0_dir(a_bank0_dir),
    .cart_tran_pin30(a_pin30), .cart_tran_pin30_dir(a_pin30_dir),
    .cart_pin30_pwroff_reset(a_pin30_pwroff),
    .cart_tran_pin31(a_pin31), .cart_tran_pin31_dir(a_pin31_dir)
);

gba_cart_model cart_alt (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(a_bank3), .bank3_dir(a_bank3_dir),
    .bank2(a_bank2), .bank2_dir(a_bank2_dir),
    .bank1(a_bank1), .bank1_dir(a_bank1_dir),
    .bank0(a_bank0), .pin30(a_pin30),
    .rom_addr(a_rom_addr), .rom_rdata(rom_word(a_rom_addr)),
    .save_addr(a_save_addr), .save_rdata(8'hA5),
    .cs1_latch_count(), .cs2_latch_count(),
    .rom_rd_count(), .save_rd_count(), .wr_pulse_count(),
    .rom_wr_count(), .save_wr_count(),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

wire [9:0]  a_seen;
wire [31:0] a_rd_pulses, a_wr_pulses;
cart_state_probe #(
    .EXP_ADDR_SETUP(6), .EXP_ADDR_LATCH(4), .EXP_READ_TURN(3),
    .EXP_READ_SETUP(8), .EXP_WRITE(5), .EXP_WRITE_HOLD(7),
    .EXP_DONE(1), .EXP_READ_SEQ(3), .EXP_WRITE_SETUP(1),
    .EXP_RD_LOW(7), .EXP_WR_LOW(4)
) probe_alt (
    .clk(clk), .enable(probe_en), .state(dut_alt.state),
    .rd_n(a_bank0[5]), .wr_n(a_bank0[6]),
    .seen_mask(a_seen), .rd_pulses(a_rd_pulses), .wr_pulses(a_wr_pulses)
);

// --- rig: the same parameter set plus 256 ---------------------------------

tri  [7:0] w_bank2, w_bank3, w_bank1;
wire       w_bank2_dir, w_bank3_dir, w_bank1_dir;
tri  [7:4] w_bank0;
wire       w_bank0_dir;
tri        w_pin30;
wire       w_pin30_dir, w_pin30_pwroff;
tri        w_pin31;
wire       w_pin31_dir;
wire [31:0] w_rdata;
wire        w_done, w_busy;
wire [23:0] w_rom_addr;
wire [15:0] w_save_addr;

gba_cart_bus #(
    .ADDR_HOLD_CYCLES(5 + 256),
    .ADDR_LATCH_CYCLES(3 + 256),
    .READ_TURNAROUND_CYCLES(2 + 256),
    .READ_SETUP_CYCLES(7 + 256),
    .WRITE_SETUP_CYCLES(4 + 256),
    .WRITE_HOLD_CYCLES(6 + 256)
) dut_wrap (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(req), .wr(wr), .addr(addr), .acc(acc), .wdata(wdata),
    .rdata(w_rdata), .done(w_done), .busy(w_busy),
    .e_ad_out(w_e_ad_out), .e_ad_oe(w_e_ad_oe),
    .e_hi_out(w_e_hi_out), .e_hi_oe(w_e_hi_oe),
    .e_ctl_out(w_e_ctl_out),
    .e_p30_out(w_e_p30_out), .e_p30_oe(w_e_p30_oe),
    .e_ad_in(w_e_ad_in), .e_hi_in(w_e_hi_in)
);

cart_pins w_pins (
    .clk(clk), .reset(reset), .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(w_mode_ready),
    .gba_ad_out(w_e_ad_out), .gba_ad_oe(w_e_ad_oe),
    .gba_hi_out(w_e_hi_out), .gba_hi_oe(w_e_hi_oe),
    .gba_ctl_out(w_e_ctl_out),
    .gba_p30_out(w_e_p30_out), .gba_p30_oe(w_e_p30_oe),
    .gba_ad_in(w_e_ad_in), .gba_hi_in(w_e_hi_in),
    .cart_tran_bank2(w_bank2), .cart_tran_bank2_dir(w_bank2_dir),
    .cart_tran_bank3(w_bank3), .cart_tran_bank3_dir(w_bank3_dir),
    .cart_tran_bank1(w_bank1), .cart_tran_bank1_dir(w_bank1_dir),
    .cart_tran_bank0(w_bank0), .cart_tran_bank0_dir(w_bank0_dir),
    .cart_tran_pin30(w_pin30), .cart_tran_pin30_dir(w_pin30_dir),
    .cart_pin30_pwroff_reset(w_pin30_pwroff),
    .cart_tran_pin31(w_pin31), .cart_tran_pin31_dir(w_pin31_dir)
);

gba_cart_model cart_wrap (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(w_bank3), .bank3_dir(w_bank3_dir),
    .bank2(w_bank2), .bank2_dir(w_bank2_dir),
    .bank1(w_bank1), .bank1_dir(w_bank1_dir),
    .bank0(w_bank0), .pin30(w_pin30),
    .rom_addr(w_rom_addr), .rom_rdata(rom_word(w_rom_addr)),
    .save_addr(w_save_addr), .save_rdata(8'hA5),
    .cs1_latch_count(), .cs2_latch_count(),
    .rom_rd_count(), .save_rd_count(), .wr_pulse_count(),
    .rom_wr_count(), .save_wr_count(),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

wire [9:0]  w_seen;
wire [31:0] w_rd_pulses, w_wr_pulses;
cart_state_probe #(
    .EXP_ADDR_SETUP(6), .EXP_ADDR_LATCH(4), .EXP_READ_TURN(3),
    .EXP_READ_SETUP(8), .EXP_WRITE(5), .EXP_WRITE_HOLD(7),
    .EXP_DONE(1), .EXP_READ_SEQ(3), .EXP_WRITE_SETUP(1),
    .EXP_RD_LOW(7), .EXP_WR_LOW(4)
) probe_wrap (
    .clk(clk), .enable(probe_en), .state(dut_wrap.state),
    .rd_n(w_bank0[5]), .wr_n(w_bank0[6]),
    .seen_mask(w_seen), .rd_pulses(w_rd_pulses), .wr_pulses(w_wr_pulses)
);

// --- stimulus --------------------------------------------------------------

// One request pulse reaches all three rigs at the same edge; they then run at
// their own speeds and the task waits for the slowest.
task automatic pulse_all(input is_write, input [27:0] a, input [1:0] size,
                         input [31:0] d);
begin
    @(posedge clk);
    wr <= is_write;
    addr <= a;
    acc <= size;
    wdata <= d;
    req <= 1'b1;
    @(posedge clk);
    req <= 1'b0;
    wait (s_busy && a_busy && w_busy);
    wait (!s_busy && !a_busy && !w_busy);
    repeat (3) @(posedge clk);
end
endtask

initial begin
    repeat (2) @(posedge clk);
    reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (s_mode_ready && a_mode_ready && w_mode_ready);
    repeat (4) @(posedge clk);
    probe_en <= 1'b1;
    @(posedge clk);

    // A 16-bit ROM read walks ADDR_SETUP, ADDR_LATCH, READ_TURN, READ_SETUP,
    // DONE.
    pulse_all(1'b0, 28'h0000120, 2'b01, 32'd0);
    if (s_rdata[15:0] !== rom_word(24'h000090))
        $fatal(1, "shipped-timing ROM read returned %h, expected %h",
               s_rdata[15:0], rom_word(24'h000090));
    if (a_rdata[15:0] !== rom_word(24'h000090))
        $fatal(1, "alt-timing ROM read returned %h", a_rdata[15:0]);
    if (w_rdata !== a_rdata)
        $fatal(1, "parameters+256 read %h, parameters alone read %h",
               w_rdata, a_rdata);

    // A 32-bit ROM read adds READ_SEQ.
    pulse_all(1'b0, 28'h0000120, 2'b10, 32'd0);
    if (s_rdata !== {rom_word(24'h000091), rom_word(24'h000090)})
        $fatal(1, "shipped-timing 32-bit ROM read returned %h", s_rdata);
    if (w_rdata !== a_rdata)
        $fatal(1, "parameters+256 32-bit read %h, parameters alone %h",
               w_rdata, a_rdata);

    // A write into a writable space adds WRITE_SETUP, WRITE, WRITE_HOLD and
    // is the only way to get WR# low, which is what EXP_WR_LOW measures.
    pulse_all(1'b1, 28'hE000123, 2'b00, 32'h0000005A);

    probe_en <= 1'b0;
    @(posedge clk);

    // Every state the module has must have been timed, or the durations above
    // prove less than they appear to.
    if (s_seen[9:1] !== 9'h1FF)
        $fatal(1, "shipped-timing rig never entered states %b", ~s_seen[9:1]);
    if (a_seen[9:1] !== 9'h1FF)
        $fatal(1, "alt-timing rig never entered states %b", ~a_seen[9:1]);
    if (w_seen[9:1] !== 9'h1FF)
        $fatal(1, "wrapped-timing rig never entered states %b", ~w_seen[9:1]);

    // One RD# pulse for the 16-bit read, two for the 32-bit read, none for
    // the write.
    if (s_rd_pulses !== 32'd3 || a_rd_pulses !== 32'd3 || w_rd_pulses !== 32'd3)
        $fatal(1, "RD# pulse counts were %0d/%0d/%0d, expected 3 each",
               s_rd_pulses, a_rd_pulses, w_rd_pulses);
    if (s_wr_pulses !== 32'd1 || a_wr_pulses !== 32'd1 || w_wr_pulses !== 32'd1)
        $fatal(1, "WR# pulse counts were %0d/%0d/%0d, expected 1 each",
               s_wr_pulses, a_wr_pulses, w_wr_pulses);

    $display("TB PASS: tb_gba_cart_timing");
    $finish;
end

endmodule
