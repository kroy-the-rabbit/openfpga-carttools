`default_nettype none

// A GBA EEPROM save, one 8-byte block at a time.
//
// Same shape as cart_save_gba, which reads SRAM and Flash a byte at a time
// through the save window. EEPROM is not in that window and is not addressable
// like memory: it is a serial chip in its own space that answers a request
// with a whole block. gba_eeprom_io does one block; this walks them and turns
// them into the byte stream the dump engine writes.
//
// It writes to the cartridge, and cart_save_gba does not. That is not a
// relaxation of the rule, it is the protocol: the address is clocked in a bit
// at a time and there is no other way to say which block is wanted. What is
// written is only ever a read request, 1 1 and an address and 0, and
// gba_eeprom_io cannot express a write command at all.
//
// SIZE COMES FROM THE PROBE, not from the ROM. gba_eeprom_probe settles 512
// against 8 KiB by asking the chip; nothing in the cartridge says. addr_bits
// has to be the width the probe found, because a chip given the wrong one does
// not answer.
module cart_save_gba_eeprom (
    input  wire        clk,
    input  wire        reset,

    // The connector's actual state. gba_eeprom_io needs it to abandon rather
    // than hang when the slot leaves GBA mode.
    input  wire        cart_mode,

    input  wire        start,          // pulse
    input  wire [31:0] size_bytes,     // 512 or 8192, from gba_eeprom_probe
    input  wire [3:0]  addr_bits,      // 6 or 14, from the same place

    output reg         busy,
    output reg         done,
    output wire [31:0] total_bytes,

    // What the read looked like, for the screen. On EEPROM a chip that is not
    // there reads all ones, the same as open bus, so blank_ff is the row that
    // carries "nothing answered" as well as "the save is empty".
    output reg         responded,
    output reg         blank_ff,
    output reg         blank_00,
    output reg  [31:0] first_word,

    // gba_cart_bus master port, passed through from gba_eeprom_io.
    output wire        bus_req,
    output wire        bus_wr,
    output wire [27:0] bus_addr,
    output wire [1:0]  bus_acc,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy,

    // Byte stream out. Held until taken.
    output reg  [7:0]  out_data,
    output reg         out_valid,
    input  wire        out_ready
);

// Straight through, so the caller sees the same number it supplied and the
// file header cannot disagree with the stream.
assign total_bytes = size_bytes;

reg         io_start;
reg  [13:0] io_block;
wire        io_busy, io_done;
wire [63:0] io_data;

gba_eeprom_io io (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (io_start), .flush (1'b0), .addr_bits (addr_bits),
    .block (io_block),
    .busy (io_busy), .done (io_done), .data (io_data),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
);

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_REQ  = 3'd1;
localparam [2:0] ST_WAIT = 3'd2;
localparam [2:0] ST_EMIT = 3'd3;
localparam [2:0] ST_DONE = 3'd4;

reg [2:0]  state;
reg [63:0] blk;
reg [2:0]  byte_idx;      // which of the eight, 0 first
reg [31:0] emitted;

wire [31:0] next_emitted = emitted + 32'd1;
wire        last_byte    = (next_emitted >= size_bytes);

always @(posedge clk) begin
    done     <= 1'b0;
    io_start <= 1'b0;

    if (reset) begin
        state      <= ST_IDLE;
        busy       <= 1'b0;
        out_valid  <= 1'b0;
        out_data   <= 8'd0;
        io_block   <= 14'd0;
        blk        <= 64'd0;
        byte_idx   <= 3'd0;
        emitted    <= 32'd0;
        responded  <= 1'b0;
        blank_ff   <= 1'b0;
        blank_00   <= 1'b0;
        first_word <= 32'd0;
    end else if (busy && !cart_mode) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        out_valid <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                if (start && size_bytes != 32'd0) begin
                    busy       <= 1'b1;
                    io_block   <= 14'd0;
                    emitted    <= 32'd0;
                    byte_idx   <= 3'd0;
                    blank_ff   <= 1'b1;
                    blank_00   <= 1'b1;
                    first_word <= 32'd0;
                    responded  <= 1'b0;
                    state      <= ST_REQ;
                end
            end

            ST_REQ: begin
                if (!io_busy) begin
                    io_start <= 1'b1;
                    state    <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                if (io_done) begin
                    blk       <= io_data;
                    byte_idx  <= 3'd0;
                    out_data  <= io_data[63:56];
                    out_valid <= 1'b1;
                    state     <= ST_EMIT;
                end
            end

            // Most significant byte of the block first, which is the order the
            // bits came off the chip.
            ST_EMIT: begin
                if (out_valid && out_ready) begin
                    // Evidence, taken on the byte actually handed over.
                    if (out_data !== 8'hFF) blank_ff <= 1'b0;
                    if (out_data !== 8'h00) blank_00 <= 1'b0;
                    if (emitted < 32'd4)
                        first_word <= {first_word[23:0], out_data};

                    if (last_byte) begin
                        out_valid <= 1'b0;
                        emitted   <= next_emitted;
                        state     <= ST_DONE;
                    end else if (byte_idx == 3'd7) begin
                        out_valid <= 1'b0;
                        emitted   <= next_emitted;
                        io_block  <= io_block + 14'd1;
                        state     <= ST_REQ;
                    end else begin
                        emitted  <= next_emitted;
                        byte_idx <= byte_idx + 3'd1;
                        blk      <= {blk[55:0], 8'd0};
                        out_data <= blk[55:48];
                    end
                end
            end

            ST_DONE: begin
                // Nothing on a GBA EEPROM gates the chip the way a GB RAM
                // enable does, so there is no independent way to tell a chip
                // that answered from one that did not. What can be said is
                // that the read ran to the end; blank_ff carries the rest.
                responded <= 1'b1;
                busy      <= 1'b0;
                done      <= 1'b1;
                state     <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
