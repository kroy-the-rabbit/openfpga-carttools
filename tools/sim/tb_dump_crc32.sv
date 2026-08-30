// SOURCES: src/fpga/services/dump/dump_crc32.sv
//
// tb_dump_crc32.sv - pinned to Python, because agreeing with Python is the
//                    entire purpose of the module
//
// A CRC32 that is self-consistent but not zlib's is worthless here. The user
// verifies dumps with zlib.crc32 and No-Intro publishes the same variant, so
// every expected value below was produced by
//
//     python3 -c "import zlib; print(hex(zlib.crc32(...)))"
//
// and each one is annotated with the exact input it came from. Nothing here is
// derived from the RTL, so a wrong polynomial, a missing final inversion, a
// non-reflected shift direction or an initialiser of zero all fail rather than
// quietly agreeing with themselves.
//
// The last check is the honest one, in the habit of tb_dump_checksum: it feeds
// two different images that share a CRC32 and asserts that the module cannot
// tell them apart. A CRC is 32 bits wide; it is a strong accident detector and
// no kind of proof, and the check that demonstrates that is written down here
// rather than left out.
//
`default_nettype none
`timescale 1ns/1ps

module tb_dump_crc32;

reg clk = 1'b0;
always #5 clk = ~clk;

reg        reset = 1'b1;
reg        start = 1'b0;
reg [7:0]  data  = 8'd0;
reg        valid = 1'b0;
wire [31:0] crc;
wire [31:0] count;

dump_crc32 dut (
    .clk (clk), .reset (reset), .start (start),
    .data (data), .valid (valid),
    .crc (crc), .count (count)
);

integer errors = 0;

// Small staging buffer for the literal test vectors.
reg [7:0] img [0:63];

// Not called expect: that is a SystemVerilog keyword and iverilog parses it as
// a property statement.
// 512 bits, not dump_checksum's 256: a label longer than 32 characters is
// silently truncated from the left, which turns a failure message into a
// puzzle exactly when it is needed.
task chk32(input [31:0] got, input [31:0] want, input [511:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %08h, expected %08h", what, got, want);
        errors = errors + 1;
    end
end
endtask

task chk(input integer got, input integer want, input [511:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

task do_start;
begin
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    @(negedge clk);
end
endtask

// Unpack an ASCII literal into img. Verilog right-justifies a string in a wide
// reg, so byte 0 of the message is the high byte of the used part.
task load_str(input [255:0] s, input integer n);
    integer k;
begin
    for (k = 0; k < n; k = k + 1) img[k] = s[(n - 1 - k) * 8 +: 8];
end
endtask

// Bytes back to back, valid held high, which is how the reader will present
// them when the buffer is draining.
task feed_img(input integer n);
    integer k;
begin
    for (k = 0; k < n; k = k + 1) begin
        @(negedge clk);
        data  = img[k];
        valid = 1'b1;
    end
    @(negedge clk);
    valid = 1'b0;
    data  = 8'h5A;              // garbage, to prove it is not being consumed
    @(negedge clk);
end
endtask

// The same, with valid low on two cycles out of three and rubbish on data in
// between. A byte must be taken only when valid says so.
task feed_img_gapped(input integer n);
    integer k;
begin
    for (k = 0; k < n; k = k + 1) begin
        @(negedge clk);
        data  = img[k];
        valid = 1'b1;
        @(negedge clk);
        data  = ~img[k];
        valid = 1'b0;
        @(negedge clk);
        data  = 8'hA5;
    end
    @(negedge clk);
end
endtask

task feed_run(input integer n, input [7:0] b);
    integer k;
begin
    for (k = 0; k < n; k = k + 1) begin
        @(negedge clk);
        data  = b;
        valid = 1'b1;
    end
    @(negedge clk);
    valid = 1'b0;
    data  = 8'h5A;
    @(negedge clk);
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // --- empty input --------------------------------------------------------
    // python3 -c "import zlib; print(hex(zlib.crc32(b'')))" -> 0x0
    // This is not a special case in the module: the register sits at
    // 0xFFFFFFFF and crc is its inverse, so zero falls out of reset.
    do_start;
    chk32(crc, 32'h00000000, "crc of an empty image");
    chk(count, 0, "count of an empty image");

    // --- one zero byte ------------------------------------------------------
    // python3 -c "import zlib; print(hex(zlib.crc32(b'\x00')))" -> 0xd202ef8d
    // Worth its own vector: an implementation that skips bytes which happen to
    // be zero, or that only mixes in non-zero data, still passes the empty
    // case and fails here.
    do_start;
    img[0] = 8'h00;
    feed_img(1);
    chk32(crc, 32'hD202EF8D, "crc of a single 0x00");
    chk(count, 1, "count after a single byte");

    // --- the standard check value -------------------------------------------
    // python3 -c "import zlib; print(hex(zlib.crc32(b'123456789')))"
    //     -> 0xcbf43926
    // Every CRC32 variant publishes its check value over these nine bytes, and
    // this one is what identifies the module as IEEE 802.3 / zlib rather than
    // CRC-32C, CRC-32/BZIP2, JAMCRC or any of the other near misses.
    do_start;
    load_str("123456789", 9);
    feed_img(9);
    chk32(crc, 32'hCBF43926, "crc of 123456789");
    chk(count, 9, "count of 123456789");

    // --- the value is live, not only valid at the end -----------------------
    // The UI is meant to display a running CRC while the dump proceeds, so the
    // output has to be correct after every byte and not just after some
    // end-of-image pulse. Stream the same message in two halves and read the
    // output in the middle without restarting.
    // python3 -c "import zlib; print(hex(zlib.crc32(b'1234')))" -> 0x9be3e0a3
    do_start;
    load_str("1234", 4);
    feed_img(4);
    chk32(crc, 32'h9BE3E0A3, "crc part way through, after 1234");
    load_str("56789", 5);
    feed_img(5);
    chk32(crc, 32'hCBF43926, "crc after the second half arrives");
    chk(count, 9, "count across two bursts");

    // --- valid actually gates -----------------------------------------------
    // Same nine bytes, but with data inverted and then set to 0xA5 on the
    // cycles where valid is low. If any of that leaks in the answer changes.
    do_start;
    load_str("123456789", 9);
    feed_img_gapped(9);
    chk32(crc, 32'hCBF43926, "crc of 123456789 fed with gaps");
    chk(count, 9, "count of 123456789 fed with gaps");

    // --- a long run of one byte ---------------------------------------------
    // python3 -c "import zlib; print(hex(zlib.crc32(b'\xff'*1048576)))"
    //     -> 0x956bac74
    // 1 MiB of 0xFF is not an arbitrary vector. It is what a GB read returns
    // with no cartridge in the slot, and roughly what a GBA read returns past
    // the end of ROM, so this is the CRC of "nothing was there" at a common
    // image size. It also exercises the counter well past 16 bits, which is
    // where an accumulator that silently wrapped would show up.
    do_start;
    feed_run(1048576, 8'hFF);
    chk32(crc, 32'h956BAC74, "crc of 1 MiB of 0xFF");
    chk(count, 1048576, "count after 1 MiB");

    // python3 -c "import zlib; print(hex(zlib.crc32(b'\x00'*4096)))"
    //     -> 0xc71c0011
    do_start;
    feed_run(4096, 8'h00);
    chk32(crc, 32'hC71C0011, "crc of 4096 zero bytes");

    // --- length matters, which a plain sum would not see --------------------
    // python3 -c "import zlib; print(hex(zlib.crc32(b'\xff'*4096)))"
    //     -> 0xf154670a
    // Different from the 1 MiB run above purely by length. A truncated dump of
    // the same bytes therefore cannot report the same CRC.
    do_start;
    feed_run(4096, 8'hFF);
    chk32(crc, 32'hF154670A, "crc of 4096 0xFF bytes");

    // --- start genuinely clears ---------------------------------------------
    // Feed a different image first, then start, then the check message. If
    // start left any state behind the answer would not be the check value.
    do_start;
    load_str("garbage!", 8);
    feed_img(8);
    do_start;
    load_str("123456789", 9);
    feed_img(9);
    chk32(crc, 32'hCBF43926, "crc of 123456789 after a previous image");
    chk(count, 9, "count of 123456789 after a previous image");

    // And the negative half of that claim: without the start, the same two
    // images concatenated must NOT read as the check value. Otherwise the
    // check above would pass for a module that ignores its input entirely.
    do_start;
    load_str("garbage!", 8);
    feed_img(8);
    load_str("123456789", 9);
    feed_img(9);
    if (crc === 32'hCBF43926) begin
        $display("ERROR: a continued stream matched the check value; start is doing nothing");
        errors = errors + 1;
    end
    chk(count, 17, "count of a continued stream");

    // --- reset clears mid-stream --------------------------------------------
    do_start;
    load_str("123456789", 9);
    feed_img(4);
    @(negedge clk);
    reset = 1'b1;
    @(negedge clk);
    reset = 1'b0;
    @(negedge clk);
    chk32(crc, 32'h00000000, "crc after reset part way through");
    chk(count, 0, "count after reset part way through");

    // --- the limit, stated rather than hidden -------------------------------
    // A CRC32 gives an image an identity. It does not give it a proof. The two
    // eight-byte images below are different and share a CRC32, and this check
    // passes when the module reports them as identical - which is the point of
    // writing it down.
    //
    // They were not found by luck. CRC32 over messages of a fixed length is an
    // affine map, so the differences a CRC cannot see form a subspace, and for
    // anything longer than four bytes that subspace is non-trivial. The
    // difference used here is de ad be ef 46 7c d8 5d, solved for over GF(2)
    // and confirmed with Python:
    //   zlib.crc32(bytes.fromhex('1122334455667788')) -> 0x9118e1c2
    //   zlib.crc32(bytes.fromhex('cf8f8dab131aafd5')) -> 0x9118e1c2
    //
    // In practice this matters twice. A random corruption escapes with
    // probability about one in four billion, which is acceptable for the job.
    // A CRC is also trivially forgeable, so it authenticates nothing - but
    // nothing here is trying to authenticate anything, only to name an image.
    //
    // The larger limitation is not testable in RTL and is recorded instead:
    // this CRC is taken from the bytes leaving the reader, not read back from
    // the card. A fault between here and the SD write would still be reported
    // as a matching CRC.
    do_start;
    img[0] = 8'h11; img[1] = 8'h22; img[2] = 8'h33; img[3] = 8'h44;
    img[4] = 8'h55; img[5] = 8'h66; img[6] = 8'h77; img[7] = 8'h88;
    feed_img(8);
    chk32(crc, 32'h9118E1C2, "crc of the first image of the colliding pair");

    do_start;
    img[0] = 8'hCF; img[1] = 8'h8F; img[2] = 8'h8D; img[3] = 8'hAB;
    img[4] = 8'h13; img[5] = 8'h1A; img[6] = 8'hAF; img[7] = 8'hD5;
    feed_img(8);
    chk32(crc, 32'h9118E1C2, "crc of the second image of the colliding pair");

    if (errors != 0) begin
        $display("tb_dump_crc32: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_dump_crc32");
    $finish;
end

initial begin
    #200000000;
    $display("ERROR: tb_dump_crc32 watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
