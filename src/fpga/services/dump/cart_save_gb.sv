// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// cart_save_gb.sv - read the battery-backed RAM out of a GB or GBC cartridge
//
// The save is the only thing in a cartridge that is not recoverable from
// anywhere else. A ROM dump that goes wrong wastes a minute; there is no
// No-Intro record of somebody's save file. Everything below is shaped by that.
//
// Reaching the RAM at all requires putting the cartridge into the one state
// where a stray write would land on it:
//
//   enable   write 0x0A to 0x0000-0x1FFF
//   read     0xA000-0xBFFF, /CS low, which gb_cart_bus derives from the
//            address rather than taking from here
//   disable  write 0x00 to 0x0000-0x1FFF
//
// **The invariant is that this module never sets bus_wr with an address in
// 0xA000-0xBFFF.** That single sentence covers every way this operation can
// destroy a save, and tb_gb_save_write_protect checks it continuously over
// every transaction, mutation checked. The two writes above are to ROM space,
// where /CS stays high; gb_cart_bus asserts /CS for 0xA000-0xBFFF and nothing
// else, so a write cannot reach the RAM even if this module asked for one.
//
// The enabled window is kept as short as the operation allows: enable, read,
// disable, and the disable happens on every exit including an abort. An abort
// that leaves the RAM enabled is worse than an abort that fails loudly, since
// the cartridge then leaves the slot with its write gate open.
//
// What this does not do: it never writes a byte into 0xA000-0xBFFF. Restore
// is a separate operation and a separate argument.
//
// ---- Banking, and a coverage claim that was wrong --------------------------
//
// This module first shipped reading one bank and refusing everything else, on
// the evidence that all ten battery-backed cartridges here report RAM size
// 0x02, 8 KB, one bank. That survey was taken over the nineteen filed images
// and the nineteen matched official ROMs, and it was wrong, because the set
// had a hole in it: Link's Awakening DX is 1 MB, MBC5 + RAM + battery, and
// **32 KB of save RAM in four banks**. Its image is missing from the library
// precisely because it and Link's Awakening both title themselves ZELDA, and
// the second dump overwrote the first - the collision bug in
// docs/HANDOFF.md item 2. The first cartridge anyone tried the save path on
// was that one, and it was silently refused.
//
// So the banking is here, and it is exercised by hardware after all.
//
//   0x0149 = 0x00   none                       refused, nothing to read
//   0x0149 = 0x01   2 KB, one partial bank     supported
//   0x0149 = 0x02   8 KB, one bank             supported
//   0x0149 = 0x03   32 KB, four banks          supported
//   0x0149 = 0x05   64 KB, eight banks         supported, MBC5 only
//   0x0149 = 0x04   128 KB, sixteen banks      supported, MBC5 only
//   MBC2 (0x0147 = 0x05/0x06)                  refused: 512 nibbles inside
//                                              the mapper, and 0x0149 reads
//                                              0x00 even though RAM exists
//
// Two traps, one per mapper, and each is the reason for a specific write:
//
// **MBC1 needs mode 1 to reach any RAM bank but 0.** In mode 0 the two bits
// at 0x4000 extend the ROM bank instead, so a banked read in mode 0 returns
// bank 0 four times over - a 32 KB file that looks entirely plausible. Mode 1
// is written before the banked read and **mode 0 is written back afterwards**,
// because the mode register persists and a ROM dump that followed would
// otherwise bank wrongly.
//
// **MBC3 maps its clock registers over the RAM window** when 0x08-0x0C is
// written to 0x4000. This module writes only 0x00-0x03 there, so the RTC can
// never be read and filed as save data. MBC3 tops out at 32 KB, so the wider
// sizes are refused for it rather than masked - a bank number this module
// cannot express is not one it should truncate.
//

module cart_save_gb (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,          // pulse
    input  wire        abort,          // level; leave by way of the disable
    input  wire [7:0]  cart_type,      // header 0x0147
    input  wire [7:0]  ram_size_code,  // header 0x0149

    // Whether this cartridge's save can be read at all. Combinational, so a
    // caller can gate the button on it rather than starting and failing.
    output wire        supported,

    output reg         busy,
    output reg         done,
    output wire [31:0] total_bytes,

    // Did the RAM actually answer? The first 256 bytes are read with the RAM
    // disabled and again with it enabled, and the two sums compared. Equal
    // sums mean the enable very probably did not take and what follows is
    // open bus, which is a 8 KB file of 0xFF that looks exactly like a
    // successful backup. Reported, not enforced: see blank below.
    output reg         responded,

    // Every byte read was 0xFF, or every byte was 0x00. Not an error - a
    // cartridge whose battery has died reads exactly this way and that is
    // information the user wants - but it is the signature the open-bus case
    // also produces, so the two are shown together.
    output reg         blank_ff,
    output reg         blank_00,

    // The first four bytes of the enabled pass, most significant first. A
    // verdict says a read failed; these say how it failed - all FF is open
    // bus or a dead battery, the same four bytes the disabled pass returned
    // is a gate that did not open, and anything else is data. It is the one
    // piece of the removed diagnostics page worth keeping, and it costs the
    // screen nothing: ui_screen assembles it into a whole row before the
    // column mux, the way the CRC32 row is built.
    output reg  [31:0] first_word,

    // gb_cart_bus. The handshake rule is that req must be dropped before done
    // arrives or a second transaction is issued; see docs/STATUS.md.
    output reg         bus_req,
    output reg         bus_wr,
    output reg  [15:0] bus_addr,
    output reg  [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,

    // Byte stream out. Held until taken.
    output reg  [7:0]  out_data,
    output reg         out_valid,
    input  wire        out_ready
);

// ---- What this cartridge has ----------------------------------------------

localparam [7:0] RAM_2K   = 8'h01;
localparam [7:0] RAM_8K   = 8'h02;
localparam [7:0] RAM_32K  = 8'h03;
localparam [7:0] RAM_128K = 8'h04;   // not in size order; 04 is larger than 05
localparam [7:0] RAM_64K  = 8'h05;

wire q_mbc2 = (cart_type >= 8'h05) && (cart_type <= 8'h06);
wire q_mbc1 = (cart_type >= 8'h01) && (cart_type <= 8'h03);
wire q_mbc3 = (cart_type >= 8'h0F) && (cart_type <= 8'h13);
wire q_mbc5 = (cart_type >= 8'h19) && (cart_type <= 8'h1E);

// Banks of 8 KB. The 2 KB case is one partial bank.
function [4:0] banks_of(input [7:0] code);
    begin
        case (code)
            RAM_2K:   banks_of = 5'd1;
            RAM_8K:   banks_of = 5'd1;
            RAM_32K:  banks_of = 5'd4;
            RAM_64K:  banks_of = 5'd8;
            RAM_128K: banks_of = 5'd16;
            default:  banks_of = 5'd0;
        endcase
    end
endfunction

wire [4:0] q_banks = banks_of(ram_size_code);

// Live, not latched, because a caller gates its button on this: a cartridge
// whose save cannot be read has to say so before the press, not after a file
// has been opened. Above 32 KB only MBC5 has the bank bits to address it, and
// a size a mapper cannot reach is refused rather than truncated.
assign supported = !q_mbc2 && (q_banks != 5'd0) &&
                   ((q_banks <= 5'd4) || q_mbc5);

assign total_bytes = (ram_size_code == RAM_2K) ? 32'd2048
                                               : {22'd0, q_banks, 13'd0};

// What the run itself uses is latched at start. Identification cannot run
// during a dump today, so these cannot move underneath a run; latching them
// means that stays true if that ever changes, and a half-MBC1 read would be
// silent rather than obvious.
reg [7:0] type_l;
reg [7:0] size_l;
wire is_mbc1 = (type_l >= 8'h01) && (type_l <= 8'h03);
wire is_mbc5 = (type_l >= 8'h19) && (type_l <= 8'h1E);
wire [12:0] last_offset = (size_l == RAM_2K) ? 13'd2047 : 13'd8191;
wire [4:0]  bank_count  = banks_of(size_l);
wire        banked      = bank_count > 5'd1;

// The RAM window. The high three bits are what makes gb_cart_bus assert /CS,
// and they are the only address bits this module puts there.
localparam [15:0] RAM_BASE = 16'hA000;

// Where the enable gate lives. Any address in 0x0000-0x1FFF works; 0x0000 is
// the one every mapper decodes.
localparam [15:0] REG_ENABLE = 16'h0000;
localparam [15:0] REG_MODE   = 16'h6000;   // MBC1 banking mode
localparam [15:0] REG_BANK   = 16'h4000;   // RAM bank select
localparam [7:0]  RAM_ON     = 8'h0A;      // the low nibble is what is decoded
localparam [7:0]  RAM_OFF    = 8'h00;

// How many bytes the presence probe compares. 256, from GB-SAVE-PLAN: enough
// that a false "did not respond" needs 256 bytes of genuine save data to
// coincide with 256 bytes of open bus, and small enough to cost nothing.
localparam [12:0] PROBE_BYTES = 13'd256;

// ---- Sequencing ------------------------------------------------------------

localparam [3:0] ST_IDLE      = 4'd0;
localparam [3:0] ST_PROBE_RD  = 4'd1;   // read with the RAM still disabled
localparam [3:0] ST_PROBE_W   = 4'd2;
localparam [3:0] ST_ENABLE    = 4'd3;
localparam [3:0] ST_ENABLE_W  = 4'd4;
localparam [3:0] ST_MODE      = 4'd5;   // MBC1 only, the banking mode
localparam [3:0] ST_MODE_W    = 4'd6;
localparam [3:0] ST_BANK      = 4'd14;  // select the RAM bank, if there is one
localparam [3:0] ST_BANK_W    = 4'd15;
localparam [3:0] ST_READ      = 4'd7;
localparam [3:0] ST_READ_W    = 4'd8;
localparam [3:0] ST_EMIT      = 4'd9;
localparam [3:0] ST_NEXT      = 4'd10;
localparam [3:0] ST_DISABLE   = 4'd11;
localparam [3:0] ST_DISABLE_W = 4'd12;
localparam [3:0] ST_DONE      = 4'd13;

reg [3:0]  state;
reg [12:0] offset;
reg [4:0]  bank;
// Which mode to leave MBC1 in. The banked read needs mode 1 and the cartridge
// must not be left there: the register persists, and a ROM dump afterwards
// would take the 0x4000 bits as a RAM bank rather than the top of the ROM
// bank. So ST_MODE runs twice, once each way, and this says which pass it is.
reg        mode_restore;
reg [15:0] sum_off;        // sum of the first PROBE_BYTES with RAM disabled
reg [15:0] sum_on;         // and with it enabled

// An abort has to leave through the disable, so it is latched rather than
// acted on directly: the state machine finishes the transaction it is in,
// then takes the exit. Cleared at the start of a run so a stale abort cannot
// cut the next one short.
reg abort_l;

wire [15:0] read_addr = RAM_BASE | {3'd0, offset};

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        offset    <= 13'd0;
        sum_off   <= 16'd0;
        sum_on    <= 16'd0;
        responded <= 1'b0;
        blank_ff   <= 1'b0;
        blank_00   <= 1'b0;
        first_word <= 32'd0;
        abort_l    <= 1'b0;
        out_valid <= 1'b0;
        out_data  <= 8'd0;
        bus_wr    <= 1'b0;
        bus_addr  <= 16'd0;
        bus_wdata <= 8'd0;
        type_l       <= 8'd0;
        size_l       <= 8'd0;
        bank         <= 5'd0;
        mode_restore <= 1'b0;
    end else begin
        if (abort && busy) abort_l <= 1'b1;

        case (state)
            ST_IDLE: begin
                busy      <= 1'b0;
                out_valid <= 1'b0;
                if (start) begin
                    busy         <= 1'b1;
                    type_l       <= cart_type;
                    size_l       <= ram_size_code;
                    bank         <= 5'd0;
                    mode_restore <= 1'b0;
                    offset    <= 13'd0;
                    sum_off   <= 16'd0;
                    sum_on    <= 16'd0;
                    responded  <= 1'b0;
                    abort_l    <= 1'b0;
                    // Cleared per run, not per reset: it is a shift register
                    // four bytes deep, so a second save would otherwise show
                    // the first save's bytes shifted out by this one's.
                    first_word <= 32'd0;
                    // Both start true and are cleared by the first byte that
                    // disagrees, so a run that reads nothing cannot report a
                    // blank save it never looked at.
                    blank_ff  <= 1'b1;
                    blank_00  <= 1'b1;
                    state     <= ST_PROBE_RD;
                end
            end

            // ---- The disabled pass -----------------------------------------
            // Nothing has been written to the cartridge yet. If the RAM is
            // not enabled - and out of reset it is not - these reads return
            // open bus, and open bus is what a failed enable would return
            // later. Comparing the two is the only non-destructive way to
            // tell "the RAM answered" from "the bus floated".
            ST_PROBE_RD: begin
                bus_wr   <= 1'b0;
                bus_req  <= 1'b1;
                bus_addr <= read_addr;
                state    <= ST_PROBE_W;
            end

            ST_PROBE_W: begin
                if (bus_done) begin
                    sum_off <= sum_off + {8'd0, bus_rdata};
                    if (offset == PROBE_BYTES - 13'd1) begin
                        offset <= 13'd0;
                        state  <= abort_l ? ST_DISABLE : ST_ENABLE;
                    end else begin
                        offset <= offset + 13'd1;
                        state  <= ST_PROBE_RD;
                    end
                end
            end

            // ---- Open the gate ---------------------------------------------
            ST_ENABLE: begin
                bus_wr    <= 1'b1;
                bus_req   <= 1'b1;
                bus_addr  <= REG_ENABLE;
                bus_wdata <= RAM_ON;
                state     <= ST_ENABLE_W;
            end

            ST_ENABLE_W: if (bus_done) state <= is_mbc1 ? ST_MODE : ST_BANK;

            // MBC1's mode register, and it is written on the way in and on the
            // way out. The value follows mode_restore: mode 1 to read, mode 0
            // to leave the cartridge as it was found.
            //
            // Mode 1 is what makes the two bits at 0x4000 select a RAM bank.
            // In mode 0 they extend the ROM bank instead, so a banked read
            // without this returns bank 0 as many times as there are banks -
            // a 32 KB file that is entirely plausible and entirely wrong.
            //
            // Written even for a single-bank cartridge, where mode 0 would do,
            // because one path tested once is worth more than a special case:
            // mode 1 reaches bank 0 as well.
            ST_MODE: begin
                bus_wr    <= 1'b1;
                bus_req   <= 1'b1;
                bus_addr  <= REG_MODE;
                bus_wdata <= mode_restore ? 8'h00 : 8'h01;
                state     <= ST_MODE_W;
            end

            ST_MODE_W: if (bus_done) state <= mode_restore ? ST_DISABLE : ST_BANK;

            // Select the bank. A single-bank cartridge needs no write at all,
            // and not writing is the point: on MBC3 this register is where
            // 0x08-0x0C would map the clock over the RAM window, so the fewer
            // writes reach it the better. The value is masked to four bits,
            // which is every bank MBC5 has; MBC1 and MBC3 never get past 3
            // because `supported` refuses the wider sizes for them.
            ST_BANK: begin
                if (!banked) begin
                    state <= ST_READ;
                end else begin
                    bus_wr    <= 1'b1;
                    bus_req   <= 1'b1;
                    bus_addr  <= REG_BANK;
                    bus_wdata <= {4'd0, bank[3:0]};
                    state     <= ST_BANK_W;
                end
            end

            ST_BANK_W: if (bus_done) state <= ST_READ;

            // ---- The data pass ---------------------------------------------
            ST_READ: begin
                if (abort_l) begin
                    // Out through the mode restore as well as the disable: an
                    // abort that left MBC1 in mode 1 would make the next ROM
                    // dump read the wrong banks.
                    if (is_mbc1 && !mode_restore) begin
                        mode_restore <= 1'b1;
                        state        <= ST_MODE;
                    end else begin
                        state <= ST_DISABLE;
                    end
                end else begin
                    bus_wr   <= 1'b0;
                    bus_req  <= 1'b1;
                    bus_addr <= read_addr;
                    state    <= ST_READ_W;
                end
            end

            ST_READ_W: begin
                if (bus_done) begin
                    out_data  <= bus_rdata;
                    out_valid <= 1'b1;
                    if (bus_rdata != 8'hFF) blank_ff <= 1'b0;
                    if (bus_rdata != 8'h00) blank_00 <= 1'b0;
                    if (bank == 5'd0 && offset < PROBE_BYTES)
                        sum_on <= sum_on + {8'd0, bus_rdata};
                    if (bank == 5'd0 && offset < 13'd4)
                        first_word <= {first_word[23:0], bus_rdata};
                    state <= ST_EMIT;
                end
            end

            ST_EMIT: begin
                if (out_ready) begin
                    out_valid <= 1'b0;
                    state     <= ST_NEXT;
                end
            end

            ST_NEXT: begin
                // The verdict lands as soon as both sums are complete, which
                // is 256 bytes in rather than the whole save, so an abort part
                // way through still leaves a meaningful answer about whether
                // the RAM was ever answering.
                if (bank == 5'd0 && offset == PROBE_BYTES - 13'd1)
                    responded <= (sum_on != sum_off);

                if (offset == last_offset) begin
                    offset <= 13'd0;
                    if (bank + 5'd1 == bank_count) begin
                        // MBC1 has to be put back in mode 0 before the gate
                        // shuts; every other mapper goes straight there.
                        if (is_mbc1) begin
                            mode_restore <= 1'b1;
                            state        <= ST_MODE;
                        end else begin
                            state <= ST_DISABLE;
                        end
                    end else begin
                        bank  <= bank + 5'd1;
                        state <= ST_BANK;
                    end
                end else begin
                    offset <= offset + 13'd1;
                    state  <= ST_READ;
                end
            end

            // ---- Close the gate, on every exit -----------------------------
            ST_DISABLE: begin
                bus_wr    <= 1'b1;
                bus_req   <= 1'b1;
                bus_addr  <= REG_ENABLE;
                bus_wdata <= RAM_OFF;
                state     <= ST_DISABLE_W;
            end

            ST_DISABLE_W: if (bus_done) state <= ST_DONE;

            ST_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
