// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Read-only GG identification: the 16-byte headers at 1FF0, 3FF0 and 7FF0
// are each read twice. No banking, RAM-enable, or EEPROM operation is used.
// Header size and checksum fields are evidence, not a ROM-length verdict.
// Raw byte i occupies bits [i*8 +: 8], matching the other identifiers.
module cart_identify_gg (
    input wire clk,
    input wire reset,
    input wire gg_mode,
    input wire start,
    output reg busy,
    output reg done,
    output reg cart_req,
    output wire cart_wr,
    output reg [15:0] cart_addr,
    output wire [7:0] cart_wdata,
    input wire [7:0] cart_rdata,
    input wire cart_done,
    input wire cart_busy,
    output reg [2:0] result,
    output reg [127:0] raw_bytes,
    output reg [15:0] header_addr,
    output reg [19:0] product_code,
    output reg [3:0] sw_version,
    output reg [3:0] region,
    output reg [3:0] rom_size_code,
    output reg [15:0] checksum_read
);

localparam [2:0] RESULT_GG = 3'd0, RESULT_NO_CART = 3'd1,
                 RESULT_UNSTABLE = 3'd2, RESULT_NOT_GG = 3'd3,
                 RESULT_NO_POWER = 3'd4;
localparam [2:0] ST_IDLE = 3'd0, ST_REQ = 3'd1, ST_WAIT = 3'd2,
                 ST_NEXT = 3'd3, ST_JUDGE = 3'd4, ST_DONE = 3'd5;
reg [2:0] state;
reg [1:0] candidate;
reg [3:0] idx;
reg pass;
reg same, all_zero, all_ones;
reg [7:0] hdr [0:47];
wire [5:0] slot = {candidate, idx};
wire signature0 = {hdr[0], hdr[1], hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7]} == 64'h544D522053454741;
wire signature1 = {hdr[16], hdr[17], hdr[18], hdr[19], hdr[20], hdr[21], hdr[22], hdr[23]} == 64'h544D522053454741;
wire signature2 = {hdr[32], hdr[33], hdr[34], hdr[35], hdr[36], hdr[37], hdr[38], hdr[39]} == 64'h544D522053454741;
// If no signature is found, expose the usual 7FF0 location for diagnosis.
wire [1:0] selected = signature0 ? 2'd0 : signature1 ? 2'd1 : 2'd2;
wire [5:0] selected_base = {selected, 4'b0000};
assign cart_wr = 1'b0;
assign cart_wdata = 8'd0;

function [15:0] header_base(input [1:0] which);
    case (which)
        2'd0: header_base = 16'h1FF0;
        2'd1: header_base = 16'h3FF0;
        default: header_base = 16'h7FF0;
    endcase
endfunction

integer i;
always @(posedge clk) begin
    done <= 1'b0;
    cart_req <= 1'b0;
    if (reset) begin
        state <= ST_IDLE;
        busy <= 1'b0;
        cart_addr <= 0;
        candidate <= 0;
        idx <= 0;
        pass <= 0;
        same <= 1'b1;
        all_zero <= 1'b1;
        all_ones <= 1'b1;
        result <= RESULT_NO_CART;
        raw_bytes <= 0;
        header_addr <= 0;
        product_code <= 0;
        sw_version <= 0;
        region <= 0;
        rom_size_code <= 0;
        checksum_read <= 0;
    end else if (busy && !gg_mode && state != ST_DONE) begin
        // Actual loss of the selected bus invalidates all old identity.
        result <= RESULT_NO_POWER;
        raw_bytes <= 0;
        header_addr <= 0;
        product_code <= 0;
        sw_version <= 0;
        region <= 0;
        rom_size_code <= 0;
        checksum_read <= 0;
        state <= ST_DONE;
    end else begin
        case (state)
            ST_IDLE: if (start) begin
                busy <= 1'b1;
                candidate <= 0;
                idx <= 0;
                pass <= 0;
                same <= 1'b1;
                all_zero <= 1'b1;
                all_ones <= 1'b1;
                raw_bytes <= 0;
                header_addr <= 0;
                product_code <= 0;
                sw_version <= 0;
                region <= 0;
                rom_size_code <= 0;
                checksum_read <= 0;
                result <= gg_mode ? RESULT_NO_CART : RESULT_NO_POWER;
                state <= gg_mode ? ST_REQ : ST_DONE;
            end
            ST_REQ: if (!cart_busy) begin
                cart_addr <= header_base(candidate) + {12'd0, idx};
                cart_req <= 1'b1;
                state <= ST_WAIT;
            end
            ST_WAIT: if (cart_done) begin
                if (pass) begin
                    if (cart_rdata != hdr[slot]) same <= 1'b0;
                end else begin
                    hdr[slot] <= cart_rdata;
                    if (cart_rdata != 8'h00) all_zero <= 1'b0;
                    if (cart_rdata != 8'hFF) all_ones <= 1'b0;
                end
                state <= ST_NEXT;
            end
            ST_NEXT: begin
                if (idx != 4'd15) begin
                    idx <= idx + 1'b1;
                    state <= ST_REQ;
                end else begin
                    idx <= 0;
                    if (!pass) begin
                        pass <= 1'b1;
                        state <= ST_REQ;
                    end else if (candidate != 2'd2) begin
                        candidate <= candidate + 1'b1;
                        pass <= 1'b0;
                        state <= ST_REQ;
                    end else state <= ST_JUDGE;
                end
            end
            ST_JUDGE: begin
                for (i = 0; i < 16; i = i + 1)
                    raw_bytes[i*8 +: 8] <= hdr[selected_base + i];
                header_addr <= header_base(selected);
                product_code <= {hdr[selected_base + 14][7:4], hdr[selected_base + 13], hdr[selected_base + 12]};
                sw_version <= hdr[selected_base + 14][3:0];
                region <= hdr[selected_base + 15][7:4];
                rom_size_code <= hdr[selected_base + 15][3:0];
                checksum_read <= {hdr[selected_base + 11], hdr[selected_base + 10]};
                // A changing bus is never reported absent or trustworthy,
                // even if its first pass happened to contain all FF/00.
                if (!same) result <= RESULT_UNSTABLE;
                else if (all_zero || all_ones) result <= RESULT_NO_CART;
                else if (signature0 || signature1 || signature2) result <= RESULT_GG;
                else result <= RESULT_NOT_GG;
                state <= ST_DONE;
            end
            ST_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                state <= ST_IDLE;
            end
            default: state <= ST_IDLE;
        endcase
    end
end
endmodule
`default_nettype wire
