// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv tools/sim/gba_cart_model.sv
//
// tb_gba_cart_model.sv - the contention detector, and the address spaces the
// inherited testbench never reached.
//
// Two halves.
//
// The first is a negative control for gba_cart_model itself. Every other
// testbench relies on the model reporting a drive-against-drive collision, and
// a detector that never fires proves nothing, so a stub bus is driven into
// each of the three collisions by hand and the flag is checked. The stub's
// model is built with CONTENTION_FATAL(0) so it reports instead of ending the
// run.
//
// The second half is the coverage the old testbench was missing around
// addressing: the 0xF quarter of save space, which decodes identically to 0xE
// and was never touched, and a ROM address with a non-zero A16-A23, whose
// value on bank1 was never asserted at all, only its direction.
//
// Shipped default timing.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gba_cart_model;

reg clk = 1'b0;
always #5 clk = ~clk;

// ==========================================================================
// Half one: does the detector detect?
// ==========================================================================

reg        stub_mode = 1'b0;
reg        stub_clr  = 1'b0;
reg [7:4]  stub_bank0 = 4'hf;
reg        stub_pin30 = 1'b1;
reg        stub_dir1 = 1'b0, stub_dir2 = 1'b0, stub_dir3 = 1'b0;
reg        stub_drive = 1'b0;
tri  [7:0] stub_bank1, stub_bank2, stub_bank3;

// The stub plays the part of gba_cart_bus refusing to let go of the bus.
assign stub_bank1 = stub_drive && stub_dir1 ? 8'h11 : 8'hzz;
assign stub_bank2 = stub_drive && stub_dir2 ? 8'h22 : 8'hzz;
assign stub_bank3 = stub_drive && stub_dir3 ? 8'h33 : 8'hzz;

wire stub_contention, stub_both_cs;

gba_cart_model #(.CONTENTION_FATAL(0)) stub_cart (
    .cart_mode(stub_mode), .clr(stub_clr),
    .bank3(stub_bank3), .bank3_dir(stub_dir3),
    .bank2(stub_bank2), .bank2_dir(stub_dir2),
    .bank1(stub_bank1), .bank1_dir(stub_dir1),
    .bank0(stub_bank0), .pin30(stub_pin30),
    .rom_addr(), .rom_rdata(16'h1234),
    .save_addr(), .save_rdata(8'h5A),
    .cs1_latch_count(), .cs2_latch_count(),
    .rom_rd_count(), .save_rd_count(), .wr_pulse_count(),
    .rom_wr_count(), .save_wr_count(),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(stub_contention), .both_cs_seen(stub_both_cs)
);

task stub_quiet;
begin
    stub_bank0 = 4'hf;
    stub_pin30 = 1'b1;
    stub_dir1 = 1'b0;
    stub_dir2 = 1'b0;
    stub_dir3 = 1'b0;
    stub_drive = 1'b0;
    #20;
    stub_clr = 1'b1;
    #10;
    stub_clr = 1'b0;
    #20;
end
endtask

// ==========================================================================
// Half two: the real module against the real model
// ==========================================================================

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
wire [31:0] cs1_latch_count, cs2_latch_count;
wire [31:0] rom_rd_count, save_rd_count;
wire [31:0] wr_pulse_count, save_wr_count;
wire [23:0] last_cs1_latch_addr;
wire [15:0] last_cs2_latch_addr, last_save_wr_addr;
wire [7:0]  last_save_wr_data;

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
           $time, busy);
end

function [7:0] save_byte(input [15:0] a);
begin
    save_byte = a[7:0] ^ a[15:8] ^ 8'h3C;
end
endfunction

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
    .rom_addr(rom_addr), .rom_rdata(rom_word(rom_addr)),
    .save_addr(save_addr), .save_rdata(save_byte(save_addr)),
    .cs1_latch_count(cs1_latch_count), .cs2_latch_count(cs2_latch_count),
    .rom_rd_count(rom_rd_count), .save_rd_count(save_rd_count),
    .wr_pulse_count(wr_pulse_count),
    .rom_wr_count(), .save_wr_count(save_wr_count),
    .last_cs1_latch_addr(last_cs1_latch_addr),
    .last_cs2_latch_addr(last_cs2_latch_addr),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(last_save_wr_addr),
    .last_save_wr_data(last_save_wr_data),
    .contention_seen(), .both_cs_seen()
);

// Pin-level capture of the address phase, independent of the model, so the
// value on bank1 is asserted and not only its direction.
reg [7:0]  latch_bank1 = 8'h00;
reg [15:0] latch_ad    = 16'h0000;
reg        latch_bank1_dir = 1'b0;
always @(negedge bank0[4]) begin
    #1;
    latch_bank1 = bank1;
    latch_ad = {bank2, bank3};
    latch_bank1_dir = bank1_dir;
end

// Save accesses select with CS2#. CS1# going low during one would be a second
// chip select on a bus that only expects one.
reg cs1_fell_in_save = 1'b0;
reg watch_save = 1'b0;
always @(negedge bank0[4]) begin
    #1;
    if (watch_save) cs1_fell_in_save = 1'b1;
end

// On a save read the data comes back on bank1 while AD keeps carrying the
// address, so releasing AD mid-read would drop the address the cart is using.
always @(posedge clk) begin
    #1;
    if (watch_save && cart_mode && pin30 === 1'b0 && bank0[5] === 1'b0 && !wr) begin
        if (bank2_dir !== 1'b1 || bank3_dir !== 1'b1)
            $fatal(1, "save read released the address on AD during RD# low");
    end
end

task automatic pulse(input is_write, input [27:0] a, input [1:0] size,
                     input [31:0] d);
begin
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    @(posedge clk);
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

// A save access, checked the same way whichever quarter it lands in.
task automatic save_round_trip(input [27:0] a, input [15:0] want_addr,
                               input [7:0] payload);
begin
    watch_save = 1'b1;
    cs1_fell_in_save = 1'b0;

    pulse(1'b0, a, 2'b00, 32'd0);
    if (save_rd_count !== 32'd1 || cs2_latch_count !== 32'd1)
        $fatal(1, "save read at %h took %0d reads over %0d selects", a,
               save_rd_count, cs2_latch_count);
    if (last_cs2_latch_addr !== want_addr)
        $fatal(1, "save read at %h presented address %h, expected %h", a,
               last_cs2_latch_addr, want_addr);
    if (rdata !== {4{save_byte(want_addr)}})
        $fatal(1, "save read at %h returned %h, expected %h replicated", a,
               rdata, save_byte(want_addr));
    if (cs1_latch_count !== 32'd0)
        $fatal(1, "save read at %h asserted CS1# as well as CS2#", a);

    pulse(1'b1, a, 2'b00, {24'd0, payload});
    if (save_wr_count !== 32'd1 || wr_pulse_count !== 32'd1)
        $fatal(1, "save write at %h made %0d WR# pulses, %0d reached save space",
               a, wr_pulse_count, save_wr_count);
    if (last_save_wr_addr !== want_addr)
        $fatal(1, "save write at %h landed at %h, expected %h", a,
               last_save_wr_addr, want_addr);
    if (last_save_wr_data !== payload)
        $fatal(1, "save write at %h delivered %h, expected %h", a,
               last_save_wr_data, payload);
    if (cs1_latch_count !== 32'd0)
        $fatal(1, "save write at %h asserted CS1# as well as CS2#", a);

    if (cs1_fell_in_save)
        $fatal(1, "CS1# fell during a save access at %h", a);
    watch_save = 1'b0;
end
endtask

initial begin
    // --- detector self-test -----------------------------------------------
    stub_mode = 1'b1;
    stub_quiet;
    if (stub_contention !== 1'b0 || stub_both_cs !== 1'b0)
        $fatal(1, "the contention detector fired on an idle bus");

    // A ROM read with the host still driving AD: the cart drives it too.
    stub_bank0[4] = 1'b0;
    #10;
    stub_dir2 = 1'b1;
    stub_dir3 = 1'b1;
    stub_drive = 1'b1;
    stub_bank0[5] = 1'b0;
    #20;
    if (stub_contention !== 1'b1)
        $fatal(1, "the detector missed AD driven by both sides during a ROM read");
    stub_quiet;

    // A save read with the host still driving bank1.
    stub_pin30 = 1'b0;
    #10;
    stub_dir1 = 1'b1;
    stub_drive = 1'b1;
    stub_bank0[5] = 1'b0;
    #20;
    if (stub_contention !== 1'b1)
        $fatal(1, "the detector missed bank1 driven by both sides during a save read");
    stub_quiet;

    // Both chip selects at once, which no cartridge is asked to resolve.
    stub_bank0[4] = 1'b0;
    stub_pin30 = 1'b0;
    #20;
    if (stub_both_cs !== 1'b1)
        $fatal(1, "the detector missed CS1# and CS2# asserted together");
    stub_quiet;
    stub_mode = 1'b0;

    // --- the module against the model -------------------------------------
    repeat (2) @(posedge clk);
    reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(posedge clk);

    // A ROM address with every high bit exercised. 0x1234568 is halfword
    // 0x91A2B4, so A23-A16 is 0x91 and AD carries 0xA2B4. From here on the
    // model is the fatal one: if the module held AD past the RD# edge, the run
    // would stop rather than resolve quietly.
    pulse(1'b0, 28'h1234568, 2'b01, 32'd0);
    if (last_cs1_latch_addr !== 24'h91A2B4)
        $fatal(1, "ROM read latched %h, expected 91A2B4", last_cs1_latch_addr);
    if (latch_bank1 !== 8'h91)
        $fatal(1, "bank1 carried %h at the CS1# edge, expected 91", latch_bank1);
    if (latch_ad !== 16'hA2B4)
        $fatal(1, "AD carried %h at the CS1# edge, expected A2B4", latch_ad);
    if (latch_bank1_dir !== 1'b1)
        $fatal(1, "bank1 was not driven during the address phase");
    if (rdata[15:0] !== rom_word(24'h91A2B4))
        $fatal(1, "ROM read returned %h, expected %h", rdata[15:0],
               rom_word(24'h91A2B4));

    // The top of what the module can address: rom_word_addr is latched_addr
    // [24:1], so 0x1FFFFFE is halfword 0xFFFFFF, all high bits set.
    pulse(1'b0, 28'h1FFFFFE, 2'b01, 32'd0);
    if (last_cs1_latch_addr !== 24'hFFFFFF)
        $fatal(1, "top-of-space read latched %h, expected FFFFFF",
               last_cs1_latch_addr);
    if (latch_bank1 !== 8'hFF)
        $fatal(1, "bank1 carried %h for the top of the space, expected FF",
               latch_bank1);

    // --- save space, both quarters ----------------------------------------
    // 0xE and 0xF decode identically. Only 0xE was ever exercised.
    save_round_trip(28'hE00135A, 16'h135A, 8'h5A);
    save_round_trip(28'hF00ABCD, 16'hABCD, 8'hC3);
    save_round_trip(28'hF000000, 16'h0000, 8'h01);
    save_round_trip(28'hE00FFFF, 16'hFFFF, 8'hFE);

    // A ROM read after a save access has to hand the bus back cleanly.
    pulse(1'b0, 28'h1234568, 2'b01, 32'd0);
    if (rdata[15:0] !== rom_word(24'h91A2B4))
        $fatal(1, "ROM read after save access returned %h", rdata[15:0]);
    if (pin30 !== 1'b1)
        $fatal(1, "CS2# was still asserted during a ROM read");

    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0)
        $fatal(1, "a bank was left driven after the last transaction");

    $display("TB PASS: tb_gba_cart_model");
    $finish;
end

endmodule
