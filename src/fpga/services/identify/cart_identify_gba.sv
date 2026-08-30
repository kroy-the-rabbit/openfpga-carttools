`default_nettype none

//
// cart_identify_gba.sv - read and validate a GBA cartridge header
//
// Milestone v0.1, and the project's first hard stop: until this works against
// real cartridges, plan.md says nothing that writes to SD or to a cartridge
// gets built.
//
// This replaces the probe that came with the fork, which read 0xAC and 0xAE
// into a register pair. That probe never worked: it drove its own request
// signals and nothing was connected to them, so it captured whatever the
// emulator's ROM cache happened to be fetching. See docs/STATUS.md.
//
// What it reads
// -------------
// The 32 bytes at 0x0A0..0x0BF, as sixteen 16-bit accesses. That covers the
// whole of the GBA header except the entry point and the Nintendo logo:
//
//   0xA0..0xAB  game title, 12 bytes of ASCII, space padded
//   0xAC..0xAF  game code, 4 bytes, for example "AMTE"
//   0xB0..0xB1  maker code, 2 bytes
//   0xB2        fixed value, always 0x96 on a real cartridge
//   0xB3        main unit code
//   0xB4        device type
//   0xB5..0xBB  reserved, zero on every retail cartridge
//   0xBC        software version
//   0xBD        header complement check
//   0xBE..0xBF  reserved
//
// The Nintendo logo at 0x04..0x9F is deliberately not checked. It would be a
// strong validity test, but it needs 156 bytes of known-good data compiled
// into this core, and getting those bytes wrong would reject good cartridges
// for a reason nobody could see. The two checks below cost nothing and are
// enough to tell a cartridge from an empty slot.
//
// How it decides
// --------------
// Three independent judgements, kept separate in the result rather than
// collapsed into one boolean, because they fail for different reasons and the
// user needs to be told which:
//
//   present    something answered. An empty slot floats to all-ones or reads
//              back all-zeros, so a header that is entirely 0x0000 or
//              entirely 0xFFFF is nothing rather than something.
//
//   stable     the same 32 bytes came back twice. The header is read twice
//              and compared. A cartridge with dirty contacts or a marginal
//              connection can return plausible-looking garbage that passes a
//              checksum, and reporting a wrong title is worse than reporting
//              a failure. plan.md's adversarial review asks about slow or
//              marginal cartridges; this is the answer.
//
//   valid      the fixed byte is 0x96 and the complement check matches. Both
//              are properties of the header itself, so this needs no ROM
//              database, which the plan also requires.
//
// A cartridge that is present and stable but not valid is reported as exactly
// that. It might be a GB cartridge, a reproduction, or something this core
// should not touch, and the caller must not treat it as a GBA cartridge.
//

module cart_identify_gba (
    input  wire        clk,
    input  wire        reset,

    // Held low when the Pocket has not powered the slot. Starting a read then
    // would be reading a bus that is not there.
    input  wire        cart_mode,

    input  wire        start,          // single-cycle strobe, ignored while busy
    output reg         busy,
    output reg         done,           // single-cycle strobe

    // Cartridge bus master port. Matches gba_cart_bus.
    output reg         cart_req,
    output wire        cart_wr,
    output reg  [27:0] cart_addr,
    output wire [1:0]  cart_acc,
    output wire [31:0] cart_wdata,
    input  wire [31:0] cart_rdata,
    input  wire        cart_done,
    input  wire        cart_busy,

    // Result, valid from `done` until the next `start`.
    output reg  [2:0]  result,
    output reg  [95:0] title,          // 0xA0..0xAB, first byte in the high bits
    output reg  [31:0] game_code,      // 0xAC..0xAF, first byte in the high bits
    output reg  [15:0] maker_code,     // 0xB0..0xB1
    output reg  [7:0]  device_type,    // 0xB4
    output reg  [7:0]  sw_version,     // 0xBC
    output reg         fixed_ok,       // 0xB2 == 0x96
    output reg         checksum_ok,    // 0xBD matches the computed complement
    output reg         reserved_ok,    // 0xB5..0xBB are all zero

    // The raw 32 bytes, word i at [16*i +: 16], word 0 being 0xA0.
    //
    // Here so the diagnostics screen can show what the cartridge actually
    // said. On a first hardware bring-up the difference between "all FFFF",
    // "all 0000", "plausible ASCII with a bad checksum" and "the right bytes
    // in the wrong order" is the difference between knowing what is wrong and
    // guessing, and none of that survives being reduced to a result code.
    output wire [255:0] raw_words,
    output reg  [7:0]   checksum_read,  // the byte at 0xBD, as read
    output wire [7:0]   checksum_calc   // what it should have been
);

// Result codes. These reach the user as a line of text, so the numbers are
// part of the interface: append, never renumber.
localparam [2:0] RESULT_GBA       = 3'd0;  // present, stable, valid
localparam [2:0] RESULT_NO_CART   = 3'd1;  // nothing in the slot
localparam [2:0] RESULT_UNSTABLE  = 3'd2;  // two reads disagreed
localparam [2:0] RESULT_NOT_GBA   = 3'd3;  // present and stable, header wrong
localparam [2:0] RESULT_NO_POWER  = 3'd4;  // slot not selected or not powered

localparam [27:0] HEADER_BASE = 28'h00000A0;
localparam integer WORDS = 16;

localparam [1:0] ACC_16BIT = 2'b01;

localparam [2:0] ST_IDLE    = 3'd0;
localparam [2:0] ST_REQ     = 3'd1;
localparam [2:0] ST_WAIT    = 3'd2;
localparam [2:0] ST_NEXT    = 3'd3;
localparam [2:0] ST_JUDGE   = 3'd4;
localparam [2:0] ST_DONE    = 3'd5;

reg [2:0]  state;
reg [3:0]  idx;           // 0..15, which header word
reg        pass;          // 0 = first read of the header, 1 = the check read

reg [15:0] hdr [0:WORDS-1];    // what the first pass read

// This module only ever reads, and only ever 16 bits at a time.
assign cart_wr    = 1'b0;
assign cart_acc   = ACC_16BIT;
assign cart_wdata = 32'd0;

// ---- Judgements over the captured header ----------------------------------
//
// Accumulated as the words arrive rather than computed at the end.
//
// The first version summed all 29 bytes in one combinational block. Quartus
// built the 29-term adder chain it was asked for, and that chain became the
// critical path of the whole core at 1.03 ns of slack, for arithmetic that
// runs once per identification. Adding one word per arrival is two adds deep
// instead of twenty-nine, and it costs nothing: the words arrive one at a
// time anyway, hundreds of cycles apart.
//
// It also removed the second copy of the header. Comparing each word of the
// check pass against the stored one as it arrives answers the same question
// as keeping both copies and comparing at the end, using 256 fewer bits.

reg       all_zero;
reg       all_ones;
reg       same;
reg [7:0] sum;

// The complement check covers 0xA0 through 0xBC inclusive: every byte of
// words 0 to 13, plus the low byte of word 14. The value it is checked
// against is stored at 0xBD, the high byte of word 14.
//
//   stored == (0 - sum - 0x19) & 0xFF
//
wire [7:0] checksum_want = 8'h00 - sum - 8'h19;
assign     checksum_calc = checksum_want;

genvar gi;
generate
    for (gi = 0; gi < WORDS; gi = gi + 1) begin : g_raw
        assign raw_words[16*gi +: 16] = hdr[gi];
    end
endgenerate
wire       hdr_fixed_ok  = (hdr[9][7:0] == 8'h96);
wire       hdr_check_ok  = (hdr[14][15:8] == checksum_want);
wire       hdr_resvd_ok  = (hdr[10][15:8] == 8'h00) && (hdr[11] == 16'h0000) &&
                           (hdr[12] == 16'h0000) && (hdr[13] == 16'h0000);


// ---- Main sequencer -------------------------------------------------------

always @(posedge clk) begin
    done <= 1'b0;

    if (reset) begin
        state       <= ST_IDLE;
        busy        <= 1'b0;
        cart_req    <= 1'b0;
        cart_addr   <= 28'd0;
        idx         <= 4'd0;
        pass        <= 1'b0;
        result      <= RESULT_NO_CART;
        all_zero    <= 1'b1;
        all_ones    <= 1'b1;
        same        <= 1'b1;
        sum         <= 8'd0;
        title       <= 96'd0;
        game_code   <= 32'd0;
        maker_code  <= 16'd0;
        device_type <= 8'd0;
        sw_version  <= 8'd0;
        checksum_read <= 8'd0;
        fixed_ok    <= 1'b0;
        checksum_ok <= 1'b0;
        reserved_ok <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                cart_req <= 1'b0;
                if (start) begin
                    if (!cart_mode) begin
                        // Refusing here rather than issuing a request is the
                        // point: gba_cart_bus ignores requests with cart_mode
                        // low and would never raise done, so a caller waiting
                        // on done would wait forever.
                        result <= RESULT_NO_POWER;
                        busy   <= 1'b1;
                        state  <= ST_DONE;
                    end else begin
                        busy     <= 1'b1;
                        idx      <= 4'd0;
                        pass     <= 1'b0;
                        all_zero <= 1'b1;
                        all_ones <= 1'b1;
                        same     <= 1'b1;
                        sum      <= 8'd0;
                        state    <= ST_REQ;
                    end
                end
            end

            ST_REQ: begin
                // gba_cart_bus samples req only in its own idle state, so
                // hold off until it is actually idle. One cycle of req is
                // then enough, and dropping it immediately avoids handing it
                // a second request it never asked for.
                cart_addr <= HEADER_BASE + {24'd0, idx, 1'b0};
                if (!cart_busy) begin
                    cart_req <= 1'b1;
                    state    <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                cart_req <= 1'b0;
                if (cart_done) begin
                    if (pass) begin
                        // The check pass keeps nothing. It only has to answer
                        // whether the cartridge said the same thing twice.
                        if (cart_rdata[15:0] != hdr[idx]) same <= 1'b0;
                    end else begin
                        hdr[idx] <= cart_rdata[15:0];

                        if (cart_rdata[15:0] != 16'h0000) all_zero <= 1'b0;
                        if (cart_rdata[15:0] != 16'hFFFF) all_ones <= 1'b0;

                        // 0xA0..0xBC: whole words up to 13, then one byte.
                        if (idx < 4'd14)
                            sum <= sum + cart_rdata[7:0] + cart_rdata[15:8];
                        else if (idx == 4'd14)
                            sum <= sum + cart_rdata[7:0];
                    end
                    state <= ST_NEXT;
                end
            end

            ST_NEXT: begin
                if (idx == WORDS - 1) begin
                    idx <= 4'd0;
                    if (pass) begin
                        state <= ST_JUDGE;
                    end else begin
                        pass  <= 1'b1;
                        state <= ST_REQ;
                    end
                end else begin
                    idx   <= idx + 4'd1;
                    state <= ST_REQ;
                end
            end

            ST_JUDGE: begin
                title       <= {hdr[0][7:0], hdr[0][15:8], hdr[1][7:0], hdr[1][15:8],
                                hdr[2][7:0], hdr[2][15:8], hdr[3][7:0], hdr[3][15:8],
                                hdr[4][7:0], hdr[4][15:8], hdr[5][7:0], hdr[5][15:8]};
                game_code   <= {hdr[6][7:0], hdr[6][15:8], hdr[7][7:0], hdr[7][15:8]};
                maker_code  <= {hdr[8][7:0], hdr[8][15:8]};
                device_type <= hdr[10][7:0];
                sw_version  <= hdr[14][7:0];
                checksum_read <= hdr[14][15:8];

                fixed_ok    <= hdr_fixed_ok;
                checksum_ok <= hdr_check_ok;
                reserved_ok <= hdr_resvd_ok;

                // Order matters. An absent cartridge is not an unstable one,
                // and an unstable read must not be reported as a cartridge
                // this core recognises, however good the checksum looked.
                if (all_zero || all_ones)
                    result <= RESULT_NO_CART;
                else if (!same)
                    result <= RESULT_UNSTABLE;
                else if (hdr_fixed_ok && hdr_check_ok)
                    result <= RESULT_GBA;
                else
                    result <= RESULT_NOT_GBA;

                state <= ST_DONE;
            end

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
