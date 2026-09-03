`default_nettype none

// Is the EEPROM 512 bytes or 8 KiB, and is it answering at all.
//
// Nothing in a cartridge says. The SDK string is EEPROM_V for both, the
// header carries no save field, and the emulator that the bit counts came from
// tells them apart by watching the game's DMA transfer length, which a dumper
// does not have. So ask the chip.
//
// A 512 byte chip takes a 6 bit address, an 8 KiB chip 14. Give a chip the
// wrong width and it does not answer: the 14 bit chip is still counting
// address bits when the request ends and never reaches its data phase, and the
// bus reads open bus, which is all ones. So the width that returns anything
// other than all ones is the width the chip has.
//
// ORDER MATTERS. The 6 bit attempt goes first because it is the one that
// leaves less behind: it under-runs a wide chip, which stays waiting, rather
// than over-running a narrow one, which would run request bits into a data
// phase. Either way the flush before each attempt puts the chip back at rest.
//
// A blank 512 byte save reads all ones and is indistinguishable from a chip
// that is not answering, so it is reported as not found rather than guessed
// at. Refusing to dump beats writing a file of the wrong size.
module gba_eeprom_probe (
    input  wire        clk,
    input  wire        reset,
    input  wire        cart_mode,

    input  wire        start,

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

reg        io_start;
reg        io_flush;
reg  [3:0] io_bits;
wire        io_busy, io_done;
wire [63:0] io_data;

gba_eeprom_io io (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .start (io_start), .flush (io_flush), .addr_bits (io_bits),
    .block (14'd0),
    .busy (io_busy), .done (io_done), .data (io_data),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
);

// All ones is open bus, which is what a chip that did not answer leaves on
// AD0 for all 64 bits.
wire answered = io_data !== 64'hFFFF_FFFF_FFFF_FFFF;

localparam [2:0] ST_IDLE    = 3'd0;
localparam [2:0] ST_FLUSH6  = 3'd1;
localparam [2:0] ST_TRY6    = 3'd2;
localparam [2:0] ST_FLUSH14 = 3'd3;
localparam [2:0] ST_TRY14   = 3'd4;
localparam [2:0] ST_DONE    = 3'd5;

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
        io_bits    <= 4'd6;
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
                    state      <= ST_FLUSH6;
                end
            end

            ST_FLUSH6: begin
                if (!io_busy) begin
                    io_start <= 1'b1;
                    io_flush <= 1'b1;
                    waiting  <= 1'b1;
                    state    <= ST_TRY6;
                end
            end

            ST_TRY6: begin
                if (!io_busy) begin
                    if (io_flush) begin
                        io_start <= 1'b1;
                        io_flush <= 1'b0;
                        io_bits  <= 4'd6;
                        waiting  <= 1'b1;
                    end else if (answered) begin
                        size_bytes <= 32'd512;
                        addr_bits  <= 4'd6;
                        found      <= 1'b1;
                        state      <= ST_DONE;
                    end else begin
                        state <= ST_FLUSH14;
                    end
                end
            end

            ST_FLUSH14: begin
                if (!io_busy) begin
                    io_start <= 1'b1;
                    io_flush <= 1'b1;
                    waiting  <= 1'b1;
                    state    <= ST_TRY14;
                end
            end

            ST_TRY14: begin
                if (!io_busy) begin
                    if (io_flush) begin
                        io_start <= 1'b1;
                        io_flush <= 1'b0;
                        io_bits  <= 4'd14;
                        waiting  <= 1'b1;
                    end else if (answered) begin
                        size_bytes <= 32'd8192;
                        addr_bits  <= 4'd14;
                        found      <= 1'b1;
                        state      <= ST_DONE;
                    end else begin
                        size_bytes <= 32'd0;
                        found      <= 1'b0;
                        state      <= ST_DONE;
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
