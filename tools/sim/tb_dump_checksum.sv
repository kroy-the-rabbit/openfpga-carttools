// SOURCES: src/fpga/services/dump/dump_checksum.sv
//
// tb_dump_checksum.sv - the sum, and what it does and does not catch
//
// The interesting cases are the faults it has to catch, because it exists in
// response to one it did not: a floating data line that produced a dump the
// core reported as successful. So the corruptions modelled here are the ones
// hardware has actually produced or plausibly will: a single bit stuck across
// the image, a single bit floating, a truncated read, and a bank returned
// twice.
//
// The last case is the honest one. A sum cannot localise an error and two
// compensating faults cancel, so there is a check here that demonstrates the
// limit rather than hiding it.
//
`default_nettype none
`timescale 1ns/1ps

module tb_dump_checksum;

reg clk = 1'b0;
always #5 clk = ~clk;

reg        reset = 1'b1;
reg        start = 1'b0;
reg [7:0]  data = 8'd0;
reg        valid = 1'b0;
wire [15:0] sum, stored;
wire [23:0] count;

dump_checksum dut (
    .clk (clk), .reset (reset), .start (start),
    .data (data), .valid (valid),
    .sum (sum), .stored (stored), .count (count)
);

integer errors = 0;
integer i;

// A modelled 32 KB cartridge whose stored checksum is correct.
localparam integer SZ = 32768;
reg [7:0] rom [0:SZ-1];

task build_rom;
    integer k, g;
begin
    for (k = 0; k < SZ; k = k + 1) rom[k] = (k * 7 + (k >> 5)) & 8'hFF;
    g = 0;
    for (k = 0; k < SZ; k = k + 1)
        if (k != 24'h14E && k != 24'h14F) g = (g + rom[k]) & 16'hFFFF;
    rom[24'h14E] = (g >> 8) & 8'hFF;
    rom[24'h14F] = g & 8'hFF;
end
endtask

// Feed the image through, optionally corrupted. mode 0 clean, 1 bit 7 stuck,
// 2 bit 7 alternating, 3 truncated, 4 second bank repeated.
task feed(input integer mode);
    integer k;
    reg [7:0] b;
    integer lim;
begin
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    lim = (mode == 3) ? SZ - 64 : SZ;
    for (k = 0; k < lim; k = k + 1) begin
        b = rom[k];
        if (mode == 1) b = b | 8'h80;
        if (mode == 2 && ((k & 8) != 0)) b = b ^ 8'h80;
        if (mode == 4 && k >= 16384) b = rom[k - 16384];
        @(negedge clk);
        data  = b;
        valid = 1'b1;
        @(negedge clk);
        valid = 1'b0;
    end
    @(negedge clk);
end
endtask

// Not called expect: that is a SystemVerilog keyword and iverilog parses it
// as a property statement.
task chk(input integer got, input integer want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

initial begin
    build_rom;
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // --- a clean image agrees with itself ---------------------------------
    feed(0);
    chk(count, SZ, "bytes counted");
    if (sum !== stored) begin
        $display("ERROR: clean image sum %04h, stored %04h", sum, stored);
        errors = errors + 1;
    end

    // --- bit 7 stuck high, which is what Super Mario Land 2 did ------------
    // The header checksum cannot see this and neither can reading the header
    // twice. This is the whole reason the module exists.
    feed(1);
    if (sum === stored) begin
        $display("ERROR: bit 7 stuck high was not caught");
        errors = errors + 1;
    end

    // --- bit 7 floating, the same fault as it actually presented -----------
    feed(2);
    if (sum === stored) begin
        $display("ERROR: bit 7 flipping both ways was not caught");
        errors = errors + 1;
    end

    // --- a short read -------------------------------------------------------
    feed(3);
    chk(count, SZ - 64, "bytes counted on a truncated read");
    if (sum === stored) begin
        $display("ERROR: a truncated image was not caught");
        errors = errors + 1;
    end

    // --- a bank read twice, which is the banking fault this can see ---------
    feed(4);
    if (sum === stored) begin
        $display("ERROR: a repeated bank was not caught");
        errors = errors + 1;
    end

    // --- and the limit, stated rather than hidden ---------------------------
    // Two bytes wrong by equal and opposite amounts cancel. A sum cannot see
    // that, and nothing here pretends otherwise: this check passes when the
    // corruption is invisible, which is the point of writing it down.
    rom[16'h2000] = rom[16'h2000] + 8'd1;
    rom[16'h3000] = rom[16'h3000] - 8'd1;
    feed(0);
    if (sum !== stored) begin
        $display("ERROR: compensating errors did not cancel; this test is wrong");
        errors = errors + 1;
    end
    rom[16'h2000] = rom[16'h2000] - 8'd1;
    rom[16'h3000] = rom[16'h3000] + 8'd1;

    // --- start really does clear it -----------------------------------------
    feed(0);
    chk(count, SZ, "bytes counted after a restart");

    if (errors != 0) begin
        $display("tb_dump_checksum: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_dump_checksum");
    $finish;
end

initial begin
    #200000000;
    $display("ERROR: tb_dump_checksum watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
