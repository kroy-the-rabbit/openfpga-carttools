// SOURCES: src/fpga/services/dump/dump_path_gen.sv
//
// tb_dump_path_gen.sv - the struct that names the file
//
// If this is wrong the dump does not come out mis-named, it does not come out
// at all: 0x0192 answers "malformed path" or "general error" and nothing is
// ever written. So the whole 264-byte struct is checked as bytes, not as an
// idea, including the null terminator, the zero padding after it, and the two
// numeric words that follow the path field.
//
// Titles are checked in the shapes cartridges actually use: space padded,
// zero padded, mixed case, punctuation, the full fifteen characters with no
// padding at all, and the all-padding case a failed read produces.
//
`default_nettype none
`timescale 1ns/1ps

module tb_dump_path_gen;

reg clk = 1'b0;
always #5 clk = ~clk;

reg rclk = 1'b0;
always #6.734 rclk = ~rclk;

reg         reset = 1'b1;
reg         start = 1'b0;
reg         selftest = 1'b0;
reg [119:0] title = 120'd0;
reg [31:0]  total_bytes = 32'd0;
reg         byte_order = 1'b1;
reg  [2:0]  path_style = 3'd0;
reg         field_order = 1'b0;
reg         create_only = 1'b0;
wire        busy, done;

reg  [6:0]  rd_addr = 7'd0;
wire [31:0] rd_q;

reg [1:0] cart_kind = 2'd0;

dump_path_gen dut (
    .clk (clk), .reset (reset), .start (start), .selftest (selftest),
    .path_style (path_style),
    .field_order (field_order),
    .create_only (create_only),
    .title (title), .cart_kind (cart_kind),
    .total_bytes (total_bytes), .byte_order (byte_order),
    .busy (busy), .done (done),
    .rd_clk (rclk), .rd_addr (rd_addr), .rd_q (rd_q)
);

integer errors = 0;

task read_word(input [6:0] a);
begin
    @(negedge rclk);
    rd_addr = a;
    repeat (3) @(negedge rclk);
end
endtask

// One byte of the path field, as the module was told to lay it out.
task read_path_byte(input integer off, output reg [7:0] b);
begin
    read_word(off[8:2]);
    case (off % 4)
        0: b = byte_order ? rd_q[7:0]   : rd_q[31:24];
        1: b = byte_order ? rd_q[15:8]  : rd_q[23:16];
        2: b = byte_order ? rd_q[23:16] : rd_q[15:8];
        default: b = byte_order ? rd_q[31:24] : rd_q[7:0];
    endcase
end
endtask

reg [7:0] got;
integer   k;

task expect_path(input [2047:0] want, input integer wlen, input [255:0] what);
begin
    for (k = 0; k < wlen; k = k + 1) begin
        read_path_byte(k, got);
        if (got !== want[8*(wlen-1-k) +: 8]) begin
            $display("ERROR: %0s byte %0d = %02h '%0s', expected %02h '%0s'",
                     what, k, got, got,
                     want[8*(wlen-1-k) +: 8], want[8*(wlen-1-k) +: 8]);
            errors = errors + 1;
        end
    end
    // The terminator, and that the padding after it really is zero.
    read_path_byte(wlen, got);
    if (got !== 8'h00) begin
        $display("ERROR: %0s is not null terminated at %0d, byte is %02h",
                 what, wlen, got);
        errors = errors + 1;
    end
    read_path_byte(255, got);
    if (got !== 8'h00) begin
        $display("ERROR: %0s leaves byte 255 as %02h, expected 00", what, got);
        errors = errors + 1;
    end
end
endtask

task run(input [119:0] t, input st, input [31:0] size, input bo);
begin
    @(negedge clk);
    title       = t;
    selftest    = st;
    total_bytes = size;
    byte_order  = bo;
    start       = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk);
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // --- an ordinary space padded title -------------------------------------
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    expect_path("/Assets/carttools/common/TESTCART.gb", 36, "space padded");

    // The two words after the path field. They are fields of a byte array,
    // not free standing numbers, so they follow byte_order like the path
    // does. Getting this wrong is what refused every open for three hardware
    // sessions: APF read flags as 03000000, create clear and resize clear,
    // whatever the path said.
    read_word(7'd64);
    if (rd_q !== 32'h00000003) begin
        $display("ERROR: flags at byte_order 1 is %08h, expected 00000003",
                 rd_q);
        errors = errors + 1;
    end
    read_word(7'd65);
    if (rd_q !== 32'h00008000) begin
        $display("ERROR: size at byte_order 1 is %08h, expected 00008000",
                 rd_q);
        errors = errors + 1;
    end

    // --- the same title with the other byte order ---------------------------
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b0);
    expect_path("/Assets/carttools/common/TESTCART.gb", 36, "byte_order 0");

    // Byte reversed, because byte 0 of the struct now goes in the top of the
    // word and byte 0 of a little endian u32 is its low byte.
    read_word(7'd64);
    if (rd_q !== 32'h03000000) begin
        $display("ERROR: flags at byte_order 0 is %08h, expected 03000000",
                 rd_q);
        errors = errors + 1;
    end
    read_word(7'd65);
    if (rd_q !== 32'h00800000) begin
        $display("ERROR: size at byte_order 0 is %08h, expected 00800000",
                 rd_q);
        errors = errors + 1;
    end

    // --- zero padded, mixed case, punctuation -------------------------------
    // Lower case is folded up and anything that is not alphanumeric becomes
    // an underscore, because a colon or a slash in a title would otherwise
    // become a directory separator or an illegal name.
    run({"Zelda:DX", 56'h00000000000000}, 1'b0, 32'h100000, 1'b1);
    expect_path("/Assets/carttools/common/ZELDA_DX.gb", 36, "sanitised");

    // --- all fifteen characters used ----------------------------------------
    run("POKEMON BLUE VR", 1'b0, 32'h100000, 1'b1);
    expect_path("/Assets/carttools/common/POKEMON_BLUE_VR.gb", 43,
                "full length title");

    // --- a title that is entirely padding -----------------------------------
    // A cartridge that read back as all 0xFF must not produce a file called
    // ".gb", which is a hidden file with no name.
    run({15{8'hFF}}, 1'b0, 32'h8000, 1'b1);
    expect_path("/Assets/carttools/common/UNTITLED.gb", 36, "unreadable title");

    // --- named after the system, not just after the cartridge ---------------
    // A dump is useless to the tools that read it if the extension is wrong: a
    // 16 MB GBA image called .gb is mis-identified by everything that looks at
    // it, and two such files were written before this existed. The size cannot
    // stand in either - a 1 MB Game Boy cartridge and a 1 MB GBA cartridge are
    // both ordinary.
    cart_kind = 2'd1;                       // 0x0143 was 0x80 or 0xC0
    run("TESTCART       ", 1'b0, 32'h8000, 1'b1);
    expect_path("/Assets/carttools/common/TESTCART.gbc", 37, "colour cartridge");

    cart_kind = 2'd2;
    run("TESTCART       ", 1'b0, 32'h800000, 1'b1);
    expect_path("/Assets/carttools/common/TESTCART.gba", 37, "advance cartridge");

    // And back, because a stale kind would rename the next dump. The three
    // extensions are not the same length, so this also catches a length that
    // was set once and never cleared.
    cart_kind = 2'd0;
    run("TESTCART       ", 1'b0, 32'h8000, 1'b1);
    expect_path("/Assets/carttools/common/TESTCART.gb", 36, "back to plain gb");

    // The self test is not a cartridge and overrides all three.
    cart_kind = 2'd2;
    run(120'd0, 1'b1, 32'd256, 1'b1);
    expect_path("/Assets/carttools/common/SELFTEST.bin", 37, "self test beats kind");
    cart_kind = 2'd0;

    // --- the self test ramp, which names itself -----------------------------
    run(120'd0, 1'b1, 32'd256, 1'b1);
    expect_path("/Assets/carttools/common/SELFTEST.bin", 37, "self test");
    read_word(7'd65);
    if (rd_q !== 32'd256) begin
        $display("ERROR: self test size word is %08h, expected 100", rd_q);
        errors = errors + 1;
    end

    // Create alone rather than create and resize, which is the other reading
    // of the flag documentation and therefore also in the search.
    create_only = 1'b1;
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    read_word(7'd64);
    if (rd_q !== 32'h00000001) begin
        $display("ERROR: create-only flags is %08h, expected 00000001", rd_q);
        errors = errors + 1;
    end
    create_only = 1'b0;

    // --- all four roots ------------------------------------------------------
    // Which one APF wants is not derivable from anything in this tree, so all
    // four are in the build and picked at runtime. What is checked here is
    // only that each produces the string it claims to; hardware decides which
    // is right.
    path_style = 3'd1;
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    expect_path("Assets/carttools/common/TESTCART.gb", 35, "style 1, no leading slash");

    path_style = 3'd2;
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    expect_path("TESTCART.gb", 11, "style 2, bare filename");

    path_style = 3'd3;
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    expect_path("/Saves/carttools/common/TESTCART.gb", 35, "style 3, under Saves");

    // And back, because the prefix is a register now and a stale one would be
    // the kind of bug that only shows on the second dump.
    path_style = 3'd0;
    run({"TESTCART", 56'h20202020202020}, 1'b0, 32'h8000, 1'b1);
    expect_path("/Assets/carttools/common/TESTCART.gb", 36, "style 0 again");

    if (errors != 0) begin
        $display("tb_dump_path_gen: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_dump_path_gen");
    $finish;
end

initial begin
    #20000000;
    $display("ERROR: tb_dump_path_gen watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
