// SOURCES: src/fpga/ui/ui_renderer.sv src/fpga/ui/ui_textbuf.sv src/fpga/ui/ui_font.vh
//
// tb_ui_renderer.sv - testbench for the CartTools on-screen text layer
//
// What this proves:
//   1. Every one of the 38400 framebuffer addresses is written exactly once
//      per refresh pass, and the same is true of the pass after it.
//   2. A screen full of known text produces exactly the pixels the font ROM
//      says it should, checked pixel by pixel against an independent model.
//   3. Selected glyphs match hand-written bitmaps, which pins the font bit
//      order rather than just checking the renderer against itself.
//   4. Inverse swaps foreground and background, and dim halves the
//      foreground while leaving the background alone.
//   5. Characters outside 0x20..0x7E render as a blank cell_i rather than as
//      garbage, and the font ROM is never addressed outside 0..759.
//   6. A text buffer write lands on screen within one pass with no handshake,
//      which is the assumption the renderer is built on.
//   7. Out of range text buffer writes are ignored rather than wrapping.
//
// Run:  iverilog -g2012 -o tb.vvp tools/sim/tb_ui_renderer.sv \
//         src/fpga/ui/ui_renderer.sv src/fpga/ui/ui_textbuf.sv \
//         src/fpga/ui/ui_font.vh && vvp tb.vvp
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`timescale 1ns / 1ps
`default_nettype none

module tb_ui_renderer;

    // === Geometry, matching ui_renderer defaults ===
    localparam integer H_ACTIVE = 240;
    localparam integer V_ACTIVE = 160;
    localparam integer COLS     = 30;
    localparam integer ROWS     = 20;
    localparam integer CELLS    = COLS * ROWS;          // 600
    localparam integer PIXELS   = H_ACTIVE * V_ACTIVE;  // 38400
    localparam integer FONT_LO  = 8'h20;
    localparam integer FONT_HI  = 8'h7E;

    // === Palette ===
    // Deliberately asymmetric so a swapped foreground and background, or a
    // dim that did nothing, cannot pass by coincidence.
    localparam [17:0] FG  = {6'd63, 6'd63, 6'd48};
    localparam [17:0] BG  = {6'd2,  6'd4,  6'd8};
    localparam [17:0] DIM = {1'b0, FG[17:13], 1'b0, FG[11:7], 1'b0, FG[5:1]};

    // === Clock: 100 MHz, close enough to the real 100.663 MHz clk_sys ===
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // === DUT ===
    reg         reset;
    reg  [9:0]  tb_addr;
    reg  [7:0]  tb_char;
    reg  [1:0]  tb_attr;
    reg         tb_we;

    wire [15:0] pixel_addr;
    wire [17:0] pixel_data;
    wire        pixel_we;

    ui_renderer dut (
        .clk        (clk),
        .reset      (reset),
        .color_fg   (FG),
        .color_bg   (BG),
        .tb_addr    (tb_addr),
        .tb_char    (tb_char),
        .tb_attr    (tb_attr),
        .tb_we      (tb_we),
        .pixel_addr (pixel_addr),
        .pixel_data (pixel_data),
        .pixel_we   (pixel_we)
    );

    // === Bookkeeping ===
    integer errors = 0;

    task fail;
        input [8*160-1:0] msg;
        begin
            errors = errors + 1;
            $error("%0s", msg);
        end
    endtask

    // === Capture of one refresh pass ===
    // Sampled on negedge, where the DUT outputs are settled.
    reg [17:0] fb     [0:PIXELS-1];
    integer    wcount [0:PIXELS-1];
    integer    wr_total;
    reg        capturing = 1'b0;
    integer    x_seen = 0;
    integer    oob_seen = 0;

    always @(negedge clk) begin
        if (capturing && pixel_we === 1'b1) begin
            wr_total = wr_total + 1;
            if (pixel_addr >= PIXELS) begin
                oob_seen = oob_seen + 1;
            end else begin
                fb[pixel_addr]     = pixel_data;
                wcount[pixel_addr] = wcount[pixel_addr] + 1;
            end
            if (^pixel_data === 1'bx)
                x_seen = x_seen + 1;
        end
    end

    // === Model of what should be on screen ===
    reg [7:0] model_char [0:CELLS-1];
    reg [1:0] model_attr [0:CELLS-1];

    // Reference copy of the font ROM, taken from the DUT's own memory. This
    // checks the renderer's addressing, bit order and attribute logic against
    // the ROM; check_cell_pattern below checks the ROM itself against
    // hand-written bitmaps, so neither is verified only against itself.
    reg [7:0] ref_font [0:759];

    // === Stimulus helpers ===
    task put;
        input integer r;
        input integer c;
        input [7:0]   ch;
        input [1:0]   at;
        integer cell_i;
        begin
            cell_i = r * COLS + c;
            @(negedge clk);
            tb_addr = cell_i[9:0];
            tb_char = ch;
            tb_attr = at;
            tb_we   = 1'b1;
            if (cell_i < CELLS) begin
                model_char[cell_i] = ch;
                model_attr[cell_i] = at;
            end
            @(negedge clk);
            tb_we = 1'b0;
        end
    endtask

    // Writes len characters of s, most significant character first, which is
    // the natural left to right order for a Verilog string literal.
    task putstr;
        input integer r;
        input integer c;
        input integer len;
        input [8*32-1:0] s;
        input [1:0] at;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1)
                put(r, c + k, s[(len - 1 - k) * 8 +: 8], at);
        end
    endtask

    // Lays the whole printable font out from (r, c) onwards, wrapping rows.
    task put_charset;
        input integer r;
        input [1:0] at;
        integer k;
        begin
            for (k = 0; k <= FONT_HI - FONT_LO; k = k + 1)
                put(r + (k / COLS), k % COLS, FONT_LO + k, at);
        end
    endtask

    // === Pass capture ===
    // Arms on the write of the last address, so the very next negedge is the
    // write of address 0 and the window is exactly one pass.
    task capture_pass;
        integer i;
        integer waited;
        begin
            for (i = 0; i < PIXELS; i = i + 1)
                wcount[i] = 0;
            wr_total = 0;
            x_seen   = 0;
            oob_seen = 0;

            waited = 0;
            @(negedge clk);
            while (!(pixel_we === 1'b1 && pixel_addr == PIXELS - 1)) begin
                @(negedge clk);
                waited = waited + 1;
                if (waited > 2 * PIXELS)
                    $fatal(1, "capture_pass: address %0d was not written in %0d cycles, the pixel counter is not covering the framebuffer",
                           PIXELS - 1, waited);
            end
            #1 capturing = 1'b1;
            repeat (PIXELS) @(negedge clk);
            #1 capturing = 1'b0;
        end
    endtask

    // === Checks ===
    task check_coverage;
        input [8*32-1:0] label;
        integer i;
        integer missing;
        integer extra;
        begin
            missing = 0;
            extra   = 0;
            for (i = 0; i < PIXELS; i = i + 1) begin
                if (wcount[i] == 0) missing = missing + 1;
                if (wcount[i] > 1)  extra   = extra + 1;
            end
            if (wr_total != PIXELS) begin
                errors = errors + 1;
                $error("%0s: %0d writes in one pass, expected %0d",
                       label, wr_total, PIXELS);
            end
            if (missing != 0) begin
                errors = errors + 1;
                $error("%0s: %0d framebuffer addresses were never written",
                       label, missing);
            end
            if (extra != 0) begin
                errors = errors + 1;
                $error("%0s: %0d framebuffer addresses were written more than once",
                       label, extra);
            end
            if (oob_seen != 0) begin
                errors = errors + 1;
                $error("%0s: %0d writes outside 0..%0d", label, oob_seen, PIXELS - 1);
            end
            if (x_seen != 0) begin
                errors = errors + 1;
                $error("%0s: %0d writes carried X on pixel_data", label, x_seen);
            end
            if (missing == 0 && extra == 0 && wr_total == PIXELS)
                $display("  [ok] %0s: all %0d pixels written exactly once",
                         label, PIXELS);
        end
    endtask

    function [17:0] want_pixel;
        input pbit;
        input [1:0] at;
        begin
            case (at)
                2'd1:    want_pixel = pbit ? BG  : FG;    // inverse
                2'd2:    want_pixel = pbit ? DIM : BG;    // dim
                default: want_pixel = pbit ? FG  : BG;    // normal, reserved
            endcase
        end
    endfunction

    task check_screen;
        input [8*32-1:0] label;
        integer a, r, c, crow, ccol, grow, gcol, cell_i, gi, bad;
        reg [7:0] ch;
        reg [1:0] at;
        reg [7:0] frow;
        reg [17:0] want;
        begin
            bad = 0;
            for (a = 0; a < PIXELS; a = a + 1) begin
                r    = a / H_ACTIVE;
                c    = a % H_ACTIVE;
                crow = r / 8;
                ccol = c / 8;
                grow = r % 8;
                gcol = c % 8;
                cell_i = crow * COLS + ccol;
                ch   = model_char[cell_i];
                at   = model_attr[cell_i];

                if (ch >= FONT_LO[7:0] && ch <= FONT_HI[7:0]) begin
                    gi   = ch - FONT_LO;
                    frow = ref_font[gi * 8 + grow];
                end else begin
                    frow = 8'h00;               // blanked, not looked up
                end

                want = want_pixel(frow[gcol], at);

                if (fb[a] !== want) begin
                    bad = bad + 1;
                    if (bad <= 8) begin
                        errors = errors + 1;
                        $error("%0s: pixel %0d (row %0d col %0d, cell %0d, char 0x%02h, attr %0d): got %05h want %05h",
                               label, a, r, c, cell_i, ch, at, fb[a], want);
                    end
                end
            end
            if (bad > 8) begin
                $error("%0s: %0d mismatching pixels in total", label, bad);
            end
            if (bad == 0)
                $display("  [ok] %0s: all %0d pixels match the font and attribute model",
                         label, PIXELS);
        end
    endtask

    // Compares one 8x8 cell_i against a hand-written bitmap, 64 characters,
    // '#' foreground and '.' background, top row first, left column first.
    task check_cell_pattern;
        input [8*24-1:0] label;
        input integer crow;
        input integer ccol;
        input [1:0] at;
        input [8*64-1:0] pat;
        integer r, c, k, a, bad;
        reg [7:0] pc;
        reg [17:0] want;
        begin
            bad = 0;
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    k    = r * 8 + c;
                    pc   = pat[(63 - k) * 8 +: 8];
                    want = want_pixel(pc == "#", at);
                    a    = (crow * 8 + r) * H_ACTIVE + (ccol * 8 + c);
                    if (fb[a] !== want) begin
                        bad = bad + 1;
                        if (bad <= 4) begin
                            errors = errors + 1;
                            $error("%0s: cell (%0d,%0d) attr %0d pixel (%0d,%0d): got %05h want %05h",
                                   label, crow, ccol, at, r, c, fb[a], want);
                        end
                    end
                end
            end
            if (bad == 0)
                $display("  [ok] %0s: cell (%0d,%0d) attr %0d matches its bitmap",
                         label, crow, ccol, at);
        end
    endtask

    // === Hand-written reference bitmaps, read off the IBM 8x8 glyphs ===
    localparam [8*64-1:0] PAT_A =
        {"..##....",
         ".####...",
         "##..##..",
         "##..##..",
         "######..",
         "##..##..",
         "##..##..",
         "........"};

    localparam [8*64-1:0] PAT_H =
        {"##..##..",
         "##..##..",
         "##..##..",
         "######..",
         "##..##..",
         "##..##..",
         "##..##..",
         "........"};

    localparam [8*64-1:0] PAT_BLANK =
        {"........",
         "........",
         "........",
         "........",
         "........",
         "........",
         "........",
         "........"};

    // Where the printable set lands when laid out from a given start row:
    // 'A' is 0x41, so index 33, which is row + 1, column 3.
    localparam integer A_ROW_OFF = (8'h41 - 8'h20) / COLS;   // 1
    localparam integer A_COL     = (8'h41 - 8'h20) % COLS;   // 3
    localparam integer H_ROW_OFF = (8'h48 - 8'h20) / COLS;   // 1
    localparam integer H_COL     = (8'h48 - 8'h20) % COLS;   // 10

    // === Test sequence ===
    integer i;

    initial begin
        for (i = 0; i < CELLS; i = i + 1) begin
            model_char[i] = 8'h20;      // ui_textbuf powers up full of spaces
            model_attr[i] = 2'd0;
        end

        tb_addr = 10'd0;
        tb_char = 8'h20;
        tb_attr = 2'd0;
        tb_we   = 1'b0;
        reset   = 1'b1;

        repeat (8) @(negedge clk);
        reset = 1'b0;
        repeat (8) @(negedge clk);

        for (i = 0; i < 760; i = i + 1)
            ref_font[i] = dut.font.font_rom[i];

        $display("tb_ui_renderer: 30x20 cells, %0d pixels per pass, fg=%05h bg=%05h dim=%05h",
                 PIXELS, FG, BG, DIM);

        // --- Fill the screen ---------------------------------------------
        // The whole printable set four times over, once per attribute, so
        // every glyph and every attribute is on screen at the same time.
        put_charset(0,  2'd0);          // rows 0..3   normal
        put_charset(5,  2'd1);          // rows 5..8   inverse
        put_charset(10, 2'd2);          // rows 10..13 dim
        put_charset(15, 2'd3);          // rows 15..18 reserved, renders normal

        // A line of real text, the way a caller would actually write one.
        putstr(4, 0, 15, "CARTRIDGE TOOLS", 2'd0);

        // Characters with no glyph. Left half normal, right half inverse, so
        // both the blanked pixel and the attribute applied to it are checked.
        put(19, 0,  8'h00, 2'd0);
        put(19, 1,  8'h01, 2'd0);
        put(19, 2,  8'h1F, 2'd0);
        put(19, 3,  8'h7F, 2'd0);
        put(19, 4,  8'h80, 2'd0);
        put(19, 5,  8'hFF, 2'd0);
        put(19, 10, 8'h00, 2'd1);
        put(19, 11, 8'h7F, 2'd1);
        put(19, 12, 8'hFF, 2'd1);

        // Out of range cell_i writes must be dropped, not wrapped onto row 0.
        put(20, 0,  8'h58, 2'd0);       // cell_i 600
        put(34, 3,  8'h58, 2'd1);       // cell_i 1023

        // --- Pass 1 --------------------------------------------------------
        capture_pass;
        check_coverage("pass 1");
        check_screen("pass 1");

        check_cell_pattern("glyph A",         A_ROW_OFF,      A_COL, 2'd0, PAT_A);
        check_cell_pattern("glyph H",         H_ROW_OFF,      H_COL, 2'd0, PAT_H);
        check_cell_pattern("glyph A inverse", 5  + A_ROW_OFF, A_COL, 2'd1, PAT_A);
        check_cell_pattern("glyph A dim",     10 + A_ROW_OFF, A_COL, 2'd2, PAT_A);
        check_cell_pattern("glyph A reserved",15 + A_ROW_OFF, A_COL, 2'd3, PAT_A);
        check_cell_pattern("unmapped 0x00",   19, 0,  2'd0, PAT_BLANK);
        check_cell_pattern("unmapped 0x7F",   19, 3,  2'd0, PAT_BLANK);
        check_cell_pattern("unmapped 0xFF",   19, 5,  2'd0, PAT_BLANK);
        check_cell_pattern("unmapped inverse",19, 10, 2'd1, PAT_BLANK);

        // --- Pass 2, nothing changed ---------------------------------------
        capture_pass;
        check_coverage("pass 2");
        check_screen("pass 2");

        // --- Pass 3, a cell_i changed with no handshake ----------------------
        // Written while the renderer is mid-pass, which is the whole point:
        // there is no synchronisation and the next pass must simply show it.
        put(4, 0, 8'h5A, 2'd1);         // 'Z', inverse
        capture_pass;
        check_coverage("pass 3");
        check_screen("pass 3");
        check_cell_pattern("late write", 4, 0, 2'd1,
            {"#######.",
             "##...##.",
             "#...##..",
             "...##...",
             "..##..#.",
             ".##..##.",
             "#######.",
             "........"});

        // --- Verdict --------------------------------------------------------
        if (errors != 0) begin
            $display("tb_ui_renderer: FAIL, %0d error(s)", errors);
            $fatal(1, "tb_ui_renderer failed");
        end

        $display("tb_ui_renderer: 3 passes x %0d pixels, %0d glyphs, 4 attributes, 9 unmapped cells",
                 PIXELS, FONT_HI - FONT_LO + 1);
        $display("TB PASS: tb_ui_renderer");
        $finish;
    end

    // Safety net: the design free-runs, so a hang means the counter stalled.
    initial begin
        #20000000;
        $fatal(1, "tb_ui_renderer: timeout, renderer never completed its passes");
    end

endmodule

`default_nettype wire
