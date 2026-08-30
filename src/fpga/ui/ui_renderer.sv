//
// ui_renderer.sv - text layer painter for the CartTools utility display
//
// Turns a 30x20 character buffer into the 240x160 framebuffer that
// video_adapter.sv scans out. This is the whole display path of the core:
// there is no emulator behind it, so the renderer simply owns the
// framebuffer write port outright.
//
// Clocking:
//   clk (= clk_sys, ~100.66 MHz). clk_vid and the raster scan belong to
//   video_adapter and are not this module's business.
//
// Refresh:
//   The pixel counter free-runs. Every clk cycle produces one framebuffer
//   write, so a full 38400 pixel pass takes 38400 cycles, about 382 us, or
//   roughly 43 passes per displayed frame. Nothing needs to synchronise with
//   it: a caller writes the text buffer whenever it likes and the change
//   appears within one pass. A cell changed mid-pass shows the old glyph on
//   the rows already painted and the new one below, for well under a frame.
//   That is invisible and is why there is no double buffer or vsync handshake.
//
// Pipeline (3 stages, one framebuffer write per cycle once filled):
//   S0  pixel counter; drives the text buffer read address
//   S1  text buffer output valid; drives the font ROM address
//   S2  font ROM output valid; pick the pixel out of the glyph row
//   S3  registered pixel_addr / pixel_data / pixel_we to video_adapter
//
// Geometry:
//   240 / 8 = 30 columns, 160 / 8 = 20 rows, 600 cells.
//   Character cell   = {row[7:3], col[7:3]}
//   Position in cell = {row[2:0], col[2:0]}
//
// Attributes:
//   0  normal    foreground glyph on background
//   1  inverse   background glyph on foreground (swapped)
//   2  dim       foreground halved, on background
//   3  reserved  currently rendered as normal
//
// Characters outside 0x20..0x7E are blanked. The font ROM only holds
// 0x20..0x7E, so the address is forced to the space glyph and the pixel is
// gated off as well; the ROM is never read out of range.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module ui_renderer #(
    parameter H_ACTIVE = 240,
    parameter V_ACTIVE = 160,
    parameter COLS     = 30,                        // H_ACTIVE / 8
    parameter ROWS     = 20,                        // V_ACTIVE / 8
    parameter PIXELS   = H_ACTIVE * V_ACTIVE        // 38400
) (
    input  wire        clk,              // clk_sys
    input  wire        reset,            // Active high, hold until PLL locked

    // Palette (clk domain, treat as static). 18-bit {R[5:0], G[5:0], B[5:0]},
    // the same packing video_adapter expects on pixel_data.
    input  wire [17:0] color_fg,
    input  wire [17:0] color_bg,

    // Text buffer write port, passed straight through to ui_textbuf
    input  wire [9:0]  tb_addr,          // row * COLS + col, 0..599
    input  wire [7:0]  tb_char,          // ASCII
    input  wire [1:0]  tb_attr,          // 0 normal, 1 inverse, 2 dim, 3 reserved
    input  wire        tb_we,

    // video_adapter framebuffer write port (clk_sys domain)
    output reg  [15:0] pixel_addr,       // 0..38399, linear row * 240 + col
    output reg  [17:0] pixel_data,       // {R[5:0], G[5:0], B[5:0]}
    output reg         pixel_we
);

    // === S0: free-running pixel counter ===
    // col/row and the linear address are kept in step rather than multiplied
    // out, which keeps the address path to an adder.
    reg [7:0]  col;          // 0..239
    reg [7:0]  row;          // 0..159
    reg [15:0] pix_addr;     // 0..38399
    reg        valid_s0;

    always @(posedge clk) begin
        if (reset) begin
            col      <= 8'd0;
            row      <= 8'd0;
            pix_addr <= 16'd0;
            valid_s0 <= 1'b0;
        end else begin
            valid_s0 <= 1'b1;

            if (col == H_ACTIVE - 1) begin
                col <= 8'd0;
                row <= (row == V_ACTIVE - 1) ? 8'd0 : (row + 8'd1);
            end else begin
                col <= col + 8'd1;
            end

            pix_addr <= (pix_addr == PIXELS - 1) ? 16'd0 : (pix_addr + 16'd1);
        end
    end

    // Character cell containing the pixel the counter is currently on.
    wire [4:0] cell_col = col[7:3];
    wire [4:0] cell_row = row[7:3];
    wire [9:0] cell_addr = cell_row * COLS + cell_col;    // 0..599

    // === Text buffer ===
    wire [7:0] cell_char;
    wire [1:0] cell_attr;

    ui_textbuf #(
        .COLS (COLS),
        .ROWS (ROWS)
    ) textbuf (
        .clk     (clk),
        .tb_addr (tb_addr),
        .tb_char (tb_char),
        .tb_attr (tb_attr),
        .tb_we   (tb_we),
        .rd_addr (cell_addr),
        .rd_char (cell_char),
        .rd_attr (cell_attr)
    );

    // === S1: text buffer output valid, address the font ROM ===
    reg [2:0]  glyph_row_s1;
    reg [2:0]  glyph_col_s1;
    reg [15:0] pix_addr_s1;
    reg        valid_s1;

    always @(posedge clk) begin
        if (reset) begin
            glyph_row_s1 <= 3'd0;
            glyph_col_s1 <= 3'd0;
            pix_addr_s1  <= 16'd0;
            valid_s1     <= 1'b0;
        end else begin
            glyph_row_s1 <= row[2:0];
            glyph_col_s1 <= col[2:0];
            pix_addr_s1  <= pix_addr;
            valid_s1     <= valid_s0;
        end
    end

    // Printable window check. Anything else renders as a space: the ROM index
    // is forced to glyph 0 so the read stays in range, and the pixel is gated
    // off at S2 as well.
    wire in_range = (cell_char >= 8'h20) && (cell_char <= 8'h7E);

    wire [6:0] glyph_index = cell_char[6:0] - 7'h20;               // 0..94
    wire [9:0] font_addr   = in_range ? ({glyph_index, 3'b000} + {7'd0, glyph_row_s1})
                                      : 10'd0;                     // 0..759

    // === Font ROM ===
    // src/fpga/ui/ui_font.vh is generated by tools/font/make_font.py and
    // checked in, so the Quartus build never needs Python, a $readmemh, or an
    // external .mif. Read latency is one cycle, which is the S1 to S2 step.
    wire [7:0] font_q;

    ui_font_rom font (
        .clk  (clk),
        .addr (font_addr),
        .q    (font_q)
    );

    // === S2: font row valid, pick the pixel ===
    reg [2:0]  glyph_col_s2;
    reg [15:0] pix_addr_s2;
    reg [1:0]  attr_s2;
    reg        in_range_s2;
    reg        valid_s2;

    always @(posedge clk) begin
        if (reset) begin
            glyph_col_s2 <= 3'd0;
            pix_addr_s2  <= 16'd0;
            attr_s2      <= 2'd0;
            in_range_s2  <= 1'b0;
            valid_s2     <= 1'b0;
        end else begin
            glyph_col_s2 <= glyph_col_s1;
            pix_addr_s2  <= pix_addr_s1;
            attr_s2      <= cell_attr;
            in_range_s2  <= in_range;
            valid_s2     <= valid_s1;
        end
    end

    // Bit 0 of a font row byte is the leftmost column, matching ui_font.vh.
    wire glyph_pixel = in_range_s2 & font_q[glyph_col_s2];

    // Dim is the foreground with every channel halved. Cheap, and it stays
    // correct whatever palette the caller supplies.
    wire [17:0] color_dim = {1'b0, color_fg[17:13],
                             1'b0, color_fg[11:7],
                             1'b0, color_fg[5:1]};

    reg [17:0] pixel_next;
    always @(*) begin
        case (attr_s2)
            2'd1:    pixel_next = glyph_pixel ? color_bg  : color_fg;  // inverse
            2'd2:    pixel_next = glyph_pixel ? color_dim : color_bg;  // dim
            default: pixel_next = glyph_pixel ? color_fg  : color_bg;  // normal, reserved
        endcase
    end

    // === S3: registered output to video_adapter ===
    always @(posedge clk) begin
        if (reset) begin
            pixel_addr <= 16'd0;
            pixel_data <= 18'd0;
            pixel_we   <= 1'b0;
        end else begin
            pixel_addr <= pix_addr_s2;
            pixel_data <= pixel_next;
            pixel_we   <= valid_s2;
        end
    end

endmodule

`default_nettype wire
