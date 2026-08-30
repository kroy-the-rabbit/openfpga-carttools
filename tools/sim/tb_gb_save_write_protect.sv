// SOURCES: src/fpga/services/dump/cart_save_gb.sv src/fpga/core/gb_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gb_cart_model.sv
//
// tb_gb_save_write_protect.sv - /WR must never fall while /CS is low
//
// That one sentence covers every way reading a save can destroy it. A save is
// the only thing in a cartridge that cannot be recovered from anywhere else,
// and reading it means putting the cartridge into the one state where a stray
// write would land: RAM enabled, /CS asserted for 0xA000-0xBFFF.
//
// The check is at the connector, on the pins cart_pins drives, so it holds
// against a bus bug and a pin-mux bug alike:
//
//   bank0[7:4] = {PHI, WR_n, RD_n, CS_n}, connector pins 2-5
//
// and it is armed for the whole run rather than around each transaction,
// because a /WR edge at any other moment is exactly as dangerous.
//
// ---- This test can fail, and proves it every run ---------------------------
//
// A monitor for a condition that never occurs passes whether or not it works.
// Two monitors in this tree passed with their fix removed before anyone
// checked, so the mutation is built in rather than left as a note: phase 2
// drives a deliberate write into the RAM window through the same bus, and the
// run fails unless the monitor catches it. Phase 1 is the real reader and must
// be clean.
//
// Bus timing is shortened here. What is being proven is structural - which
// addresses assert /CS, and which transactions set /WR - and 8448 transactions
// at the shipped 800 ns would buy nothing but wall clock. tb_gb_cart_bus holds
// the shipped strobe widths to the cycle.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gb_save_write_protect;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg gb_mode = 1'b0;

integer errors = 0;

// Watchdog. A testbench that stops making progress has to fail with a message
// naming itself, not stall until run_all.py's own timeout.
initial begin
    #40_000_000;
    $fatal(1, "%m: watchdog expired at %0t, state never reached the end", $time);
end

// ---- The reader, and a way to drive the bus without it ---------------------

reg        start = 1'b0;
reg        abort = 1'b0;
reg [7:0]  cart_type = 8'h03;      // MBC1 + RAM + battery
reg [7:0]  ram_size_code = 8'h02;  // 8 KB, one bank

wire        supported, busy, done;
wire [31:0] total_bytes;
wire        responded, blank_ff, blank_00;

wire        rd_req, rd_wr;
wire [15:0] rd_addr;
wire [7:0]  rd_wdata;
wire [7:0]  out_data;
wire        out_valid;

// Phase 2 takes the bus away from the reader to prove the monitor is live.
reg        tb_drive = 1'b0;
reg        tb_req = 1'b0;
reg        tb_wr = 1'b0;
reg [15:0] tb_addr = 16'd0;
reg [7:0]  tb_wdata = 8'd0;

wire       bus_req   = tb_drive ? tb_req   : rd_req;
wire       bus_wr    = tb_drive ? tb_wr    : rd_wr;
wire [15:0] bus_addr = tb_drive ? tb_addr  : rd_addr;
wire [7:0] bus_wdata = tb_drive ? tb_wdata : rd_wdata;

wire [7:0] bus_rdata;
wire       bus_done;

cart_save_gb dut (
    .clk (clk), .reset (reset),
    .start (start), .abort (abort),
    .cart_type (cart_type), .ram_size_code (ram_size_code),
    .supported (supported),
    .busy (busy), .done (done), .total_bytes (total_bytes),
    .responded (responded), .blank_ff (blank_ff), .blank_00 (blank_00),
    .bus_req (rd_req), .bus_wr (rd_wr), .bus_addr (rd_addr),
    .bus_wdata (rd_wdata), .bus_rdata (bus_rdata), .bus_done (bus_done),
    .out_data (out_data), .out_valid (out_valid), .out_ready (1'b1)
);

wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

gb_cart_bus #(
    .ADDR_SETUP_CYCLES (2),
    .STROBE_CYCLES     (4),
    .HOLD_CYCLES       (2),
    .PHI_HALF_CYCLES   (6)
) bus (
    .clk (clk), .reset (reset), .gb_mode (gb_mode),
    .req (bus_req), .wr (bus_wr), .addr (bus_addr), .wdata (bus_wdata),
    .rdata (bus_rdata), .done (bus_done), .busy (),
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_ad_in (e_ad_in), .e_hi_in (e_hi_in)
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
    .clk (clk), .reset (reset), .mode (gb_mode ? 2'b10 : 2'b00),
    .mode_ready (mode_ready),
    .gba_ad_out (16'd0), .gba_ad_oe (1'b0),
    .gba_hi_out (8'd0), .gba_hi_oe (1'b0),
    .gba_ctl_out (4'hF),
    .gba_p30_out (1'b0), .gba_p30_oe (1'b0),
    .gba_ad_in (), .gba_hi_in (),
    .gb_ad_out (e_ad_out), .gb_ad_oe (e_ad_oe),
    .gb_hi_out (e_hi_out), .gb_hi_oe (e_hi_oe),
    .gb_ctl_out (e_ctl_out),
    .gb_p30_out (e_p30_out), .gb_p30_oe (e_p30_oe),
    .gb_ad_in (e_ad_in), .gb_hi_in (e_hi_in),
    .cart_tran_bank2 (bank2), .cart_tran_bank2_dir (bank2_dir),
    .cart_tran_bank3 (bank3), .cart_tran_bank3_dir (bank3_dir),
    .cart_tran_bank1 (bank1), .cart_tran_bank1_dir (bank1_dir),
    .cart_tran_bank0 (bank0), .cart_tran_bank0_dir (bank0_dir),
    .cart_tran_pin30 (pin30), .cart_tran_pin30_dir (pin30_dir),
    .cart_pin30_pwroff_reset (pin30_pwroff),
    .cart_tran_pin31 (pin31), .cart_tran_pin31_dir (pin31_dir)
);

// The model sees the same engine interface the pins are driven from. It is
// here for the RAM gate: without it a reader that never enabled the RAM would
// still read plausible bytes, and this whole operation would be untested.
wire        contention_seen;
wire [15:0] last_write_addr;
wire [7:0]  last_write_data;
wire        ram_enabled;
wire [31:0] ram_write_count;
wire        read_while_disabled;

gb_cart_model #(.CONTENTION_FATAL(1)) cart (
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_hi_in (e_hi_in),
    .contention_seen (contention_seen),
    .last_write_addr (last_write_addr),
    .last_write_data (last_write_data),
    .rom_read_count (), .cs_during_rom_read (),
    .ram_enabled (ram_enabled),
    .ram_write_count (ram_write_count),
    .read_while_disabled (read_while_disabled)
);

// ---- The monitor -----------------------------------------------------------
//
// Sampled on every clock edge rather than on a /WR edge, so a strobe that is
// low across an edge is caught however it got there. The strobes are at least
// four clocks wide, so nothing can slip between two samples.

wire wr_n_pin = bank0[6];
wire cs_n_pin = bank0[4];

integer violations = 0;
reg [15:0] violation_addr = 16'd0;

always @(posedge clk) begin
    if (!reset && !wr_n_pin && !cs_n_pin) begin
        violations = violations + 1;
        violation_addr = e_ad_out;
    end
end

// ---- Checks ----------------------------------------------------------------

task expect_int(input integer got, input integer want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

task expect_bit(input got, input want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %b, expected %b", what, got, want);
        errors = errors + 1;
    end
end
endtask

task xfer(input is_write, input [15:0] a, input [7:0] d);
begin
    @(posedge clk);
    tb_req   <= 1'b1;
    tb_wr    <= is_write;
    tb_addr  <= a;
    tb_wdata <= d;
    @(posedge clk);
    tb_req <= 1'b0;
    wait (bus_done == 1'b1);
    @(posedge clk);
end
endtask

integer i;

initial begin
    for (i = 0; i < 8192; i = i + 1) cart.ram[i] = i[7:0] ^ 8'h5A;

    repeat (4) @(posedge clk);
    reset = 1'b0;
    gb_mode = 1'b1;
    wait (mode_ready == 1'b1);
    repeat (4) @(posedge clk);

    // ---- Phase 1: a real save read, start to finish ------------------------
    expect_bit(supported, 1'b1, "MBC1 with 8 KB is supported");
    expect_int(total_bytes, 8192, "total_bytes");

    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    wait (done == 1'b1);
    @(posedge clk);

    // The invariant.
    if (violations != 0) begin
        $display("ERROR: /WR fell %0d times with /CS low, last at %04h",
                 violations, violation_addr);
        errors = errors + 1;
    end

    // The other half of the same promise: not one byte went into the window,
    // whatever the strobes did.
    expect_int(ram_write_count, 0, "writes into 0xA000-0xBFFF");

    // The gate is shut again. An abort or an exit that left it open would send
    // the cartridge back out of the slot with its RAM writable.
    expect_bit(ram_enabled, 1'b0, "RAM still enabled after the read");

    // And the presence probe really did read with the gate shut, which is what
    // makes "the RAM answered" a measurement rather than an assumption.
    expect_bit(read_while_disabled, 1'b1, "the disabled pass happened");
    expect_bit(responded, 1'b1, "the RAM answered");

    // ---- Phase 2: prove the monitor can fail -------------------------------
    //
    // The same bus, driven directly, doing the one thing the reader must never
    // do. gb_cart_bus permits it - /CS comes from the address and /WR from the
    // request - which is precisely why the reader's restraint is the thing
    // being tested and why it has to be checked rather than assumed.
    tb_drive = 1'b1;
    xfer(1'b1, 16'h0000, 8'h0A);      // open the gate, as a real write would
    violations = 0;
    xfer(1'b1, 16'hA000, 8'hFF);      // and the write that must be caught

    if (violations == 0) begin
        $display("ERROR: a write into the RAM window did not trip the monitor;");
        $display("       every clean result above this line is worthless");
        errors = errors + 1;
    end
    if (ram_write_count == 0) begin
        $display("ERROR: the model did not record the deliberate RAM write");
        errors = errors + 1;
    end

    xfer(1'b1, 16'h0000, 8'h00);      // leave it shut

    if (errors == 0) $display("TB PASS: tb_gb_save_write_protect");
    else begin
        $display("tb_gb_save_write_protect: %0d checks failed", errors);
        $fatal(1, "failed");
    end
    $finish;
end

endmodule

`default_nettype wire
