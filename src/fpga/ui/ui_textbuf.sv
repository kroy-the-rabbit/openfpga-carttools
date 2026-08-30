//
// ui_textbuf.sv - character cell buffer for the CartTools on-screen text layer
//
// 30 columns x 20 rows = 600 cells, which is exactly the 240x160 framebuffer
// divided by the 8x8 font. One cell is 10 bits: {attr[1:0], char[7:0]}.
//
// Clocking:
//   Both ports live in clk_sys (~100.66 MHz). The renderer repaints the whole
//   screen in 38403 clk_sys cycles, about 382 us, so a writer never has to
//   wait for or synchronise with a repaint; a cell changed mid-pass is simply
//   picked up by the next one.
//
// Storage:
//   600 x 10 = 6000 bits, inferred as a simple dual-port M10K block. Written
//   as an array with a synchronous write port and a synchronous read port so
//   Quartus infers RAM rather than 600 cells' worth of registers.
//
// Power-on contents:
//   Every cell is initialised to a space with attribute 0, so the screen is
//   blank rather than random before the first write. Quartus turns the initial
//   block into the block's .mif; simulation gets the same contents.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module ui_textbuf #(
    parameter COLS  = 30,
    parameter ROWS  = 20,
    parameter CELLS = COLS * ROWS      // 600
) (
    input  wire        clk,            // clk_sys

    // Write port - whoever is putting text on screen
    input  wire [9:0]  tb_addr,        // row * COLS + col, 0..599
    input  wire [7:0]  tb_char,        // ASCII, 0x20..0x7E renders, else blank
    input  wire [1:0]  tb_attr,        // 0 normal, 1 inverse, 2 dim, 3 reserved
    input  wire        tb_we,

    // Read port - ui_renderer, one cycle of latency
    input  wire [9:0]  rd_addr,
    output wire [7:0]  rd_char,
    output wire [1:0]  rd_attr
);

    // === Cell storage ===
    // Packed as {attr, char} so the whole cell is one memory word and the
    // renderer cannot see a half-updated cell.
    reg [9:0] cells [0:CELLS-1];

    integer i;
    initial begin
        for (i = 0; i < CELLS; i = i + 1)
            cells[i] = {2'b00, 8'h20};   // attribute 0, space
    end

    // === Write port ===
    // Out of range addresses are ignored rather than wrapping, so a caller
    // that runs off the end of the last row cannot corrupt the top of screen.
    always @(posedge clk) begin
        if (tb_we && (tb_addr < CELLS))
            cells[tb_addr] <= {tb_attr, tb_char};
    end

    // === Read port ===
    reg [9:0] rd_q;
    always @(posedge clk) begin
        rd_q <= cells[rd_addr];
    end

    assign rd_char = rd_q[7:0];
    assign rd_attr = rd_q[9:8];

endmodule

`default_nettype wire
