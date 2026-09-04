// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// gba_save_scan.sv - find a GBA cartridge's save technology by reading its ROM
//
// A GBA header carries no save type and no save size. What it does carry,
// everywhere except a handful of unlicensed carts, is the SDK's save library
// leaving its own name in the image as a plain ASCII string. Every dumper
// worth the name keys off those strings and so does this:
//
//   EEPROM_V       EEPROM, 512 B or 8 KiB, the string does not say which
//   SRAM_V         SRAM, 32 KiB
//   SRAM_F_V       FRAM in the SRAM window, 32 KiB, read identically
//   FLASH_V        Flash, 64 KiB
//   FLASH512_V     Flash, 64 KiB
//   FLASH1M_V      Flash, 128 KiB
//
// **Why a string and not a probe.** Every other way of telling these apart
// requires writing to the cartridge: Flash is identified by a command
// sequence, EEPROM by clocking an address in. Writing to a GBA cartridge is
// blocked by an open defect in gba_cart_bus, recorded under a KNOWN DEFECT
// heading in tb_gba_cart_async, and a save is the one thing a stray write
// destroys irrecoverably. Reading the ROM costs time and nothing else.
//
// **This does not resolve a type, it reports what it saw.** The caller
// decides. That split is deliberate: a cartridge carrying two different
// families of string is a real thing, usually a multi-game cart or a
// reproduction, and the honest answer there is that it is ambiguous rather
// than whichever match came first. plan.md Phase 12 says ambiguous cases are
// reported as ambiguous, and a module that returned a single winner would
// have thrown that away before the caller ever saw it.
//
// So the output is a bitmask, one bit per signature, plus `ambiguous` when
// more than one family is present. Sizes and refusals belong to the caller.
//
// How the matching works
// ----------------------
// A rolling window of the last ten bytes, ten being the longest signature.
// Every byte shifts the window and every signature compares against the
// suffix of its own length. That is a handful of byte comparators and no
// state machine per pattern, which matters because this is on the same die as
// ui_screen's critical path and nothing here should need to be timed.
//
// The window is not cleared between the 32-bit reads that fill it, so a
// signature straddling a word boundary is found. It is cleared at the start
// of a scan, and a signature can therefore never be reported from the tail of
// a previous cartridge.
//
// Bytes are consumed in ascending address order. GBA ROM is little-endian and
// gba_cart_bus returns {second halfword, first halfword}, so the four bytes of
// a word are emitted low byte first, exactly as cart_dump_gba emits them.
//
// LIMIT: whatever `rom_size_bytes` says, capped by the 32 MiB the connector
// can address. A size of zero scans nothing and reports nothing found, which
// is the right answer when the size probe found no cartridge.
//
// This module never writes. bus_wr is tied low and there is no code path that
// could raise it.
//

module gba_save_scan #(
    // Long enough for cart_pins to turn the connector round, which takes
    // sixteen cycles, with room to spare. Same value gba_size_probe uses.
    parameter integer MODE_WAIT_CYCLES = 4096
) (
    input  wire        clk,
    input  wire        reset,

    // The connector's actual state, not the request. gba_cart_bus ignores
    // requests while this is low and never raises done, so a scan that does
    // not wait for it hangs, and a scan that does not notice it dropping hangs
    // on the request already outstanding. gba_size_probe learned both of those
    // the hard way and this module did not, which cost a shipped core.
    input  wire        cart_mode,

    input  wire        start,             // pulse
    input  wire [31:0] rom_size_bytes,    // from gba_size_probe

    // Interrupt a scan that is running, without destroying one that finished.
    // A dump takes the GBA bus through core_top's mux, so a scan underneath it
    // waits for a done that never comes. The interrupted scan restarts from
    // byte zero when the dump releases the bus. It was a reset once, and a
    // reset also cleared the seen bits, so dumping a ROM silently threw away a
    // completed scan and the save button vanished until the cartridge was
    // rescanned. A partial result is never reported as a whole one.
    input  wire        abort,

    output reg         busy,
    output reg         done,

    // The connector must be in GBA mode for the whole scan, and by the time
    // this starts cart_probe has already parked the mode at idle: the size
    // probe hits the same problem and solves it the same way. Without this the
    // bus sits with cart_mode low, gba_cart_bus holds its FSM in ST_IDLE and
    // never raises done, and this module waits for a done that is not coming
    // with busy stuck high. That is not hypothetical; it shipped to a card
    // once and froze the core. core_top's mode mux honours this.
    output reg         want_gba,

    // One bit per signature, latched across a whole scan. Held after done
    // until the next start.
    output wire        found_eeprom,
    output wire        found_sram,
    output wire        found_sram_f,
    output wire        found_flash,
    output wire        found_flash512,
    output wire        found_flash1m,

    // More than one family present. The caller must refuse rather than pick.
    output wire        ambiguous,
    output wire        found_any,

    // The whole ROM was read. Low when the scan gave up waiting for the
    // connector or the mode dropped underneath it. Without this, an abandoned
    // scan and a ROM with no save string are the same answer, and only one of
    // them means the cartridge has no save.
    output reg         complete,

    // gba_cart_bus master port. Same handshake rule as cart_dump_gba: wait for
    // !bus_busy, raise req for one cycle, drop it, then wait for done.
    output reg         bus_req,
    output wire        bus_wr,
    output reg  [27:0] bus_addr,
    output wire [1:0]  bus_acc,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

localparam [1:0] ACCESS_32BIT = 2'b10;

assign bus_wr    = 1'b0;
assign bus_acc   = ACCESS_32BIT;
assign bus_wdata = 32'd0;

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_MODE = 3'd1;
localparam [2:0] ST_REQ  = 3'd2;
localparam [2:0] ST_WAIT = 3'd3;
localparam [2:0] ST_FEED = 3'd4;
localparam [2:0] ST_DONE = 3'd5;
localparam [2:0] ST_RETRY = 3'd6;

reg [2:0]  state;
reg [15:0] mode_wait;
reg [27:0] addr;
reg [31:0] word;
reg [1:0]  bsel;

// The rolling window. w[0] is the most recent byte, w[9] the oldest, so a
// signature reads backwards across the array and every comparison below is
// written in that order.
reg [7:0] w [0:9];
integer   k;

wire [7:0] cur_byte = (bsel == 2'd0) ? word[7:0]   :
                      (bsel == 2'd1) ? word[15:8]  :
                      (bsel == 2'd2) ? word[23:16] :
                                       word[31:24];

// The window as it will be after this byte is shifted in. Comparing against
// the registered window instead would evaluate one byte behind, and a
// signature ending on the very last byte of the ROM would never be tested,
// because the scan finishes on the same cycle that byte is fed.
wire [7:0] nw0 = cur_byte;
wire [7:0] nw1 = w[0];
wire [7:0] nw2 = w[1];
wire [7:0] nw3 = w[2];
wire [7:0] nw4 = w[3];
wire [7:0] nw5 = w[4];
wire [7:0] nw6 = w[5];
wire [7:0] nw7 = w[6];
wire [7:0] nw8 = w[7];
wire [7:0] nw9 = w[8];

// "EEPROM_V", eight bytes.
wire hit_eeprom = nw7 == "E" && nw6 == "E" && nw5 == "P" && nw4 == "R" &&
                  nw3 == "O" && nw2 == "M" && nw1 == "_" && nw0 == "V";

// "SRAM_V", six bytes. "SRAM_F_V" also ends in _V but has F_ before it, so the
// two are distinguished by their own comparisons rather than by ordering.
wire hit_sram   = nw5 == "S" && nw4 == "R" && nw3 == "A" && nw2 == "M" &&
                  nw1 == "_" && nw0 == "V";

// "SRAM_F_V", eight bytes.
wire hit_sram_f = nw7 == "S" && nw6 == "R" && nw5 == "A" && nw4 == "M" &&
                  nw3 == "_" && nw2 == "F" && nw1 == "_" && nw0 == "V";

// "FLASH_V", seven bytes.
wire hit_flash  = nw6 == "F" && nw5 == "L" && nw4 == "A" && nw3 == "S" &&
                  nw2 == "H" && nw1 == "_" && nw0 == "V";

// "FLASH512_V", ten bytes.
wire hit_flash512 = nw9 == "F" && nw8 == "L" && nw7 == "A" && nw6 == "S" &&
                    nw5 == "H" && nw4 == "5" && nw3 == "1" && nw2 == "2" &&
                    nw1 == "_" && nw0 == "V";

// "FLASH1M_V", nine bytes.
wire hit_flash1m = nw8 == "F" && nw7 == "L" && nw6 == "A" && nw5 == "S" &&
                   nw4 == "H" && nw3 == "1" && nw2 == "M" && nw1 == "_" &&
                   nw0 == "V";

reg seen_eeprom, seen_sram, seen_sram_f, seen_flash, seen_flash512, seen_flash1m;

assign found_eeprom   = seen_eeprom;
assign found_sram     = seen_sram;
assign found_sram_f   = seen_sram_f;
assign found_flash    = seen_flash;
assign found_flash512 = seen_flash512;
assign found_flash1m  = seen_flash1m;

// Families, not signatures. SRAM_V and SRAM_F_V are the same technology read
// the same way, and the three Flash strings are all Flash, so a cartridge
// carrying both Flash strings is not ambiguous. A cartridge carrying an SRAM
// string and a Flash string is.
wire fam_eeprom = seen_eeprom;
wire fam_sram   = seen_sram | seen_sram_f;
wire fam_flash  = seen_flash | seen_flash512 | seen_flash1m;

assign found_any = fam_eeprom | fam_sram | fam_flash;
assign ambiguous = (fam_eeprom & fam_sram) | (fam_eeprom & fam_flash) |
                   (fam_sram   & fam_flash);

wire [31:0] next_addr = addr + 32'd4;
wire        at_end    = (next_addr >= rom_size_bytes);

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        want_gba  <= 1'b0;
        complete  <= 1'b0;
        mode_wait <= 16'd0;
        addr     <= 28'd0;
        word     <= 32'd0;
        bsel     <= 2'd0;
        bus_addr <= 28'd0;
        seen_eeprom   <= 1'b0;
        seen_sram     <= 1'b0;
        seen_sram_f   <= 1'b0;
        seen_flash    <= 1'b0;
        seen_flash512 <= 1'b0;
        seen_flash1m  <= 1'b0;
        for (k = 0; k < 10; k = k + 1) w[k] <= 8'h00;
    end else if (busy && abort) begin
        bus_req  <= 1'b0;
        complete <= 1'b0;
        state    <= ST_RETRY;
    end else if (state != ST_IDLE && state != ST_MODE && state != ST_DONE &&
                 state != ST_RETRY && !cart_mode) begin
        // The connector left GBA mode underneath us. gba_cart_bus has reset
        // and will never answer the outstanding request, so stop rather than
        // hang, and report nothing rather than a result gathered across a mode
        // change. ST_DONE is excluded for the reason gba_size_probe documents:
        // without that, a scan started with cart_mode already low re-enters
        // this branch forever, busy stuck high and done never pulsing, which
        // is the hang the branch exists to prevent.
        bus_req  <= 1'b0;
        complete <= 1'b0;
        state    <= ST_DONE;
    end else begin
        case (state)
            ST_IDLE: begin
                busy     <= 1'b0;
                want_gba <= 1'b0;
                if (start) begin
                    busy      <= 1'b1;
                    want_gba  <= 1'b1;
                    mode_wait <= MODE_WAIT_CYCLES[15:0];
                    addr <= 28'd0;
                    bsel <= 2'd0;
                    // Cleared here, so a signature can never be reported from
                    // the tail of the previous cartridge's scan.
                    seen_eeprom   <= 1'b0;
                    seen_sram     <= 1'b0;
                    seen_sram_f   <= 1'b0;
                    seen_flash    <= 1'b0;
                    seen_flash512 <= 1'b0;
                    seen_flash1m  <= 1'b0;
                    for (k = 0; k < 10; k = k + 1) w[k] <= 8'h00;
                    // A ROM too small to hold a signature is a complete scan
                    // of nothing, not an abandoned one.
                    complete <= (rom_size_bytes >= 32'd4);
                    state    <= (rom_size_bytes < 32'd4) ? ST_DONE : ST_MODE;
                end
            end

            // The mode was asked for one cycle ago and cart_pins takes sixteen
            // to turn the connector round, so cart_mode is still low even on a
            // good cartridge. Waiting is not optional: a request issued now is
            // ignored and done never comes. The timeout is what turns an
            // unpowered slot into an answer instead of a hang.
            ST_MODE: begin
                if (cart_mode) begin
                    state <= ST_REQ;
                end else if (mode_wait == 16'd0) begin
                    complete <= 1'b0;
                    state    <= ST_DONE;
                end else begin
                    mode_wait <= mode_wait - 16'd1;
                end
            end

            ST_REQ: begin
                bus_addr <= addr;
                if (!bus_busy) begin
                    bus_req <= 1'b1;
                    state   <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                if (bus_done) begin
                    word  <= bus_rdata;
                    bsel  <= 2'd0;
                    state <= ST_FEED;
                end
            end

            // One byte per cycle into the window. Four cycles per word against
            // the tens of cycles the read itself costs, so this is not what
            // sets the pace of a scan.
            ST_FEED: begin
                w[0] <= cur_byte;
                for (k = 1; k < 10; k = k + 1) w[k] <= w[k-1];

                if (hit_eeprom)   seen_eeprom   <= 1'b1;
                if (hit_sram)     seen_sram     <= 1'b1;
                if (hit_sram_f)   seen_sram_f   <= 1'b1;
                if (hit_flash)    seen_flash    <= 1'b1;
                if (hit_flash512) seen_flash512 <= 1'b1;
                if (hit_flash1m)  seen_flash1m  <= 1'b1;

                if (bsel == 2'd3) begin
                    if (at_end) begin
                        state <= ST_DONE;
                    end else begin
                        addr  <= next_addr[27:0];
                        state <= ST_REQ;
                    end
                end else begin
                    bsel <= bsel + 2'd1;
                end
            end

            // A dump interrupted this scan and has now released the bus.
            // Begin again rather than publishing the partial result. Starting
            // at byte zero is required because a save signature may have
            // straddled the interrupted read or may have occurred before it.
            ST_RETRY: begin
                busy      <= 1'b1;
                want_gba  <= 1'b1;
                mode_wait <= MODE_WAIT_CYCLES[15:0];
                addr      <= 28'd0;
                bsel      <= 2'd0;
                seen_eeprom   <= 1'b0;
                seen_sram     <= 1'b0;
                seen_sram_f   <= 1'b0;
                seen_flash    <= 1'b0;
                seen_flash512 <= 1'b0;
                seen_flash1m  <= 1'b0;
                for (k = 0; k < 10; k = k + 1) w[k] <= 8'h00;
                complete <= (rom_size_bytes >= 32'd4);
                state    <= (rom_size_bytes < 32'd4) ? ST_DONE : ST_MODE;
            end

            ST_DONE: begin
                busy     <= 1'b0;
                want_gba <= 1'b0;
                done     <= 1'b1;
                state    <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
