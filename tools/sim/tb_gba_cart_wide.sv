// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv tools/sim/gba_cart_model.sv
//
// tb_gba_cart_wide.sv - 32-bit accesses and the ROM page boundary.
//
// `need_second_beat` is true for any acc that is neither 2'b00 nor 2'b01, and
// it never fired in the inherited testbench for a write, so the second write
// beat and the address re-presentation between beats have never executed. The
// page-boundary branch has never executed at all: `rom_page_end` needs a
// 32-bit read whose first halfword sits at offset 0xFFFF inside a 128 KB page,
// and the only address the old testbench read was 0x0000120.
//
// Both paths are covered here at the shipped default timing, against the
// cartridge model, which auto-increments its own latched address on the RD#
// rising edge exactly as a real cart does. That is what makes the page test
// meaningful: the cart's counter carries only within the low 16 bits, so if
// the module bursted across the boundary the model would return the halfword
// from the bottom of the page and the data check would fail.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gba_cart_wide;

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
wire [31:0] cs1_latch_count, cs2_latch_count;
wire [31:0] rom_rd_count, save_rd_count;
wire [31:0] wr_pulse_count, rom_wr_count, save_wr_count;
wire [23:0] last_cs1_latch_addr;
wire [15:0] last_cs2_latch_addr;

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
    .save_addr(save_addr), .save_rdata(save_addr[7:0] ^ 8'h6D),
    .cs1_latch_count(cs1_latch_count), .cs2_latch_count(cs2_latch_count),
    .rom_rd_count(rom_rd_count), .save_rd_count(save_rd_count),
    .wr_pulse_count(wr_pulse_count),
    .rom_wr_count(rom_wr_count), .save_wr_count(save_wr_count),
    .last_cs1_latch_addr(last_cs1_latch_addr),
    .last_cs2_latch_addr(last_cs2_latch_addr),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(),
    .contention_seen(), .both_cs_seen()
);

// Per-beat record of what the cart would have latched on each WR# rising
// edge, so a two-beat write can be checked beat by beat rather than only at
// its last beat.
integer    wr_events = 0;
reg [23:0] wr_ev_cs1 [0:3];
reg [15:0] wr_ev_cs2 [0:3];
reg [15:0] wr_ev_ad  [0:3];
reg [7:0]  wr_ev_b1  [0:3];
always @(posedge bank0[6]) begin
    #1;
    if (cart_mode && wr_events < 4) begin
        wr_ev_cs1[wr_events] = rom_addr;
        wr_ev_cs2[wr_events] = save_addr;
        wr_ev_ad[wr_events]  = {bank2, bank3};
        wr_ev_b1[wr_events]  = bank1;
        wr_events = wr_events + 1;
    end
end

// CS1 rising while a transaction is still in flight means the address phase is
// being restarted rather than bursted.
integer cs1_rises = 0;
always @(posedge bank0[4]) begin
    #1;
    if (cart_mode && busy) cs1_rises = cs1_rises + 1;
end

task automatic pulse(input is_write, input [27:0] a, input [1:0] size,
                     input [31:0] d);
begin
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    wr_events = 0;
    cs1_rises = 0;
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

initial begin
    repeat (2) @(posedge clk);
    reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(posedge clk);

    // --- 32-bit ROM read, inside a page -----------------------------------
    // One address phase, two RD# pulses, the cart supplying the second
    // halfword from its own incremented counter.
    pulse(1'b0, 28'h0000120, 2'b10, 32'd0);
    if (rdata !== {rom_word(24'h000091), rom_word(24'h000090)})
        $fatal(1, "32-bit ROM read returned %h, expected %h", rdata,
               {rom_word(24'h000091), rom_word(24'h000090)});
    if (rom_rd_count !== 32'd2)
        $fatal(1, "32-bit ROM read used %0d RD# pulses, expected 2",
               rom_rd_count);
    if (cs1_latch_count !== 32'd1)
        $fatal(1, "32-bit ROM read latched the address %0d times, expected 1",
               cs1_latch_count);
    if (cs1_rises !== 0)
        $fatal(1, "CS1# rose %0d times inside a 32-bit ROM burst", cs1_rises);

    // acc 2'b11 is not a distinct width: anything that is not 8- or 16-bit is
    // the two-beat path.
    pulse(1'b0, 28'h0000120, 2'b11, 32'd0);
    if (rdata !== {rom_word(24'h000091), rom_word(24'h000090)})
        $fatal(1, "acc 2'b11 ROM read returned %h", rdata);
    if (rom_rd_count !== 32'd2)
        $fatal(1, "acc 2'b11 ROM read used %0d RD# pulses", rom_rd_count);

    // --- 32-bit ROM read across a page boundary ---------------------------
    // 0x0F5FFFE is halfword 0x7AFFFF, the last halfword of page 0x7A, and it
    // carries a non-zero A16-A23 (0x7A then 0x7B) which nothing else covers.
    // The cart's counter would wrap to 0x7A0000, so the module has to issue a
    // fresh address phase for 0x7B0000 instead of bursting.
    pulse(1'b0, 28'h0F5FFFE, 2'b10, 32'd0);
    if (rdata !== {rom_word(24'h7B0000), rom_word(24'h7AFFFF)})
        $fatal(1, "page-crossing 32-bit read returned %h, expected %h", rdata,
               {rom_word(24'h7B0000), rom_word(24'h7AFFFF)});
    if (cs1_latch_count !== 32'd2)
        $fatal(1, "page-crossing read latched the address %0d times, expected 2",
               cs1_latch_count);
    if (last_cs1_latch_addr !== 24'h7B0000)
        $fatal(1, "page-crossing read re-latched %h, expected 7B0000",
               last_cs1_latch_addr);
    if (rom_rd_count !== 32'd2)
        $fatal(1, "page-crossing read used %0d RD# pulses, expected 2",
               rom_rd_count);
    if (cs1_rises !== 1)
        $fatal(1, "page-crossing read raised CS1# %0d times, expected 1",
               cs1_rises);

    // The same address as a 16-bit read stays a single beat: rom_page_end only
    // means anything when a second beat is coming.
    pulse(1'b0, 28'h0F5FFFE, 2'b01, 32'd0);
    if (rdata[15:0] !== rom_word(24'h7AFFFF))
        $fatal(1, "16-bit read at the page end returned %h", rdata[15:0]);
    if (cs1_latch_count !== 32'd1 || rom_rd_count !== 32'd1)
        $fatal(1, "16-bit read at the page end took %0d latches and %0d reads",
               cs1_latch_count, rom_rd_count);

    // --- 32-bit write into GPIO space -------------------------------------
    // The only writable space where the address advances between beats, so
    // this is what proves the inter-beat address re-presentation.
    pulse(1'b1, 28'h80000C4, 2'b10, 32'hAABBCCDD);
    if (wr_pulse_count !== 32'd2 || rom_wr_count !== 32'd2)
        $fatal(1, "32-bit GPIO write made %0d WR# pulses, %0d reached the cart",
               wr_pulse_count, rom_wr_count);
    if (cs1_latch_count !== 32'd2)
        $fatal(1, "32-bit GPIO write latched the address %0d times, expected 2",
               cs1_latch_count);
    if (wr_events !== 2)
        $fatal(1, "recorded %0d write beats, expected 2", wr_events);
    if (wr_ev_cs1[0] !== 24'h000062 || wr_ev_ad[0] !== 16'hCCDD)
        $fatal(1, "GPIO write beat 0 was %h to %h, expected CCDD to 000062",
               wr_ev_ad[0], wr_ev_cs1[0]);
    if (wr_ev_cs1[1] !== 24'h000063 || wr_ev_ad[1] !== 16'hAABB)
        $fatal(1, "GPIO write beat 1 was %h to %h, expected AABB to 000063",
               wr_ev_ad[1], wr_ev_cs1[1]);

    // --- 32-bit write into ROM space --------------------------------------
    // Both beats run, both address phases happen, and no WR# pulse escapes.
    pulse(1'b1, 28'h0000200, 2'b10, 32'h11223344);
    if (wr_pulse_count !== 32'd0)
        $fatal(1, "32-bit ROM-space write produced %0d WR# pulses",
               wr_pulse_count);
    if (cs1_latch_count !== 32'd2)
        $fatal(1, "32-bit ROM-space write latched the address %0d times",
               cs1_latch_count);

    // --- 32-bit write into save space -------------------------------------
    // Pinned as it really behaves, which is not what the word "32-bit"
    // suggests. The GBA save bus is one byte wide, and for save space the
    // module holds AD at latched_addr[15:0] and bank1 at latched_wdata[7:0]
    // for both beats, neither of which depends on `beat`. So a 32-bit save
    // write writes the same byte to the same address twice. It is redundant
    // rather than wrong, since a real GBA 32-bit SRAM write also moves only
    // the low byte, but a caller expecting four bytes to land will not get
    // them.
    pulse(1'b1, 28'hE000100, 2'b10, 32'h11223344);
    if (save_wr_count !== 32'd2 || cs2_latch_count !== 32'd2)
        $fatal(1, "32-bit save write made %0d writes over %0d address phases",
               save_wr_count, cs2_latch_count);
    if (wr_ev_cs2[0] !== 16'h0100 || wr_ev_b1[0] !== 8'h44)
        $fatal(1, "save write beat 0 put %h at %h, expected 44 at 0100",
               wr_ev_b1[0], wr_ev_cs2[0]);
    if (wr_ev_cs2[1] !== 16'h0100 || wr_ev_b1[1] !== 8'h44)
        $fatal(1, "save write beat 1 put %h at %h, expected 44 at 0100",
               wr_ev_b1[1], wr_ev_cs2[1]);

    // --- 32-bit read from save space --------------------------------------
    // Also pinned as it really behaves: the save branch of ST_READ_SETUP goes
    // straight to ST_DONE without consulting need_second_beat, so there is one
    // beat and the byte is replicated across all four lanes. That matches how
    // a GBA reads its own 8-bit save bus.
    pulse(1'b0, 28'hE000100, 2'b10, 32'd0);
    if (save_rd_count !== 32'd1 || cs2_latch_count !== 32'd1)
        $fatal(1, "32-bit save read took %0d reads over %0d address phases",
               save_rd_count, cs2_latch_count);
    if (rdata !== {4{8'h00 ^ 8'h6D}})
        $fatal(1, "32-bit save read returned %h, expected the byte replicated",
               rdata);
    if (last_cs2_latch_addr !== 16'h0100)
        $fatal(1, "32-bit save read latched save address %h, expected 0100",
               last_cs2_latch_addr);

    // Nothing above may leave a pin driven.
    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0)
        $fatal(1, "a bank was still driven after the last transaction");

    $display("TB PASS: tb_gba_cart_wide");
    $finish;
end

endmodule
