// SOURCES: src/fpga/services/dump/cart_save_gba.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_cart_model.sv
//
// tb_gba_save_write_protect.sv - WR# must never fall during a GBA save read
//
// That one sentence covers every way reading a GBA save can destroy it. A
// save is the only thing in a cartridge that cannot be recovered from
// anywhere else, and unlike a GB save there is no gate to open here: a GBA
// SRAM cartridge answers in its window from the moment it is powered, so the
// bytes are live for the whole read and a single WR# pulse lands on them.
//
// The check is at the connector, on the pins cart_pins drives, so it holds
// against a bus bug and a pin-mux bug alike:
//
//   bank0[7:4] = {PHI, WR_n, RD_n, CS_n}, connector pins 2-5
//
// and it is armed for the whole run rather than around each transaction,
// because a WR# edge at any other moment is exactly as dangerous. The
// cartridge model's own counters are checked as well, since they see the
// pulse the way a real chip would, on the rising edge with CS2# low.
//
// This matters more here than the equivalent does for GB. Writing to a GBA
// cartridge is blocked outright by an open defect: aborting inside
// gba_cart_bus's ST_WRITE raises WR# and releases the data pins on the same
// instant, so the cartridge latches whatever the bus settles to. Until that
// is fixed nothing in this core may write to a GBA cartridge at all, and this
// file is what holds cart_save_gba to it.
//
// ---- This test can fail, and proves it every run ---------------------------
//
// A monitor for a condition that never occurs passes whether or not it works.
// Two monitors in this tree passed with their fix removed before anyone
// checked, so the mutation is built in rather than left as a note: phase 2
// takes the bus away from the reader and drives a deliberate write into the
// save window through it, and the run fails unless the monitor catches that.
// Phase 1 is the real reader and must be clean.
//
// Bus timing is turned down. What is being proven is structural, which
// transactions can pulse WR# at all, and 32768 transactions at the shipped
// strobe widths would buy nothing but wall clock. tb_gba_cart_timing holds the
// shipped numbers to the cycle.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1ns/1ps

module tb_gba_save_write_protect;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg clr = 1'b0;

reg         start = 1'b0;
reg  [31:0] size_bytes = 32'd0;

wire        rd_busy, rd_done;
wire [31:0] total_bytes;

// The reader's bus port.
wire        dut_req, dut_wr;
wire [27:0] dut_addr;
wire [1:0]  dut_acc;
wire [31:0] dut_wdata;

// Phase 2 drives these instead, so the deliberate write goes through the same
// bus, the same pin mux and the same connector as the read did. A write
// injected at the pins would prove the monitor works on a stimulus the real
// path cannot produce, which is not the same claim.
reg         tb_drive = 1'b0;
reg         tb_req   = 1'b0;
reg         tb_wr    = 1'b0;
reg  [27:0] tb_addr  = 28'd0;
reg  [1:0]  tb_acc   = 2'b00;
reg  [31:0] tb_wdata = 32'd0;

wire        bus_req   = tb_drive ? tb_req   : dut_req;
wire        bus_wr    = tb_drive ? tb_wr    : dut_wr;
wire [27:0] bus_addr  = tb_drive ? tb_addr  : dut_addr;
wire [1:0]  bus_acc   = tb_drive ? tb_acc   : dut_acc;
wire [31:0] bus_wdata = tb_drive ? tb_wdata : dut_wdata;

wire [31:0] bus_rdata;
wire        bus_done, bus_busy;
wire [7:0]  out_data;
wire        out_valid;
wire        out_ready = 1'b1;

integer errors = 0;

cart_save_gba dut (
    .clk (clk), .reset (reset),
    .start (start), .size_bytes (size_bytes),
    .busy (rd_busy), .done (rd_done), .total_bytes (total_bytes),
    .bus_req (dut_req), .bus_wr (dut_wr), .bus_addr (dut_addr),
    .bus_acc (dut_acc), .bus_wdata (dut_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy),
    .out_data (out_data), .out_valid (out_valid), .out_ready (out_ready)
);

// --- bus, pins and cartridge -------------------------------------------------

wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

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
wire [15:0] last_save_wr_addr;
wire [7:0]  last_save_wr_data;

gba_cart_bus #(
    .ADDR_HOLD_CYCLES  (1),
    .ADDR_LATCH_CYCLES (1),
    .READ_TURNAROUND_CYCLES(1),
    .READ_SETUP_CYCLES (2),
    .WRITE_SETUP_CYCLES(1),
    .WRITE_HOLD_CYCLES (1)
) bus (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .req (bus_req), .wr (bus_wr), .addr (bus_addr), .acc (bus_acc),
    .wdata (bus_wdata), .rdata (bus_rdata),
    .done (bus_done), .busy (bus_busy),
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_ad_in (e_ad_in), .e_hi_in (e_hi_in)
);

cart_pins pins (
    .clk (clk), .reset (reset), .mode (cart_mode ? 2'b01 : 2'b00),
    .mode_ready (mode_ready),
    .gba_ad_out (e_ad_out), .gba_ad_oe (e_ad_oe),
    .gba_hi_out (e_hi_out), .gba_hi_oe (e_hi_oe),
    .gba_ctl_out (e_ctl_out),
    .gba_p30_out (e_p30_out), .gba_p30_oe (e_p30_oe),
    .gba_ad_in (e_ad_in), .gba_hi_in (e_hi_in),
    .cart_tran_bank2 (bank2), .cart_tran_bank2_dir (bank2_dir),
    .cart_tran_bank3 (bank3), .cart_tran_bank3_dir (bank3_dir),
    .cart_tran_bank1 (bank1), .cart_tran_bank1_dir (bank1_dir),
    .cart_tran_bank0 (bank0), .cart_tran_bank0_dir (bank0_dir),
    .cart_tran_pin30 (pin30), .cart_tran_pin30_dir (pin30_dir),
    .cart_pin30_pwroff_reset (pin30_pwroff),
    .cart_tran_pin31 (pin31), .cart_tran_pin31_dir (pin31_dir)
);

function [7:0] save_content(input [15:0] a);
begin
    save_content = ({a[3:0], a[7:4]} ^ a[15:8]) ^ 8'h5A;
end
endfunction

gba_cart_model cart (
    .cart_mode (cart_mode), .clr (clr),
    .bank3 (bank3), .bank3_dir (bank3_dir),
    .bank2 (bank2), .bank2_dir (bank2_dir),
    .bank1 (bank1), .bank1_dir (bank1_dir),
    .bank0 (bank0), .pin30 (pin30),
    .rom_addr (rom_addr), .rom_rdata (16'h0000),
    .save_addr (save_addr), .save_rdata (save_content(save_addr)),
    .cs1_latch_count (cs1_latch_count), .cs2_latch_count (cs2_latch_count),
    .rom_rd_count (rom_rd_count), .save_rd_count (save_rd_count),
    .wr_pulse_count (wr_pulse_count),
    .rom_wr_count (rom_wr_count), .save_wr_count (save_wr_count),
    .last_cs1_latch_addr (),
    .last_cs2_latch_addr (),
    .last_rom_wr_addr (), .last_rom_wr_data (),
    .last_save_wr_addr (last_save_wr_addr),
    .last_save_wr_data (last_save_wr_data),
    .contention_seen (), .both_cs_seen ()
);

// --- the monitor -------------------------------------------------------------
// WR# at the connector, every falling edge, armed the whole run. `armed` is
// what phase 2 lowers, and lowering it is the only way a WR# edge is allowed
// to pass without an error.
wire cart_wr_n = bank0[6];
reg  armed     = 1'b1;
integer wr_falls_seen = 0;

always @(negedge cart_wr_n) begin
    if (!reset && cart_mode) begin
        wr_falls_seen = wr_falls_seen + 1;
        if (armed) begin
            $display("ERROR: WR# fell at the connector at %0t, addr %h",
                     $time, bus_addr);
            errors = errors + 1;
        end
    end
end

// The module's own port, checked as well. The bus refusing to pulse WR# would
// otherwise hide a bus_wr that should never have been asserted at all.
always @(posedge clk) begin
    if (!reset && !tb_drive && dut_req && dut_wr !== 1'b0) begin
        $display("ERROR: the reader asserted bus_wr at %0t", $time);
        errors = errors + 1;
    end
end

// --- phase 1 -----------------------------------------------------------------
integer got = 0;
always @(posedge clk) begin
    if (!reset && out_valid && out_ready) got = got + 1;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_gba_save_write_protect.vcd");
        $dumpvars(0, tb_gba_save_write_protect);
    end

    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);
    cart_mode = 1'b1;
    wait (mode_ready);
    repeat (2) @(posedge clk);

    // ---- Phase 1: the real reader, over a whole 32 KiB SRAM ----------------
    size_bytes = 32'd32768;
    clr   = 1'b1;
    @(negedge clk);
    clr   = 1'b0;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (rd_done == 1'b1);
    @(negedge clk);

    if (got !== 32768) begin
        $display("ERROR: phase 1 emitted %0d bytes, expected 32768", got);
        errors = errors + 1;
    end
    if (save_rd_count !== 32'd32768) begin
        $display("ERROR: %0d save reads, expected 32768", save_rd_count);
        errors = errors + 1;
    end
    if (wr_pulse_count !== 32'd0) begin
        $display("ERROR: %0d WR# pulses reached the cartridge during a read",
                 wr_pulse_count);
        errors = errors + 1;
    end
    if (save_wr_count !== 32'd0) begin
        $display("ERROR: %0d writes landed in the save window", save_wr_count);
        errors = errors + 1;
    end
    if (wr_falls_seen !== 0) begin
        $display("ERROR: %0d WR# falling edges during phase 1", wr_falls_seen);
        errors = errors + 1;
    end

    // ---- Phase 2: prove the monitor can fail --------------------------------
    // The reader is idle and the bus is driven straight from here. This is the
    // write cart_save_gba must never make, made deliberately, so a monitor
    // that has quietly stopped working takes the run down with it.
    armed    = 1'b0;
    tb_drive = 1'b1;
    @(negedge clk);
    tb_addr  = 28'hE00_0100;
    tb_acc   = 2'b00;
    tb_wdata = 32'h0000_00A5;
    tb_wr    = 1'b1;
    wait (bus_busy == 1'b0);
    @(negedge clk);
    tb_req = 1'b1;
    @(negedge clk);
    tb_req = 1'b0;
    wait (bus_done == 1'b1);
    @(negedge clk);
    tb_wr = 1'b0;
    repeat (8) @(negedge clk);

    if (wr_falls_seen === 0) begin
        $display("ERROR: the deliberate write produced no WR# edge, so the monitor in phase 1 proved nothing");
        errors = errors + 1;
    end
    if (save_wr_count === 32'd0) begin
        $display("ERROR: the model did not record the deliberate save write");
        errors = errors + 1;
    end else if (last_save_wr_addr !== 16'h0100 || last_save_wr_data !== 8'hA5) begin
        $display("ERROR: the deliberate write landed as addr %h data %h, expected 0100 A5",
                 last_save_wr_addr, last_save_wr_data);
        errors = errors + 1;
    end

    if (errors == 0) $display("TB PASS: tb_gba_save_write_protect");
    else begin
        $display("TB FAIL: tb_gba_save_write_protect, %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

initial begin
    #40000000;
    $display("ERROR: timeout  got=%0d wr_falls=%0d save_rd=%0d",
             got, wr_falls_seen, save_rd_count);
    $fatal(1);
end

endmodule

`default_nettype wire
