// SOURCES: src/fpga/services/dump/cart_save_gba_eeprom.sv src/fpga/services/dump/gba_eeprom_io.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_eeprom_model.sv
//
// tb_cart_save_gba_eeprom.sv - an EEPROM save as a byte stream
//
// Runs through the real bus and a chip model that decides what to drive from
// the strobes, so the stream can only be right if the block walk, the byte
// order inside a block and the addressing are all right.
//
// The content function makes every block differ from its neighbours and every
// byte differ inside a block, so a stream that repeats a block, drops one,
// reverses the bytes or stops early cannot pass.
//
// Backpressure is applied irregularly, because the dump engine's buffer does
// stall and a reader that only works when the consumer is always ready is a
// reader that works in a testbench.

`default_nettype none
`timescale 1ns/1ps

module tb_cart_save_gba_eeprom;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg start = 1'b0;
reg [31:0] size_bytes = 32'd0;
reg [3:0]  addr_bits = 4'd14;
reg [3:0]  chip_addr_bits = 4'd14;

wire        busy, done;
wire [31:0] total_bytes;
wire        responded, blank_ff, blank_00;
wire [31:0] first_word;
wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata, bus_rdata;
wire        bus_done, bus_busy;
wire [7:0]  out_data;
wire        out_valid;

integer errors = 0;

task expect_eq(input [31:0] got, input [31:0] want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

// Irregular backpressure, so a reader that assumes a consumer is always ready
// fails here rather than on a card.
reg        bp_mode = 1'b0;
reg [7:0]  stall_ctr = 8'd0;
reg [15:0] lfsr = 16'hBEEF;
wire       out_ready = bp_mode ? (stall_ctr == 8'd0) : 1'b1;

always @(posedge clk) begin
    if (bp_mode) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        if (stall_ctr != 8'd0) stall_ctr <= stall_ctr - 8'd1;
        else if (out_valid && lfsr[2:0] == 3'd0) stall_ctr <= {5'd0, lfsr[7:5]};
    end
end

cart_save_gba_eeprom dut (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (start), .size_bytes (size_bytes), .addr_bits (addr_bits),
    .busy (busy), .done (done), .total_bytes (total_bytes),
    .responded (responded), .blank_ff (blank_ff), .blank_00 (blank_00),
    .first_word (first_word),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy),
    .out_data (out_data), .out_valid (out_valid), .out_ready (out_ready)
);

wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

tri  [7:0] bank2, bank3, bank1;
// An undriven AD line reads as ones, which is the open-bus signature the
// probe uses to mean "this chip did not answer". Without it an undriven bus
// is x in simulation and every comparison against all-ones would be false,
// so a chip that said nothing would look like a chip that said something.
pullup pu_ad [7:0] (bank3);
wire       bank2_dir, bank3_dir, bank1_dir;
tri  [7:4] bank0;
wire       bank0_dir;
tri        pin30;
wire       pin30_dir, pin30_pwroff;
tri        pin31;
wire       pin31_dir;

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
    .done (bus_done), .busy (bus_busy), .write_active (),
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


wire [13:0] req_block;
wire [31:0] req_count, bit_writes, bit_reads;

gba_eeprom_model chip (
    .cart_mode (cart_mode), .chip_addr_bits (chip_addr_bits),
    .bank0 (bank0), .pin30 (pin30),
    .bank3 (bank3), .bank3_dir (bank3_dir),
    .req_block (req_block), .req_count (req_count),
    .bit_writes (bit_writes), .bit_reads (bit_reads)
);

// The model's contents, written out again rather than shared.
function [63:0] want_block(input [13:0] b);
    integer k;
    reg [63:0] v;
begin
    v = 64'd0;
    for (k = 0; k < 8; k = k + 1)
        v = {v[55:0], ({b[3:0], b[7:4]} ^ b[13:8] ^ k[7:0]) ^ 8'hC3};
    want_block = v;
end
endfunction

function [7:0] want_byte(input integer off);
    reg [63:0] v;
    integer sh;
begin
    v = want_block(off[16:3]);
    // The chip sends the most significant of the 64 bits first, and that
    // first byte is the LAST byte of the block in the file. Established on a
    // cartridge, not reasoned about: Minish Cap's save signature came off the
    // chip reversed inside every group of eight and reads only this way round.
    sh = 8 * (off % 8);
    want_byte = v >> sh;
end
endfunction

integer got = 0;

always @(posedge clk) begin
    if (!reset && out_valid && out_ready) begin
        if (out_data !== want_byte(got)) begin
            if (errors < 10)
                $display("ERROR: byte %0d is %h, expected %h",
                         got, out_data, want_byte(got));
            errors = errors + 1;
        end
        got = got + 1;
    end
end

task run_read(input [31:0] n, input [3:0] nbits);
begin
    got = 0;
    @(negedge clk);
    size_bytes = n;
    addr_bits  = nbits;
    start      = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk);
end
endtask

initial begin
    repeat (4) @(posedge clk);
    reset = 1'b0;
    cart_mode = 1'b1;
    wait (mode_ready);
    repeat (4) @(posedge clk);

    // --- 8 KiB, the size Minish Cap has ------------------------------------
    chip_addr_bits = 4'd14;
    run_read(32'd8192, 4'd14);
    expect_eq(got, 8192, "bytes emitted for an 8 KiB save");
    expect_eq(total_bytes, 8192, "total_bytes");
    expect_eq(req_count, 1024, "blocks requested for 8 KiB");
    expect_eq(responded, 1, "responded after a complete read");
    expect_eq(blank_ff, 0, "a save with data is not blank FF");
    expect_eq(blank_00, 0, "a save with data is not blank 00");
    expect_eq(first_word, {want_byte(0), want_byte(1), want_byte(2), want_byte(3)},
              "first_word is the first four bytes");

    // --- 512 bytes, six bit addressing -------------------------------------
    chip_addr_bits = 4'd6;
    run_read(32'd512, 4'd6);
    expect_eq(got, 512, "bytes emitted for a 512 byte save");
    expect_eq(req_count, 1024 + 64, "blocks requested for 512 bytes");

    // --- the same 8 KiB read, with the consumer stalling -------------------
    // A byte held across a stall must be the same byte when it is finally
    // taken, and the block walk must not advance underneath it.
    bp_mode = 1'b1;
    chip_addr_bits = 4'd14;
    run_read(32'd8192, 4'd14);
    expect_eq(got, 8192, "bytes emitted under backpressure");
    bp_mode = 1'b0;

    // --- cart_mode dropping mid-read must not hang -------------------------
    @(negedge clk);
    size_bytes = 32'd8192; addr_bits = 4'd14; start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (40) @(posedge clk);
    @(negedge clk);
    cart_mode = 1'b0;
    repeat (8) @(posedge clk);
    if (busy !== 1'b0) begin
        $display("ERROR: a cart_mode drop left the read busy");
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("TB FAIL: tb_cart_save_gba_eeprom, %0d error(s)", errors);
        $fatal(1);
    end
    $display("TB PASS: tb_cart_save_gba_eeprom");
    $finish;
end

initial begin
    #900000000;
    $display("TB FAIL: tb_cart_save_gba_eeprom timed out");
    $fatal(1);
end

endmodule

`default_nettype wire
