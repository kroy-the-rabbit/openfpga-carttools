`default_nettype none

// Is the EEPROM 512 bytes or 8 KiB, and is it answering at all.
//
// Nothing in a cartridge says. The SDK string is EEPROM_V for both, the
// header carries no save field, and the emulator that the bit counts came from
// tells them apart by watching the game's DMA transfer length, which a dumper
// does not have. So ask the chip.
//
// A 512 byte chip takes a 6 bit address and an 8 KiB chip 14, and the two
// widths fail in opposite ways.
//
//   A 6 bit request to an 8 KiB chip UNDER-RUNS. The chip is still counting
//   address bits when the request ends, and on a real cartridge it answers
//   anyway, with a block that is not the one asked for. That is not a refusal.
//   It is a wrong answer wearing the shape of a right one.
//
//   A 14 bit request to a 512 byte chip OVER-RUNS. The chip took its 6 bits,
//   read the next as the terminator and began its data phase, and the seven
//   address bits still coming abort it. Nothing is left driving AD0, so the
//   read that follows returns open bus, which is all ones.
//
// So the WIDE request is the one that discriminates, and it goes first. A chip
// that answers 14 bits is 8 KiB. Only when nothing answers at 14 is 6 worth
// trying. The other way round, which is what this module did first, reports
// 512 for every 8 KiB cartridge: Minish Cap has an 8 KiB chip and was dumped
// as 512 bytes of the wrong blocks before that was understood.
//
// WHAT IS VERIFIED AND WHAT IS NOT. The 8 KiB branch is settled on a
// cartridge. The 512 branch rests on the over-run above and has only ever run
// in simulation, because no 512 byte EEPROM cartridge has been through here.
// It is the branch to distrust first if a small save ever comes out wrong.
//
// Several blocks are tried at each width, because the whole discriminator is
// "did anything come back" and a blank block reads all ones exactly like a
// chip that said nothing.
//
// THE 14 BIT ADDRESSES ALL HAVE addr[7:0] == 0, and that is not decoration. A
// 512 byte chip reads the over-run bits as the start of a fresh command. An
// over-run beginning 1 0 is a WRITE command aimed at somebody's save. Zeros
// are hunted for a start bit and discarded, so zeros are the only safe thing
// to over-run with. Any address added to this list must keep addr[7:0] == 0.
//
// A chip that answers at neither width is reported as not found rather than
// guessed at, which is also what a completely blank save looks like. Refusing
// to dump beats writing a file of a size nobody established.
module gba_eeprom_probe (
    input  wire        clk,
    input  wire        reset,
    input  wire        cart_mode,

    input  wire        start,

    // A dump takes the GBA bus away through core_top's mux, so a probe running
    // underneath one would wait on a bus_done that never comes and sit busy
    // for ever. Same abort as gba_save_scan, and for the same reason: this is
    // exactly how the save scan froze the core twice.
    input  wire        abort,

    output reg         busy,
    output reg         done,

    // Valid when done: 512, 8192, or 0 for a chip that never answered.
    output reg  [31:0] size_bytes,
    // The width that worked, for the reader to use. Meaningless when size is 0.
    output reg  [3:0]  addr_bits,
    output reg         found,

    // gba_cart_bus master port, passed through from the transfer engine.
    output wire        bus_req,
    output wire        bus_wr,
    output wire [27:0] bus_addr,
    output wire [1:0]  bus_acc,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

reg         io_start;
reg         io_flush;
reg  [3:0]  io_bits;
reg  [13:0] io_block;
wire        io_busy, io_done;
wire [63:0] io_data;

gba_eeprom_io io (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (io_start), .flush (io_flush), .addr_bits (io_bits),
    .block (io_block),
    .busy (io_busy), .done (io_done), .data (io_data),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
);

// All ones is open bus, which is what a chip that did not answer leaves on
// AD0 for all 64 bits.
wire answered = io_data !== 64'hFFFF_FFFF_FFFF_FFFF;

// The attempts, in order: four at 14 bits, then two at 6. Wide first, because
// the wide request is the one a chip of the other size cannot answer at all.
// Every 14 bit address has its low eight bits clear; see the note above.
localparam [2:0] N_ATTEMPTS = 3'd6;

reg [2:0] att;

wire [3:0]  att_bits  = (att < 3'd4) ? 4'd14 : 4'd6;
wire [13:0] att_block = (att == 3'd0) ? 14'h0000 :
                        (att == 3'd1) ? 14'h0100 :
                        (att == 3'd2) ? 14'h0200 :
                        (att == 3'd3) ? 14'h0300 :
                        (att == 3'd4) ? 14'h0000 :
                                        14'h0001;

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_FLUSH = 3'd1;
localparam [2:0] ST_REQ   = 3'd2;
localparam [2:0] ST_CHECK = 3'd3;
localparam [2:0] ST_DONE  = 3'd4;

reg [2:0] state;
reg       waiting;

always @(posedge clk) begin
    done     <= 1'b0;
    io_start <= 1'b0;

    if (reset) begin
        state      <= ST_IDLE;
        busy       <= 1'b0;
        waiting    <= 1'b0;
        size_bytes <= 32'd0;
        addr_bits  <= 4'd14;
        found      <= 1'b0;
        io_flush   <= 1'b0;
        io_bits    <= 4'd14;
        io_block   <= 14'd0;
        att        <= 3'd0;
    end else if (busy && abort) begin
        // Stops without clearing a result, because abort only fires while
        // busy and busy means there is no result yet. Resetting on a dump is
        // what threw away a finished save scan and made the save button
        // vanish after every ROM dump.
        state   <= ST_IDLE;
        busy    <= 1'b0;
        waiting <= 1'b0;
        found   <= 1'b0;
    end else if (busy && !cart_mode) begin
        // The connector left GBA mode. gba_cart_bus has reset itself and will
        // never raise done, so stop rather than hang.
        state   <= ST_IDLE;
        busy    <= 1'b0;
        waiting <= 1'b0;
        found   <= 1'b0;
    end else if (waiting) begin
        if (io_done) waiting <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                if (start && cart_mode) begin
                    busy       <= 1'b1;
                    found      <= 1'b0;
                    size_bytes <= 32'd0;
                    att        <= 3'd0;
                    state      <= ST_FLUSH;
                end
            end

            // Zeros, so whatever the last attempt left the chip part way
            // through is finished and drained before the next one starts.
            ST_FLUSH: begin
                if (!io_busy) begin
                    io_start <= 1'b1;
                    io_flush <= 1'b1;
                    waiting  <= 1'b1;
                    state    <= ST_REQ;
                end
            end

            ST_REQ: begin
                if (!io_busy) begin
                    io_start <= 1'b1;
                    io_flush <= 1'b0;
                    io_bits  <= att_bits;
                    io_block <= att_block;
                    waiting  <= 1'b1;
                    state    <= ST_CHECK;
                end
            end

            ST_CHECK: begin
                if (!io_busy) begin
                    if (answered) begin
                        size_bytes <= (att_bits == 4'd14) ? 32'd8192 : 32'd512;
                        addr_bits  <= att_bits;
                        found      <= 1'b1;
                        state      <= ST_DONE;
                    end else if (att + 3'd1 >= N_ATTEMPTS) begin
                        size_bytes <= 32'd0;
                        found      <= 1'b0;
                        state      <= ST_DONE;
                    end else begin
                        att   <= att + 3'd1;
                        state <= ST_FLUSH;
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
