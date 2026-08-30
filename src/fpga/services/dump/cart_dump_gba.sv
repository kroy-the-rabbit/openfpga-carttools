// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// cart_dump_gba.sv - read a whole Game Boy Advance ROM
//
// The GBA counterpart of cart_dump_gb.sv, and much smaller than it, because a
// GBA cartridge has no mapper. There are no bank registers, no window at
// 0x4000, no MBC1 bank hole: the ROM is flat from byte 0 and the whole module
// is an address counter feeding a byte stream. Nothing here writes to the
// cartridge, and there is no code path that could - bus_wr is tied low.
//
// Where the size comes from
// -------------------------
// From `size_bytes`, and from nowhere else. A GBA header has no ROM size
// field, so the size is probed on the bus by a separate module; guessing it
// here would put two different answers in the core. `size_bytes` must be held
// stable for the whole dump, exactly as cart_dump_gb needs rom_size_code held
// stable, because the loop bound is read live.
//
// Exactly `size_bytes` bytes are emitted. A size that is not a multiple of
// four stops part way through the last 32-bit read and the remaining bytes of
// that word are dropped rather than emitted, so the count downstream always
// matches the count in the APF file header. Real GBA mask ROMs are powers of
// two, so this only matters if a caller ever asks for a truncated image.
//
// Why 32-bit accesses
// -------------------
// acc = ACCESS_32BIT makes gba_cart_bus latch the address once and fetch the
// second halfword through ST_READ_SEQ, which is the cartridge's own burst
// path: one CS1# address phase, two RD# pulses. Two 16-bit reads would cost a
// second address phase for the same four bytes - 42 cycles against 48 - and
// would tell the cartridge to restart its internal counter every halfword.
// There is no ACCESS_32BIT constant in gba_cart_bus; it infers 32 bits from
// acc being neither of the two it names. The constant is declared here so the
// intent is written down rather than left as a bare 2'b10.
//
// Byte order
// ----------
// GBA ROM is little-endian. gba_cart_bus returns {second halfword, first
// halfword}, and within a halfword the byte at the even address is the low
// byte, so a read at A emits rdata[7:0], rdata[15:8], rdata[23:16],
// rdata[31:24] - which is simply the word emitted low byte first.
//
// LIMIT: 32 MiB. rom_word_addr in gba_cart_bus is latched_addr[24:1], 24 bits
// of halfword address, so the connector cannot be asked for a byte beyond
// 0x1FFFFFF. A size_bytes larger than that is not rejected here - it would
// need an error path this module has no way to report - but the reads past
// 32 MiB alias back to the start of the ROM and the tail of such a dump would
// be a mirror of its head. Nothing on the market is that large, and the size
// probe cannot return more, since 32 MiB is also its last candidate.
//
// Like cart_dump_gb, this module has no abort input: when it is waiting for a
// bus_done that is not coming - because the connector left GBA mode under it,
// say - reset is the only thing that recovers it. dump_engine holds the mode
// for the whole dump and drives reset on abort for exactly that reason.
//

module cart_dump_gba (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,          // pulse
    input  wire [31:0] size_bytes,     // from the size probe

    output reg         busy,
    output reg         done,
    output wire [31:0] total_bytes,

    // gba_cart_bus master port. The handshake rule is the one from
    // cart_identify_gba: that bus samples req only in its own idle state and
    // has no refuse guard, so wait for !bus_busy, raise req for one cycle,
    // drop it, then wait for done. Holding req until done issues a second
    // transaction nobody asked for.
    output reg         bus_req,
    output wire        bus_wr,
    output reg  [27:0] bus_addr,
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

// gba_cart_bus names ACCESS_8BIT and ACCESS_16BIT and treats everything else
// as 32 bits. 2'b10 is that "everything else".
localparam [1:0] ACCESS_32BIT = 2'b10;

// Read-only by construction. A ROM-space write could not pulse WR# anyway -
// cart_write_enable in gba_cart_bus requires eeprom, save or gpio space - but
// the request is never made in the first place.
assign bus_wr    = 1'b0;
assign bus_acc   = ACCESS_32BIT;
assign bus_wdata = 32'd0;

// Straight through, so the caller sees the same number it supplied and the
// file header cannot disagree with the stream.
assign total_bytes = size_bytes;

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_REQ  = 3'd1;
localparam [2:0] ST_WAIT = 3'd2;
localparam [2:0] ST_EMIT = 3'd3;
localparam [2:0] ST_DONE = 3'd4;

reg [2:0]  state;
reg [27:0] addr;        // byte address of the word being read, always word aligned
reg [31:0] emitted;     // bytes accepted by the consumer so far
reg [31:0] word;        // the 32 bits last read
reg [1:0]  bsel;        // which byte of `word` is on out_data

// >= rather than ==, so that a caller who breaks the rule above and shrinks
// size_bytes mid-dump gets a short dump instead of a module that counts past
// its target and runs for four billion bytes.
wire [31:0] next_emitted = emitted + 32'd1;
wire        last_byte    = (next_emitted >= size_bytes);

// Little-endian: byte 0 of the word is the byte at the lowest address, so
// selecting by index emits the four bytes in ascending address order. The
// bsel == 3 case never reaches this mux: that byte is the last of the word
// and is followed by a new read, not by another byte of this one.
wire [1:0] next_bsel = bsel + 2'd1;
wire [7:0] next_byte = (next_bsel == 2'd1) ? word[15:8]  :
                       (next_bsel == 2'd2) ? word[23:16] :
                                             word[31:24];

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        addr      <= 28'd0;
        emitted   <= 32'd0;
        word      <= 32'd0;
        bsel      <= 2'd0;
        out_valid <= 1'b0;
        out_data  <= 8'd0;
        bus_addr  <= 28'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                busy      <= 1'b0;
                out_valid <= 1'b0;
                if (start) begin
                    busy    <= 1'b1;
                    addr    <= 28'd0;
                    emitted <= 32'd0;
                    bsel    <= 2'd0;
                    // A zero-byte dump is a legitimate answer from a probe
                    // that found nothing. Finishing immediately is right;
                    // reading a word first and then dropping it would put a
                    // pointless transaction on a connector that may have no
                    // cartridge in it.
                    state   <= (size_bytes == 32'd0) ? ST_DONE : ST_REQ;
                end
            end

            ST_REQ: begin
                bus_addr <= addr;
                if (!bus_busy) begin
                    bus_req <= 1'b1;
                    state   <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                if (bus_done) begin
                    word      <= bus_rdata;
                    bsel      <= 2'd0;
                    out_data  <= bus_rdata[7:0];
                    out_valid <= 1'b1;
                    state     <= ST_EMIT;
                end
            end

            // out_data and out_valid change only when a byte is taken, so a
            // consumer that stalls for a thousand cycles sees the same byte
            // for a thousand cycles and takes it exactly once.
            ST_EMIT: begin
                if (out_ready) begin
                    emitted <= next_emitted;
                    if (last_byte) begin
                        out_valid <= 1'b0;
                        state     <= ST_DONE;
                    end else if (bsel == 2'd3) begin
                        out_valid <= 1'b0;
                        addr      <= addr + 28'd4;
                        state     <= ST_REQ;
                    end else begin
                        bsel     <= next_bsel;
                        out_data <= next_byte;
                    end
                end
            end

            ST_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
