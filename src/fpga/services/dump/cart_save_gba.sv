// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// cart_save_gba.sv - read the battery-backed SRAM out of a Game Boy Advance
// cartridge
//
// The GBA counterpart of cart_save_gb.sv, and far smaller than it, because
// there is no gate to open and no bank register to set. A GBA SRAM cartridge
// answers in the save window from the moment it is powered: select the
// address, pulse RD#, take the byte. The whole module is an address counter
// feeding a byte stream, the same shape as cart_dump_gba.
//
// **Whatever can be read without writing, and that is a deliberate limit
// rather than a first cut.** A GBA cartridge carries one of five save
// technologies and two of them answer plain reads in the save window:
//
//   SRAM 32 KiB       plain reads                             this module
//   FLASH 64 KiB      plain reads: the chip powers up in      this module
//                     read array mode and commands are only
//                     needed for ID, erase, program and bank
//                     select, none of which a backup does
//   FLASH 128 KiB     first bank would read, second needs a   refused
//                     bank select write, and half a save is
//                     worse than none
//   EEPROM 512 B      serial, the address is written in       refused
//   EEPROM 8 KiB      serial, the address is written in       refused
//
// Which of the two it is comes from the caller, off the ROM scan, and reaches
// this module only as a byte count. Nothing here behaves differently for
// Flash: the read is the same read.
//
// The three refusals are not caution for its own sake. Writing to a GBA
// cartridge is blocked by an open defect: aborting inside gba_cart_bus's
// ST_WRITE raises WR# and releases the data pins on the same instant, and a
// cartridge latches write data on the WR# rising edge, so the byte it
// captures is whatever the released bus settles to. In save space that is a
// corrupted byte in somebody's save file, in exactly the hot-unplug case it
// is most likely to happen. It is asserted in its real form in
// tb_gba_cart_async under a KNOWN DEFECT heading. Until that is fixed,
// nothing in this core may write to a GBA cartridge, and a save reader that
// needed a write would be the first thing to do it.
//
// So bus_wr is tied low here, as it is in cart_dump_gba, and there is no code
// path that could raise it. tb_gba_save_write_protect checks that at the
// connector pins across a whole read.
//
// Where the size comes from
// -------------------------
// From `size_bytes`, and from nowhere else, exactly as cart_dump_gba takes
// its ROM size from a probe rather than guessing. A GBA header carries no
// save type and no save size; the type is found by scanning the ROM for the
// signature string the SDK leaves in it, and the caller turns that into a
// byte count. Guessing here would put two different answers in the core.
//
// LIMIT: 64 KiB. gba_cart_bus uses latched_addr[15:0] as the address it
// drives in save space, so an offset past 0xFFFF wraps to the start of the
// window rather than reading anything new. That is exactly 64 KiB, which is
// the largest thing this module is ever asked for: a 128 KiB Flash would need
// the bank select write that gets it refused.
//
// Byte order does not arise. Save space is read a byte at a time - the bus
// replicates the byte across all four lanes of rdata and returns in one beat
// - so the stream is simply ascending addresses, low address first.
//
// Like cart_dump_gba, this module has no abort input: when it is waiting for
// a bus_done that is not coming, reset is the only thing that recovers it.
// dump_engine holds the mode for the whole read and drives reset on abort.
//

module cart_save_gba (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,          // pulse
    input  wire [31:0] size_bytes,     // from the caller's save type decision

    output reg         busy,
    output reg         done,
    output wire [31:0] total_bytes,

    // gba_cart_bus master port. The handshake rule is the one from
    // cart_identify_gba and cart_dump_gba: that bus samples req only in its
    // own idle state and has no refuse guard, so wait for !bus_busy, raise
    // req for one cycle, drop it, then wait for done. Holding req until done
    // issues a second transaction nobody asked for.
    output reg         bus_req,
    output wire        bus_wr,
    output reg  [27:0] bus_addr,
    output wire [1:0]  bus_acc,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy,

    // Byte stream out. Held until taken.
    output reg  [7:0]  out_data,
    output reg         out_valid,
    input  wire        out_ready
);

localparam [1:0] ACCESS_8BIT = 2'b00;

// The save window. gba_cart_bus decodes save space as addr[27:24] == 0xE or
// 0xF and asserts CS2# for it; 0xE is the base the GBA itself uses.
localparam [27:0] SAVE_BASE = 28'hE00_0000;

// Read-only by construction. cart_write_enable in gba_cart_bus requires
// latched_wr, so WR# cannot fall while this is low, whatever the address.
assign bus_wr    = 1'b0;
assign bus_acc   = ACCESS_8BIT;
assign bus_wdata = 32'd0;

// Straight through, so the caller sees the same number it supplied and the
// file header cannot disagree with the stream.
assign total_bytes = size_bytes;

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_REQ  = 3'd1;
localparam [2:0] ST_WAIT = 3'd2;
localparam [2:0] ST_EMIT = 3'd3;
localparam [2:0] ST_DONE = 3'd4;

reg [2:0]  state;
reg [31:0] offset;      // byte offset into the save window
reg [31:0] emitted;     // bytes accepted by the consumer so far

// >= rather than ==, so a caller who shrinks size_bytes mid-read gets a short
// file instead of a module that counts past its target.
wire [31:0] next_emitted = emitted + 32'd1;
wire        last_byte    = (next_emitted >= size_bytes);

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        offset    <= 32'd0;
        emitted   <= 32'd0;
        out_valid <= 1'b0;
        out_data  <= 8'd0;
        bus_addr  <= 28'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                busy      <= 1'b0;
                out_valid <= 1'b0;
                if (start) begin
                    busy    <= 1'b1;
                    offset  <= 32'd0;
                    emitted <= 32'd0;
                    // A zero-byte save is the right answer for a cartridge
                    // whose type was refused or not found. Finishing without
                    // a transaction keeps the connector alone.
                    state   <= (size_bytes == 32'd0) ? ST_DONE : ST_REQ;
                end
            end

            ST_REQ: begin
                bus_addr <= SAVE_BASE | {4'd0, offset[23:0]};
                if (!bus_busy) begin
                    bus_req <= 1'b1;
                    state   <= ST_WAIT;
                end
            end

            // Save space returns in one beat with the byte replicated across
            // rdata, so any lane would do; the low one is the one the bus
            // documents.
            ST_WAIT: begin
                if (bus_done) begin
                    out_data  <= bus_rdata[7:0];
                    out_valid <= 1'b1;
                    state     <= ST_EMIT;
                end
            end

            // out_data and out_valid change only when a byte is taken, so a
            // consumer that stalls for a thousand cycles sees the same byte
            // for a thousand cycles and takes it exactly once.
            ST_EMIT: begin
                if (out_ready) begin
                    emitted   <= next_emitted;
                    out_valid <= 1'b0;
                    if (last_byte) begin
                        state <= ST_DONE;
                    end else begin
                        offset <= offset + 32'd1;
                        state  <= ST_REQ;
                    end
                end
            end

            ST_DONE: begin
                busy      <= 1'b0;
                out_valid <= 1'b0;
                done      <= 1'b1;
                state     <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
