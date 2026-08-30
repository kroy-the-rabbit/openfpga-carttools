// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Sole owner of the Analogue Pocket cartridge connector pins. Every direction
// decision for those pins is made here. Protocol engines present a flat
// interface and never name a cart_tran_* signal;
// tools/sim/check_pin_isolation.py enforces that.
//
// Pin map, verified in docs/HARDWARE-NOTES.md section 1:
//
//   bank3[7:0] = ad[7:0]                       connector pins 6-13
//   bank2[7:0] = ad[15:8]                      connector pins 14-21
//   bank1[7:0] = hi[7:0]                       connector pins 22-29
//   bank0[7:4] = ctl = {PHI, WR_n, RD_n, CS_n} connector pins 2-5
//   pin30                                      connector pin 30
//   pin31                                      connector pin 31
//
// cart_pin30_pwroff_reset is not a connector pin. It releases a clamp that
// otherwise holds connector pin 30 low, which holds a Game Boy cartridge in
// reset.
//
// A *_dir bit of 1 puts the level translator in output mode, 0 in input mode.
// Direction is per bank, not per pin.

module cart_pins (
    input  wire        clk,
    input  wire        reset,

    // 00 idle, 01 GBA, 10 GB, 11 idle.
    input  wire [1:0]  mode,
    // High only when the pins are carrying the requested mode.
    output wire        mode_ready,

    // GBA engine, src/fpga/core/gba_cart_bus.sv.
    input  wire [15:0] gba_ad_out,
    input  wire        gba_ad_oe,
    input  wire [7:0]  gba_hi_out,
    input  wire        gba_hi_oe,
    input  wire [3:0]  gba_ctl_out,
    input  wire        gba_p30_out,
    input  wire        gba_p30_oe,
    output wire [15:0] gba_ad_in,
    output wire [7:0]  gba_hi_in,

    // GB engine, src/fpga/core/gb_cart_bus.sv.
    input  wire [15:0] gb_ad_out,
    input  wire        gb_ad_oe,
    input  wire [7:0]  gb_hi_out,
    input  wire        gb_hi_oe,
    input  wire [3:0]  gb_ctl_out,
    input  wire        gb_p30_out,
    input  wire        gb_p30_oe,
    output wire [15:0] gb_ad_in,
    output wire [7:0]  gb_hi_in,

    inout  wire [7:0]  cart_tran_bank2,
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,
    output wire        cart_tran_pin31_dir
);

localparam [1:0] MODE_IDLE = 2'b00;
localparam [1:0] MODE_GBA  = 2'b01;
localparam [1:0] MODE_GB   = 2'b10;

// Cycles of idle a mode change must pass through before any pin is driven for
// the new mode. Switching protocols reverses the direction of eight pins, and
// overlapping the old drive with the new one is contention.
localparam [4:0] SETTLE_CYCLES = 5'd16;


// mode_q is the mode the settle counter is counting for. A mode input that
// disagrees with it drops mode_ready combinationally, so leaving a mode is
// immediate and entering one costs the settle window.
reg [1:0] mode_q;
reg [4:0] settle;

always @(posedge clk) begin
    if (reset) begin
        mode_q <= MODE_IDLE;
        settle <= SETTLE_CYCLES;
    end else if (mode != mode_q) begin
        mode_q <= mode;
        settle <= SETTLE_CYCLES;
    end else if (settle != 5'd0) begin
        settle <= settle - 5'd1;
    end
end

assign mode_ready = (mode == mode_q) && (settle == 5'd0);

wire [1:0] active = mode_ready ? mode : MODE_IDLE;
wire       sel_gba = active == MODE_GBA;
wire       sel_gb  = active == MODE_GB;

// Engine mux. Idle, mode 2'b11, and any pin no engine claims take the safe
// idle of docs/HARDWARE-NOTES.md section 3.
wire [15:0] ad_out  = sel_gba ? gba_ad_out  : sel_gb ? gb_ad_out  : 16'h0000;
wire        ad_oe   = sel_gba ? gba_ad_oe   : sel_gb ? gb_ad_oe   : 1'b0;
wire [7:0]  hi_out  = sel_gba ? gba_hi_out  : sel_gb ? gb_hi_out  : 8'h00;
wire        hi_oe   = sel_gba ? gba_hi_oe   : sel_gb ? gb_hi_oe   : 1'b0;
wire [3:0]  ctl_out = sel_gba ? gba_ctl_out : sel_gb ? gb_ctl_out : 4'hf;
wire        p30_out = sel_gba ? gba_p30_out : sel_gb ? gb_p30_out : 1'b0;
wire        p30_oe  = sel_gba ? gba_p30_oe  : sel_gb ? gb_p30_oe  : 1'b0;

assign cart_tran_bank3     = ad_oe ? ad_out[7:0]  : 8'hzz;
assign cart_tran_bank3_dir = ad_oe;
assign cart_tran_bank2     = ad_oe ? ad_out[15:8] : 8'hzz;
assign cart_tran_bank2_dir = ad_oe;

assign cart_tran_bank1     = hi_oe ? hi_out : 8'hzz;
assign cart_tran_bank1_dir = hi_oe;

// The strobes are always driven. A strobe left floating behind a level
// translator can drift low and latch a write into a cartridge.
assign cart_tran_bank0     = ctl_out;
assign cart_tran_bank0_dir = 1'b1;

assign cart_tran_pin30     = p30_oe ? p30_out : 1'b0;
assign cart_tran_pin30_dir = p30_oe;
// Released only while an engine owns the slot. Low holds a Game Boy cartridge
// in reset, which is the strongest safe state.
assign cart_pin30_pwroff_reset = sel_gba || sel_gb;

// Pin 31 is IRQ on a GBA cartridge and the analogue VIN on a Game Boy one. No
// engine claims it, so it is never driven.
assign cart_tran_pin31     = 1'bz;
assign cart_tran_pin31_dir = 1'b0;

assign gba_ad_in = {cart_tran_bank2, cart_tran_bank3};
assign gba_hi_in = cart_tran_bank1;
assign gb_ad_in  = {cart_tran_bank2, cart_tran_bank3};
assign gb_hi_in  = cart_tran_bank1;

endmodule
