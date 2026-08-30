// SOURCES: src/fpga/services/identify/cart_identify_gba.sv
//
// tb_cart_identify.sv - unit test for the GBA header reader
//
// This drives cart_identify_gba against a stub of the cartridge bus rather
// than the real one. The point of separating them is that the questions are
// different: whether the header is parsed and judged correctly is arithmetic,
// and whether the pins wiggle correctly is timing. Mixing them means a
// checksum bug and a bus bug look the same on the waveform.
//
// The end to end test, identify through the real gba_cart_bus and a cartridge
// model, belongs in its own testbench once tools/sim/gba_cart_model.sv exists.
//
// The good header below is not the module's own arithmetic played back at it.
// The complement byte 0xDF was computed independently in Python from the same
// 29 bytes, so a sign error or an off-by-one in the module's sum shows up as a
// failure here rather than agreeing with itself.
//
`default_nettype none
`timescale 1ns/1ps

module tb_cart_identify;

localparam integer WORDS = 16;

reg clk = 1'b0;
always #5 clk = ~clk;          // 100 MHz, close enough to the real clk_sys

reg reset = 1'b1;
reg cart_mode = 1'b1;
reg start = 1'b0;

wire        busy, done;
wire        cart_req, cart_wr;
wire [27:0] cart_addr;
wire [1:0]  cart_acc;
wire [31:0] cart_wdata;

reg  [31:0] cart_rdata;
reg         cart_done;
reg         cart_busy;

wire [2:0]  result;
wire [95:0] title;
wire [31:0] game_code;
wire [15:0] maker_code;
wire [7:0]  device_type;
wire [7:0]  sw_version;
wire        fixed_ok, checksum_ok, reserved_ok;

localparam [2:0] RESULT_GBA      = 3'd0;
localparam [2:0] RESULT_NO_CART  = 3'd1;
localparam [2:0] RESULT_UNSTABLE = 3'd2;
localparam [2:0] RESULT_NOT_GBA  = 3'd3;
localparam [2:0] RESULT_NO_POWER = 3'd4;

cart_identify_gba dut (
    .clk        ( clk ),
    .reset      ( reset ),
    .cart_mode  ( cart_mode ),
    .start      ( start ),
    .busy       ( busy ),
    .done       ( done ),
    .cart_req   ( cart_req ),
    .cart_wr    ( cart_wr ),
    .cart_addr  ( cart_addr ),
    .cart_acc   ( cart_acc ),
    .cart_wdata ( cart_wdata ),
    .cart_rdata ( cart_rdata ),
    .cart_done  ( cart_done ),
    .cart_busy  ( cart_busy ),
    .result     ( result ),
    .title      ( title ),
    .game_code  ( game_code ),
    .maker_code ( maker_code ),
    .device_type( device_type ),
    .sw_version ( sw_version ),
    .fixed_ok   ( fixed_ok ),
    .checksum_ok( checksum_ok ),
    .reserved_ok( reserved_ok )
);

integer errors = 0;

task expect_eq32(input [255:0] what, input [31:0] got, input [31:0] want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = 0x%08x, expected 0x%08x", what, got, want);
            errors = errors + 1;
        end
    end
endtask

task expect_bit(input [255:0] what, input got, input want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %b, expected %b", what, got, want);
            errors = errors + 1;
        end
    end
endtask

// ---- The stub cartridge bus ----------------------------------------------
//
// Two banks: what the first read of a word returns and what the second read
// returns. They are the same for every case except the unstable one, which is
// the only way to test that the double read is actually a double read and not
// the same buffer inspected twice.

reg [15:0] bank_a [0:WORDS-1];
reg [15:0] bank_b [0:WORDS-1];
reg [3:0]  seen [0:WORDS-1];       // how many times each word has been read

// Requests seen, so the testbench can assert the module asked for what it
// should have asked for rather than trusting the result it produced.
integer req_count;
reg [27:0] first_addr;
reg        saw_write;
reg        saw_bad_acc;

integer w;

// Model of gba_cart_bus's handshake: req is accepted only when not busy, the
// bus is busy for a few cycles, then done pulses for exactly one cycle with
// rdata valid. The delay is deliberately not 1 cycle: a module that assumes
// an immediate answer would pass against a zero-latency stub and hang against
// the real thing.
localparam integer BUS_LATENCY = 7;

integer lat;
reg [3:0] pend_idx;

always @(posedge clk) begin
    if (reset) begin
        cart_busy   <= 1'b0;
        cart_done   <= 1'b0;
        cart_rdata  <= 32'd0;
        lat         <= 0;
        req_count   <= 0;
        saw_write   <= 1'b0;
        saw_bad_acc <= 1'b0;
        first_addr  <= 28'hFFFFFFF;
        for (w = 0; w < WORDS; w = w + 1) seen[w] <= 4'd0;
    end else begin
        cart_done <= 1'b0;

        if (!cart_busy && cart_req) begin
            if (req_count == 0) first_addr <= cart_addr;
            req_count <= req_count + 1;
            if (cart_wr)          saw_write   <= 1'b1;
            if (cart_acc != 2'b01) saw_bad_acc <= 1'b1;

            pend_idx  <= cart_addr[4:1];
            cart_busy <= 1'b1;
            lat       <= BUS_LATENCY;
        end else if (cart_busy) begin
            if (lat == 0) begin
                cart_rdata     <= (seen[pend_idx] == 0) ? {16'd0, bank_a[pend_idx]}
                                                        : {16'd0, bank_b[pend_idx]};
                seen[pend_idx] <= seen[pend_idx] + 4'd1;
                cart_done      <= 1'b1;
                cart_busy      <= 1'b0;
            end else begin
                lat <= lat - 1;
            end
        end
    end
end

// ---- Header fixtures ------------------------------------------------------

reg [15:0] good [0:WORDS-1];

task load_good;
    begin
        good[0]  = 16'h4554;   // "TE"  0xA0
        good[1]  = 16'h5453;   // "ST"
        good[2]  = 16'h4143;   // "CA"
        good[3]  = 16'h5452;   // "RT"
        good[4]  = 16'h2020;   // "  "
        good[5]  = 16'h2020;   // "  "
        good[6]  = 16'h4D41;   // "AM"  0xAC game code
        good[7]  = 16'h4554;   // "TE"
        good[8]  = 16'h3130;   // "01"  0xB0 maker
        good[9]  = 16'h0096;   //       0xB2 fixed 0x96
        good[10] = 16'h0000;
        good[11] = 16'h0000;
        good[12] = 16'h0000;
        good[13] = 16'h0000;
        good[14] = 16'hDF00;   //       0xBC version 0x00, 0xBD complement 0xDF
        good[15] = 16'h0000;
    end
endtask

task set_both(input integer i, input [15:0] v);
    begin
        bank_a[i] = v;
        bank_b[i] = v;
    end
endtask

task load_case_good;
    begin
        for (w = 0; w < WORDS; w = w + 1) set_both(w, good[w]);
    end
endtask

task run_identify;
    begin
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait (done == 1'b1);
        @(negedge clk);
    end
endtask

task reset_stub;
    begin
        reset = 1'b1;
        @(negedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(negedge clk);
    end
endtask

// ---- Cases ----------------------------------------------------------------

integer timeout;

initial begin
    load_good();
    cart_mode = 1'b1;

    // ---- 1. A good cartridge -------------------------------------------
    reset_stub();
    load_case_good();
    run_identify();

    expect_eq32("good: result", {29'd0, result}, {29'd0, RESULT_GBA});
    expect_bit ("good: fixed_ok", fixed_ok, 1'b1);
    expect_bit ("good: checksum_ok", checksum_ok, 1'b1);
    expect_bit ("good: reserved_ok", reserved_ok, 1'b1);
    expect_eq32("good: game_code", game_code, "AMTE");
    expect_eq32("good: maker_code", {16'd0, maker_code}, {16'd0, 16'h3031});
    expect_eq32("good: title[95:64]", title[95:64], "TEST");
    expect_eq32("good: title[63:32]", title[63:32], "CART");
    expect_eq32("good: title[31:0]",  title[31:0],  "    ");
    expect_eq32("good: sw_version", {24'd0, sw_version}, 32'd0);

    // It must have read the header twice, sixteen words each time, starting
    // at 0xA0, never writing, always 16 bits wide.
    expect_eq32("good: request count", req_count, 32);
    expect_eq32("good: first address", {4'd0, first_addr}, 32'h000000A0);
    expect_bit ("good: never wrote", saw_write, 1'b0);
    expect_bit ("good: always 16-bit", saw_bad_acc, 1'b0);

    // ---- 2. Empty slot, floating high ----------------------------------
    reset_stub();
    for (w = 0; w < WORDS; w = w + 1) set_both(w, 16'hFFFF);
    run_identify();
    expect_eq32("all ones: result", {29'd0, result}, {29'd0, RESULT_NO_CART});

    // ---- 3. Empty slot, reading back zero ------------------------------
    reset_stub();
    for (w = 0; w < WORDS; w = w + 1) set_both(w, 16'h0000);
    run_identify();
    expect_eq32("all zeros: result", {29'd0, result}, {29'd0, RESULT_NO_CART});

    // ---- 4. Marginal cartridge: the two reads disagree ------------------
    //
    // Both copies are individually valid headers with correct checksums, so
    // anything that judged a single pass would call this a good cartridge and
    // report a title from whichever pass it happened to keep.
    reset_stub();
    load_case_good();
    bank_b[3] = 16'h5453;               // "RT" becomes "ST" on the second read
    run_identify();
    expect_eq32("unstable: result", {29'd0, result}, {29'd0, RESULT_UNSTABLE});

    // ---- 5. Present, stable, wrong fixed byte ---------------------------
    reset_stub();
    load_case_good();
    set_both(9, 16'h0000);              // 0xB2 is not 0x96
    run_identify();
    expect_eq32("bad fixed: result", {29'd0, result}, {29'd0, RESULT_NOT_GBA});
    expect_bit ("bad fixed: fixed_ok", fixed_ok, 1'b0);
    expect_bit ("bad fixed: checksum_ok", checksum_ok, 1'b0);

    // ---- 6. Present, stable, one byte of the title corrupted ------------
    //
    // The complement check exists to catch exactly this, and it is the case
    // that separates a real header from 32 bytes of plausible ASCII.
    reset_stub();
    load_case_good();
    set_both(0, 16'h4555);              // "TE" -> "UE"
    run_identify();
    expect_eq32("bad checksum: result", {29'd0, result}, {29'd0, RESULT_NOT_GBA});
    expect_bit ("bad checksum: fixed_ok", fixed_ok, 1'b1);
    expect_bit ("bad checksum: checksum_ok", checksum_ok, 1'b0);

    // ---- 7. Reserved bytes non-zero -------------------------------------
    //
    // Not a rejection on its own. It is reported and left to the caller,
    // because a cartridge that is otherwise a valid header is more likely to
    // be unusual than to be fake, and refusing to identify it would be worse
    // than saying so. The checksum moves with it, hence the recomputed 0xDE.
    reset_stub();
    load_case_good();
    set_both(11, 16'h0001);
    set_both(14, 16'hDE00);
    run_identify();
    expect_eq32("reserved set: result", {29'd0, result}, {29'd0, RESULT_GBA});
    expect_bit ("reserved set: reserved_ok", reserved_ok, 1'b0);
    expect_bit ("reserved set: checksum_ok", checksum_ok, 1'b1);

    // ---- 8. Every byte of the checksummed range actually counts ----------
    //
    // The good header above has zeros through its reserved region, so a
    // checksum that skipped those words would still agree with it. That is
    // not a hypothetical: dropping word 13 from the sum passed the first
    // version of this testbench. This header has a non-zero byte in every one
    // of the 29 checksummed positions, so omitting any of them changes the
    // result. Its complement, 0x7B, was computed in Python, not here.
    reset_stub();
    bank_a[0]  = 16'h4241;  bank_a[1]  = 16'h4443;   // "ABCDEFGHIJKL"
    bank_a[2]  = 16'h4645;  bank_a[3]  = 16'h4847;
    bank_a[4]  = 16'h4A49;  bank_a[5]  = 16'h4C4B;
    bank_a[6]  = 16'h5857;  bank_a[7]  = 16'h5A59;   // "WXYZ"
    bank_a[8]  = 16'h4639;                           // "9F"
    bank_a[9]  = 16'h1196;                           // fixed 0x96, unit 0x11
    bank_a[10] = 16'h3322;  bank_a[11] = 16'h5544;   // device, reserved
    bank_a[12] = 16'h7766;  bank_a[13] = 16'h9988;
    bank_a[14] = 16'h7BAA;                           // version 0xAA, check 0x7B
    bank_a[15] = 16'hCCBB;
    for (w = 0; w < WORDS; w = w + 1) bank_b[w] = bank_a[w];
    run_identify();
    expect_eq32("dense: result", {29'd0, result}, {29'd0, RESULT_GBA});
    expect_bit ("dense: checksum_ok", checksum_ok, 1'b1);
    expect_eq32("dense: title[95:64]", title[95:64], "ABCD");
    expect_eq32("dense: game_code", game_code, "WXYZ");
    expect_eq32("dense: sw_version", {24'd0, sw_version}, 32'h000000AA);
    // Reserved bytes set, so this is a cartridge that identifies but is
    // unusual, and the flag must say so rather than being folded into result.
    expect_bit ("dense: reserved_ok", reserved_ok, 1'b0);

    // ---- 9. Slot not powered --------------------------------------------
    //
    // The real bus ignores requests with cart_mode low and never raises done,
    // so a module that issued one anyway would hang the UI. It must refuse
    // without touching the bus.
    reset_stub();
    load_case_good();
    cart_mode = 1'b0;
    run_identify();
    expect_eq32("no power: result", {29'd0, result}, {29'd0, RESULT_NO_POWER});
    expect_eq32("no power: no requests issued", req_count, 0);
    cart_mode = 1'b1;

    // ---- 10. done is one cycle, and busy actually falls ------------------
    reset_stub();
    load_case_good();
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    @(negedge clk);
    if (busy !== 1'b1) begin
        $display("ERROR: busy did not rise after start");
        errors = errors + 1;
    end
    wait (done == 1'b1);
    @(posedge clk);
    #1;
    if (done !== 1'b0) begin
        $display("ERROR: done was longer than one cycle");
        errors = errors + 1;
    end
    if (busy !== 1'b0) begin
        $display("ERROR: busy still high after done");
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("tb_cart_identify: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_cart_identify");
    $finish;
end

// A hang here means a handshake bug, which is the failure mode that matters
// most: the UI waits on done and there is no other way out.
initial begin
    #500000;
    $display("ERROR: tb_cart_identify timed out");
    $fatal(1);
end

endmodule

`default_nettype wire
