`default_nettype none

// Is the EEPROM 512 bytes or 8 KiB, and is it answering at all.
//
// Nothing in a cartridge says. The SDK string is EEPROM_V for both, the
// header carries no save field, and the emulator that the bit counts came from
// tells them apart by watching the game's DMA transfer length, which a dumper
// does not have. So ask the chip.
//
// A 512 byte chip takes a 6 bit address and an 8 KiB chip takes 14. Requests
// at the wrong width do not reliably fail. Minish Cap proved that a 6 bit
// request to an 8 KiB chip answers with the wrong block. Super Mario Advance
// proved the other direction: a 14 bit request to its 512 byte chip answers
// too, using the first six address bits. Reading wide block numbers 0 through
// 63 therefore returns the same physical block 64 times.
//
// Detect that alias instead of treating any wide answer as proof of 8 KiB.
// Read 64 consecutive blocks with 14 address bits. If any block differs from
// block zero, the chip is 8 KiB. If all 64 match and the value is not open
// bus, it is 512 bytes. This is the same discriminator used by the open source
// cartridge reader implementation checked after the hardware result.
//
// The test is necessarily data-dependent. A real 8 KiB save whose first 512
// bytes contain the same 8-byte value would look narrow. Completely blank
// data is worse: it is indistinguishable from no chip on this bus, so an
// all-ones result is still refused rather than assigned a size.
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

// Sixty-four wide requests cover the first 512 bytes. A narrow chip uses the
// six leading address bits, which are zero throughout this range, so every
// request aliases block zero.
reg [5:0] att;
reg [63:0] first_data;

wire [3:0]  att_bits  = 4'd14;
wire [13:0] att_block = {8'd0, att};

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
        att        <= 6'd0;
        first_data <= 64'd0;
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
                    att        <= 6'd0;
                    first_data <= 64'd0;
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
                    if (att == 6'd0) begin
                        first_data <= io_data;
                        att        <= 6'd1;
                        state      <= ST_REQ;
                    end else if (io_data != first_data) begin
                        size_bytes <= 32'd8192;
                        addr_bits  <= 4'd14;
                        found      <= 1'b1;
                        state      <= ST_DONE;
                    end else if (att == 6'd63) begin
                        if (first_data == 64'hFFFF_FFFF_FFFF_FFFF) begin
                            size_bytes <= 32'd0;
                            found      <= 1'b0;
                        end else begin
                            size_bytes <= 32'd512;
                            addr_bits  <= 4'd6;
                            found      <= 1'b1;
                        end
                        state      <= ST_DONE;
                    end else begin
                        att   <= att + 6'd1;
                        state <= ST_REQ;
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
