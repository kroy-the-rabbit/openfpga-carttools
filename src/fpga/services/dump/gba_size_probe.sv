`default_nettype none

//
// gba_size_probe.sv - work out how much ROM a GBA cartridge actually has
//
// A GBA header has no ROM size field. docs/GBA-DUMP-PLAN.md calls this the one
// genuinely new mechanism in the GBA path and the only one that can be wrong
// in a way that still produces a plausible-looking file, so this module runs
// alone, before anything is written to the card.
//
// The mechanism
// -------------
// During a ROM read gba_cart_bus drives the halfword address onto AD and then
// releases it for the cartridge to answer. Past the end of ROM nothing
// answers and the bus floats at the last thing driven, which is the address:
// a read at byte address A comes back as (A >> 1) & 0xFFFF. That is observed
// on hardware, recorded in docs/BRINGUP.md as 0A0 0050 0051 0052, and the
// useful part of it is that the value is decided by what this core drove
// rather than by the cartridge, so it is predictable instead of something we
// would have to characterise.
//
// So for each candidate size S in 1, 2, 4, 8, 16 MiB, read at byte offset S
// and classify:
//
//   open bus  the value equals its own halfword address. Nothing is driving.
//   mirror    the value equals the value at (address & (S - 1)). The high
//             address lines are not decoded, so the ROM wrapped.
//   data      neither. The ROM is at least S; try the next candidate.
//
// The smallest S that is open bus or mirror is the size. Nothing tripping by
// 16 MiB means 32 MiB, which is also the ceiling: rom_word_addr is
// latched_addr[24:1], 24 bits of halfword address, so the bus physically
// cannot be asked for more than 32 MiB and there is no larger candidate to
// test. That answer is reached by exhaustion rather than by observation, and
// `status` says so: STATUS_CEILING, never STATUS_SIZED.
//
// Being hard to fool
// ------------------
// Everything below exists because a cartridge is not a cooperating witness.
// Each defence names the attack it answers.
//
//   Four sample points per candidate, spread over 1.9 MiB at offsets that are
//   not round numbers, and *all four* must agree before a candidate is called
//   the end.
//       Attack: a run of real ROM data that happens to look like the end at
//       exactly the boundary. Faking one offset is plausible; faking four,
//       nearly two megabytes apart, at values that match each location's own
//       address, is not.
//
//   Four halfwords per sample point at strides 0, 2, 0x40, 0x402 rather than
//   eight consecutive ones.
//       Attack: the case docs/GBA-DUMP-PLAN.md names, a short ascending
//       halfword run at a candidate boundary. Consecutive reads walk straight
//       down such a run; a 0x402-byte stride steps outside anything shorter
//       than a kilobyte.
//
//   The mirror reference is the probe address wrapped by the candidate,
//   address & (S - 1), not offset 0.
//       Attack: a partial mirror, and a cartridge whose first bytes happen to
//       repeat. Offset 0 is only the right comparison for the first sample
//       point; every other point mirrors to its own image, and comparing it
//       against offset 0 would ask a question whose answer means nothing.
//       Offset 0 is still read and still compared, but as evidence only - see
//       "The offset-0 anchor" below.
//
//   A mirror is only believed if the four probed halfwords are not all the
//   same value.
//       Attack: a blank region. A stretch of 0xFFFF at the probe compares
//       equal to a stretch of 0xFFFF at the reference and looks exactly like
//       a mirror while being genuine data. Repetition is only evidence of
//       wrapping if there is something to repeat.
//
//       This is a trade, and it costs something: a MIRRORING cartridge with a
//       constant run at a sample point is refused as a mirror and reported
//       larger than it is. Case "mirror with a blank point" in the testbench
//       holds that behaviour down so that changing it has to be deliberate.
//
//   A mirror is only believed if the reference read did not itself look like
//   open bus.
//       Attack: the mirror arm bypassing the 32-bit confirmation. Every
//       candidate S is a power of two of at least 1 MiB, so S >> 1 has no low
//       16 bits and open_pred at the probe address equals open_pred at the
//       wrapped address. Wherever BOTH the probe address and its wrapped
//       image are past the end of ROM, an open-bus point therefore also
//       satisfies mirror-and-varied, and would have tripped the candidate
//       through the mirror arm without the confirmation read ever being
//       consulted. That state is reachable - a sub-candidate cartridge gets
//       there, see the 512 KiB case in the testbench - so rather than rely on
//       an invariant nobody enumerated, a reference that reads back as its
//       own address disqualifies the mirror evidence and leaves the decision
//       to the open arm, which is confirmed.
//
//       Stated plainly: NO TEST FAILS WITHOUT THIS RULE. Removing it was
//       mutation-checked and the suite stayed green, because the bypass needs
//       a point whose mirror evidence trips while its open arm does NOT, and
//       that combination is out of reach here - a candidate is only believed
//       when all four of its points agree, point 0's wrapped reference is
//       always offset 0, and offset 0 has to hold real data or the presence
//       pass refuses the cartridge outright. So the rule is belt and braces
//       over an invariant, not a defence with a demonstration behind it. It
//       is kept because it costs one comparison and turns "unreachable if you
//       trace it" into "unreachable by construction"; it is written down here
//       because the next person to read a green suite deserves to know which
//       lines it is actually holding.
//
//   Open bus is confirmed with one 32-bit read at the sample point.
//       Attack: a cartridge that stores its own halfword address as data,
//       which no 16-bit read can tell from open bus however many places it
//       looks. It shows up in a burst: gba_cart_bus takes the second halfword
//       through ST_READ_SEQ without re-driving AD, so real open bus returns
//       the *same* address twice, {A, A}, while a cartridge answering the
//       burst returns the next halfword, {A + 1, A}. Only that exact
//       ascending signature is rejected - anything else is still taken as
//       open bus, because a float that decayed over the longer burst window
//       must not be read as a cartridge answering.
//
//   A presence pass before any candidate: six scattered reads under 1 MiB
//   must not all look like open bus, and must not all be the same value.
//       Attack: an empty slot, which is open bus everywhere and would
//       otherwise trip the 1 MiB candidate and be reported as a 1 MiB
//       cartridge. Also a cartridge that answers with a constant, which is
//       indistinguishable from a blank one. Both come back with size_valid
//       low, and with different statuses - STATUS_NO_CART and STATUS_CONSTANT
//       - because a genuinely blank-looking cartridge with a valid header is
//       a different thing from an empty slot and the screen must not present
//       them as the same refusal.
//
// The offset-0 anchor
// -------------------
// Four halfwords at offset 0, at the same strides, are read once per probe and
// compared against every sample point as well. They are not part of the
// decision: at any point other than the first, offset 0 is not what the
// address would wrap to, so acting on a match there would be acting on a
// coincidence. They are kept because they are two reads' worth of evidence
// anchored on the most distinctive sixteen bytes in the cartridge - the GBA
// header - and because a point that matches offset 0 while failing the wrapped
// comparison is a fact worth having on screen when a size looks wrong.
//
// Where it is unsure, it over-reports
// -----------------------------------
// Every tie-break above fails towards a larger size, never a smaller one. A
// dump that is too long wastes time and contains mirrored data; a dump that
// is too short has lost part of the cartridge and looks fine. Those are not
// symmetrical, so a cartridge that answers one sample point and not another
// gets the next candidate up rather than a truncated dump.
//
// That bias is aggressive and it will fire on real hardware: one live address
// past the end - a partly decoded high line, a marginal contact - pushes a
// 4 MiB cartridge to 8 MiB. It is the safe direction, but only if the screen
// can say WHICH point dissented, which is what the evidence outputs are for.
//
// The evidence outputs
// --------------------
// This module answers a question no cartridge can confirm. If it says 8 MiB
// and the cartridge is 16, nothing downstream notices: the dump completes, the
// file is well formed, and only a comparison against another dump finds it. So
// it exports what it saw and not only what it concluded:
//
//   dbg_class    per sample point, unset / data / open / mirror
//   dbg_hits     per sample point, how many of the four halfwords matched the
//                open-bus prediction, the wrapped reference and offset 0.
//                4/4 is a decision; 3/4 is a marginal contact and looks
//                nothing like it in a summary
//   dbg_words    the four halfwords at the last sample point completed, and
//                dbg_addr its address
//   dbg_base     the four halfwords at offset 0
//   dbg_pres     the six presence reads, which are the whole evidence behind
//                a STATUS_NO_CART or STATUS_CONSTANT refusal
//   dbg_points   how many sample points were completed
//
// A point classed DATA whose open count reads 4/4 is the impostor signature:
// every 16-bit read looked like open bus and the 32-bit confirmation said a
// cartridge was answering. That distinction is why the counts are kept rather
// than only the classes.
//
// The cost is around 540 flops if all of it is displayed, and nothing at all
// while it is not: an output no one reads is stripped. If the fit gets tight,
// drop dbg_base and dbg_words first, dbg_hits second; the classes and the
// status are what make a wrong answer diagnosable from a photograph.
//
// Read-only, and the word wr appears nowhere below except tied off. A
// ROM-space write cannot pulse WR# on this bus in any case - cart_write_enable
// needs eeprom, save or gpio space - but the tie-off is here so that reading
// this module alone is enough to know it.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

module gba_size_probe #(
    // Sample point offsets from the candidate boundary. Deliberately not
    // round: a cartridge whose data coincidentally looks like the end is
    // likelier to do so on an aligned boundary, because that is where its own
    // structures sit.
    //
    // Parameters rather than constants for one reason only: so a testbench can
    // instantiate a second probe with a deliberately bad offset and watch it
    // misclassify. Nothing in the core overrides them.
    //
    // ONE HARD CONSTRAINT, and it is not obvious. The 32-bit confirmation read
    // must not start at halfword offset 0xFFFF within a 128 KiB page: that is
    // gba_cart_bus's rom_page_end case, where the second beat re-runs the
    // address phase and so re-drives AD with the next address. Open bus would
    // then return {A + 1, A}, the exact signature of a cartridge answering,
    // and the probe would call a genuinely empty region data - which means an
    // over-report all the way to the ceiling, for every candidate, because a
    // candidate size is a power of two of at least 1 MiB and so contributes
    // nothing to the low 17 address bits. These offsets decide it on their
    // own; none of them lands there. tb_gba_size_probe both asserts that of
    // these four values and demonstrates, with a second instance, what happens
    // to a cartridge when one of them is wrong.
    parameter [23:0] PT_OFF0 = 24'h000000,   // the boundary itself
    parameter [23:0] PT_OFF1 = 24'h0AAAA6,
    parameter [23:0] PT_OFF2 = 24'h13579C,
    parameter [23:0] PT_OFF3 = 24'h1E0006,
    // How long to wait for the connector to carry GBA mode after the probe has
    // asked for it. cart_pins settles in 16 cycles, so this is three orders of
    // magnitude of margin, and it is only ever paid in full when the slot is
    // not powered at all - which is the case it exists to report rather than
    // hang on.
    parameter integer MODE_WAIT_CYCLES = 4096
) (
    input  wire        clk,
    input  wire        reset,

    // Low when the connector is not carrying GBA mode. gba_cart_bus ignores
    // requests then and never raises done, so a probe started or interrupted
    // there would wait forever. Refused up front, and abandoned if the mode
    // goes away mid-probe.
    input  wire        cart_mode,

    input  wire        start,          // single-cycle strobe, ignored while busy
    output reg         busy,
    output reg         done,           // single-cycle strobe

    // The connector must be in GBA mode for the whole probe, and cart_probe
    // parks the mode at idle the moment it finishes identifying. So the probe
    // asks for the mode itself and holds the request until it is done, exactly
    // as dump_engine does for a dump. core_top's mode mux honours this.
    output reg         want_gba,

    // Result, valid from done until the next start.
    output reg  [31:0] size_bytes,
    output reg         size_valid,
    output reg  [2:0]  status,

    // Cartridge bus master port, the same shape as cart_identify_gba's so the
    // two can share one mux into gba_cart_bus.
    output reg         cart_req,
    output wire        cart_wr,
    output reg  [27:0] cart_addr,
    output reg  [1:0]  cart_acc,
    output wire [31:0] cart_wdata,
    input  wire [31:0] cart_rdata,
    input  wire        cart_done,
    input  wire        cart_busy,

    // Evidence. Cleared at start, valid from done until the next start.
    output wire [39:0]  dbg_class,     // 2 bits per point, point p at [2*p]
    output wire [239:0] dbg_hits,      // {base, mirror, open} nibbles per point
    output wire [63:0]  dbg_words,     // the four halfwords at the last point
    output reg  [27:0]  dbg_addr,      // that point's byte address
    output wire [63:0]  dbg_base,      // the four halfwords at offset 0
    output wire [95:0]  dbg_pres,      // the six presence reads
    output reg  [4:0]   dbg_points     // sample points completed, 0 to 20
);

localparam [1:0] ACC_16BIT = 2'b01;
// gba_cart_bus has no named 32-bit constant: it infers a 32-bit access from
// acc being neither ACCESS_8BIT nor ACCESS_16BIT. docs/GBA-DUMP-PLAN.md asks
// for the value to be named at the call site rather than written as a bare
// 2'b10 and left for the reader to work out.
localparam [1:0] ACC_32BIT = 2'b10;

localparam integer NCAND   = 5;   // 1, 2, 4, 8, 16 MiB; 32 MiB is the fallthrough
localparam integer NPOINTS = 4;
localparam integer NWORDS  = 4;
localparam integer NPRES   = 6;
localparam integer NSLOTS  = NCAND * NPOINTS;   // 20 evidence slots

localparam [31:0] SIZE_32MIB = 32'h02000000;

// Status codes reach the user as a line of text, so the numbers are part of
// the interface: append, never renumber.
localparam [2:0] STATUS_IDLE     = 3'd0;  // never run since reset
localparam [2:0] STATUS_SIZED    = 3'd1;  // a candidate tripped; size_bytes is it
localparam [2:0] STATUS_CEILING  = 3'd2;  // nothing tripped, so 32 MiB by exhaustion
localparam [2:0] STATUS_NO_CART  = 3'd3;  // the presence pass saw only open bus
localparam [2:0] STATUS_NO_POWER = 3'd4;  // slot not selected, or lost mid-probe
localparam [2:0] STATUS_CONSTANT = 3'd5;  // something answers, with one value everywhere

// Point classes, for the evidence outputs. UNSET is zero so a point that was
// never reached is obvious. A point that read as open bus at all four
// halfwords but failed the 32-bit confirmation is DATA with an open count of
// 4, which is the impostor signature and is meant to be legible as one.
localparam [1:0] CLS_UNSET  = 2'd0;
localparam [1:0] CLS_DATA   = 2'd1;
localparam [1:0] CLS_OPEN   = 2'd2;
localparam [1:0] CLS_MIRROR = 2'd3;

localparam [4:0] ST_IDLE     = 5'd0;
localparam [4:0] ST_MODE     = 5'd1;
localparam [4:0] ST_REQ      = 5'd2;
localparam [4:0] ST_WAIT     = 5'd3;
localparam [4:0] ST_PRES_SET = 5'd4;
localparam [4:0] ST_PRES_GOT = 5'd5;
localparam [4:0] ST_BASE_SET = 5'd6;
localparam [4:0] ST_BASE_GOT = 5'd7;
localparam [4:0] ST_PT_SET   = 5'd8;
localparam [4:0] ST_REF_SET  = 5'd9;
localparam [4:0] ST_REF_GOT  = 5'd10;
localparam [4:0] ST_PRB_SET  = 5'd11;
localparam [4:0] ST_PRB_GOT  = 5'd12;
localparam [4:0] ST_CONF_SET = 5'd13;
localparam [4:0] ST_CONF_GOT = 5'd14;
localparam [4:0] ST_POINT    = 5'd15;
localparam [4:0] ST_DONE     = 5'd16;

reg [4:0] state;
reg [4:0] ret_state;      // where a completed read returns to
reg [15:0] mode_wait;     // how long the connector has to turn round

reg [2:0] cand;           // candidate index, S = 1 MiB << cand
reg [1:0] point;          // sample point within the candidate
reg [1:0] word;           // halfword within the sample point
reg [2:0] pres;           // presence read index

reg [31:0] rdata_q;
reg [15:0] ref_val;       // the mirror image of the halfword being probed
reg [15:0] first_val;     // first halfword of this sample point

reg pt_open;              // every halfword so far equalled its own address
reg pt_mirror;            // every halfword so far equalled its mirror image
reg pt_varied;            // this point's halfwords are not all one value
reg pt_conf;              // the 32-bit read agreed that nothing is driving
reg pt_ref_open;          // every mirror reference read looked like open bus
reg pt_base;              // every halfword so far equalled its offset-0 image

reg [2:0] open_hits;      // of four, and 4 needs three bits
reg [2:0] mir_hits;
reg [2:0] base_hits;

reg [15:0] pres_first;
reg        pres_all_open;
reg        pres_varied;

reg [15:0] base_val [0:NWORDS-1];   // the four halfwords at offset 0
reg [15:0] pt_word  [0:NWORDS-1];   // the four at the point being sampled
reg [15:0] pres_val [0:NPRES-1];

reg [1:0]  pclass [0:NSLOTS-1];
reg [3:0]  popen  [0:NSLOTS-1];
reg [3:0]  pmir   [0:NSLOTS-1];
reg [3:0]  pbase  [0:NSLOTS-1];

integer i;

// This module only ever reads.
assign cart_wr    = 1'b0;
assign cart_wdata = 32'd0;

// ---- Where to look --------------------------------------------------------

function [23:0] point_off(input [1:0] j);
begin
    case (j)
        2'd0:    point_off = PT_OFF0;
        2'd1:    point_off = PT_OFF1;
        2'd2:    point_off = PT_OFF2;
        default: point_off = PT_OFF3;
    endcase
end
endfunction

// Strides within a sample point. The first two are adjacent so that the
// 32-bit confirmation read covers the same halfword the second stride reads
// on its own, which is what makes the two answers comparable. The last two
// step far enough out to leave any short planted run behind.
function [15:0] word_stride(input [1:0] k);
begin
    case (k)
        2'd0:    word_stride = 16'h0000;
        2'd1:    word_stride = 16'h0002;
        2'd2:    word_stride = 16'h0040;
        default: word_stride = 16'h0402;
    endcase
end
endfunction

// Presence addresses, all inside the smallest candidate so that a 1 MiB
// cartridge is fully covered. Two of them are header bytes cart_identify_gba
// reads, which differ from each other on any real cartridge; the rest are
// scattered so that a slot answering with a constant cannot pass by accident.
function [27:0] pres_addr(input [2:0] i2);
begin
    case (i2)
        3'd0:    pres_addr = 28'h0000000;
        3'd1:    pres_addr = 28'h00000A0;   // title
        3'd2:    pres_addr = 28'h00000B2;   // fixed 0x96 / main unit code
        3'd3:    pres_addr = 28'h002468A;
        3'd4:    pres_addr = 28'h007BCDE;
        default: pres_addr = 28'h00F1234;
    endcase
end
endfunction

wire [27:0] cand_size   = 28'h0100000 << cand;      // 1 MiB .. 16 MiB
wire [27:0] cand_mask   = cand_size - 28'd1;
wire [27:0] point_base  = cand_size + {4'd0, point_off(point)};
wire [27:0] probe_addr  = point_base + {12'd0, word_stride(word)};
wire [27:0] mirror_addr = probe_addr & cand_mask;

// Which of the twenty evidence slots this point is. cand is 0..4 and point is
// 0..3, so the slot is cand * 4 + point, which is a concatenation.
wire [4:0]  slot = {cand[2:0], point};

// cart_addr still holds the address the returned data came from, so the
// open-bus prediction is read straight off it. addr[16:1] is the low half of
// rom_word_addr, which is exactly what the core drove onto AD.
wire [15:0] rv          = rdata_q[15:0];
wire [15:0] open_pred   = cart_addr[16:1];
wire        pt_open_n   = pt_open   && (rv == open_pred);
wire        pt_mirror_n = pt_mirror && (rv == ref_val);
wire        pt_base_n   = pt_base   && (rv == base_val[word]);
wire        pt_varied_n = pt_varied || ((word != 2'd0) && (rv != first_val));
// The mirror arm needs a reference it can trust; see the header. The open arm
// needs the confirmation read, always.
wire        pt_end      = (pt_open && pt_conf) ||
                          (pt_mirror && pt_varied && !pt_ref_open);
wire [1:0]  pt_class    = (pt_open && pt_conf) ? CLS_OPEN :
                          (pt_mirror && pt_varied && !pt_ref_open) ? CLS_MIRROR
                                                                   : CLS_DATA;

wire        pres_open_n   = pres_all_open && (rv == open_pred);
wire        pres_varied_n = pres_varied || ((pres != 3'd0) && (rv != pres_first));

genvar gi;
generate
    for (gi = 0; gi < NSLOTS; gi = gi + 1) begin : g_slots
        assign dbg_class[2*gi  +: 2]  = pclass[gi];
        assign dbg_hits [12*gi +: 12] = {pbase[gi], pmir[gi], popen[gi]};
    end
    for (gi = 0; gi < NWORDS; gi = gi + 1) begin : g_words
        assign dbg_words[16*gi +: 16] = pt_word[gi];
        assign dbg_base [16*gi +: 16] = base_val[gi];
    end
    for (gi = 0; gi < NPRES; gi = gi + 1) begin : g_pres
        assign dbg_pres[16*gi +: 16] = pres_val[gi];
    end
endgenerate

always @(posedge clk) begin
    done <= 1'b0;

    if (reset) begin
        state         <= ST_IDLE;
        ret_state     <= ST_IDLE;
        busy          <= 1'b0;
        want_gba      <= 1'b0;
        cart_req      <= 1'b0;
        cart_addr     <= 28'd0;
        cart_acc      <= ACC_16BIT;
        size_bytes    <= 32'd0;
        size_valid    <= 1'b0;
        status        <= STATUS_IDLE;
        cand          <= 3'd0;
        point         <= 2'd0;
        word          <= 2'd0;
        pres          <= 3'd0;
        mode_wait     <= 16'd0;
        rdata_q       <= 32'd0;
        ref_val       <= 16'd0;
        first_val     <= 16'd0;
        pt_open       <= 1'b0;
        pt_mirror     <= 1'b0;
        pt_varied     <= 1'b0;
        pt_conf       <= 1'b0;
        pt_ref_open   <= 1'b0;
        pt_base       <= 1'b0;
        open_hits     <= 3'd0;
        mir_hits      <= 3'd0;
        base_hits     <= 3'd0;
        pres_first    <= 16'd0;
        pres_all_open <= 1'b1;
        pres_varied   <= 1'b0;
        dbg_addr      <= 28'd0;
        dbg_points    <= 5'd0;
        for (i = 0; i < NSLOTS; i = i + 1) begin
            pclass[i] <= CLS_UNSET;
            popen[i]  <= 4'd0;
            pmir[i]   <= 4'd0;
            pbase[i]  <= 4'd0;
        end
        for (i = 0; i < NWORDS; i = i + 1) begin
            base_val[i] <= 16'd0;
            pt_word[i]  <= 16'd0;
        end
        for (i = 0; i < NPRES; i = i + 1) pres_val[i] <= 16'd0;
    end else if (state != ST_IDLE && state != ST_MODE && state != ST_DONE &&
                 !cart_mode) begin
        // The connector left GBA mode underneath us. gba_cart_bus has reset
        // and will never answer the outstanding request, so stop rather than
        // hang, and report nothing rather than a size measured across a mode
        // change.
        //
        // ST_DONE is excluded because it is where this branch sends everything
        // it catches. Without that, a probe started with cart_mode already low
        // kept re-entering the abort, busy stuck high and done never pulsing -
        // which is exactly the hang the branch exists to prevent, and it was
        // caught by case 11 of tb_gba_size_probe on the first run.
        cart_req   <= 1'b0;
        size_bytes <= 32'd0;
        size_valid <= 1'b0;
        status     <= STATUS_NO_POWER;
        state      <= ST_DONE;
    end else begin
        case (state)
            ST_IDLE: begin
                cart_req <= 1'b0;
                if (start) begin
                    busy       <= 1'b1;
                    want_gba   <= 1'b1;
                    size_bytes <= 32'd0;
                    size_valid <= 1'b0;
                    status     <= STATUS_IDLE;

                    // Everything the last run left behind goes now, BEFORE the
                    // decision to proceed. Evidence from a previous cartridge
                    // shown beside this cartridge's verdict is worse than no
                    // evidence at all, and a refusal is exactly the case where
                    // someone reads the screen carefully.
                    dbg_addr   <= 28'd0;
                    dbg_points <= 5'd0;
                    for (i = 0; i < NSLOTS; i = i + 1) begin
                        pclass[i] <= CLS_UNSET;
                        popen[i]  <= 4'd0;
                        pmir[i]   <= 4'd0;
                        pbase[i]  <= 4'd0;
                    end
                    for (i = 0; i < NWORDS; i = i + 1) begin
                        base_val[i] <= 16'd0;
                        pt_word[i]  <= 16'd0;
                    end
                    for (i = 0; i < NPRES; i = i + 1) pres_val[i] <= 16'd0;

                    pres          <= 3'd0;
                    pres_all_open <= 1'b1;
                    pres_varied   <= 1'b0;
                    mode_wait     <= MODE_WAIT_CYCLES[15:0];
                    state         <= ST_MODE;
                end
            end

            // The probe asked for GBA mode one cycle ago and cart_pins takes
            // sixteen to turn the connector round, so cart_mode is still low
            // even on a perfectly good cartridge. Waiting is not optional:
            // gba_cart_bus ignores requests with cart_mode low and never
            // raises done, so issuing one now would hang.
            //
            // The timeout is what turns an unpowered slot into an answer.
            // Without it this state is the same forever-wait it exists to
            // avoid, just moved one module along.
            ST_MODE: begin
                if (cart_mode) begin
                    state <= ST_PRES_SET;
                end else if (mode_wait == 16'd0) begin
                    status     <= STATUS_NO_POWER;
                    size_valid <= 1'b0;
                    state      <= ST_DONE;
                end else begin
                    mode_wait <= mode_wait - 16'd1;
                end
            end

            // ---- the shared read -----------------------------------------
            //
            // gba_cart_bus samples req only in its own idle state and, unlike
            // gb_cart_bus, has no one-cycle refusal guard. So: wait until it
            // is idle, raise req for exactly one cycle, drop it, then wait for
            // done. Holding req until done would hand it a second request it
            // never asked for.
            ST_REQ: begin
                if (!cart_busy) begin
                    cart_req <= 1'b1;
                    state    <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                cart_req <= 1'b0;
                if (cart_done) begin
                    rdata_q <= cart_rdata;
                    state   <= ret_state;
                end
            end

            // ---- presence ------------------------------------------------
            ST_PRES_SET: begin
                cart_addr <= pres_addr(pres);
                cart_acc  <= ACC_16BIT;
                ret_state <= ST_PRES_GOT;
                state     <= ST_REQ;
            end

            ST_PRES_GOT: begin
                if (pres == 3'd0) pres_first <= rv;
                pres_all_open <= pres_open_n;
                pres_varied   <= pres_varied_n;
                pres_val[pres] <= rv;

                if (pres == NPRES - 1) begin
                    if (pres_open_n || !pres_varied_n) begin
                        // Either nothing is answering at all, or everything
                        // answers the same thing. Neither is a size, and they
                        // are different enough to be told apart on screen.
                        size_bytes <= 32'd0;
                        size_valid <= 1'b0;
                        status     <= pres_open_n ? STATUS_NO_CART
                                                  : STATUS_CONSTANT;
                        state      <= ST_DONE;
                    end else begin
                        word  <= 2'd0;
                        state <= ST_BASE_SET;
                    end
                end else begin
                    pres  <= pres + 3'd1;
                    state <= ST_PRES_SET;
                end
            end

            // ---- the offset-0 anchor -------------------------------------
            ST_BASE_SET: begin
                cart_addr <= {12'd0, word_stride(word)};
                cart_acc  <= ACC_16BIT;
                ret_state <= ST_BASE_GOT;
                state     <= ST_REQ;
            end

            ST_BASE_GOT: begin
                base_val[word] <= rv;
                if (word == NWORDS - 1) begin
                    cand  <= 3'd0;
                    point <= 2'd0;
                    state <= ST_PT_SET;
                end else begin
                    word  <= word + 2'd1;
                    state <= ST_BASE_SET;
                end
            end

            // ---- one sample point ----------------------------------------
            ST_PT_SET: begin
                pt_open     <= 1'b1;
                pt_mirror   <= 1'b1;
                pt_varied   <= 1'b0;
                pt_conf     <= 1'b0;
                pt_ref_open <= 1'b1;
                pt_base     <= 1'b1;
                open_hits   <= 3'd0;
                mir_hits    <= 3'd0;
                base_hits   <= 3'd0;
                word        <= 2'd0;
                dbg_addr    <= point_base;
                // A point that exits early leaves the halfwords it never read
                // at zero rather than at the previous point's values.
                for (i = 0; i < NWORDS; i = i + 1) pt_word[i] <= 16'd0;
                state       <= ST_REF_SET;
            end

            ST_REF_SET: begin
                cart_addr <= mirror_addr;
                cart_acc  <= ACC_16BIT;
                ret_state <= ST_REF_GOT;
                state     <= ST_REQ;
            end

            ST_REF_GOT: begin
                ref_val <= rv;
                // Did the reference itself read back as its own address? If
                // every one did, the wrapped region is as empty as the probed
                // region and the mirror comparison is comparing two floats.
                pt_ref_open <= pt_ref_open && (rv == open_pred);
                state   <= ST_PRB_SET;
            end

            ST_PRB_SET: begin
                cart_addr <= probe_addr;
                cart_acc  <= ACC_16BIT;
                ret_state <= ST_PRB_GOT;
                state     <= ST_REQ;
            end

            ST_PRB_GOT: begin
                if (word == 2'd0) first_val <= rv;
                pt_word[word] <= rv;
                pt_open   <= pt_open_n;
                pt_mirror <= pt_mirror_n;
                pt_varied <= pt_varied_n;
                pt_base   <= pt_base_n;

                if (rv == open_pred)     open_hits <= open_hits + 3'd1;
                if (rv == ref_val)       mir_hits  <= mir_hits  + 3'd1;
                if (rv == base_val[word]) base_hits <= base_hits + 3'd1;

                if (!pt_open_n && !pt_mirror_n) begin
                    // Already neither, so the remaining halfwords cannot
                    // change this point's answer. The common case on a real
                    // cartridge, and what keeps the probe short. The hit
                    // counts for such a point are over the halfwords actually
                    // read, which is why a DATA point with 0/4 says nothing
                    // and a DATA point with 3/4 says a great deal.
                    state <= ST_POINT;
                end else if (word == NWORDS - 1) begin
                    if (pt_open_n) state <= ST_CONF_SET;
                    else           state <= ST_POINT;
                end else begin
                    word  <= word + 2'd1;
                    state <= ST_REF_SET;
                end
            end

            // ---- the burst that tells a float from a driver ---------------
            ST_CONF_SET: begin
                cart_addr <= point_base;
                cart_acc  <= ACC_32BIT;
                ret_state <= ST_CONF_GOT;
                state     <= ST_REQ;
            end

            ST_CONF_GOT: begin
                // Reject only the exact ascending answer. A cartridge driving
                // the burst returns the next halfword; a float returns
                // whatever it decayed to, and calling that a driver would make
                // the probe over-report on the very cartridges it is there to
                // measure.
                pt_conf <= (rdata_q[15:0] == open_pred) &&
                           (rdata_q[31:16] != (open_pred + 16'd1));
                state   <= ST_POINT;
            end

            // ---- verdicts ------------------------------------------------
            ST_POINT: begin
                pclass[slot] <= pt_class;
                popen[slot]  <= {1'b0, open_hits};
                pmir[slot]   <= {1'b0, mir_hits};
                pbase[slot]  <= {1'b0, base_hits};
                dbg_points   <= dbg_points + 5'd1;

                if (!pt_end) begin
                    // One dissenting point is enough: this candidate is data.
                    if (cand == NCAND - 1) begin
                        // Nothing tripped anywhere below 32 MiB, and 32 MiB is
                        // all the bus can address, so there is nothing left to
                        // test and nothing above it to be wrong about. It is
                        // still a weaker claim than a measured size, and the
                        // status keeps them apart.
                        size_bytes <= SIZE_32MIB;
                        size_valid <= 1'b1;
                        status     <= STATUS_CEILING;
                        state      <= ST_DONE;
                    end else begin
                        cand  <= cand + 3'd1;
                        point <= 2'd0;
                        state <= ST_PT_SET;
                    end
                end else if (point == NPOINTS - 1) begin
                    size_bytes <= {4'd0, cand_size};
                    size_valid <= 1'b1;
                    status     <= STATUS_SIZED;
                    state      <= ST_DONE;
                end else begin
                    point <= point + 2'd1;
                    state <= ST_PT_SET;
                end
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
