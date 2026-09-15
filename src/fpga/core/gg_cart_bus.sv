// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Memory cycles for the official Analogue Game Gear adapter. The pin owner
// permutes logical address bits; this engine never names connector pins.
// Unlike GB, /CE selects ROM as well as mapper writes, and the top control
// bit is /IOREQ, which stays inactive. GG CLK is tied high in the adapter.
//
// The first qualified profile is Sega ROM banking up to 512 KiB. Its only
// permitted writes disable RAM/EEPROM or select ROM banks. In particular,
// neither EEPROM-enable values at FFFC nor serial commands at 8000 can pass.
// Rejected requests still complete, without changing any cartridge strobe.
//
// Timing parameters count complete clocks, with a minimum of one each. At
// 100.663296 MHz the defaults are about 0.5 us setup, 1 us strobe, 0.5 us hold.
// They are conservative bring-up values, not hardware-qualified timings.
module gg_cart_bus #(
    parameter integer ADDR_SETUP_CYCLES = 50,
    parameter integer STROBE_CYCLES = 100,
    parameter integer HOLD_CYCLES = 50
) (
    input wire clk,
    input wire reset,
    input wire gg_mode,
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

localparam integer MAX_A = ADDR_SETUP_CYCLES > STROBE_CYCLES ? ADDR_SETUP_CYCLES : STROBE_CYCLES;
localparam integer MAX_CYCLES = MAX_A > HOLD_CYCLES ? MAX_A : HOLD_CYCLES;
localparam integer COUNT_WIDTH = MAX_CYCLES > 1 ? $clog2(MAX_CYCLES) : 1;
localparam [COUNT_WIDTH-1:0] SETUP_COUNT = (ADDR_SETUP_CYCLES > 0 ? ADDR_SETUP_CYCLES : 1) - 1;
localparam [COUNT_WIDTH-1:0] STROBE_COUNT = (STROBE_CYCLES > 0 ? STROBE_CYCLES : 1) - 1;
localparam [COUNT_WIDTH-1:0] HOLD_COUNT = (HOLD_CYCLES > 0 ? HOLD_CYCLES : 1) - 1;
localparam [2:0] ST_IDLE = 3'd0, ST_SETUP = 3'd1, ST_STROBE = 3'd2,
                 ST_HOLD = 3'd3, ST_DONE = 3'd4;

reg [2:0] state;
reg [COUNT_WIDTH-1:0] wait_count;
reg [15:0] latched_addr;
reg [7:0] latched_wdata;
reg latched_wr;
reg armed;
reg rd_n, wr_n, ce_n;
wire enabled = gg_mode && !reset;
wire transaction = state == ST_SETUP || state == ST_STROBE || state == ST_HOLD;
wire write_allowed = (addr == 16'hFFFC && wdata == 8'h00) ||
                     (addr == 16'hFFFD && wdata == 8'h00) ||
                     (addr == 16'hFFFE && wdata == 8'h01) ||
                     (addr == 16'hFFFF && wdata <= 8'h1F);
wire request_allowed = wr ? write_allowed : addr < 16'hC000;

assign busy = state != ST_IDLE;
// Includes setup and the full write-data hold window after /WR rises. The
// outer mode owner uses this to drain normal cancellation without cutting a
// mapper-write pulse or removing data on its latching edge.
assign write_active = enabled && transaction && latched_wr;
assign e_ad_out = latched_addr;
assign e_ad_oe = enabled && transaction;
assign e_hi_out = latched_wdata;
assign e_hi_oe = enabled && transaction && latched_wr;
assign e_ctl_out = enabled ? {1'b1, wr_n, rd_n, ce_n} : 4'hF;
assign e_p30_out = 1'b1;
assign e_p30_oe = enabled;

always @(posedge clk) begin
    done <= 1'b0;
    if (!enabled) begin
        state <= ST_IDLE;
        wait_count <= 0;
        latched_addr <= 0;
        latched_wdata <= 0;
        latched_wr <= 0;
        armed <= 1'b1;
        rd_n <= 1'b1;
        wr_n <= 1'b1;
        ce_n <= 1'b1;
        rdata <= 8'hFF;
        rejected <= 1'b0;
    end else begin
        // A held request is consumed only once, even if the requester takes
        // several clocks after done to lower it.
        if (!req) armed <= 1'b1;
        case (state)
            ST_IDLE: if (req && armed) begin
                armed <= 1'b0;
                rejected <= !request_allowed;
                if (request_allowed) begin
                    latched_addr <= addr;
                    latched_wdata <= wdata;
                    latched_wr <= wr;
                    wait_count <= SETUP_COUNT;
                    state <= ST_SETUP;
                end else begin
                    rdata <= 8'hFF;
                    state <= ST_DONE;
                end
            end
            ST_SETUP: begin
                if (wait_count == 0) begin
                    ce_n <= 1'b0;
                    wr_n <= !latched_wr;
                    rd_n <= latched_wr;
                    wait_count <= STROBE_COUNT;
                    state <= ST_STROBE;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_STROBE: begin
                // Sample while the cartridge remains selected, one complete
                // clock before the rising strobe when timing permits.
                if (!latched_wr && (wait_count == 1 || STROBE_CYCLES <= 1))
                    rdata <= e_hi_in;
                if (wait_count == 0) begin
                    rd_n <= 1'b1;
                    wr_n <= 1'b1;
                    wait_count <= HOLD_COUNT;
                    state <= ST_HOLD;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_HOLD: begin
                if (wait_count == 0) begin
                    ce_n <= 1'b1;
                    state <= ST_DONE;
                end else wait_count <= wait_count - 1'b1;
            end
            ST_DONE: begin
                done <= 1'b1;
                state <= ST_IDLE;
            end
            default: begin
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                ce_n <= 1'b1;
                state <= ST_IDLE;
            end
        endcase
    end
end
endmodule
`default_nettype wire
