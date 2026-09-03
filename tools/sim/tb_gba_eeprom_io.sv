// SOURCES: src/fpga/services/dump/gba_eeprom_io.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_eeprom_model.sv
//
// tb_gba_eeprom_io.sv - one EEPROM block, through the real bus and a chip
//
// Runs against gba_cart_bus and cart_pins rather than a stub, for the reason
// tb_cart_save_gba does: what is worth proving lives in the interaction. The
// chip model decides what to drive from the strobes alone, so it agrees with
// this module only if the module is right.
//
// What has to hold:
//
//   The request is 1 1, the address most significant bit first, then 0. The
//   model kills the run on a 1 0 prefix, which is the write command. That is
//   the only bit between backing up a save and destroying one.
//
//   Sixty-eight reads, not sixty-four. The first four are the chip turning
//   round and carry nothing. Taking them as data shifts every byte.
//
//   The block is returned most significant bit first.
//
//   Six-bit addressing works as well as fourteen, because a 512 byte chip and
//   an 8 KiB one are told apart by which one answers.

`default_nettype none
`timescale 1ns/1ps

module tb_gba_eeprom_io;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;

reg        start = 1'b0;
reg [3:0]  addr_bits = 4'd14;
reg [13:0] block = 14'd0;

wire        busy, done;
wire [63:0] data;
wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata, bus_rdata;
wire        bus_done, bus_busy;

integer errors = 0;

task expect_eq64(input [63:0] got, input [63:0] want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %h, expected %h", what, got, want);
        errors = errors + 1;
    end
end
endtask

task expect_eq(input [31:0] got, input [31:0] want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

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

gba_eeprom_io dut (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (start), .addr_bits (addr_bits), .block (block),
    .busy (busy), .done (done), .data (data),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
);

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

gba_eeprom_model #(.ADDR_BITS (14)) chip (
    .cart_mode (cart_mode), .bank0 (bank0), .pin30 (pin30),
    .bank3 (bank3), .bank3_dir (bank3_dir),
    .req_block (req_block), .req_count (req_count),
    .bit_writes (bit_writes), .bit_reads (bit_reads)
);

// The same content function the model uses, written out again rather than
// shared, so a model that computes the wrong thing does not agree with itself.
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

// Every request must land in EEPROM space and be a halfword.
always @(posedge clk) begin
    if (!reset && bus_req) begin
        if (bus_addr[27:24] !== 4'hD) begin
            $display("ERROR: request outside EEPROM space, addr %h", bus_addr);
            errors = errors + 1;
        end
        if (bus_acc !== 2'b01) begin
            $display("ERROR: acc %b is not a 16 bit access", bus_acc);
            errors = errors + 1;
        end
    end
end

task read_block(input [13:0] b, input [3:0] nbits);
begin
    @(negedge clk);
    block     = b;
    addr_bits = nbits;
    start     = 1'b1;
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

    // --- one block, fourteen bit addressing -------------------------------
    read_block(14'd0, 4'd14);
    expect_eq64(data, want_block(14'd0), "block 0");
    expect_eq(req_count, 1, "requests after one block");
    expect_eq(req_block, 0, "the block the chip was asked for");
    // 2 command + 14 address + 1 terminator, then 4 turnaround + 64 data.
    expect_eq(bit_writes, 17, "request bits sent");
    expect_eq(bit_reads, 68, "bits read back");

    // --- a different block, and the address has to reach the chip ---------
    read_block(14'd1, 4'd14);
    expect_eq64(data, want_block(14'd1), "block 1");
    expect_eq(req_block, 1, "block 1 reached the chip");

    read_block(14'd1023, 4'd14);
    expect_eq64(data, want_block(14'd1023), "block 1023, the last of 8 KiB");
    expect_eq(req_block, 1023, "block 1023 reached the chip");

    // A block whose index has bits set high and low, so a shift that drops
    // either end fails.
    read_block(14'd682, 4'd14);
    expect_eq64(data, want_block(14'd682), "block 682");
    expect_eq(req_block, 682, "block 682 reached the chip");

    // --- a short request to a wide chip is ignored, which is the probe ----
    //
    // Nothing in a cartridge says whether its EEPROM is 512 bytes or 8 KiB.
    // The SDK string is EEPROM_V either way, and the emulator that inspired
    // the bit counts here tells them apart by watching the game's DMA length,
    // which a dumper does not have.
    //
    // What is left is that the chip itself knows. A 14 bit chip given a 9 bit
    // request is still waiting for address bits and never answers, so it never
    // reaches its data phase. That asymmetry is the whole of the size probe,
    // and it is asserted here rather than assumed.
    read_block(14'd63, 4'd6);
    expect_eq(bit_writes, 17 + 17 + 17 + 17 + 9, "request bits with 6 bit addressing");
    expect_eq(req_count, 4, "a 9 bit request must not complete on a 14 bit chip");
    expect_eq(req_block, 682, "the chip never accepted the short request");

    // --- cart_mode dropping mid-transfer must not hang --------------------
    @(negedge clk);
    block = 14'd0; addr_bits = 4'd14; start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk);
    cart_mode = 1'b0;
    repeat (4) @(posedge clk);
    if (busy !== 1'b0) begin
        $display("ERROR: a cart_mode drop left the transfer busy");
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("TB FAIL: tb_gba_eeprom_io, %0d error(s)", errors);
        $fatal(1);
    end
    $display("TB PASS: tb_gba_eeprom_io");
    $finish;
end

initial begin
    #4000000;
    $display("TB FAIL: tb_gba_eeprom_io timed out");
    $fatal(1);
end

endmodule

`default_nettype wire
