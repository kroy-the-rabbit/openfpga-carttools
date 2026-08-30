// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_buffer.sv - the one chunk of a dump that is addressable at a time
//
// Bytes arrive one at a time on the cartridge clock and leave as 32-bit words
// on the bridge clock, so this is the clock crossing for the payload as well
// as its buffer. It is a plain simple-dual-port RAM: written only from
// wr_clk, read only from rd_clk, never both at the same address, because the
// producer fills the whole chunk before it says so and the consumer reads the
// whole chunk before asking for another. The handshake that guarantees that
// is in dump_engine; there is no flag or FIFO here to enforce it.
//
// BYTE ORDER, and why it is a runtime input rather than a decision
// ----------------------------------------------------------------
// Four cartridge bytes have to be packed into one bridge word, and which end
// they go in is not derivable from anything in this tree. The two swaps that
// exist, one in io_bridge_peripheral.v and one in core_bridge_cmd.v, cancel,
// so the only in-tree evidence is that a plain 32-bit number written to the
// datatable is read back by APF as that number. Whether APF then treats a
// span of slot payload as little-endian bytes within each of those words is
// the question, and the donor's data_loader and data_unloader, which would
// have answered it, were stripped before this repo was cut.
//
// Guessing costs a Quartus run per guess. So byte_order is an input, the UI
// can flip it, and one hardware session settles it: dump the self-test ramp
// and look at whether the file counts up or counts 03 02 01 00 07 06 05 04.
//
//   byte_order 0   first byte of the chunk in bits [31:24]
//   byte_order 1   first byte of the chunk in bits [7:0]     (the answer)
//
// 1, and measured rather than reasoned. The first dump that reached the card
// came out with every group of four reversed against byte_order 0, so APF
// takes byte 0 of a read from the low byte of the word.
//
// Note that this is the opposite of the direction APF writes in: its reply to
// 0x0190 put the first character of a path in the high byte. Reads and writes
// are not symmetric across this bridge. Reasoning from one to the other is
// what produced the wrong answer here, twice.
//

module dump_buffer #(
    parameter integer WORDS = 1024,          // 4096 bytes
    parameter integer AW    = 10
) (
    // --- write side, clk_sys ---
    input  wire            wr_clk,
    input  wire            wr_rst,           // restart at word 0, byte lane 0
    input  wire            wr_en,            // one byte
    input  wire [7:0]      wr_data,
    input  wire            wr_flush,         // commit a partial trailing word
    input  wire            byte_order,       // latched by the caller, see above

    // --- read side, clk_74a ---
    input  wire            rd_clk,
    input  wire [AW-1:0]   rd_addr,
    output reg  [31:0]     rd_q
);

reg [31:0]   mem [0:WORDS-1];

reg [1:0]    lane;
reg [31:0]   pack;
reg [AW-1:0] wa;

// The byte arriving this cycle, merged into the word being built. Needed
// combinationally because the fourth byte both completes the word and is
// written in the same cycle.
wire [31:0] next_pack =
    byte_order ?
        ((lane == 2'd0) ? {pack[31:8],  wr_data}               :
         (lane == 2'd1) ? {pack[31:16], wr_data, pack[7:0]}    :
         (lane == 2'd2) ? {pack[31:24], wr_data, pack[15:0]}   :
                          {wr_data,     pack[23:0]})
      : ((lane == 2'd0) ? {wr_data,     pack[23:0]}            :
         (lane == 2'd1) ? {pack[31:24], wr_data, pack[15:0]}   :
         (lane == 2'd2) ? {pack[31:16], wr_data, pack[7:0]}    :
                          {pack[31:8],  wr_data});

// A partial word is zero filled. It only happens on a chunk whose length is
// not a multiple of four, which a cartridge dump never is, but the self-test
// pattern can be and a future GBA odd-tail could be.
reg          mem_we;
reg [AW-1:0] mem_wa;
reg [31:0]   mem_wd;

always @(*) begin
    mem_we = 1'b0;
    mem_wa = wa;
    mem_wd = next_pack;
    if (wr_en) begin
        if (lane == 2'd3) mem_we = 1'b1;
    end else if (wr_flush && lane != 2'd0) begin
        mem_we = 1'b1;
        mem_wd = pack;
    end
end

// Kept on its own so Quartus sees a clean single-write-port RAM and infers
// M10K rather than building it out of registers.
always @(posedge wr_clk) begin
    if (mem_we) mem[mem_wa] <= mem_wd;
end

always @(posedge wr_clk) begin
    if (wr_rst) begin
        lane <= 2'd0;
        pack <= 32'd0;
        wa   <= {AW{1'b0}};
    end else if (wr_en) begin
        lane <= lane + 2'd1;
        pack <= next_pack;
        if (lane == 2'd3) begin
            wa   <= wa + {{(AW-1){1'b0}}, 1'b1};
            pack <= 32'd0;
        end
    end else if (wr_flush && lane != 2'd0) begin
        lane <= 2'd0;
        pack <= 32'd0;
        wa   <= wa + {{(AW-1){1'b0}}, 1'b1};
    end
end

always @(posedge rd_clk) begin
    rd_q <= mem[rd_addr];
end

endmodule

`default_nettype wire
