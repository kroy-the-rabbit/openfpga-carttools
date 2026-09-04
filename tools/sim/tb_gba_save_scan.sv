// SOURCES: src/fpga/services/identify/gba_save_scan.sv
//
// tb_gba_save_scan.sv - finding the SDK's save library string in a ROM
//
// The bus is stubbed here rather than instantiated, which is the opposite
// choice from tb_cart_save_gba and is deliberate. What this module does with
// the connector is one 32-bit read after another, exactly what cart_dump_gba
// already does and what tb_cart_dump_gba already proves against the real bus
// and the real cartridge model. What is worth proving here is the matcher,
// and a matcher is proven by feeding it bytes, of which it needs millions.
// A stub answers a read in two cycles instead of fifty and lets this file
// scan a whole ROM in every case below.
//
// What the cases have to cover, because each is a way a string matcher gets
// this wrong:
//
//   A signature straddling a 32-bit read. The window is fed a byte at a time
//   and never cleared between words, so this must work, and it is the first
//   thing a per-word matcher would fail. Every signature is planted at each
//   of the four byte alignments.
//
//   A signature ending on the very last byte of the ROM. The scan finishes on
//   the same cycle that byte is fed, so a matcher comparing the registered
//   window rather than the window including the current byte never tests it.
//   That was a real defect in this module before this case was written.
//
//   SRAM_V against SRAM_F_V. Both end in "_V" and both begin "SRAM", so a
//   matcher that stops at the first match, or that compares too few bytes,
//   reports the wrong one. Neither may be reported for the other.
//
//   FLASH_V against FLASH512_V and FLASH1M_V. All three begin "FLASH" and all
//   three end "_V". FLASH512_V and FLASH1M_V must not raise FLASH_V, which
//   would be harmless here because they are the same family, but would hide a
//   matcher that is comparing on a prefix.
//
//   Two families at once. A cartridge carrying an SRAM string and a Flash
//   string is ambiguous and must say so rather than pick one.
//
//   A clean ROM. No string, nothing found, nothing ambiguous.
//
//   A rerun. The seen bits are cleared at start, so a cartridge with no
//   signature scanned after one with a signature reports nothing.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1ns/1ps

module tb_gba_save_scan;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;

reg         start = 1'b0;
reg  [31:0] rom_size_bytes = 32'd0;

wire        busy, done;
wire        found_eeprom, found_sram, found_sram_f;
wire        found_flash, found_flash512, found_flash1m;
wire        ambiguous, found_any;
wire        want_gba;
wire        complete;
reg         cart_mode = 1'b1;
// Cycles after start before cart_mode rises, standing in for cart_pins
// turning the connector round. 0 means it is already up.
integer     mode_delay = 0;
// Hold cart_mode low for the whole run, standing in for an empty or
// unpowered slot. The scan must time out rather than wait.
reg         mode_never = 1'b0;
reg         abort = 1'b0;
// Feed count at which abort is pulsed mid-scan. -1 never.
integer     abort_at = -1;
// Feed count at which cart_mode is dropped mid-scan. -1 never.
integer     drop_at = -1;
integer     feeds = 0;

wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata;
reg  [31:0] bus_rdata = 32'd0;
reg         bus_done  = 1'b0;
reg         bus_busy  = 1'b0;

integer errors = 0;

gba_save_scan dut (
    .clk (clk), .reset (reset),
    .start (start), .rom_size_bytes (rom_size_bytes),
    .busy (busy), .done (done), .want_gba (want_gba),
    .cart_mode (cart_mode), .complete (complete), .abort (abort),
    .found_eeprom (found_eeprom), .found_sram (found_sram),
    .found_sram_f (found_sram_f), .found_flash (found_flash),
    .found_flash512 (found_flash512), .found_flash1m (found_flash1m),
    .ambiguous (ambiguous), .found_any (found_any),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy)
);

// --- the ROM ------------------------------------------------------------------
// A sparse model: filler everywhere, with a planted string at `plant_at`. The
// filler is a function of the address rather than a constant, so a matcher
// that latched on a run of identical bytes would not pass, and it is forced
// away from the ASCII the signatures use.
localparam integer ROM_BYTES = 4096;

reg [7:0] plant [0:15];
integer   plant_len = 0;
integer   plant_at  = -1;
reg [7:0] plant2 [0:15];
integer   plant2_len = 0;
integer   plant2_at  = -1;

function [7:0] rom_byte(input integer a);
    integer off;
begin
    rom_byte = 8'h20 + ((a * 7) % 8'h1F);   // 0x20-0x3E, no letters
    if (plant_at >= 0 && a >= plant_at && a < plant_at + plant_len) begin
        off = a - plant_at;
        rom_byte = plant[off];
    end
    if (plant2_at >= 0 && a >= plant2_at && a < plant2_at + plant2_len) begin
        off = a - plant2_at;
        rom_byte = plant2[off];
    end
end
endfunction

// The stub. One transaction, two cycles, a whole 32-bit word built little
// endian from four ROM bytes, which is the order gba_cart_bus returns.
always @(posedge clk) begin
    bus_done <= 1'b0;
    if (reset) begin
        bus_busy <= 1'b0;
    end else if (!cart_mode) begin
        // gba_cart_bus holds its FSM in reset while cart_mode is low and never
        // raises done. The stub has to do the same or the tests below prove
        // nothing about the real thing.
        bus_busy <= 1'b0;
    end else if (bus_req && !bus_busy) begin
        bus_busy <= 1'b1;
        bus_rdata <= {rom_byte(bus_addr + 3), rom_byte(bus_addr + 2),
                      rom_byte(bus_addr + 1), rom_byte(bus_addr + 0)};
    end else if (bus_busy) begin
        bus_busy <= 1'b0;
        bus_done <= 1'b1;
    end
end

// Counts bytes fed, so a test can drop the mode partway through a scan.
always @(posedge clk) begin
    if (!reset && dut.state == 3'd4) feeds <= feeds + 1;
end

// --- the mode must be held for the whole scan --------------------------------
// By the time this module starts, cart_probe has parked the connector at idle.
// gba_cart_bus holds its FSM in ST_IDLE while cart_mode is low and never
// raises done, so a scan that does not ask for the mode waits forever with
// busy high. That shipped to a card once and froze the core: every dump option
// vanished and only a reload recovered it. gba_size_probe has want_gba for
// exactly this reason and this module now does too.
//
// The invariant is want_gba == busy, every cycle. Asserted rather than
// sampled at the ends, because a hold that drops mid-scan is the same failure
// arriving later.
integer want_errors = 0;
always @(posedge clk) begin
    if (!reset && want_gba !== busy) begin
        if (want_errors < 5)
            $display("ERROR: want_gba=%b with busy=%b at %0t", want_gba, busy, $time);
        want_errors = want_errors + 1;
        errors = errors + 1;
    end
end

// --- the module may never write ----------------------------------------------
always @(posedge clk) begin
    if (!reset && bus_req && bus_wr !== 1'b0) begin
        $display("ERROR: bus_wr asserted with a request at %0t", $time);
        errors = errors + 1;
    end
end

// --- helpers ------------------------------------------------------------------
task set_plant(input [127:0] s, input integer len, input integer at);
    integer j;
begin
    plant_len = len;
    plant_at  = at;
    // s is packed with the first character in the high bytes.
    for (j = 0; j < len; j = j + 1)
        plant[j] = s[(len - 1 - j) * 8 +: 8];
end
endtask

task set_plant2(input [127:0] s, input integer len, input integer at);
    integer j;
begin
    plant2_len = len;
    plant2_at  = at;
    for (j = 0; j < len; j = j + 1)
        plant2[j] = s[(len - 1 - j) * 8 +: 8];
end
endtask

task no_plant2;
begin
    plant2_len = 0;
    plant2_at  = -1;
end
endtask

task run_scan(input [31:0] n);
    integer d;
begin
    rom_size_bytes = n;
    feeds     = 0;
    cart_mode = (mode_delay == 0) && !mode_never;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    if (mode_delay > 0 && !mode_never) begin
        for (d = 0; d < mode_delay; d = d + 1) @(negedge clk);
        cart_mode = 1'b1;
    end
    if (drop_at >= 0) begin
        wait (feeds >= drop_at);
        cart_mode = 1'b0;
    end
    if (abort_at >= 0) begin
        // Driven from a negedge, as everything else here is. wait releases
        // just after a posedge, so raising it there and dropping it at the
        // following negedge never spans an edge the DUT samples.
        wait (feeds >= abort_at);
        @(negedge clk);
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
    end
    wait (done == 1'b1);
    @(negedge clk);
    cart_mode = 1'b1;
end
endtask

// One expectation per signature, so a wrong one is named rather than counted.
task expect_only(input [5:0] want, input [511:0] label);
    reg [5:0] got;
begin
    got = {found_flash1m, found_flash512, found_flash, found_sram_f,
           found_sram, found_eeprom};
    if (got !== want) begin
        $display("ERROR: %0s gave %b, expected %b  (flash1m,flash512,flash,sram_f,sram,eeprom)",
                 label, got, want);
        errors = errors + 1;
    end
end
endtask

integer align;
integer at;

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_gba_save_scan.vcd");
        $dumpvars(0, tb_gba_save_scan);
    end

    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // ---- A clean ROM finds nothing -----------------------------------------
    plant_at = -1; plant_len = 0; no_plant2;
    run_scan(ROM_BYTES);
    expect_only(6'b000000, "a clean ROM");
    if (found_any !== 1'b0 || ambiguous !== 1'b0) begin
        $display("ERROR: a clean ROM reported found_any=%b ambiguous=%b",
                 found_any, ambiguous);
        errors = errors + 1;
    end

    // ---- Each signature, at every byte alignment ----------------------------
    // The straddle case. A matcher that looked at whole words rather than a
    // rolling window would pass at alignment 0 and fail at the other three.
    for (align = 0; align < 4; align = align + 1) begin
        at = 512 + align;

        no_plant2;

        set_plant("SRAM_V", 6, at);
        run_scan(ROM_BYTES);
        expect_only(6'b000010, "SRAM_V");

        set_plant("SRAM_F_V", 8, at);
        run_scan(ROM_BYTES);
        expect_only(6'b000100, "SRAM_F_V");

        set_plant("EEPROM_V", 8, at);
        run_scan(ROM_BYTES);
        expect_only(6'b000001, "EEPROM_V");

        set_plant("FLASH_V", 7, at);
        run_scan(ROM_BYTES);
        expect_only(6'b001000, "FLASH_V");

        set_plant("FLASH512_V", 10, at);
        run_scan(ROM_BYTES);
        expect_only(6'b010000, "FLASH512_V");

        set_plant("FLASH1M_V", 9, at);
        run_scan(ROM_BYTES);
        expect_only(6'b100000, "FLASH1M_V");
    end

    // ---- A signature ending on the last byte of the ROM ---------------------
    // The scan finishes on the cycle that byte is fed. This is the case a
    // matcher that compares the registered window silently fails.
    no_plant2;
    set_plant("SRAM_V", 6, ROM_BYTES - 6);
    run_scan(ROM_BYTES);
    expect_only(6'b000010, "SRAM_V ending on the last byte");

    set_plant("FLASH512_V", 10, ROM_BYTES - 10);
    run_scan(ROM_BYTES);
    expect_only(6'b010000, "FLASH512_V ending on the last byte");

    // ---- Two families at once is ambiguous ----------------------------------
    set_plant("SRAM_V", 6, 512);
    set_plant2("FLASH1M_V", 9, 1024);
    run_scan(ROM_BYTES);
    expect_only(6'b100010, "SRAM_V and FLASH1M_V together");
    if (ambiguous !== 1'b1) begin
        $display("ERROR: an SRAM string and a Flash string did not report ambiguous");
        errors = errors + 1;
    end

    // ---- Two strings of the same family are not ambiguous -------------------
    set_plant("FLASH_V", 7, 512);
    set_plant2("FLASH1M_V", 9, 1024);
    run_scan(ROM_BYTES);
    if (ambiguous !== 1'b0) begin
        $display("ERROR: two Flash strings reported ambiguous, they are one family");
        errors = errors + 1;
    end
    if (found_any !== 1'b1) begin
        $display("ERROR: two Flash strings did not report found_any");
        errors = errors + 1;
    end

    // ---- A rerun clears what the last cartridge left ------------------------
    plant_at = -1; plant_len = 0; no_plant2;
    run_scan(ROM_BYTES);
    expect_only(6'b000000, "a clean ROM after a signature was found");
    if (found_any !== 1'b0 || ambiguous !== 1'b0) begin
        $display("ERROR: a rerun kept the previous cartridge's result");
        errors = errors + 1;
    end

    // ---- A zero-size ROM finishes and touches nothing -----------------------
    run_scan(32'd0);
    expect_only(6'b000000, "a zero-size ROM");

    // ---- The connector is not up yet when the scan starts -------------------
    // This is the case that shipped and froze a core. cart_probe parks the
    // mode, the size probe drops its request as it finishes, and cart_pins
    // takes sixteen cycles to turn the connector round, so cart_mode is low
    // when the scan begins. A scan that issues a request now is ignored by
    // gba_cart_bus and waits for a done that never comes.
    plant_at = -1; plant_len = 0; no_plant2;
    set_plant("SRAM_V", 6, 512);
    mode_delay = 40;
    run_scan(ROM_BYTES);
    mode_delay = 0;
    expect_only(6'b000010, "SRAM_V with the mode arriving late");
    if (complete !== 1'b1) begin
        $display("ERROR: a scan that waited for the mode did not report complete");
        errors = errors + 1;
    end

    // ---- The connector never comes up ---------------------------------------
    // An empty or unpowered slot. It must give up and finish, and it must NOT
    // claim the ROM held no save string, because it never read the ROM.
    mode_never = 1'b1;
    run_scan(ROM_BYTES);
    mode_never = 1'b0;
    if (complete !== 1'b0) begin
        $display("ERROR: a scan that never got the connector reported complete");
        errors = errors + 1;
    end
    if (busy !== 1'b0) begin
        $display("ERROR: the scanner is still busy after giving up on the mode");
        errors = errors + 1;
    end

    // ---- The mode drops partway through -------------------------------------
    // A cartridge pulled mid-scan. gba_cart_bus resets and the outstanding
    // request is never answered, so the scan has to notice rather than wait.
    set_plant("FLASH1M_V", 9, 3000);
    drop_at = 600;
    run_scan(ROM_BYTES);
    drop_at = -1;
    if (complete !== 1'b0) begin
        $display("ERROR: a scan abandoned mid-run reported complete");
        errors = errors + 1;
    end
    if (busy !== 1'b0) begin
        $display("ERROR: the scanner is still busy after the mode dropped");
        errors = errors + 1;
    end

    // ---- And it recovers -----------------------------------------------------
    // The next cartridge must scan normally. A module that latched an abort
    // would pass everything above and be useless.
    plant_at = -1; plant_len = 0; no_plant2;
    set_plant("SRAM_V", 6, 512);
    run_scan(ROM_BYTES);
    expect_only(6'b000010, "SRAM_V after an abandoned scan");
    if (complete !== 1'b1) begin
        $display("ERROR: the scan after an abandoned one did not report complete");
        errors = errors + 1;
    end

    // A scan must actually have run, or the invariant above was never tested.
    if (want_errors == 0 && errors == 0 && busy !== 1'b0) begin
        $display("ERROR: the scanner is still busy at the end of the run");
        errors = errors + 1;
    end

    // ---- A dump interruption restarts a running scan ----------------------
    // A guarded ROM dump starts as soon as its fresh size probe finishes. The
    // save scan also starts on that edge, then loses the bus to the dump. If it
    // merely stops, the save button disappears after the ROM dump and never
    // returns. It must restart from byte zero when the dump releases the bus.
    plant_at = -1; plant_len = 0; no_plant2;
    set_plant("SRAM_V", 6, 512);
    abort_at = 300;
    run_scan(ROM_BYTES);
    abort_at = -1;
    expect_only(6'b000010, "SRAM_V after a dump interruption");
    if (busy !== 1'b0) begin
        $display("ERROR: the restarted scanner is still busy");
        errors = errors + 1;
    end
    if (complete !== 1'b1) begin
        $display("ERROR: the restarted scan did not report complete");
        errors = errors + 1;
    end
    if (feeds <= ROM_BYTES) begin
        $display("ERROR: the interrupted scan did not restart from byte zero");
        errors = errors + 1;
    end

    // ---- An abort does NOT destroy a finished scan -------------------------
    // This is the defect the abort input exists to fix. It was a reset, and a
    // reset cleared the seen bits, so dumping a ROM threw away a completed
    // scan and the save button vanished until the cartridge was rescanned.
    run_scan(ROM_BYTES);
    expect_only(6'b000010, "SRAM_V before an abort");
    abort = 1'b1;
    repeat (4) @(negedge clk);
    abort = 1'b0;
    repeat (4) @(negedge clk);
    expect_only(6'b000010, "SRAM_V after an abort with no scan running");
    if (complete !== 1'b1) begin
        $display("ERROR: an abort with no scan running cleared complete");
        errors = errors + 1;
    end

    if (errors == 0) $display("TB PASS: tb_gba_save_scan");
    else begin
        $display("TB FAIL: tb_gba_save_scan, %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

initial begin
    #200000000;
    $display("ERROR: timeout");
    $fatal(1);
end

endmodule

`default_nettype wire
