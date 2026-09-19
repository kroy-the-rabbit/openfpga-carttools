// Sega ROM mapper model, independent of the adapter-address permutation.
// Defaults to the mapper revision with fixed slots 0 and 1. A dumper which
// selects a bank but reads slot 1 will therefore duplicate data and fail.
`default_nettype none
`timescale 1ns/1ps
module gg_cart_model #(
    parameter integer ROM_BYTES = 524288,
    parameter integer SLOT1_FIXED = 1,
    parameter integer MIN_HOLD_NS = 0
) (
    input wire [15:0] e_ad_out,
    input wire e_ad_oe,
    input wire [7:0] e_hi_out,
    input wire e_hi_oe,
    input wire [3:0] e_ctl_out,
    input wire e_p30_out,
    input wire e_p30_oe,
    output wire [7:0] e_hi_in,
    output reg [31:0] rom_read_count = 0,
    output reg [31:0] mapper_write_count = 0,
    output reg [31:0] save_write_count = 0,
    output reg [31:0] eeprom_enable_count = 0,
    output reg [31:0] eeprom_command_count = 0,
    output reg [7:0] bank2 = 2
);
reg [7:0] rom [0:ROM_BYTES-1];
reg [7:0] bank0 = 0, bank1 = 1;
reg eeprom_enabled = 0;
wire live = e_p30_oe && e_p30_out;
wire iorq_n = e_ctl_out[3], wr_n = e_ctl_out[2];
wire rd_n = e_ctl_out[1], ce_n = e_ctl_out[0];
wire driving = live && !ce_n && !rd_n && wr_n && e_ad_out < 16'hC000;
wire [7:0] mapped_bank = e_ad_out < 16'h4000 ?
                          ((SLOT1_FIXED || e_ad_out < 16'h0400) ? 8'd0 : bank0) :
                        e_ad_out < 16'h8000 ? (SLOT1_FIXED ? 8'd1 : bank1) : bank2;
wire [21:0] linear_addr = {mapped_bank, e_ad_out[13:0]};
assign e_hi_in = driving ? rom[linear_addr % ROM_BYTES] : 8'hFF;

always @(negedge e_p30_oe or negedge e_p30_out) begin
    bank0 = 0;
    bank1 = 1;
    bank2 = 2;
    eeprom_enabled = 0;
end

always @(*) begin
    if (driving && e_hi_oe)
        $fatal(1, "GG data contention at %04x", e_ad_out);
end

always @(negedge rd_n) begin
    #1;
    if (live) begin
        if (!iorq_n || ce_n || !wr_n || !e_ad_oe || e_hi_oe)
            $fatal(1, "GG invalid ROM-read controls at %04x", e_ad_out);
        if (e_ad_out >= 16'hC000)
            $fatal(1, "GG read outside ROM space");
        rom_read_count = rom_read_count + 1;
    end
end

reg have_write = 0;
time write_edge = 0;
reg [15:0] held_addr;
reg [7:0] held_data;
always @(posedge wr_n) begin
    if (live && e_ad_oe && e_hi_oe && !ce_n) begin
        if (!iorq_n || !rd_n)
            $fatal(1, "GG invalid mapper-write controls");
        have_write = 1;
        write_edge = $time;
        held_addr = e_ad_out;
        held_data = e_hi_out;
        if (e_ad_out >= 16'hFFFC) begin
            mapper_write_count = mapper_write_count + 1;
            case (e_ad_out)
                16'hFFFC: begin
                    eeprom_enabled = e_hi_out[3];
                    if (e_hi_out[3]) eeprom_enable_count = eeprom_enable_count + 1;
                end
                16'hFFFD: bank0 = e_hi_out;
                16'hFFFE: bank1 = e_hi_out;
                16'hFFFF: bank2 = e_hi_out;
            endcase
        end else if (e_ad_out >= 16'h8000 && e_ad_out < 16'hC000) begin
            save_write_count = save_write_count + 1;
            if (eeprom_enabled && e_ad_out == 16'h8000)
                eeprom_command_count = eeprom_command_count + 1;
        end
    end
end

always @(e_ad_out or e_ad_oe or e_hi_out or e_hi_oe or e_p30_oe or e_p30_out) begin
    // Let combinational mode-loss gating settle before distinguishing an
    // actual disconnect from an early release while the cartridge is live.
    #0;
    if (live && have_write && $time - write_edge < MIN_HOLD_NS) begin
        if (!e_ad_oe || !e_hi_oe || e_ad_out !== held_addr || e_hi_out !== held_data)
            $fatal(1, "GG mapper write-data/address hold shortened: %0t ns", $time - write_edge);
    end
end
endmodule
`default_nettype wire
