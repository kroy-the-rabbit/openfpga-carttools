// SOURCES: src/fpga/services/dump/cart_save_gba.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_cart_model.sv
//
// tb_cart_save_gba.sv - reading GBA SRAM, one byte at a time
//
// Runs against the real bus and the real cartridge model rather than a stub,
// because the things worth proving live in that interaction:
//
//   The access width. GBA save RAM is eight bits wide and the bus returns a
//   save read in one beat, so a 16 or 32 bit request would be a category
//   error even though the bus would answer it. The model counts CS2# address
//   phases and save RD# pulses independently of what the module believes it
//   asked for: N bytes must cost N of each.
//
//   The addresses. The model reports the address it latched on CS2#, and the
//   content function makes every byte in the window differ from its
//   neighbours, so a stream that is off by one, reversed, or repeating a
//   single byte cannot pass.
//
//   That nothing is written. cart_save_gba ties bus_wr low, which is easy to
//   claim and cheap to check, so it is checked at the module's port here and
//   at the connector pins in tb_gba_save_write_protect.
//
// Back pressure is the module's own: a consumer that stalls indefinitely,
// including across the boundary where the module goes back to the bus for the
// next byte, must lose no byte and see none twice. Every byte here is such a
// boundary, since each one costs a fresh transaction.
//
// Bus timing is turned down. What is being proven is structural, and 32768
// transactions at the shipped strobe widths would buy nothing but wall clock.
// tb_gba_cart_timing holds the shipped numbers to the cycle.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1ns/1ps

module tb_cart_save_gba;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg clr = 1'b0;

reg         start = 1'b0;
reg  [31:0] size_bytes = 32'd0;

wire        rd_busy, rd_done;
wire [31:0] total_bytes;
wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata, bus_rdata;
wire        bus_done, bus_busy;
wire [7:0]  out_data;
wire        out_valid;

integer errors = 0;

// --- the consumer's back pressure -------------------------------------------
// bp_mode 0 takes every byte the cycle it appears. bp_mode 1 stalls for a
// pseudo-random few cycles after every byte, and every byte is followed by a
// fresh bus transaction, so the stall always straddles one.
reg        bp_mode = 1'b0;
reg [7:0]  stall_ctr = 8'd0;
reg [15:0] lfsr = 16'hBEEF;
wire       out_ready = bp_mode ? (stall_ctr == 8'd0) : 1'b1;

cart_save_gba dut (
    .clk (clk), .reset (reset),
    .start (start), .size_bytes (size_bytes),
    .busy (rd_busy), .done (rd_done), .total_bytes (total_bytes),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
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

// The save chip's contents, as a function of the 16-bit address it latched.
// Nibble-swapping and folding the high byte in makes neighbouring addresses
// differ in most bits, so an off-by-one or a stuck address cannot pass.
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
    .last_save_wr_addr (), .last_save_wr_data (),
    .contention_seen (), .both_cs_seen ()
);

// --- the module may never write, and must ask for bytes ----------------------
// Sampled on the request rather than every cycle: what matters is what the bus
// latches, and a per-cycle check buries a real failure under thousands of
// identical lines.
always @(posedge clk) begin
    if (!reset && bus_req) begin
        if (bus_wr !== 1'b0) begin
            $display("ERROR: bus_wr asserted with a request at %0t", $time);
            errors = errors + 1;
        end
        if (bus_acc !== 2'b00) begin
            $display("ERROR: acc %b is not an 8 bit access", bus_acc);
            errors = errors + 1;
        end
        if (bus_addr[27:24] !== 4'hE) begin
            $display("ERROR: request outside the save window, addr %h", bus_addr);
            errors = errors + 1;
        end
    end
end

// --- the stream --------------------------------------------------------------
integer got = 0;
integer i;

always @(posedge clk) begin
    if (!reset && out_valid && out_ready) begin
        if (out_data !== save_content(got[15:0])) begin
            if (errors < 10)
                $display("ERROR: byte %0d is %h, expected %h",
                         got, out_data, save_content(got[15:0]));
            errors = errors + 1;
        end
        got = got + 1;
    end
    if (bp_mode) begin
        if (stall_ctr != 8'd0) stall_ctr <= stall_ctr - 8'd1;
        else if (out_valid) begin
            lfsr      <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            stall_ctr <= {5'd0, lfsr[2:0]} + 8'd1;
        end
    end
end

// Control is driven on negedge, as in tb_cart_dump_gba. A blocking assignment
// made at a posedge races the DUT's own sampling of it at that same edge, and
// start is one cycle wide, so losing that race means the read never begins.
task run_read(input [31:0] n, input use_bp);
begin
    got        = 0;
    bp_mode    = use_bp;
    size_bytes = n;
    clr        = 1'b1;
    @(negedge clk);
    clr   = 1'b0;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (rd_done == 1'b1);
    @(negedge clk);
    bp_mode   = 1'b0;
    stall_ctr = 8'd0;
end
endtask

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_cart_save_gba.vcd");
        $dumpvars(0, tb_cart_save_gba);
    end

    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);
    cart_mode = 1'b1;
    wait (mode_ready);
    repeat (2) @(posedge clk);

    // The content function has to have teeth: neighbouring bytes must differ,
    // or an off-by-one would pass. Checked rather than assumed, so the test
    // cannot quietly lose its point if that function is ever changed.
    for (i = 0; i < 64; i = i + 1) begin
        if (save_content(i[15:0]) === save_content(i[15:0] + 16'd1)) begin
            $display("ERROR: save_content is flat at %0d, the test has no teeth", i);
            errors = errors + 1;
        end
    end

    // ---- Phase 1: a short read, no back pressure ---------------------------
    run_read(32'd256, 1'b0);
    if (got !== 256) begin
        $display("ERROR: phase 1 emitted %0d bytes, expected 256", got);
        errors = errors + 1;
    end
    if (total_bytes !== 32'd256) begin
        $display("ERROR: total_bytes is %0d, expected 256", total_bytes);
        errors = errors + 1;
    end
    // One byte, one CS2# address phase, one save RD# pulse. A wider access
    // would move the same bytes in fewer transactions and this would fail.
    if (cs2_latch_count !== 32'd256) begin
        $display("ERROR: %0d CS2 latches for 256 bytes, expected 256",
                 cs2_latch_count);
        errors = errors + 1;
    end
    if (save_rd_count !== 32'd256) begin
        $display("ERROR: %0d save reads for 256 bytes, expected 256",
                 save_rd_count);
        errors = errors + 1;
    end
    if (rom_rd_count !== 32'd0 || cs1_latch_count !== 32'd0) begin
        $display("ERROR: touched ROM space during a save read");
        errors = errors + 1;
    end

    // ---- Phase 2: the same read under back pressure -------------------------
    run_read(32'd256, 1'b1);
    if (got !== 256) begin
        $display("ERROR: phase 2 emitted %0d bytes under back pressure, expected 256",
                 got);
        errors = errors + 1;
    end

    // ---- Phase 3: a zero-byte read touches the connector at all -------------
    // The right answer for a cartridge whose save type was refused or not
    // found. It must finish, and it must not put a transaction on a connector
    // that may have nothing in it.
    run_read(32'd0, 1'b0);
    if (got !== 0) begin
        $display("ERROR: a zero-byte read emitted %0d bytes", got);
        errors = errors + 1;
    end
    if (cs2_latch_count !== 32'd0 || save_rd_count !== 32'd0) begin
        $display("ERROR: a zero-byte read put %0d transactions on the bus",
                 cs2_latch_count);
        errors = errors + 1;
    end

    // ---- Phase 4: a whole 32 KiB SRAM --------------------------------------
    run_read(32'd32768, 1'b0);
    if (got !== 32768) begin
        $display("ERROR: phase 4 emitted %0d bytes, expected 32768", got);
        errors = errors + 1;
    end
    if (save_wr_count !== 32'd0 || wr_pulse_count !== 32'd0) begin
        $display("ERROR: %0d writes reached the cartridge", save_wr_count);
        errors = errors + 1;
    end

    if (errors == 0) $display("TB PASS: tb_cart_save_gba");
    else begin
        $display("TB FAIL: tb_cart_save_gba, %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

initial begin
    #40000000;
    $display("ERROR: timeout  got=%0d cs2=%0d save_rd=%0d busy=%b done=%b state=%0d mode_ready=%b bus_busy=%b",
             got, cs2_latch_count, save_rd_count, rd_busy, rd_done,
             dut.state, mode_ready, bus_busy);
    $fatal(1);
end

endmodule

`default_nettype wire
