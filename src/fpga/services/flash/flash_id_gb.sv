// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

// Software ID probe for an SST39SF-family flash on a GB cartridge whose WE#
// is wired to /WR. Sequence from the SST39SF010A/020A/040 datasheet: Software
// ID Entry 5555:AA 2AAA:55 5555:90, read 0000 and 0001, Software ID Exit F0.
// Cartridge wiring reference: FlashGBX config fc_DMG_FerranteCrafts_32KB_2.txt.
//
// No erase or program command is formed. The command writes also land on MBC5
// registers, so ROM bank 1, RAM bank 0 and RAM disabled are written back after.
// Once the first command write is issued the sequence runs to the end unless
// slot power is lost.
module flash_id_gb #(
    parameter integer WAKE_CYCLES = 201326592
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire        cancel,
    input  wire        cart_powered,
    input  wire        mode_ready,

    output wire [1:0]  want_mode,
    output reg         busy,
    output reg         done,
    output reg         failed,

    output reg  [15:0] rom_before,   // {byte at 0000, byte at 0001}
    output reg  [15:0] flash_id,
    output reg  [15:0] rom_after,
    output reg         answered,     // flash_id differs from rom_before
    output reg         unchanged,    // rom_after equals rom_before

    output reg         bus_req,
    output reg         bus_wr,
    output reg  [15:0] bus_addr,
    output reg  [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

localparam [3:0] LAST_STEP   = 4'd13;
localparam [3:0] FIRST_WRITE = 4'd2;

// {wr, addr, data}
function [24:0] step_of(input [3:0] n);
    case (n)
        4'd0:    step_of = {1'b0, 16'h0000, 8'h00};
        4'd1:    step_of = {1'b0, 16'h0001, 8'h00};
        4'd2:    step_of = {1'b1, 16'h2000, 8'h01};   // ROM bank 1, so 5555 reaches flash 5555
        4'd3:    step_of = {1'b1, 16'h5555, 8'hAA};
        4'd4:    step_of = {1'b1, 16'h2AAA, 8'h55};
        4'd5:    step_of = {1'b1, 16'h5555, 8'h90};
        4'd6:    step_of = {1'b0, 16'h0000, 8'h00};
        4'd7:    step_of = {1'b0, 16'h0001, 8'h00};
        4'd8:    step_of = {1'b1, 16'h0000, 8'hF0};   // ID exit; also leaves RAM disabled
        4'd9:    step_of = {1'b1, 16'h2000, 8'h01};
        4'd10:   step_of = {1'b1, 16'h4000, 8'h00};
        4'd11:   step_of = {1'b1, 16'h0000, 8'h00};
        4'd12:   step_of = {1'b0, 16'h0000, 8'h00};
        default: step_of = {1'b0, 16'h0001, 8'h00};
    endcase
endfunction

localparam [2:0] S_IDLE = 3'd0, S_WAKE = 3'd1, S_LOAD = 3'd2, S_REQ = 3'd3,
                 S_WAIT = 3'd4, S_DRAIN = 3'd5;

reg [2:0]  state;
reg [3:0]  step;
reg [27:0] timer;
reg        mode_owned;
reg        fail_l;

assign want_mode = mode_owned ? 2'b10 : 2'b00;

wire [24:0] cur = step_of(step);
wire committed = step > FIRST_WRITE || (step == FIRST_WRITE && state != S_LOAD);

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state      <= S_IDLE;
        step       <= 4'd0;
        timer      <= 28'd0;
        mode_owned <= 1'b0;
        fail_l     <= 1'b0;
        busy       <= 1'b0;
        failed     <= 1'b0;
        rom_before <= 16'd0;
        flash_id   <= 16'd0;
        rom_after  <= 16'd0;
        answered   <= 1'b0;
        unchanged  <= 1'b0;
        bus_wr     <= 1'b0;
        bus_addr   <= 16'd0;
        bus_wdata  <= 8'd0;
    end else begin
        case (state)
            S_IDLE: begin
                if (start && cart_powered && !cancel) begin
                    busy       <= 1'b1;
                    failed     <= 1'b0;
                    fail_l     <= 1'b0;
                    mode_owned <= 1'b1;
                    step       <= 4'd0;
                    timer      <= WAKE_CYCLES;
                    state      <= S_WAKE;
                end
            end

            S_WAKE: begin
                if (!cart_powered || cancel) begin
                    fail_l <= 1'b1;
                    state  <= S_DRAIN;
                end else if (!mode_ready) begin
                    timer <= WAKE_CYCLES;
                end else if (timer != 28'd0) begin
                    timer <= timer - 28'd1;
                end else begin
                    state <= S_LOAD;
                end
            end

            S_LOAD: begin
                if (!cart_powered || !mode_ready || (cancel && !committed)) begin
                    fail_l <= 1'b1;
                    state  <= S_DRAIN;
                end else if (!bus_busy && !bus_done) begin
                    bus_wr    <= cur[24];
                    bus_addr  <= cur[23:8];
                    bus_wdata <= cur[7:0];
                    state     <= S_REQ;
                end
            end

            // Address and data were registered one clock ago. The bus was idle
            // then and only a request can move it, so this one-clock request
            // is accepted.
            S_REQ: begin
                bus_req <= 1'b1;
                state   <= S_WAIT;
            end

            S_WAIT: begin
                if (bus_done) begin
                    case (step)
                        4'd0:  rom_before[15:8] <= bus_rdata;
                        4'd1:  rom_before[7:0]  <= bus_rdata;
                        4'd6:  flash_id[15:8]   <= bus_rdata;
                        4'd7:  flash_id[7:0]    <= bus_rdata;
                        4'd12: rom_after[15:8]  <= bus_rdata;
                        4'd13: rom_after[7:0]   <= bus_rdata;
                        default: ;
                    endcase
                    if (step == LAST_STEP) begin
                        state <= S_DRAIN;
                    end else begin
                        step  <= step + 4'd1;
                        state <= S_LOAD;
                    end
                end else if (!cart_powered || (!mode_ready && !bus_req)) begin
                    // The bus drops a transaction without done when the mode
                    // goes away.
                    fail_l <= 1'b1;
                    state  <= S_DRAIN;
                end
            end

            // The mode is released only with the bus idle.
            S_DRAIN: begin
                if (!bus_busy || !cart_powered) begin
                    mode_owned <= 1'b0;
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    failed     <= fail_l;
                    answered   <= flash_id != rom_before;
                    unchanged  <= rom_after == rom_before;
                    state      <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
