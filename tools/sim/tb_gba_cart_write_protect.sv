// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv tools/sim/gba_cart_model.sv
//
// tb_gba_cart_write_protect.sv - WR# must never reach a cartridge outside the
// three writable spaces.
//
// gba_cart_bus gates the WR# pin with
//
//   wire cart_write_enable = latched_wr && (eeprom_space || save_space || gpio_space);
//   wire wr_n_pin = (state == ST_WRITE && cart_write_enable) ? wr_n : 1'b1;
//
// so a write anywhere else runs the whole state machine and reports done, but
// the pin stays high. That interlock is the only thing standing between a
// stray request and a corrupted cartridge, and nothing tested it in either
// direction. This testbench does both halves: writes that must be swallowed,
// and writes that must go through, so a change that disabled the interlock and
// a change that disabled writing entirely are each a failure.
//
// Run at the shipped default timing, not the shortened parameters.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gba_cart_write_protect;

reg clk = 1'b0;
always #5 clk = ~clk;

reg        reset = 1'b1;
reg        cart_mode = 1'b0;
reg        req = 1'b0;
reg        wr = 1'b0;
reg [27:0] addr = 28'd0;
reg [1:0]  acc = 2'b01;
reg [31:0] wdata = 32'd0;
reg        clr = 1'b0;

wire [31:0] rdata;
wire        done, busy;

tri  [7:0] bank2, bank3, bank1;
wire       bank2_dir, bank3_dir, bank1_dir;
tri  [7:4] bank0;
wire       bank0_dir;
tri        pin30;
wire       pin30_dir, pin30_pwroff;
tri        pin31;
wire       pin31_dir;

wire [23:0] rom_addr;
wire [15:0] save_addr;
wire [31:0] wr_pulse_count, rom_wr_count, save_wr_count;

// Watchdog. A testbench that stops making progress has to fail with a message
// naming itself, not stall until run_all.py's own timeout, where the only
// evidence left is a dead process.
initial begin
    #600_000;
    $fatal(1, "%m: watchdog expired at %0t with busy=%b; the run never reached its end",
           $time, busy);
end

// gba_cart_bus presents a flat engine interface; cart_pins owns the pins and
// every assertion below still reads them.
wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

gba_cart_bus dut (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(req), .wr(wr), .addr(addr), .acc(acc), .wdata(wdata),
    .rdata(rdata), .done(done), .busy(busy),
    .e_ad_out(e_ad_out), .e_ad_oe(e_ad_oe),
    .e_hi_out(e_hi_out), .e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),
    .e_p30_out(e_p30_out), .e_p30_oe(e_p30_oe),
    .e_ad_in(e_ad_in), .e_hi_in(e_hi_in)
);

cart_pins pins (
    .clk(clk), .reset(reset), .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(mode_ready),
    .gba_ad_out(e_ad_out), .gba_ad_oe(e_ad_oe),
    .gba_hi_out(e_hi_out), .gba_hi_oe(e_hi_oe),
    .gba_ctl_out(e_ctl_out),
    .gba_p30_out(e_p30_out), .gba_p30_oe(e_p30_oe),
    .gba_ad_in(e_ad_in), .gba_hi_in(e_hi_in),
    .cart_tran_bank2(bank2), .cart_tran_bank2_dir(bank2_dir),
    .cart_tran_bank3(bank3), .cart_tran_bank3_dir(bank3_dir),
    .cart_tran_bank1(bank1), .cart_tran_bank1_dir(bank1_dir),
    .cart_tran_bank0(bank0), .cart_tran_bank0_dir(bank0_dir),
    .cart_tran_pin30(pin30), .cart_tran_pin30_dir(pin30_dir),
    .cart_pin30_pwroff_reset(pin30_pwroff),
    .cart_tran_pin31(pin31), .cart_tran_pin31_dir(pin31_dir)
);

gba_cart_model cart (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(bank3), .bank3_dir(bank3_dir),
    .bank2(bank2), .bank2_dir(bank2_dir),
    .bank1(bank1), .bank1_dir(bank1_dir),
    .bank0(bank0), .pin30(pin30),
    .rom_addr(rom_addr), .rom_rdata(16'hBEEF),
    .save_addr(save_addr), .save_rdata(8'hA5),
    .cs1_latch_count(), .cs2_latch_count(),
    .rom_rd_count(), .save_rd_count(),
    .wr_pulse_count(wr_pulse_count),
    .rom_wr_count(rom_wr_count), .save_wr_count(save_wr_count),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

// Armed for the whole run, not just around a transaction: a WR# edge at any
// other moment is exactly as dangerous as one inside a suppressed write.
reg        wr_allowed = 1'b0;
reg [27:0] cur_addr = 28'd0;
always @(negedge bank0[6]) begin
    #1;
    if (!wr_allowed)
        $fatal(1, "WR# pulsed low for a write to %h, which is not EEPROM, save or GPIO space",
               cur_addr);
end

task automatic pulse(input is_write, input [27:0] a, input [1:0] size,
                     input [31:0] d);
begin
    @(posedge clk);
    cur_addr <= a;
    wr <= is_write;
    addr <= a;
    acc <= size;
    wdata <= d;
    req <= 1'b1;
    @(posedge clk);
    req <= 1'b0;
    wait (busy);
    wait (!busy);
    repeat (2) @(posedge clk);
end
endtask

// A write that must not reach the pin. The state machine still has to run to
// completion, because a requester that never gets `done` back is its own kind
// of failure.
task automatic deny(input [27:0] a, input [1:0] size);
begin
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    @(posedge clk);
    wr_allowed = 1'b0;
    pulse(1'b1, a, size, 32'hDEADBEEF);
    if (wr_pulse_count !== 32'd0)
        $fatal(1, "write to %h produced %0d WR# pulses, expected none",
               a, wr_pulse_count);
    if (rom_wr_count !== 32'd0 || save_wr_count !== 32'd0)
        $fatal(1, "write to %h reached the cart model", a);
    if (busy !== 1'b0)
        $fatal(1, "suppressed write to %h left the bus busy", a);
    if (bank0[6] !== 1'b1)
        $fatal(1, "suppressed write to %h left WR# low", a);
    if (pin30 !== 1'b1)
        $fatal(1, "suppressed write to %h left CS2# asserted", a);
end
endtask

// A write that must reach the pin, so the checks above are not passing for the
// trivial reason that nothing writes at all.
task automatic allow(input [27:0] a, input [1:0] size, input [31:0] d,
                     input [31:0] want_pulses);
begin
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    @(posedge clk);
    wr_allowed = 1'b1;
    pulse(1'b1, a, size, d);
    wr_allowed = 1'b0;
    if (wr_pulse_count !== want_pulses)
        $fatal(1, "write to %h produced %0d WR# pulses, expected %0d",
               a, wr_pulse_count, want_pulses);
    if (bank0[6] !== 1'b1)
        $fatal(1, "write to %h left WR# low", a);
end
endtask

integer i;

// Address decode boundaries worth naming: 0x8000000 is the base of ROM space,
// 0x80000C4..0x80000C8 is the GPIO window inside it, 0xD is EEPROM, 0xE and
// 0xF are save. Everything else is read-only as far as this module is
// concerned. The module ignores addr[27:25] when forming the pin address, so
// the aliases of ROM space are listed too: they decode as non-writable by the
// same rule and must behave the same way.
localparam integer N_DENY = 20;
reg [27:0] deny_addr [0:N_DENY-1];

initial begin
    deny_addr[0]  = 28'h0000000;   // address zero, the lowest thing reachable
    deny_addr[1]  = 28'h0000002;
    deny_addr[2]  = 28'h00000C4;   // the GPIO offset, but not in GPIO space
    deny_addr[3]  = 28'h0FFFFFE;
    deny_addr[4]  = 28'h1000000;
    deny_addr[5]  = 28'h1FFFFFE;
    deny_addr[6]  = 28'h2000000;
    deny_addr[7]  = 28'h3000000;
    deny_addr[8]  = 28'h4000000;
    deny_addr[9]  = 28'h5000000;
    deny_addr[10] = 28'h6000000;
    deny_addr[11] = 28'h7FFFFFE;
    deny_addr[12] = 28'h8000000;   // base of ROM space
    deny_addr[13] = 28'h80000C2;   // one halfword below the GPIO window
    deny_addr[14] = 28'h80000CA;   // one halfword above it
    deny_addr[15] = 28'h8FFFFFE;
    deny_addr[16] = 28'h9000000;
    deny_addr[17] = 28'hA000000;
    deny_addr[18] = 28'hB000000;
    deny_addr[19] = 28'hCFFFFFE;   // top of the space, one below EEPROM at 0xD
end

initial begin
    repeat (2) @(posedge clk);
    reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(posedge clk);

    // Everything that must be swallowed, at all three access widths so the
    // second beat of a 32-bit write cannot slip through on its own.
    for (i = 0; i < N_DENY; i = i + 1) begin
        deny(deny_addr[i], 2'b00);
        deny(deny_addr[i], 2'b01);
        deny(deny_addr[i], 2'b10);
    end

    // The odd-byte boundaries of the GPIO window. The decode is on
    // latched_addr[23:0], not on the halfword address, so 0xC3 and 0xC9 are
    // outside it even though their halfword addresses are inside.
    deny(28'h80000C3, 2'b01);
    deny(28'h80000C9, 2'b01);

    // And everything that must go through.
    allow(28'hD000000, 2'b01, 32'h00000001, 32'd1);   // EEPROM serial bit
    allow(28'hE000000, 2'b00, 32'h0000005A, 32'd1);   // save space, low quarter
    allow(28'hE00FFFF, 2'b00, 32'h000000A5, 32'd1);
    allow(28'hF000000, 2'b00, 32'h0000003C, 32'd1);   // save space, high quarter
    allow(28'hF00FFFF, 2'b00, 32'h000000C3, 32'd1);
    allow(28'h80000C4, 2'b01, 32'h00001234, 32'd1);   // GPIO window
    allow(28'h80000C6, 2'b01, 32'h00005678, 32'd1);
    allow(28'h80000C8, 2'b01, 32'h00009ABC, 32'd1);
    // A 32-bit write inside the window strobes once per beat.
    allow(28'h80000C4, 2'b10, 32'hAABBCCDD, 32'd2);

    // A read must never strobe WR# either, whatever the space.
    wr_allowed = 1'b0;
    pulse(1'b0, 28'h0000120, 2'b01, 32'd0);
    pulse(1'b0, 28'hE000123, 2'b00, 32'd0);
    pulse(1'b0, 28'h80000C4, 2'b01, 32'd0);

    $display("TB PASS: tb_gba_cart_write_protect");
    $finish;
end

endmodule
