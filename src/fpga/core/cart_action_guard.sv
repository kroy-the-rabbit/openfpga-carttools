// SPDX-License-Identifier: GPL-3.0-or-later
//
// cart_action_guard.sv - revalidate a cartridge before creating a file
//
// A physical cartridge swap does not necessarily move cart_play or
// cart_power. Any identity left from the previous cartridge is therefore a
// cache, not proof that the same cartridge is still present. X and Y queue an
// action here, cause a fresh read-only scan, and only reach dump_engine after
// the new scan and any platform-specific follow-up have completed.
//
// The caller decides what "validation complete" means. GB finishes with the
// header probe. GBA ROM needs the size probe, while GBA save also needs the
// save-type scan and, for EEPROM, the width probe.

`default_nettype none

module cart_action_guard (
    input  wire clk,
    input  wire reset,
    input  wire cancel,

    input  wire request_rom,
    input  wire request_save,
    input  wire rom_available,
    input  wire save_available,

    input  wire validation_complete,
    input  wire validated_rom_available,
    input  wire validated_save_available,

    output reg  scan_start,
    output reg  dump_start,
    output reg  save_mode,
    output reg  pending
);

always @(posedge clk) begin
    scan_start <= 1'b0;
    dump_start <= 1'b0;

    if (reset || cancel) begin
        pending   <= 1'b0;
        save_mode <= 1'b0;
    end else if (!pending) begin
        if (request_rom && rom_available) begin
            pending    <= 1'b1;
            save_mode  <= 1'b0;
            scan_start <= 1'b1;
        end else if (request_save && save_available) begin
            pending    <= 1'b1;
            save_mode  <= 1'b1;
            scan_start <= 1'b1;
        end
    end else if (validation_complete) begin
        pending <= 1'b0;
        if (save_mode ? validated_save_available
                      : validated_rom_available)
            dump_start <= 1'b1;
    end
end

endmodule

`default_nettype wire
