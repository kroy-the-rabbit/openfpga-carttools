// SOURCES: src/fpga/ui/ui_screen.sv src/fpga/ui/ui_textbuf.sv
//
// tb_ui_screen.sv - what the identification screen actually says
//
// ui_renderer's testbench proves that whatever is in the text buffer reaches
// the screen correctly. This one proves the text buffer says the right thing,
// which is a separate question and the one a user would notice.
//
// The check that matters most is the last one: every result code the
// identifier can produce has to put a non-blank line on screen. A user who
// gets a blank screen after a failed read has been told nothing, and that is
// the moment they most need telling.
//
`default_nettype none
`timescale 1ns/1ps

module tb_ui_screen;

localparam integer COLS = 30;
localparam integer ROWS = 20;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg adapter_diagnostic=0, adapter_valid=0;
reg [31:0] adapter_report=0;
reg [3:0] adapter_seq=0;

reg         valid = 1'b0;
reg  [2:0]  platform = 3'd0;
reg [1:0] answered_gba = 2'd0;
reg [19:0] gg_product=0;
reg [3:0] gg_version=0, gg_region=0;
reg [15:0] gg_header_addr=0;
reg [127:0] gg_header=0;
reg gg_size_512=0, gg_verify_checked=0, gg_verify_ok=0;
reg  [95:0] title = 96'd0;
reg  [31:0] game_code = 32'd0;
reg  [15:0] maker_code = 16'd0;
reg  [7:0]  sw_version = 8'd0;
reg         fixed_ok = 1'b0;
reg         checksum_ok = 1'b0;
reg         reserved_ok = 1'b0;
reg         scanning = 1'b0;
reg  [3:0]   id_seq = 4'd0;
reg  [119:0] gb_title = 120'd0;
reg  [7:0]   gb_cart_type = 8'd0;
reg  [7:0]   gb_rom_size = 8'd0;
reg  [7:0]   gb_ram_size = 8'd0;
reg          gb_checksum_ok = 1'b0;

reg  [1:0]   dump_state = 2'd0;
reg          dump_ready = 1'b0;
reg  [2:0]   dump_err = 3'd0;
reg  [15:0]  dump_fail_chunk = 16'd0;
reg          no_open = 1'b0;
reg  [1:0]   stall_at = 2'd0;
reg          save_shown = 1'b0;
reg          save_ready = 1'b0;
reg          restore_ready = 1'b0;
reg          save_refused = 1'b0;
reg          save_responded = 1'b0;
reg          save_blank_ff = 1'b0;
reg          save_blank_00 = 1'b0;
reg  [31:0]  save_first = 32'd0;
reg          sum_checked = 1'b0;
reg          sum_ok = 1'b0;
reg  [15:0]  sum_computed = 16'd0;
reg  [15:0]  sum_stored = 16'd0;
reg  [7:0]   dump_progress = 8'd0;
reg  [127:0] out_name = 128'd0;
reg  [4:0]   out_name_len = 5'd0;
reg  [31:0]  out_ext = 32'd0;
reg  [2:0]   out_ext_len = 3'd0;
reg          out_name_valid = 1'b0;
reg  [3:0]   gba_size_code = 4'd0;
reg  [31:0]  crc32 = 32'd0;
reg pair_checked = 0;
reg [23:0] pair_mismatches = 0, pair_even = 0, pair_odd = 0;
reg [22:0] pair_first_addr = 0;
reg [7:0] pair_first_a = 0, pair_first_b = 0;

// A literal cannot be part-selected, so the fixtures live in registers.
reg [8*33-1:0] apf_path = "/Assets/carttools/common/PROBE.gb";
reg [8*8-1:0]  swapped  = "ssA/tes/";

wire [9:0] tb_addr;
wire [7:0] tb_char;
wire [1:0] tb_attr;
wire       tb_we;

reg  [9:0] rd_addr = 10'd0;
wire [7:0] rd_char;
wire [1:0] rd_attr;

ui_screen dut (
    .gg_product(gg_product), .gg_version(gg_version), .gg_region(gg_region),
    .gg_header_addr(gg_header_addr), .gg_header(gg_header), .gg_size_512(gg_size_512),
    .gg_verify_checked(gg_verify_checked), .gg_verify_ok(gg_verify_ok),
    .adapter_diagnostic(adapter_diagnostic), .adapter_report(adapter_report), .adapter_valid(adapter_valid), .adapter_seq(adapter_seq),
    .clk        ( clk ),
    .reset      ( reset ),
    .valid      ( valid ),
    .platform   ( platform ),
    .answered_protocol(answered_gba),
    .title      ( title ),
    .game_code  ( game_code ),
    .maker_code ( maker_code ),
    .sw_version ( sw_version ),
    .fixed_ok   ( fixed_ok ),
    .checksum_ok( checksum_ok ),
    .reserved_ok( reserved_ok ),
    .gba_size_code ( gba_size_code ),
    .crc32         ( crc32 ),
    .pair_checked(pair_checked), .pair_mismatches(pair_mismatches),
    .pair_even(pair_even), .pair_odd(pair_odd),
    .pair_first_addr(pair_first_addr),
    .pair_first_a(pair_first_a), .pair_first_b(pair_first_b),
    .scanning   ( scanning ),
    .id_seq          ( id_seq ),
    .gb_title        ( gb_title ),
    .gb_cart_type    ( gb_cart_type ),
    .gb_rom_size     ( gb_rom_size ),
    .gb_ram_size     ( gb_ram_size ),
    .gb_checksum_ok  ( gb_checksum_ok ),
    .dump_state      ( dump_state ),
    .dump_ready      ( dump_ready ),
    .dump_err        ( dump_err ),
    .dump_fail_chunk ( dump_fail_chunk ),
    .no_open         ( no_open ),
    .stall_at        ( stall_at ),
    .save_shown      ( save_shown ),
    .save_ready      ( save_ready ),
    .restore_ready   ( restore_ready ),
    .save_refused    ( save_refused ),
    .save_responded  ( save_responded ),
    .save_blank_ff   ( save_blank_ff ),
    .save_blank_00   ( save_blank_00 ),
    .save_first      ( save_first ),
    .sum_checked     ( sum_checked ),
    .sum_ok          ( sum_ok ),
    .sum_computed    ( sum_computed ),
    .sum_stored      ( sum_stored ),
    .dump_progress   ( dump_progress ),
    .out_name        ( out_name ),
    .out_name_len    ( out_name_len ),
    .out_ext         ( out_ext ),
    .out_ext_len     ( out_ext_len ),
    .out_name_valid  ( out_name_valid ),
    .tb_addr    ( tb_addr ),
    .tb_char    ( tb_char ),
    .tb_attr    ( tb_attr ),
    .tb_we      ( tb_we )
);

ui_textbuf buf_i (
    .clk     ( clk ),
    .tb_addr ( tb_addr ),
    .tb_char ( tb_char ),
    .tb_attr ( tb_attr ),
    .tb_we   ( tb_we ),
    .rd_addr ( rd_addr ),
    .rd_char ( rd_char ),
    .rd_attr ( rd_attr )
);

integer errors = 0;
integer i;

// Read one row back as a string. The buffer read port has a cycle of latency.
task read_row(input integer row, output reg [8*COLS-1:0] out);
    begin
        out = {(8*COLS){1'b0}};
        for (i = 0; i < COLS; i = i + 1) begin
            @(negedge clk);
            rd_addr = row * COLS + i;
            @(negedge clk);
            out[8*(COLS-1-i) +: 8] = rd_char;
        end
    end
endtask

reg [8*COLS-1:0] got;

// Retain an extra byte: matching truncation in the DUT and the expected literal
// must not make an overlong row pass. Actual output is also checked by prefix.
task expect_row(input [255:0] what, input integer row, input [8*(COLS+1)-1:0] want);
    begin
        if (want[8*COLS +: 8] !== 8'd0)
            $fatal(1, "UI_ROW_LENGTH: %0s expected row exceeds %0d columns", what, COLS);
        read_row(row, got);
        if (got !== want[8*COLS-1:0]) begin
            $display("ERROR: %0s row %0d", what, row);
            $display("         got: |%0s|", got);
            $display("    expected: |%0s|", want);
            errors = errors + 1;
        end
    end
endtask

task expect_first(input integer row, input [7:0] want);
    begin
        read_row(row, got);
        if (got[8*(COLS-1) +: 8] !== want)
            $fatal(1, "UI_ROW_PREFIX: row %0d lost its first character", row);
    end
endtask

task expect_row_not_blank(input [255:0] what, input integer row);
    begin
        read_row(row, got);
        if (got === {COLS{8'h20}}) begin
            $display("ERROR: %0s left row %0d blank", what, row);
            errors = errors + 1;
        end
    end
endtask

// A repaint is 600 writes. Give it room and then some.
task settle;
    begin
        for (i = 0; i < 1200; i = i + 1) @(posedge clk);
    end
endtask

integer r;

initial begin
    reset = 1'b1;
    repeat (4) @(negedge clk);
    reset = 1'b0;

    // ---- 1. It paints itself out of reset ------------------------------
    //
    // Without this the screen would keep the buffer's power-on contents until
    // something happened to change, which after a cold boot with no cartridge
    // is never.
    settle();
    // The build stamp. Two hardware sessions were spent flashing bitstreams
    // that looked identical on screen; simulation uses the committed
    // placeholder, hardware gets the commit.
    expect_row("cold boot", 0, "CARTRIDGE TOOLS           0000");
    expect_row("cold boot", 2, "READY                         ");

    // ---- 2. Scanning ----------------------------------------------------
    scanning = 1'b1;
    settle();
    expect_row("scanning", 2, "READING HEADER...             ");
    scanning = 1'b0;

    // ---- 3. Empty slot ---------------------------------------------------
    valid  = 1'b1;
    platform = 3'd0;
    settle();
    expect_row("no cart", 2, "NO CARTRIDGE DETECTED         ");
    // The detail rows must clear, not keep values from a previous cartridge.
    expect_row("no cart", 4, "                              ");
    expect_row("no cart", 5, "                              ");

    // ---- 4. A cartridge --------------------------------------------------
    platform    = 3'd1;
    title       = "TESTCART    ";
    game_code   = "AMTE";
    maker_code  = 16'h3031;      // "01"
    sw_version  = 8'h00;
    fixed_ok    = 1'b1;
    checksum_ok = 1'b1;
    reserved_ok = 1'b1;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("gba cart", 2, "GBA CARTRIDGE                 ");
    expect_row("gba cart", 4, "TESTCART                      ");
    expect_row("gba cart", 5, "Code AMTE      Maker 01       ");
    expect_row("gba cart", 6, "Version 00                    ");
    expect_row("gba cart", 7, "header ok  checksum ok        ");

    // ---- 5. A failing checksum is visible, not silent --------------------
    checksum_ok = 1'b0;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("bad checksum", 7, "header ok  checksum --        ");

    // ---- 6. The version field is hex, not decimal ------------------------
    checksum_ok = 1'b1;
    sw_version  = 8'hAF;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("hex version", 6, "Version AF                    ");
    sw_version  = 8'h00;
    id_seq = id_seq + 4'd1;

    // ---- 6b. The probed ROM size shares the version row ------------------
    //
    // A GBA header has no size field, so this number is measured on the bus
    // afterwards and arrives after the probe that id_seq counts. It therefore
    // has to repaint the screen on its own account, which is why the code is
    // in the snapshot and why this case does not touch id_seq.
    gba_size_code = 4'd3;
    settle();
    expect_row("probed size", 6, "Version 00     ROM 4 MB       ");

    gba_size_code = 4'd5;
    settle();
    expect_row("probed size 16", 6, "Version 00     ROM 16 MB      ");

    // Reaching 32 MB by running out of candidates is a weaker claim than
    // measuring an end, and the screen says which it is.
    gba_size_code = 4'd7;
    settle();
    expect_row("size ceiling", 6, "Version 00     ROM 32 MB max  ");

    // A refusal says so rather than showing the last cartridge's size or a
    // confident 1 MB.
    gba_size_code = 4'd8;
    settle();
    expect_row("size refused", 6, "Version 00     size not found ");

    gba_size_code = 4'd9;
    settle();
    expect_row("blank cart", 6, "Version 00     blank cartridge");

    gba_size_code = 4'd0;
    settle();
    expect_row("no size yet", 6, "Version 00                    ");

    // ---- 7. A changed title repaints -------------------------------------
    //
    // Swapping cartridges without a reset must not leave the old name up.
    title = "OTHERCART   ";
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("second cart", 4, "OTHERCART                     ");

    // ---- 7b. A Game Boy cartridge ----------------------------------------
    //
    // Same rows, different labels and different fields. The GB header has no
    // fixed byte, so that flag is blank rather than showing a failure.
    platform       = 3'd2;
    gb_title       = "POKEMON CRYSTAL";
    gb_cart_type   = 8'h13;
    gb_rom_size    = 8'h05;
    gb_ram_size    = 8'h03;
    gb_checksum_ok = 1'b1;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("gb cart", 2, "GB / GBC CARTRIDGE            ");
    expect_row("gb cart", 4, "POKEMON CRYSTAL               ");
    // The mapper and the sizes as words. "Type 13" and "ROM 05" are the
    // numbers in the cartridge; nobody carries that table in their head.
    // The header byte stays at the right hand end for cross reference.
    expect_row("gb cart", 5, "MBC3 + RAM + battery        13");
    expect_row("gb cart", 6, "ROM  1 MB        RAM  32 KB   ");
    expect_row("gb cart", 7, "checksum ok                   ");

    gb_checksum_ok = 1'b0;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("gb bad checksum", 7, "checksum --                   ");

    // Switching back must not leave Game Boy labels on a GBA cartridge.
    platform = 3'd1;
    id_seq = id_seq + 4'd1;
    settle();
    expect_row("back to gba", 5, "Code AMTE      Maker 01       ");
    expect_row("back to gba", 4, "OTHERCART                     ");

    // ---- 8. Every platform code says something ---------------------------
    //
    // ui_screen's default arm exists so that this cannot fail, and this is
    // the test that keeps it honest when a result code is added.
    valid    = 1'b1;
    scanning = 1'b0;
    for (r = 0; r < 8; r = r + 1) begin
        platform = r[2:0];
        settle();
        expect_row_not_blank("result code", 2);
    end

    // A failed verdict must identify which probe produced it. Without this,
    // the same screen can mean floating data during the GB safety gate or a
    // bad read from the actual GBA header.
    platform = 3'd3;
    answered_gba = 1'b0;
    settle();
    expect_row("unknown at gb gate", 2,
               "UNKNOWN: GB SAFETY GATE       ");
    answered_gba = 1'b1;
    settle();
    expect_row("unknown at gba header", 2,
               "UNKNOWN: GBA HEADER           ");

    platform = 3'd4;
    answered_gba = 1'b0;
    settle();
    expect_row("unstable at gb gate", 2,
               "UNSTABLE: GB SAFETY GATE      ");
    answered_gba = 1'b1;
    settle();
    expect_row("unstable at gba header", 2,
               "UNSTABLE: GBA HEADER          ");

    // ---- 9. The help row names only buttons that do something ------------
    //
    // Restore has a separate, explicitly gated entry hint. It appears only
    // when the top has identified a supported idle cartridge.
    expect_row("main help", 18, "A scan                        ");
    expect_row("restore unavailable", 19, "                              ");
    restore_ready = 1;
    settle();
    expect_row("restore offered", 19, "HOLD SELECT 3s: RESTORE       ");
    restore_ready = 0;
    settle();
    expect_row("restore withdrawn", 19, "                              ");

    // ---- Dumping -----------------------------------------------------------
    //
    // X is only offered once a cartridge has been identified. A button that
    // is silently inert teaches the user that the core is broken.
    dump_ready = 1'b1;
    settle();
    expect_row("dump offered", 18, "A scan  X dump                ");

    // Progress as a bar, not a hex chunk count. "DUMPING 0042 OF 0200" asks
    // the reader to do hexadecimal arithmetic to find out whether anything is
    // moving. dump_engine supplies 0 to 255 so this stays a comparison per
    // cell rather than a divide, which is what failed timing here once.
    out_name      = {"ZELDA", 88'd0};
    out_name_len  = 5'd5;
    out_ext       = ".gb ";
    out_ext_len   = 3'd3;
    out_name_valid = 1'b1;

    dump_state    = 2'd1;
    dump_progress = 8'h60;          // six of sixteen cells
    settle();
    expect_row("dumping", 10, "DUMPING                       ");
    expect_row("cancel during dump", 18, "A cancel                      ");
    expect_row("dumping", 11, "[######----------]            ");
    // Named while it is being written, not only afterwards. A dump that says
    // COMPLETE without naming the file leaves the reader hunting the card.
    expect_row("dumping", 12, "ZELDA.gb                      ");

    // A rescan clears the displayed result, then the next dump enters RUN
    // before its path generator finishes. The previous operation's path is
    // still on the wires during that wait and must remain hidden.
    dump_state = 2'd0;
    settle();
    expect_row("rescan clears old name", 12,
               "                              ");
    dump_state    = 2'd1;
    out_name_valid = 1'b0;
    settle();
    expect_row("new dump hides old name", 12,
               "                              ");

    // Path validity is the only changing repaint input when the new name
    // lands, so it must both trigger the repaint and expose the new value.
    out_ext      = ".sav";
    out_ext_len  = 3'd4;
    out_name_valid = 1'b1;
    settle();
    expect_row("save name becomes valid", 12,
               "ZELDA.sav                     ");
    out_name_valid = 1'b0;
    settle();
    out_ext      = ".gb ";
    out_ext_len  = 3'd3;
    out_name_valid = 1'b1;
    settle();
    expect_row("ROM name restored", 12,
               "ZELDA.gb                      ");

    dump_progress = 8'hC0;
    settle();
    expect_row("dumping", 11, "[############----]            ");

    // Full on success whatever the counter reached: the last chunk completing
    // and the file being flushed are not the same moment.
    dump_state    = 2'd2;
    dump_progress = 8'hF0;
    settle();
    expect_row("dump ok", 10, "DUMP COMPLETE                 ");

    // The same bytes, written into the slot's own file because no open was
    // ever accepted. A different outcome, and the screen says which.
    no_open = 1'b1;
    settle();
    expect_row("dump to slot", 10, "DUMPED TO SLOT FILE           ");
    no_open = 1'b0;
    settle();
    expect_row("dump ok", 11, "[################]            ");
    expect_row("dump ok", 12, "ZELDA.gb                      ");

    // The cartridge's own verdict on the image. This is the only line on
    // this screen that judges a dump rather than reporting on it, and it
    // exists because a floating data line once produced a dump the core
    // called successful.
    sum_checked  = 1'b1;
    sum_ok       = 1'b1;
    settle();
    expect_row("dump verified", 13, "image checksum ok             ");

    // When they disagree, both numbers, because the difference is the only
    // clue to the fault.
    sum_ok       = 1'b0;
    sum_computed = 16'h540E;
    sum_stored   = 16'h16BF;
    settle();
    expect_row("dump mismatch", 13, "image sum 540E want 16BF      ");

    // A GBA dump reaches this line with nothing to claim: there is no
    // checksum anywhere in a GBA cartridge that covers its own contents.
    sum_checked = 1'b0;
    settle();
    expect_row("no header to check", 13, "                              ");
    sum_ok = 1'b1;

    // Row 14 is the image's CRC32, which is the only identity a GBA dump has
    // and a second opinion on a GB one. Hexadecimal, and assembled as a whole
    // row before the column mux rather than a digit at a time inside it.
    crc32       = 32'hCBF43926;   // zlib's answer for "123456789"
    settle();
    expect_row("dump crc", 14, "crc32  CBF43926               ");

    // While a dump is running there is no CRC to show. A CRC over a partial
    // image looks exactly like a CRC over a whole one.
    dump_state = 2'd1;
    settle();
    expect_row("crc during a dump", 14, "                              ");

    // And the value that lands is the one standing when the dump finished.
    // crc32 is deliberately NOT in the repaint trigger: it changes on every
    // byte of a dump, it is only meaningful when the dump has ended, and
    // dump_state moves at exactly that moment. So a CRC that changed on its
    // own would not reach the screen, which is a real limitation and the
    // reason this case drives the state as well as the value. The trigger is
    // where this module has failed timing before; it is kept small on
    // purpose.
    crc32      = 32'h0123ABCD;      // every nibble class, including A to F
    dump_state = 2'd2;
    settle();
    expect_row("dump crc digits", 14, "crc32  0123ABCD               ");

    // A completed self test reaches the same state, and dump_crc32 never saw
    // A failure says what happened in words. "err 5" on its own sends the
    // reader to find a table; the code is kept beside the sentence, not
    // instead of it.
    dump_state = 2'd3;
    dump_err   = 3'd5;
    settle();
    expect_row("dump failed", 10, "DUMP FAILED  err 5            ");
    expect_row("dump failed", 12, "card full or write locked     ");

    dump_err = 3'd4;
    settle();
    expect_row("dump failed", 10, "DUMP FAILED  err 4            ");
    expect_row("dump failed", 12, "APF malformed file path       ");

    dump_err = 3'd7;
    settle();
    expect_row("dump cancelled", 12, "operation cancelled           ");

    // A command APF never answered, and which one. A stalled flush is not
    // the same news as a stalled open: the bytes are already at APF, because
    // every write returned success before it.
    dump_err = 3'd6;
    stall_at = 2'd1;
    settle();
    expect_row("stalled open", 12, "APF never answered the open   ");
    stall_at = 2'd3;
    settle();
    expect_row("stalled flush", 12, "written, but never flushed    ");
    stall_at = 2'd0;

    // And it clears when the next dump starts, rather than leaving the last
    // failure under a running bar.
    dump_state    = 2'd1;
    dump_progress = 8'h00;
    settle();
    expect_row("dump restarted", 10, "DUMPING                       ");
    expect_row("dump restarted", 11, "[----------------]            ");
    expect_row("dump restarted", 12, "ZELDA.gb                      ");

    // Back to idle, which is what a scan does now: core_top clears dump_state
    // on scan_start or a slot change, because holding it meant dumping one
    // cartridge, swapping to another and pressing A left the previous
    // cartridge's result under the new cartridge's title.
    //
    // Rows 13 and 14 matter most here and were not asserted before. Rows 10
    // to 12 merely go blank; 13 and 14 carry the verdict - "image checksum
    // ok" and a CRC32 - and a stale verdict about a cartridge that is no
    // longer in the slot is the one thing on this screen a person acts on.
    dump_state  = 2'd0;
    sum_checked = 1'b1;      // deliberately still asserted: the gate is the
                             // state, not this, and that is what is tested
    settle();
    expect_row("dump idle", 10, "                              ");
    expect_row("dump idle", 11, "                              ");
    expect_row("dump idle", 12, "                              ");
    expect_row("no stale verdict when idle", 13, "                              ");
    expect_row("no stale crc when idle", 14, "                              ");

    // ---- Saving ------------------------------------------------------------
    //
    // A save has no checksum, no logo and no length of its own, so every check
    // that makes a ROM dump trustworthy is missing. Row 13 carries what there
    // is instead: whether the RAM answered at all, and whether what came back
    // is blank. Row 15 carries the first four bytes, which is the difference
    // between "it failed" and "it failed this way".

    // Y appears only when the cartridge in the slot has a save this core can
    // read. dump_ready alone is not enough - most cartridges have no save RAM
    // at all - and a button that is silently inert is worse than one that is
    // visibly absent.
    dump_ready = 1'b1;
    save_ready = 1'b0;
    settle();
    expect_row("no save offered", 18, "A scan  X dump                ");
    save_ready = 1'b1;
    settle();
    expect_row("save offered", 18, "A scan  X dump  Y save        ");

    // A cartridge with a save this core cannot read says so. Silence is what
    // the first hardware attempt got: a 32 KB MBC5 cartridge, no Y in the
    // help row, no reason, and nothing on screen to distinguish it from a
    // cartridge with no save at all.
    save_ready   = 1'b0;
    save_refused = 1'b1;
    settle();
    expect_row("save refused", 15, "save RAM here is not supported");
    expect_row("no Y when refused", 18, "A scan  X dump                ");
    save_refused = 1'b0;
    save_ready   = 1'b1;
    settle();
    expect_row("nothing to explain", 15, "                              ");

    // A save that read cleanly.
    save_shown     = 1'b1;
    save_responded = 1'b1;
    save_blank_ff  = 1'b0;
    save_blank_00  = 1'b0;
    save_first     = 32'h4A6F6E21;
    dump_state     = 2'd1;
    settle();
    dump_state     = 2'd2;
    settle();
    expect_row("save ok", 13, "save RAM answered             ");
    expect_row("save first bytes", 15, "first  4A6F6E21               ");

    // The blank-file trap, and the reason the presence probe exists. If the
    // RAM enable does not take, every read is open bus and the result is 8 KB
    // of 0xFF that looks exactly like a good backup of a dead battery. "Did
    // not answer" outranks "blank" because a save that was never read is not
    // a blank save, and the shout is deliberate: that file is probably
    // worthless, where a genuinely blank one may be perfectly good.
    save_responded = 1'b0;
    save_blank_ff  = 1'b1;
    save_first     = 32'hFFFFFFFF;
    dump_state     = 2'd1;
    settle();
    dump_state     = 2'd2;
    settle();
    expect_row("save did not answer", 13, "SAVE RAM DID NOT ANSWER       ");
    expect_row("save first bytes", 15, "first  FFFFFFFF               ");

    // A cartridge whose battery has died, with the enable working. Reported
    // rather than refused: it is information the user wants, not an error.
    save_responded = 1'b1;
    dump_state     = 2'd1;
    settle();
    dump_state     = 2'd2;
    settle();
    expect_row("save blank FF", 13, "save is blank, every byte FF  ");

    save_blank_ff = 1'b0;
    save_blank_00 = 1'b1;
    save_first    = 32'h00000000;
    dump_state    = 2'd1;
    settle();
    dump_state    = 2'd2;
    settle();
    expect_row("save blank 00", 13, "save is blank, every byte 00  ");

    // A ROM dump after a save must not inherit the save's report, and a save
    // must not inherit the ROM's checksum verdict. core_top latches which
    // kind the last dump was alongside dump_state; this is the screen half of
    // that promise.
    save_shown  = 1'b0;
    sum_checked = 1'b1;
    sum_ok      = 1'b1;
    dump_state  = 2'd1;
    settle();
    dump_state  = 2'd2;
    settle();
    expect_row("rom verdict after a save", 13, "image checksum ok             ");
    expect_row("no save bytes after a rom dump", 15, "                              ");

    // And neither survives going idle.
    dump_state = 2'd0;
    save_shown = 1'b1;
    settle();
    expect_row("no stale save verdict", 13, "                              ");
    expect_row("no stale save bytes", 15, "                              ");

    // Diagnostic rows retain all count/address bits. A successful file write
    // with unstable reads still reports the mismatch, not a verified ROM.
    valid = 1; scanning = 0; platform = 3'd2; save_shown = 0;
    pair_checked = 1;
    pair_mismatches = 24'hEF1234;
    pair_even = 24'h123456; pair_odd = 24'hDCDDDE;
    pair_first_addr = 23'h7FC08B;
    pair_first_a = 8'h12; pair_first_b = 8'hE3;
    dump_state = 2'd1;
    settle();
    expect_row("no partial pair count", 15, "                              ");
    dump_state = 2'd2;
    settle();
    expect_row("pair count", 15, "READ DIFF EF1234 (HEX)        ");
    expect_row("pair parity", 16, "EVEN 123456 ODD DCDDDE        ");
    expect_row("first pair", 17, "FIRST 1FF:008B 12/E3          ");
    expect_row("crc retained", 14, dut.ROW_CRC);
    dump_state = 2'd3;
    settle();
    expect_row("no failed pair verdict", 15, "                              ");
    expect_row("no failed pair address", 17, "                              ");

    pair_mismatches = 0; pair_even = 0; pair_odd = 0;
    dump_state = 2'd2;
    settle();
    expect_row("stable reads", 15, "PAIRED READS AGREE            ");
    expect_first(15, "P");
    expect_row("stable counts", 16, "EVEN 000000 ODD 000000        ");
    expect_row("no stale first mismatch", 17, "                              ");

    save_shown = 1;
    settle();
    expect_row("save hides rom parity", 16, "                              ");
    expect_row("save hides rom address", 17, "                              ");
    save_shown = 0; platform = 3'd1;
    settle();
    expect_row("gba hides pairs", 15, "                              ");
    platform = 3'd2; pair_checked = 0;
    settle();
    expect_row("unchecked hides pairs", 15, "                              ");
    pair_checked = 1; dump_state = 2'd0;
    settle();
    expect_row("idle hides pairs", 16, "                              ");
    dump_state = 2'd2; scanning = 1;
    settle();
    expect_row("rescan hides pairs", 15, "                              ");

    scanning=0; dump_state=0; platform=3'd6; answered_gba=2'd2;
    gg_product=20'h12345; gg_version=4'h1; gg_region=4'h6;
    gg_header_addr=16'h7FF0;
    gg_header=128'h60104523_00005AA5_41474553_20524D54;
    id_seq=id_seq+1;
    settle();
    expect_row("GG message",2,"GAME GEAR CARTRIDGE           ");
    expect_row("GG product",4,"PRODUCT 12345  REV 1          ");
    expect_row("GG header",8,"HDR0 544D522053454741         ");
    expect_row("GG selected size",6,"ROM 256 KB (MANUAL)           ");
    expect_row("GG size controls",16,"LEFT 256 KB   RIGHT 512 KB    ");
    expect_row("GG save exclusion",17,"ROM ONLY; SAVE NOT SUPPORTED  ");
    expect_first(16, "L");
    expect_first(17, "R");
    dump_ready=0;
    settle();
    expect_row("GG controls wait for ready",16,"                              ");
    dump_ready=1;
    gg_size_512=1; id_seq=id_seq+1;
    settle();
    expect_row("GG explicit size",6,"ROM 512 KB (MANUAL)           ");
    // A malformed APF path is a transport error, before any reread verdict.
    // Check the complete row, including the final 'h' and trailing padding.
    dump_state=3; dump_err=4; gg_verify_checked=0;
    settle();
    expect_row("GG malformed path code",10,"DUMP FAILED  err 4            ");
    expect_row("GG malformed path",12,"APF malformed file path       ");
    expect_first(12, "A");
    dump_state=2; gg_verify_checked=1; gg_verify_ok=1;
    settle();
    expect_row("GG reread",13,"SELECTED RANGE CRC AGREES     ");
    expect_first(13, "S");
    dump_state=3; gg_verify_ok=0;
    settle();
    expect_row("GG mismatch",12,"SELECTED RANGE CRC MISMATCH   ");
    expect_first(12, "S");
    platform=3'd4; dump_state=0; id_seq=id_seq+1;
    settle();
    expect_row("GG unstable reason",2,"UNSTABLE: GG HEADER           ");
    expect_row("GG unstable detail",7,"HEADER READS UNSTABLE         ");
    expect_first(7, "H");

    // Raw response bytes remain useful after a failed probe. They must not
    // become a product, region, or available capture size on that screen.
    gg_product=20'hFFFFF; gg_region=4'hF; gg_version=4'hF;
    gg_header={128{1'b1}}; dump_ready=0;
    for (r=0; r<4; r=r+1) begin
        case (r)
            0: platform=3'd0;  // absent
            1: platform=3'd3;  // unknown header
            2: platform=3'd4;  // unstable
            3: platform=3'd5;  // no power
        endcase
        id_seq=id_seq+1;
        settle();
        expect_row("GG failure has no product",4,"                              ");
        expect_row("GG failure has no region",5,"                              ");
        expect_row("GG failure has no size",6,"                              ");
        expect_row("GG failure has no controls",16,"                              ");
        expect_row("GG failure retains raw bytes",8,"HDR0 FFFFFFFFFFFFFFFF         ");
    end

    // A raw report must repaint even without any cartridge probe completing.
    scanning=0; valid=0; dump_state=0; adapter_diagnostic=1;
    settle();
    expect_row("adapter title", 0, "CART ADAPTER DIAGNOSTIC   0000");
    expect_first(0, "C");
    expect_row("adapter waiting", 2, "WAITING FOR APF REPORT        ");
    adapter_report=32'hA501B203; adapter_valid=1; adapter_seq=1;
    settle();
    expect_row("adapter raw", 4, "RAW  A501B203                 ");
    expect_row("adapter id", 6, "ADAPTER ID 03                 ");
    expect_row("adapter flags", 8, "PLAY 1  POWER 1               ");
    expect_row("adapter idle", 11, "CARTRIDGE BUS HELD IDLE       ");
    dump_state=3; dump_progress=8'hFF;
    settle();
    expect_row("adapter hides failed dump",11,"CARTRIDGE BUS HELD IDLE       ");
    dump_state=1; out_name_valid=1; out_name="OLDNAME         "; out_name_len=7;
    settle();
    expect_row("adapter hides stale filename",12,"                              ");

    adapter_report=32'h01010001; adapter_seq=2;
    settle();
    expect_row("adapter changed", 6, "ADAPTER ID 01                 ");

    if (errors != 0) begin
        $display("tb_ui_screen: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_ui_screen");
    $finish;
end

initial begin
    #5000000;
    $display("ERROR: tb_ui_screen timed out");
    $fatal(1);
end

endmodule

`default_nettype wire
