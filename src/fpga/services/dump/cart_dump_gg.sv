// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Sega mapper ROM capture through slot 2 for every bank, including bank 0.
// Slots 0/1 may be fixed on some Sega mapper revisions. Length is explicitly
// selected (256 or 512 KiB); this reader makes no alias-based size inference.
//
// FFFC=00 keeps SRAM and the World Series Baseball EEPROM overlay disabled.
// The bus independently whitelists every allowed mapper write. No byte is
// written to the cartridge's 8000..BFFF data/EEPROM window.
//
// Normal cancel abandons the stream but drains an already-issued transaction
// before busy falls. reset is reserved for core reset / actual power loss.
// Optional verification reinitializes the mapper and reads the complete ROM
// again, comparing CRC32 while emitting no additional file bytes.
module cart_dump_gg (
    input wire clk,
    input wire reset,
    input wire cancel,
    input wire start,
    input wire [31:0] size_bytes,
    input wire verify_enable,
    output reg busy,
    output reg done,
    output reg aborted,
    output reg [2:0] error,
    output wire [31:0] total_bytes,

    output reg bus_req,
    output reg bus_wr,
    output reg [15:0] bus_addr,
    output reg [7:0] bus_wdata,
    input wire [7:0] bus_rdata,
    input wire bus_done,
    input wire bus_busy,
    output reg [7:0] out_data,
    output reg out_valid,
    input wire out_ready,

    output reg verify_checked,
    output reg verify_ok,
    output reg [31:0] first_crc32,
    output reg [31:0] verify_crc32
);

localparam [2:0] ERROR_NONE = 3'd0, ERROR_SIZE = 3'd1,
                 ERROR_VERIFY = 3'd2, ERROR_CANCEL = 3'd3;
localparam [3:0] ST_IDLE = 4'd0, ST_INIT_REQ = 4'd1, ST_INIT_WAIT = 4'd2,
                 ST_BANK_REQ = 4'd3, ST_BANK_WAIT = 4'd4, ST_READ_REQ = 4'd5,
                 ST_READ_WAIT = 4'd6, ST_EMIT = 4'd7, ST_NEXT = 4'd8,
                 ST_PASS_DONE = 4'd9, ST_DONE = 4'd10, ST_CANCEL_WAIT = 4'd11;
reg [3:0] state;
reg [31:0] length_latched;
reg [5:0] bank_count;
reg [4:0] bank;
reg [13:0] offset;
reg [1:0] init_index;
reg second_pass;
reg verify_latched;
reg pending;
reg [31:0] crc_reg;
assign total_bytes = length_latched;

// Reflected IEEE CRC32, identical convention to dump_crc32 and zlib. The
// first pass advances only when the consumer accepts a byte; stalls cannot
// count the same byte twice. The verification pass advances at bus_done.
function [31:0] crc_byte(input [31:0] c_in, input [7:0] d);
    reg [31:0] c;
    integer i;
    begin
        c = c_in ^ {24'd0, d};
        for (i = 0; i < 8; i = i + 1)
            c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
        crc_byte = c;
    end
endfunction

always @(posedge clk) begin
    done <= 1'b0;
    bus_req <= 1'b0;
    if (reset) begin
        state <= ST_IDLE;
        busy <= 1'b0;
        aborted <= 1'b0;
        error <= ERROR_NONE;
        length_latched <= 0;
        bank_count <= 0;
        bank <= 0;
        offset <= 0;
        init_index <= 0;
        second_pass <= 0;
        verify_latched <= 0;
        pending <= 0;
        bus_wr <= 0;
        bus_addr <= 0;
        bus_wdata <= 0;
        out_data <= 0;
        out_valid <= 0;
        verify_checked <= 0;
        verify_ok <= 0;
        first_crc32 <= 0;
        verify_crc32 <= 0;
        crc_reg <= 32'hFFFFFFFF;
    end else begin
        if (bus_done) pending <= 1'b0;
        if (cancel && busy && state != ST_CANCEL_WAIT && state != ST_DONE) begin
            aborted <= 1'b1;
            error <= ERROR_CANCEL;
            out_valid <= 1'b0;
            state <= ST_CANCEL_WAIT;
        end else begin
            case (state)
                ST_IDLE: begin
                    out_valid <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        aborted <= 1'b0;
                        error <= ERROR_NONE;
                        length_latched <= size_bytes;
                        bank_count <= size_bytes == 32'h00080000 ? 6'd32 : 6'd16;
                        bank <= 0;
                        offset <= 0;
                        init_index <= 0;
                        second_pass <= 1'b0;
                        verify_latched <= verify_enable;
                        pending <= 1'b0;
                        verify_checked <= 1'b0;
                        verify_ok <= 1'b0;
                        first_crc32 <= 0;
                        verify_crc32 <= 0;
                        crc_reg <= 32'hFFFFFFFF;
                        if (cancel) begin
                            aborted <= 1'b1;
                            error <= ERROR_CANCEL;
                            state <= ST_CANCEL_WAIT;
                        end else if (size_bytes != 32'h00040000 && size_bytes != 32'h00080000) begin
                            error <= ERROR_SIZE;
                            state <= ST_DONE;
                        end else state <= ST_INIT_REQ;
                    end
                end
                ST_INIT_REQ: if (!bus_busy) begin
                    bus_req <= 1'b1;
                    bus_wr <= 1'b1;
                    bus_addr <= 16'hFFFC + {14'd0, init_index};
                    case (init_index)
                        2'd0, 2'd1: bus_wdata <= 8'h00;
                        2'd2: bus_wdata <= 8'h01;
                        default: bus_wdata <= 8'h02;
                    endcase
                    pending <= 1'b1;
                    state <= ST_INIT_WAIT;
                end
                ST_INIT_WAIT: if (bus_done) begin
                    if (init_index == 2'd3) state <= ST_BANK_REQ;
                    else begin
                        init_index <= init_index + 1'b1;
                        state <= ST_INIT_REQ;
                    end
                end
                ST_BANK_REQ: if (!bus_busy) begin
                    bus_req <= 1'b1;
                    bus_wr <= 1'b1;
                    bus_addr <= 16'hFFFF;
                    bus_wdata <= {3'd0, bank};
                    pending <= 1'b1;
                    state <= ST_BANK_WAIT;
                end
                ST_BANK_WAIT: if (bus_done) state <= ST_READ_REQ;
                ST_READ_REQ: if (!bus_busy) begin
                    bus_req <= 1'b1;
                    bus_wr <= 1'b0;
                    bus_addr <= {2'b10, offset};
                    bus_wdata <= 8'h00;
                    pending <= 1'b1;
                    state <= ST_READ_WAIT;
                end
                ST_READ_WAIT: if (bus_done) begin
                    if (second_pass) begin
                        crc_reg <= crc_byte(crc_reg, bus_rdata);
                        state <= ST_NEXT;
                    end else begin
                        out_data <= bus_rdata;
                        out_valid <= 1'b1;
                        state <= ST_EMIT;
                    end
                end
                ST_EMIT: if (out_ready) begin
                    crc_reg <= crc_byte(crc_reg, out_data);
                    out_valid <= 1'b0;
                    state <= ST_NEXT;
                end
                ST_NEXT: begin
                    if (offset != 14'h3FFF) begin
                        offset <= offset + 1'b1;
                        state <= ST_READ_REQ;
                    end else begin
                        offset <= 0;
                        if ({1'b0, bank} + 6'd1 == bank_count) state <= ST_PASS_DONE;
                        else begin
                            bank <= bank + 1'b1;
                            state <= ST_BANK_REQ;
                        end
                    end
                end
                ST_PASS_DONE: begin
                    if (!second_pass) begin
                        first_crc32 <= ~crc_reg;
                        if (verify_latched) begin
                            second_pass <= 1'b1;
                            bank <= 0;
                            offset <= 0;
                            init_index <= 0;
                            crc_reg <= 32'hFFFFFFFF;
                            state <= ST_INIT_REQ;
                        end else state <= ST_DONE;
                    end else begin
                        verify_checked <= 1'b1;
                        verify_crc32 <= ~crc_reg;
                        verify_ok <= (~crc_reg == first_crc32);
                        if (~crc_reg != first_crc32) error <= ERROR_VERIFY;
                        state <= ST_DONE;
                    end
                end
                ST_CANCEL_WAIT: begin
                    out_valid <= 1'b0;
                    // pending covers the clock between raising bus_req and
                    // the bus accepting it. Looking only at bus_busy here
                    // could release mode one clock before that write starts.
                    if ((!pending || bus_done) && !bus_busy && !bus_req)
                        state <= ST_DONE;
                end
                ST_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    out_valid <= 1'b0;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
end
endmodule
`default_nettype wire
