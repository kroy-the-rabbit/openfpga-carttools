// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Read cycles for the official Analogue Lynx adapter (AP-A03). Wiring, unverified:
// https://github.com/sfiera/pocket-adapters/blob/4c61591b7bb0565331d525b96186ce0b308667be/lynx.md
// Control is {IODAT, /CS1, /CS0, SYSCTL1}. IODAT feeds the adapter's HC164 and
// switches cartridge power, low is on. SYSCTL1 clocks it; block number MSB first.
// Same request port as gg_cart_bus: 0000..7FFF is the first 32 KiB, 8000..BFFF
// the 16 KiB bank written to FFFF. No write reaches a cartridge pin.
module lynx_cart_bus #(
    parameter integer POWER_CYCLES = 2013266,
    parameter integer SHIFT_CYCLES = 50,
    parameter integer SETTLE_CYCLES = 201327,
    parameter integer ADDR_SETUP_CYCLES = 50,
    parameter integer STROBE_CYCLES = 200,
    parameter integer HOLD_CYCLES = 50
) (
    input wire clk,
    input wire reset,
    input wire lynx_mode,
    input wire req,
    input wire wr,
    input wire [15:0] addr,
    input wire [7:0] wdata,
    output reg [7:0] rdata,
    output reg done,
    output wire busy,
    output wire write_active,
    output reg rejected,

    output wire [15:0] e_ad_out,
    output wire e_ad_oe,
    output wire [7:0] e_hi_out,
    output wire e_hi_oe,
    input wire [7:0] e_hi_in,
    output wire [3:0] e_ctl_out,
    output wire e_p30_out,
    output wire e_p30_oe
);

localparam [3:0] ST_POWER = 4'd0, ST_IDLE = 4'd1, ST_SH_DATA = 4'd2,
                 ST_SH_HIGH = 4'd3, ST_SH_LOW = 4'd4, ST_SETTLE = 4'd5,
                 ST_SETUP = 4'd6, ST_STROBE = 4'd7, ST_HOLD = 4'd8,
                 ST_DONE = 4'd9;

reg [3:0] state;
reg [21:0] wait_count;
reg [4:0] bank;
reg [7:0] block, want_block, shift_reg;
reg block_valid;
reg [2:0] bit_index;
reg [10:0] offset;
reg armed;
reg iodat, sysctl1, cs0_n;

wire enabled = lynx_mode && !reset;
wire [7:0] req_block = addr[15] ? {bank, addr[13:11]} : {4'd0, addr[14:11]};
wire write_allowed = addr >= 16'hFFFC;
wire request_allowed = wr ? write_allowed : addr < 16'hC000;
wire reading = state == ST_SETUP || state == ST_STROBE || state == ST_HOLD;

function [21:0] cycles(input integer n);
    cycles = (n > 0 ? n : 1) - 1;
endfunction

assign busy = state != ST_IDLE;
assign write_active = 1'b0;
assign e_ad_out = {5'd0, offset};
assign e_ad_oe = enabled && reading;
assign e_hi_out = 8'h00;
assign e_hi_oe = 1'b0;
assign e_ctl_out = enabled ? {iodat, 1'b1, cs0_n, sysctl1} : 4'hF;
assign e_p30_out = 1'b1;
assign e_p30_oe = enabled;

always @(posedge clk) begin
    done <= 1'b0;
    if (!enabled) begin
        state <= ST_POWER;
        wait_count <= cycles(POWER_CYCLES);
        bank <= 5'd2;
        block <= 0;
        want_block <= 0;
        shift_reg <= 0;
        block_valid <= 1'b0;
        bit_index <= 0;
        offset <= 0;
        armed <= 1'b1;
        iodat <= 1'b0;
        sysctl1 <= 1'b0;
        cs0_n <= 1'b1;
        rdata <= 8'hFF;
        rejected <= 1'b0;
    end else begin
        if (!req) armed <= 1'b1;
        case (state)
            ST_POWER: begin
                if (wait_count == 0) state <= ST_IDLE;
                else wait_count <= wait_count - 1'b1;
            end
            ST_IDLE: if (req && armed) begin
                armed <= 1'b0;
                rejected <= !request_allowed;
                if (!request_allowed) begin
                    rdata <= 8'hFF;
                    state <= ST_DONE;
                end else if (wr) begin
                    if (addr == 16'hFFFF) bank <= wdata[4:0];
                    state <= ST_DONE;
                end else begin
                    offset <= addr[10:0];
                    want_block <= req_block;
                    if (block_valid && block == req_block) begin
                        wait_count <= cycles(ADDR_SETUP_CYCLES);
                        state <= ST_SETUP;
                    end else begin
                        block_valid <= 1'b0;
                        shift_reg <= req_block;
                        bit_index <= 3'd7;
                        iodat <= req_block[7];
                        wait_count <= cycles(SHIFT_CYCLES);
                        state <= ST_SH_DATA;
                    end
                end
            end
            ST_SH_DATA: begin
                if (wait_count == 0) begin
                    sysctl1 <= 1'b1;
                    wait_count <= cycles(SHIFT_CYCLES);
                    state <= ST_SH_HIGH;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_SH_HIGH: begin
                if (wait_count == 0) begin
                    sysctl1 <= 1'b0;
                    wait_count <= cycles(SHIFT_CYCLES);
                    state <= ST_SH_LOW;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_SH_LOW: begin
                if (wait_count == 0) begin
                    if (bit_index == 0) begin
                        iodat <= 1'b0;
                        wait_count <= cycles(SETTLE_CYCLES);
                        state <= ST_SETTLE;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        shift_reg <= {shift_reg[6:0], 1'b0};
                        iodat <= shift_reg[6];
                        wait_count <= cycles(SHIFT_CYCLES);
                        state <= ST_SH_DATA;
                    end
                end else wait_count <= wait_count - 1'b1;
            end
            ST_SETTLE: begin
                if (wait_count == 0) begin
                    block <= want_block;
                    block_valid <= 1'b1;
                    wait_count <= cycles(ADDR_SETUP_CYCLES);
                    state <= ST_SETUP;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_SETUP: begin
                if (wait_count == 0) begin
                    cs0_n <= 1'b0;
                    wait_count <= cycles(STROBE_CYCLES);
                    state <= ST_STROBE;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_STROBE: begin
                if (wait_count == 1 || STROBE_CYCLES <= 1) rdata <= e_hi_in;
                if (wait_count == 0) begin
                    cs0_n <= 1'b1;
                    wait_count <= cycles(HOLD_CYCLES);
                    state <= ST_HOLD;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_HOLD: begin
                if (wait_count == 0) state <= ST_DONE;
                else wait_count <= wait_count - 1'b1;
            end
            ST_DONE: begin
                done <= 1'b1;
                state <= ST_IDLE;
            end
            default: begin
                cs0_n <= 1'b1;
                sysctl1 <= 1'b0;
                iodat <= 1'b0;
                state <= ST_IDLE;
            end
        endcase
    end
end
endmodule
`default_nettype wire
