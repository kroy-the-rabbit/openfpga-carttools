`default_nettype none

// One EEPROM block transfer: send a read request, collect the 64 bits back.
//
// GBA EEPROM is serial. It lives in its own space, addr[27:24] == 0xD, where
// gba_cart_bus asserts CS1# and holds it low across consecutive accesses. Each
// access carries one bit on AD0: a write sends a bit, a read returns one.
//
// A read of one 8-byte block is:
//
//     write  1 1                    read request
//     write  the block address      ADDR_BITS of it, most significant first
//     write  0                      terminator
//     read   4 bits                 discarded, the chip is turning round
//     read   64 bits                the block, most significant bit first
//
// ADDR_BITS is 6 on a 512 byte chip and 14 on an 8 KiB one, and nothing in the
// cartridge says which. The SDK string is EEPROM_V either way. See
// gba_eeprom_probe.sv for how that is settled.
//
// WHY THE FIRST TWO BITS ARE NOT A PARAMETER: the chip's write command is
// 1 0 followed by an address and 64 bits of data. The only thing separating a
// read from a write of whatever happens to be on the bus is that second bit,
// so it is a constant here and tb_gba_eeprom_io fails if a 1 0 prefix is ever
// emitted. This module cannot write to a cartridge and is not a base to build
// writing on.
//
// Bit counts were checked against the EEPROM implementation in Rai's
// gba_memorymux.vhd, which was written against a real cartridge: four bits
// discarded, then 64, one byte every eight, most significant bit first.
module gba_eeprom_io #(
    parameter integer ADDR_BITS_MAX = 14
) (
    input  wire        clk,
    input  wire        reset,

    // The connector's actual state, not the request. Same rule as every other
    // master: gba_cart_bus holds its FSM in ST_IDLE with cart_mode low and
    // never raises done, so a transfer started without it hangs.
    input  wire        cart_mode,

    input  wire        start,

    // Send zeros instead of a request, then read as usual and throw the
    // result away. A chip that was left part way through a command, which is
    // what a probe at the wrong address width does, is still counting bits: it
    // does not reset when CS1# rises, because on real hardware CS1# toggles
    // between every bit of a normal command anyway. Zeros finish whatever it
    // was waiting for and the read that follows drains its data phase, so the
    // next request starts against a chip at rest.
    //
    // Starting a chip that is already at rest with zeros is harmless: 0 0 is
    // not a command.
    input  wire        flush,

    // 6 for a 512 byte chip, 14 for 8 KiB. Latched at start. Ignored when
    // flush is set.
    input  wire [3:0]  addr_bits,
    // Which 8-byte block. Only the low addr_bits are sent.
    input  wire [13:0] block,

    output reg         busy,
    output reg         done,
    // The block, most significant bit first as it came off the chip.
    output reg  [63:0] data,

    // gba_cart_bus master port. Same handshake as every other master: wait for
    // !bus_busy, raise req for one cycle, drop it, then wait for done.
    output reg         bus_req,
    output reg         bus_wr,
    output wire [27:0] bus_addr,
    output wire [1:0]  bus_acc,
    output reg  [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

localparam [1:0] ACCESS_16BIT = 2'b01;

// The EEPROM window. Any address with addr[27:24] == 0xD reaches the chip on
// a cartridge of 16 MB or less; the top 256 bytes is where the GBA's own
// code puts it, so use that and stay in the same place a cartridge expects.
localparam [27:0] EEPROM_BASE = 28'hDFF_FF00;

assign bus_addr = EEPROM_BASE;
assign bus_acc  = ACCESS_16BIT;

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_SEND  = 3'd1;   // request bits out
localparam [2:0] ST_WSEND = 3'd2;
localparam [2:0] ST_RECV  = 3'd3;   // 4 discarded + 64 data bits in
localparam [2:0] ST_WRECV = 3'd4;
localparam [2:0] ST_DONE  = 3'd5;

reg [2:0]  state;
reg [3:0]  bits_l;
reg        flush_l;
reg [13:0] block_l;
reg [6:0]  sent;        // request bits sent so far
reg [6:0]  got;         // read bits taken so far

// 2 command bits + the address + 1 terminator. A flush sends more zeros than
// the longest command needs, so no pending command can survive one.
localparam [6:0] FLUSH_BITS = 7'd24;
wire [6:0] send_total = flush_l ? FLUSH_BITS : 7'd3 + {3'd0, bits_l};
wire [6:0] recv_total = 7'd68;

// The request, most significant bit first: 1, 1, address, 0. Bit 0 of sent
// selects nothing here; the position is what picks the bit.
wire [3:0] addr_index = bits_l - 4'd1 - (sent[3:0] - 4'd2);
wire next_bit = flush_l         ? 1'b0 :
                (sent == 7'd0) ? 1'b1 :
                (sent == 7'd1) ? 1'b1 :
                (sent >= {3'd0, bits_l} + 7'd2) ? 1'b0
                                                : block_l[addr_index];

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        data      <= 64'd0;
        bus_wr    <= 1'b0;
        bus_wdata <= 32'd0;
        sent      <= 7'd0;
        got       <= 7'd0;
        bits_l    <= 4'd14;
        flush_l   <= 1'b0;
        block_l   <= 14'd0;
    end else if (busy && !cart_mode) begin
        // The connector left GBA mode underneath us. gba_cart_bus has reset
        // itself and will never raise done, so stop rather than hang. Same
        // abandon guard as gba_size_probe and gba_save_scan.
        state   <= ST_IDLE;
        busy    <= 1'b0;
        bus_req <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                if (start && cart_mode) begin
                    busy    <= 1'b1;
                    bits_l  <= addr_bits;
                    flush_l <= flush;
                    block_l <= block;
                    sent    <= 7'd0;
                    got     <= 7'd0;
                    data    <= 64'd0;
                    state   <= ST_SEND;
                end
            end

            // One request bit. A write in EEPROM space puts the halfword on
            // AD and pulses WR#; the chip takes AD0.
            ST_SEND: begin
                if (!bus_busy) begin
                    bus_req   <= 1'b1;
                    bus_wr    <= 1'b1;
                    bus_wdata <= {31'd0, next_bit};
                    state     <= ST_WSEND;
                end
            end

            ST_WSEND: begin
                if (bus_done) begin
                    if (sent + 7'd1 >= send_total) begin
                        bus_wr <= 1'b0;
                        state  <= ST_RECV;
                    end else begin
                        sent  <= sent + 7'd1;
                        state <= ST_SEND;
                    end
                end
            end

            ST_RECV: begin
                if (!bus_busy) begin
                    bus_req <= 1'b1;
                    bus_wr  <= 1'b0;
                    state   <= ST_WRECV;
                end
            end

            // The first four are the chip turning round and carry nothing.
            // After that, most significant bit first.
            ST_WRECV: begin
                if (bus_done) begin
                    if (got >= 7'd4)
                        data <= {data[62:0], bus_rdata[0]};
                    if (got + 7'd1 >= recv_total)
                        state <= ST_DONE;
                    else begin
                        got   <= got + 7'd1;
                        state <= ST_RECV;
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
