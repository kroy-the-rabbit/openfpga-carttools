// gba_cart_model.sv - a behavioural GBA cartridge for the bus testbenches.
//
// This is not a testbench. It has no SOURCES line and no pass line; it is
// named in the SOURCES line of the testbenches that instantiate it.
//
// Why it exists: the cartridge stub inside tb_gba_cart_bus.sv drives AD only
// when the module has already released it (`!bank3_dir && !bank2_dir`), so a
// direction bug in gba_cart_bus cannot be observed there. The stub agrees with
// the module by construction. This model decides what to drive from the
// protocol alone, that is from the strobes and chip selects, exactly as a
// cartridge would, and then reports a drive-against-drive collision instead of
// quietly letting the resolution function hide it.
//
// The memory behind the cart is the testbench's, not this model's: the model
// presents whatever `rom_rdata` / `save_rdata` say for the address it has
// latched. That keeps the model small and lets each testbench pick a mapping
// it can predict.
//
// How MUCH memory is behind it is the model's business, though, because where a
// cartridge stops answering is a property of the cartridge. Set ROM_EXTENT and
// drive `rom_words` for that; see the "ROM extent and open bus" block below.
// The parameter defaults off, so a testbench that does not care about the end
// of the ROM needs no change and can leave those inputs unconnected.
//
// Protocol implemented, per docs/HARDWARE-NOTES.md section 4:
//   - CS1# falling latches all 24 address bits from {bank1, bank2, bank3}.
//   - RD# rising with CS1# still low increments the latched address, carrying
//     only within the low 16 bits, which is what bounds a burst to a 64K
//     halfword page.
//   - ROM data comes back on AD (bank2/bank3) while CS1# and RD# are low.
//   - CS2# falling latches a 16-bit save address from AD; save data moves on
//     bank1, one byte, because the GBA save bus is eight bits wide.
//   - WR# rising latches write data, from AD in CS1 space and from bank1 in
//     CS2 space.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none

module gba_cart_model #(
    // A contention report is a hardware-damaging condition, so it stops the
    // run by default. The self-test in tb_gba_cart_model.sv sets this to 0 so
    // it can prove the detector actually fires.
    parameter integer CONTENTION_FATAL = 1,
    // 0: the cart answers at every address, which is what every testbench
    //    written before the size probe assumed. rom_words, rom_mirrors and
    //    rom_extra_answer are then never evaluated and may be left unconnected.
    // 1: rom_words says how much mask ROM is fitted and the model stops
    //    answering above it, so past-the-end reads see the float. See the
    //    "ROM extent and open bus" block below.
    parameter integer ROM_EXTENT = 0,
    // Sampling granularity for the contention monitor, in timescale units.
    // Coarser than a delta cycle on purpose: both sides of a legal handover
    // change on the same clock edge, and a level check inside the nonblocking
    // update region would see a phantom overlap. Anything real lasts a whole
    // clock, so 1 ns against a 10 ns clock cannot miss it.
    parameter integer SAMPLE_PERIOD = 1,
    // Time to let the bus settle after a strobe edge before sampling the value
    // the cartridge would have captured on it.
    parameter integer SETTLE = 1
) (
    input  wire        cart_mode,
    // Pulse high for one moment to zero the observation counters. A port
    // rather than a hierarchical task call, so the testbenches do not depend
    // on Icarus resolving one.
    input  wire        clr,

    inout  wire [7:0]  bank3,      // AD[7:0]
    input  wire        bank3_dir,
    inout  wire [7:0]  bank2,      // AD[15:8]
    input  wire        bank2_dir,
    inout  wire [7:0]  bank1,      // A[23:16], or save data
    input  wire        bank1_dir,
    input  wire [7:4]  bank0,      // {PHI, WR#, RD#, CS1#}
    input  wire        pin30,      // CS2#

    // How much mask ROM is fitted, in halfwords, and what happens above it.
    // Only read when ROM_EXTENT is 1.
    //   rom_words == 0        an empty slot: the cart never drives at all
    //   rom_mirrors == 0      above the ROM nothing drives, so reads see the
    //                         float, which is the address this core last drove
    //   rom_mirrors == 1      the high address lines are not wired to the mask
    //                         ROM, so the address wraps within rom_words
    // rom_words must be a power of two; the wrap is a mask, not a modulo.
    input  wire [24:0] rom_words,
    input  wire        rom_mirrors,
    // "This one address answers anyway." A partly decoded high address line, or
    // a marginal contact that drops one bit of the decode, is a real fault and
    // it is the fault a size probe has to fail safely on, so the model can be
    // told to answer somewhere it has no silicon. Driven from rom_addr_raw by
    // the testbench; ignored unless ROM_EXTENT is 1.
    input  wire        rom_extra_answer,
    // Make the float decay. 0 never; 1 from the first RD# of every CS1 phase;
    // 2 from the second, which is the second beat of a 32-bit access. The
    // keeper below holds a value indefinitely and exactly, which is the one
    // way this model is kinder than a connector, and the size probe's rules
    // about what a decayed float may look like are otherwise asserted by
    // nobody. Ignored unless ROM_EXTENT is 1.
    input  wire [1:0]  ad_decay_beat,

    // The address this cartridge believes it is on, and the data the testbench
    // wants returned for it. With ROM_EXTENT set this is the WRAPPED address,
    // because a mask ROM missing its top address lines is a property of the
    // cartridge's wiring, not of the image behind it.
    output wire [23:0] rom_addr,
    // The address as latched, never wrapped. A testbench deciding whether a
    // fault answers at a particular place needs the address the bus asked for,
    // not the one the silicon would have folded it to.
    output wire [23:0] rom_addr_raw,
    input  wire [15:0] rom_rdata,
    output wire [15:0] save_addr,
    input  wire [7:0]  save_rdata,

    // Observation. Cleared only by `clr`, so a testbench can bracket exactly
    // the transactions it cares about.
    output reg  [31:0] cs1_latch_count,
    output reg  [31:0] cs2_latch_count,
    output reg  [31:0] rom_rd_count,
    output reg  [31:0] save_rd_count,
    output reg  [31:0] wr_pulse_count,
    output reg  [31:0] rom_wr_count,
    output reg  [31:0] save_wr_count,
    output reg  [23:0] last_cs1_latch_addr,
    output reg  [15:0] last_cs2_latch_addr,
    output reg  [23:0] last_rom_wr_addr,
    output reg  [15:0] last_rom_wr_data,
    output reg  [15:0] last_save_wr_addr,
    output reg  [7:0]  last_save_wr_data,

    output reg         contention_seen,
    output reg         both_cs_seen
);

wire cs1_n = bank0[4];
wire rd_n  = bank0[5];
wire wr_n  = bank0[6];
wire cs2_n = pin30;

reg [23:0] cs1_addr;
reg [15:0] cs2_addr;

// --- ROM extent and open bus ----------------------------------------------
//
// A cartridge only answers where it has silicon. Above that the AD lines are
// driven by nobody and hold whatever was last put on them, which for a ROM read
// is the halfword address gba_cart_bus drove before releasing the bus. That is
// the whole mechanism gba_size_probe measures with, and it is recorded observed
// on hardware in docs/BRINGUP.md as `0A0 0050 0051 0052`.
//
// The float is modelled by a keeper, below, and not by having the cart drive
// the address: the point of a size probe testbench is that past the end the
// cartridge is silent, and a model that answered would prove nothing about a
// cartridge that does not. The keeper stands in for board and translator
// capacitance, so it belongs to the board rather than to this cartridge; it
// lives here only because this is the module already holding the pins.
//
// A real float decays, and picks up whatever the last driver left. This one
// holds indefinitely and exactly, so it is the main way this model is kinder
// than a connector: a cartridge whose float sagged to all-ones inside the
// 139 ns read window would look like data here and like data to the probe.
wire [23:0] rom_mask = rom_words[23:0] - 24'd1;
wire        rom_inside  = (rom_words != 25'd0) && ({1'b0, cs1_addr} < rom_words);
wire        rom_fitted  = (ROM_EXTENT == 0) ? 1'b1
                        : ((rom_words != 25'd0) &&
                           (rom_inside || rom_mirrors ||
                            (rom_extra_answer === 1'b1)));

assign rom_addr_raw = cs1_addr;
assign rom_addr  = (ROM_EXTENT == 0) ? cs1_addr
                 : (rom_inside ? cs1_addr : (cs1_addr & rom_mask));
assign save_addr = cs2_addr;

// What a cartridge would drive, derived from the bus and nothing else. The
// module's direction bits deliberately do not appear here: that is the whole
// point of the model.
wire rom_drive  = cart_mode && (cs1_n === 1'b0) && (cs2_n === 1'b1) &&
                  (rd_n === 1'b0) && rom_fitted;
wire save_drive = cart_mode && (cs2_n === 1'b0) && (cs1_n === 1'b1) &&
                  (rd_n === 1'b0);

// The host is driving AD when either half of it is in output mode.
wire host_drives_ad = (bank2_dir === 1'b1) || (bank3_dir === 1'b1);
wire ad_float = (ROM_EXTENT != 0) && cart_mode && !host_drives_ad && !rom_drive;

reg [15:0] ad_keep = 16'hFFFF;

// Sampled on a timer rather than continuously, for the same reason the
// contention monitor is: both drivers change on one clock edge and a level
// check inside the nonblocking update region sees a phantom x. Anything real
// lasts a whole clock.
//
// The reduction XOR is the x/z test, not $isunknown. Icarus returns 1 from
// $isunknown on these inout port nets even when every bit reads back as a
// known 0, which silently froze the keeper at its initial value and made every
// past-the-end read return FFFF. The XOR agrees with what %h prints.
initial begin
    if (ROM_EXTENT != 0) begin
        forever begin
            #SAMPLE_PERIOD;
            if ((host_drives_ad || rom_drive) && (^{bank2, bank3} !== 1'bx))
                ad_keep = {bank2, bank3};
        end
    end
end

// A decayed float. Counted in RD# pulses since the CS1# fall rather than in
// nanoseconds because that is the unit the probe's exposure is measured in:
// the second beat of a 32-bit access holds AD undriven for about twice as long
// as a single read, and the question is what the probe does when the value has
// gone by then. All-ones is what an undriven CMOS input with a weak pull
// settles to, and it is also what a GB read with no cartridge returns.
wire [1:0] decay_beat = (ad_decay_beat === 2'b01) ? 2'd1 :
                        (ad_decay_beat === 2'b10) ? 2'd2 : 2'd0;
reg [3:0] rd_in_phase = 4'd0;

always @(negedge cs1_n) rd_in_phase = 4'd0;
always @(negedge rd_n)  rd_in_phase = rd_in_phase + 4'd1;

wire       ad_decayed = (ROM_EXTENT != 0) && (decay_beat != 2'd0) &&
                        ({2'd0, decay_beat} <= rd_in_phase);
wire [15:0] ad_held   = ad_decayed ? 16'hFFFF : ad_keep;

assign bank3 = rom_drive  ? rom_rdata[7:0]  : ad_float ? ad_held[7:0]  : 8'hzz;
assign bank2 = rom_drive  ? rom_rdata[15:8] : ad_float ? ad_held[15:8] : 8'hzz;
assign bank1 = save_drive ? save_rdata      : 8'hzz;

initial begin
    cs1_addr = 24'd0;
    cs2_addr = 16'd0;
    cs1_latch_count = 32'd0;
    cs2_latch_count = 32'd0;
    rom_rd_count = 32'd0;
    save_rd_count = 32'd0;
    wr_pulse_count = 32'd0;
    rom_wr_count = 32'd0;
    save_wr_count = 32'd0;
    last_cs1_latch_addr = 24'd0;
    last_cs2_latch_addr = 16'd0;
    last_rom_wr_addr = 24'd0;
    last_rom_wr_data = 16'd0;
    last_save_wr_addr = 16'd0;
    last_save_wr_data = 8'd0;
    contention_seen = 1'b0;
    both_cs_seen = 1'b0;
end

always @(posedge clr) begin
    cs1_latch_count = 32'd0;
    cs2_latch_count = 32'd0;
    rom_rd_count = 32'd0;
    save_rd_count = 32'd0;
    wr_pulse_count = 32'd0;
    rom_wr_count = 32'd0;
    save_wr_count = 32'd0;
    // The contention flags are observations like the rest, so they clear too.
    // With CONTENTION_FATAL set they can never survive to be read anyway.
    contention_seen = 1'b0;
    both_cs_seen = 1'b0;
end

// --- address latching -----------------------------------------------------

always @(negedge cs1_n) begin
    #SETTLE;
    if (cart_mode) begin
        cs1_addr = {bank1, bank2, bank3};
        last_cs1_latch_addr = cs1_addr;
        cs1_latch_count = cs1_latch_count + 32'd1;
    end
end

always @(negedge cs2_n) begin
    #SETTLE;
    if (cart_mode) begin
        cs2_addr = {bank2, bank3};
        last_cs2_latch_addr = cs2_addr;
        cs2_latch_count = cs2_latch_count + 32'd1;
    end
end

// --- reads ----------------------------------------------------------------

always @(negedge rd_n) begin
    #SETTLE;
    if (cart_mode) begin
        if (cs1_n === 1'b0 && cs2_n === 1'b1)
            rom_rd_count = rom_rd_count + 32'd1;
        if (cs2_n === 1'b0 && cs1_n === 1'b1)
            save_rd_count = save_rd_count + 32'd1;
    end
end

// The cart's own counter advances on the RD# rising edge, and carries only
// within the low 16 bits. A burst that would cross a 64K halfword page wraps
// back to the start of the page instead, which is the behaviour rom_page_end
// in the module exists to avoid relying on.
always @(posedge rd_n) begin
    #SETTLE;
    if (cart_mode && cs1_n === 1'b0 && cs2_n === 1'b1)
        cs1_addr[15:0] = cs1_addr[15:0] + 16'd1;
end

// --- writes ---------------------------------------------------------------

always @(negedge wr_n) begin
    #SETTLE;
    if (cart_mode)
        wr_pulse_count = wr_pulse_count + 32'd1;
end

always @(posedge wr_n) begin
    #SETTLE;
    if (cart_mode) begin
        if (cs2_n === 1'b0 && cs1_n === 1'b1) begin
            save_wr_count = save_wr_count + 32'd1;
            last_save_wr_addr = cs2_addr;
            last_save_wr_data = bank1;
        end else if (cs1_n === 1'b0 && cs2_n === 1'b1) begin
            rom_wr_count = rom_wr_count + 32'd1;
            last_rom_wr_addr = cs1_addr;
            last_rom_wr_data = {bank2, bank3};
        end
    end
end

// --- contention -----------------------------------------------------------

reg ad_clash_prev   = 1'b0;
reg bank1_clash_prev = 1'b0;
reg both_cs_prev    = 1'b0;

wire ad_clash    = rom_drive && (bank2_dir === 1'b1 || bank3_dir === 1'b1);
wire bank1_clash = save_drive && (bank1_dir === 1'b1);
wire both_cs     = cart_mode && (cs1_n === 1'b0) && (cs2_n === 1'b0);

task report_clash(input [511:0] what);
begin
    contention_seen = 1'b1;
    if (CONTENTION_FATAL)
        $fatal(1, "gba_cart_model: bus contention, %0s", what);
    else
        $display("gba_cart_model: bus contention (non-fatal), %0s", what);
end
endtask

initial begin
    forever begin
        #SAMPLE_PERIOD;
        if (ad_clash && !ad_clash_prev)
            report_clash("cart drove AD for a read while bank2/bank3_dir was still output");
        if (bank1_clash && !bank1_clash_prev)
            report_clash("cart drove save data on bank1 while bank1_dir was still output");
        if (both_cs && !both_cs_prev) begin
            both_cs_seen = 1'b1;
            if (CONTENTION_FATAL)
                $fatal(1, "gba_cart_model: CS1# and CS2# were asserted together");
            else
                $display("gba_cart_model: CS1# and CS2# asserted together (non-fatal)");
        end
        ad_clash_prev = ad_clash;
        bank1_clash_prev = bank1_clash;
        both_cs_prev = both_cs;
    end
end

endmodule

`default_nettype wire
