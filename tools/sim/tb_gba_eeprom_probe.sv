// SOURCES: src/fpga/services/dump/gba_eeprom_probe.sv src/fpga/services/dump/gba_eeprom_io.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_eeprom_model.sv
//
// tb_gba_eeprom_probe.sv - 512 bytes or 8 KiB, settled by asking the chip
//
// Nothing in a cartridge says which. The SDK string is EEPROM_V for both and
// the header has no save field, so the only source of truth is the chip's own
// refusal to answer a request of the wrong width.
//
// The case that matters most here is the second one. Probing is two attempts,
// and the first leaves a wide chip part way through a command. If the flush
// between them did not work, the 14 bit attempt would be talking to a chip
// that is still counting bits from the 6 bit attempt, and the probe would
// report no EEPROM on a cartridge that has one. That is a silent wrong answer,
// not a visible failure, which is why it is tested rather than reasoned about.

`default_nettype none
`timescale 1ns/1ps

module tb_gba_eeprom_probe;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg start = 1'b0;
reg [3:0] chip_addr_bits = 4'd14;
reg       chip_present = 1'b1;

wire        busy, done, found;
wire [31:0] size_bytes;
wire [3:0]  addr_bits;
wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata, bus_rdata;
wire        bus_done, bus_busy;

integer errors = 0;

task expect_eq(input [31:0] got, input [31:0] want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

gba_eeprom_probe dut (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (start), .abort (1'b0),
    .busy (busy), .done (done),
    .size_bytes (size_bytes), .addr_bits (addr_bits), .found (found),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
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
    .cart_mode (cart_mode && chip_present), .chip_addr_bits (chip_addr_bits),
    .bank0 (bank0), .pin30 (pin30),
    .bank3 (bank3), .bank3_dir (bank3_dir),
    .req_block (req_block), .req_count (req_count),
    .bit_writes (bit_writes), .bit_reads (bit_reads)
);

task run_probe;
begin
    @(negedge clk);
    start = 1'b1;
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

    // --- an 8 KiB chip -----------------------------------------------------
    // The 6 bit attempt goes first and this chip ignores it, so the answer
    // comes from the 14 bit attempt, after a flush has cleared the half
    // command the first attempt left behind.
    chip_addr_bits = 4'd14;
    run_probe;
    expect_eq(found, 1, "found an 8 KiB chip");
    expect_eq(size_bytes, 8192, "8 KiB size");
    expect_eq(addr_bits, 14, "8 KiB address width");

    // --- a 512 byte chip ---------------------------------------------------
    // Answers the first attempt, so the 14 bit attempt never runs.
    chip_addr_bits = 4'd6;
    run_probe;
    expect_eq(found, 1, "found a 512 byte chip");
    expect_eq(size_bytes, 512, "512 byte size");
    expect_eq(addr_bits, 6, "512 byte address width");

    // --- no chip at all ----------------------------------------------------
    // Open bus is all ones, which is also what a blank save reads. Reporting
    // not found is the honest answer to both: refusing beats writing a file
    // of a size nobody established.
    chip_present = 1'b0;
    run_probe;
    expect_eq(found, 0, "no chip is not found");
    expect_eq(size_bytes, 0, "no chip has no size");
    chip_present = 1'b1;

    // --- it recovers, and the order does not poison the next run -----------
    chip_addr_bits = 4'd14;
    run_probe;
    expect_eq(found, 1, "found again after a run with no chip");
    expect_eq(size_bytes, 8192, "8 KiB after a run with no chip");

    // --- cart_mode dropping mid-probe must not hang ------------------------
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk);
    cart_mode = 1'b0;
    repeat (8) @(posedge clk);
    if (busy !== 1'b0) begin
        $display("ERROR: a cart_mode drop left the probe busy");
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("TB FAIL: tb_gba_eeprom_probe, %0d error(s)", errors);
        $fatal(1);
    end
    $display("TB PASS: tb_gba_eeprom_probe");
    $finish;
end

initial begin
    #20000000;
    $display("TB FAIL: tb_gba_eeprom_probe timed out");
    $fatal(1);
end

endmodule

`default_nettype wire
