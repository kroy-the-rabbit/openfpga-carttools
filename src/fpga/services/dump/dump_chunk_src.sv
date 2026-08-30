// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_chunk_src.sv - fill one buffer's worth, then say so
//
// This is the producer half of apf_file_writer's chunk handshake, on the far
// side of the clock crossing. It exists so the cartridge reader can be a
// module that knows nothing about APF: cart_dump_gb emits a byte stream at
// whatever rate the bus manages, and this throttles it with out_ready so that
// exactly chunk_len bytes land in the buffer and no more.
//
// The handshake is four phase, deliberately, because it crosses clock
// domains. req is a level that stays up until ack is seen, ack is a level
// that stays up until req falls. Nothing here is a pulse, so nothing here
// depends on a pulse surviving a synchroniser.
//
// The self-test path generates its own bytes instead of reading a cartridge.
// It is not a toy: it is the only way to tell a byte order mistake from a
// cartridge read mistake, because a ramp that comes back as 03 02 01 00 is
// unambiguous in a way that a ROM image is not.
//

module dump_chunk_src #(
    parameter integer AW = 10
) (
    input  wire        clk,              // clk_sys
    input  wire        reset,

    input  wire        arm,              // pulse: a new file starts at byte 0
    input  wire        selftest,         // generate a ramp instead of reading

    // The cartridge stopped answering. Go back to idle rather than sitting in
    // ST_FILL waiting for a byte the bus will never deliver.
    input  wire        abort,

    // apf_file_writer, already synchronised into this domain
    input  wire        req,
    input  wire [31:0] req_len,
    output reg         ack,

    // cart_dump_gb byte stream
    input  wire [7:0]  src_data,
    input  wire        src_valid,
    output reg         src_ready,

    // dump_buffer write port
    output reg         buf_rst,
    output reg         buf_we,
    output reg  [7:0]  buf_data,
    output reg         buf_flush,

    // How many chunks have been handed over. Counted here rather than
    // synchronised back from the bridge domain, so the progress the user sees
    // is a value that was never in flight across a clock boundary.
    output reg  [15:0] chunks_done
);

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_FILL  = 3'd1;
localparam [2:0] ST_FLUSH = 3'd2;
localparam [2:0] ST_SETTLE= 3'd3;
localparam [2:0] ST_ACK   = 3'd4;

reg [2:0]  state;
reg [31:0] left;
reg [7:0]  ramp;
reg [1:0]  settle;

always @(posedge clk) begin
    buf_rst   <= 1'b0;
    buf_we    <= 1'b0;
    buf_flush <= 1'b0;

    if (reset) begin
        state       <= ST_IDLE;
        ack         <= 1'b0;
        src_ready   <= 1'b0;
        left        <= 32'd0;
        ramp        <= 8'd0;
        chunks_done <= 16'd0;
    end else begin
        if (arm) begin
            ramp        <= 8'd0;
            chunks_done <= 16'd0;
        end

        if (abort && state != ST_IDLE) begin
            ack       <= 1'b0;
            src_ready <= 1'b0;
            state     <= ST_IDLE;
        end else
        case (state)
            ST_IDLE: begin
                ack       <= 1'b0;
                src_ready <= 1'b0;
                if (req) begin
                    left    <= req_len;
                    buf_rst <= 1'b1;
                    state   <= ST_FILL;
                end
            end

            ST_FILL: begin
                if (left == 32'd0) begin
                    src_ready <= 1'b0;
                    state     <= ST_FLUSH;
                end else if (selftest) begin
                    buf_we   <= 1'b1;
                    buf_data <= ramp;
                    ramp     <= ramp + 8'd1;
                    left     <= left - 32'd1;
                end else begin
                    src_ready <= 1'b1;
                    if (src_valid && src_ready) begin
                        buf_we   <= 1'b1;
                        buf_data <= src_data;
                        left     <= left - 32'd1;
                        // Drop ready on the last byte in the same cycle it is
                        // taken, so the reader is not left holding a byte
                        // that belongs to the next chunk.
                        if (left == 32'd1) src_ready <= 1'b0;
                    end
                end
            end

            // A length that is not a multiple of four leaves a partial word
            // in the packer. Committing it is what makes the tail of the file
            // right rather than four bytes short.
            ST_FLUSH: begin
                buf_flush <= 1'b1;
                settle    <= 2'd3;
                state     <= ST_SETTLE;
            end

            // The buffer's write is a cycle behind the flush strobe and the
            // read side is in another clock domain. Acknowledging immediately
            // would let the bridge read a word the RAM has not taken yet.
            ST_SETTLE: begin
                if (settle == 2'd0) state <= ST_ACK;
                else                settle <= settle - 2'd1;
            end

            ST_ACK: begin
                ack <= 1'b1;
                if (!req) begin
                    ack         <= 1'b0;
                    chunks_done <= chunks_done + 16'd1;
                    state       <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
