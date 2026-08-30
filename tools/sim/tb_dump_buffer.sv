// SOURCES: src/fpga/services/dump/dump_buffer.sv
//
// tb_dump_buffer.sv - packing bytes into bridge words, in both orders
//
// The thing being proved is that byte_order actually selects between two
// layouts and that neither of them loses or reorders a byte. That matters
// more than it sounds: byte_order exists because the correct answer is not
// derivable from anything in this tree, so the only guarantee worth having is
// that whichever one hardware turns out to want, this can produce it.
//
// The partial-word flush is checked too. Without it a chunk whose length is
// not a multiple of four writes three fewer bytes than it was asked to, and
// the file ends up short in a way that only shows up on the last chunk.
//
`default_nettype none
`timescale 1ns/1ps

module tb_dump_buffer;

reg wclk = 1'b0;
always #5 wclk = ~wclk;

// Deliberately a different, unrelated period: this RAM is a clock crossing.
reg rclk = 1'b0;
always #6.734 rclk = ~rclk;

reg        wr_rst = 1'b0;
reg        wr_en = 1'b0;
reg [7:0]  wr_data = 8'd0;
reg        wr_flush = 1'b0;
reg        byte_order = 1'b1;
reg [5:0]  rd_addr = 6'd0;
wire [31:0] rd_q;

dump_buffer #(.WORDS (64), .AW (6)) dut (
    .wr_clk (wclk), .wr_rst (wr_rst), .wr_en (wr_en), .wr_data (wr_data),
    .wr_flush (wr_flush), .byte_order (byte_order),
    .rd_clk (rclk), .rd_addr (rd_addr), .rd_q (rd_q)
);

integer errors = 0;

task put(input [7:0] b);
begin
    @(negedge wclk);
    wr_data = b;
    wr_en   = 1'b1;
    @(negedge wclk);
    wr_en   = 1'b0;
end
endtask

task flush;
begin
    @(negedge wclk);
    wr_flush = 1'b1;
    @(negedge wclk);
    wr_flush = 1'b0;
    repeat (2) @(negedge wclk);
end
endtask

task restart;
begin
    @(negedge wclk);
    wr_rst = 1'b1;
    @(negedge wclk);
    wr_rst = 1'b0;
end
endtask

task rd_word(input [5:0] a);
begin
    @(negedge rclk);
    rd_addr = a;
    repeat (3) @(negedge rclk);
end
endtask

task expect_word(input [5:0] a, input [31:0] want, input [255:0] what);
begin
    rd_word(a);
    if (rd_q !== want) begin
        $display("ERROR: %0s word %0d = %08h, expected %08h",
                 what, a, rd_q, want);
        errors = errors + 1;
    end
end
endtask

integer i;
integer b0, b1, b2, b3;

initial begin
    restart;

    // --- byte_order 1: first byte of the chunk in the low byte -------------
    byte_order = 1'b1;
    restart;
    put(8'h00); put(8'h01); put(8'h02); put(8'h03);
    put(8'h04); put(8'h05); put(8'h06); put(8'h07);
    repeat (2) @(negedge wclk);
    expect_word(6'd0, 32'h03020100, "byte_order 1");
    expect_word(6'd1, 32'h07060504, "byte_order 1");

    // --- byte_order 0: first byte of the chunk in the high byte ------------
    byte_order = 1'b0;
    restart;
    put(8'h00); put(8'h01); put(8'h02); put(8'h03);
    put(8'h04); put(8'h05); put(8'h06); put(8'h07);
    repeat (2) @(negedge wclk);
    expect_word(6'd0, 32'h00010203, "byte_order 0");
    expect_word(6'd1, 32'h04050607, "byte_order 0");

    // --- a partial trailing word is committed, zero filled ------------------
    // Two bytes then a flush. Without the flush this word is never written
    // and the file loses its last two bytes.
    byte_order = 1'b1;
    restart;
    put(8'hAA); put(8'hBB);
    flush;
    expect_word(6'd0, 32'h0000BBAA, "partial word, byte_order 1");

    byte_order = 1'b0;
    restart;
    put(8'hAA); put(8'hBB);
    flush;
    expect_word(6'd0, 32'hAABB0000, "partial word, byte_order 0");

    // --- a flush on a word boundary must not write a spurious word ----------
    byte_order = 1'b1;
    restart;
    put(8'h11); put(8'h22); put(8'h33); put(8'h44);
    flush;
    // Word 1 still holds the tail of the byte_order 0 partial test above.
    // If the flush had written an empty word it would be zero.
    expect_word(6'd0, 32'h44332211, "aligned flush leaves word 0 alone");
    rd_word(6'd1);
    if (rd_q === 32'h00000000) begin
        $display("ERROR: an aligned flush wrote an empty word at 1");
        errors = errors + 1;
    end

    // --- a full buffer, every word ------------------------------------------
    byte_order = 1'b1;
    restart;
    for (i = 0; i < 256; i = i + 1) put(i[7:0]);
    repeat (2) @(negedge wclk);
    for (i = 0; i < 64; i = i + 1) begin
        b0 = 4*i; b1 = 4*i + 1; b2 = 4*i + 2; b3 = 4*i + 3;
        expect_word(i[5:0], {b3[7:0], b2[7:0], b1[7:0], b0[7:0]},
                    "full buffer");
    end

    // --- wr_rst really does rewind to word zero ------------------------------
    restart;
    put(8'hDE); put(8'hAD); put(8'hBE); put(8'hEF);
    repeat (2) @(negedge wclk);
    expect_word(6'd0, 32'hEFBEADDE, "after wr_rst, writing resumes at word 0");

    if (errors != 0) begin
        $display("tb_dump_buffer: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_dump_buffer");
    $finish;
end

initial begin
    #5000000;
    $display("ERROR: tb_dump_buffer watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
