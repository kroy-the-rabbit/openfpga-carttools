// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv tools/sim/gba_cart_model.sv
//
// tb_gba_cart_async.sv - reset, cart_mode and req arriving at the wrong moment.
//
// These are the hot-unplug and mode-change cases. Nothing in the inherited
// testbench touches them, and they are the ones that leave a cartridge
// half-written, so each is swept across every cycle of a transaction rather
// than sampled at one convenient point.
//
// The property being proved in the first two sweeps is the same one either
// way: whatever cycle the interruption lands on, the module must end with
// every pin either released or driven inactive, no strobe left asserted, no
// new WR# pulse, and no stuck `busy`. The third sweep proves a request that
// arrives while the bus is busy is dropped rather than half-latched.
//
// Shipped default timing throughout.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`default_nettype none

module tb_gba_cart_async;

reg clk = 1'b0;
always #5 clk = ~clk;

reg        reset = 1'b1;
// cart_pins is reset once at power-on. In core_top both resets are
// ~pll_core_locked; here they are separate so the sweeps below exercise the
// engine's reset with the pins held in GBA mode.
reg        pins_reset = 1'b1;
reg        cart_mode = 1'b0;
reg        req = 1'b0;
reg        wr = 1'b0;
reg [27:0] addr = 28'd0;
reg [1:0]  acc = 2'b01;
reg [31:0] wdata = 32'd0;
reg        clr = 1'b0;

wire [31:0] rdata;
wire        done, busy;

tri  [7:0] bank2, bank3, bank1;
wire       bank2_dir, bank3_dir, bank1_dir;
tri  [7:4] bank0;
wire       bank0_dir;
tri        pin30;
wire       pin30_dir, pin30_pwroff;
tri        pin31;
wire       pin31_dir;

wire [23:0] rom_addr;
wire [15:0] save_addr;
wire [31:0] cs1_latch_count, wr_pulse_count, save_wr_count, rom_rd_count;
wire [7:0]  last_save_wr_data;

function [15:0] rom_word(input [23:0] a);
begin
    rom_word = {a[7:0] ^ a[23:16], a[15:8] + 8'h5A};
end
endfunction

// Watchdog. A testbench that stops making progress has to fail with a message
// naming itself, not stall until run_all.py's own timeout, where the only
// evidence left is a dead process.
initial begin
    #600_000;
    $fatal(1, "%m: watchdog expired at %0t with busy=%b; the run never reached its end",
           $time, busy);
end

// gba_cart_bus presents a flat engine interface; cart_pins owns the pins and
// every assertion below still reads them.
wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

gba_cart_bus dut (
    .clk(clk), .reset(reset), .cart_mode(cart_mode),
    .req(req), .wr(wr), .addr(addr), .acc(acc), .wdata(wdata),
    .rdata(rdata), .done(done), .busy(busy),
    .e_ad_out(e_ad_out), .e_ad_oe(e_ad_oe),
    .e_hi_out(e_hi_out), .e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),
    .e_p30_out(e_p30_out), .e_p30_oe(e_p30_oe),
    .e_ad_in(e_ad_in), .e_hi_in(e_hi_in)
);

cart_pins pins (
    .clk(clk), .reset(pins_reset), .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(mode_ready),
    .gba_ad_out(e_ad_out), .gba_ad_oe(e_ad_oe),
    .gba_hi_out(e_hi_out), .gba_hi_oe(e_hi_oe),
    .gba_ctl_out(e_ctl_out),
    .gba_p30_out(e_p30_out), .gba_p30_oe(e_p30_oe),
    .gba_ad_in(e_ad_in), .gba_hi_in(e_hi_in),
    .cart_tran_bank2(bank2), .cart_tran_bank2_dir(bank2_dir),
    .cart_tran_bank3(bank3), .cart_tran_bank3_dir(bank3_dir),
    .cart_tran_bank1(bank1), .cart_tran_bank1_dir(bank1_dir),
    .cart_tran_bank0(bank0), .cart_tran_bank0_dir(bank0_dir),
    .cart_tran_pin30(pin30), .cart_tran_pin30_dir(pin30_dir),
    .cart_pin30_pwroff_reset(pin30_pwroff),
    .cart_tran_pin31(pin31), .cart_tran_pin31_dir(pin31_dir)
);

gba_cart_model cart (
    .cart_mode(cart_mode), .clr(clr),
    .bank3(bank3), .bank3_dir(bank3_dir),
    .bank2(bank2), .bank2_dir(bank2_dir),
    .bank1(bank1), .bank1_dir(bank1_dir),
    .bank0(bank0), .pin30(pin30),
    .rom_addr(rom_addr), .rom_rdata(rom_word(rom_addr)),
    .save_addr(save_addr), .save_rdata(8'hA5),
    .cs1_latch_count(cs1_latch_count), .cs2_latch_count(),
    .rom_rd_count(rom_rd_count), .save_rd_count(),
    .wr_pulse_count(wr_pulse_count),
    .rom_wr_count(), .save_wr_count(save_wr_count),
    .last_cs1_latch_addr(), .last_cs2_latch_addr(),
    .last_rom_wr_addr(), .last_rom_wr_data(),
    .last_save_wr_addr(), .last_save_wr_data(last_save_wr_data),
    .contention_seen(), .both_cs_seen()
);

// A WR# edge after the interruption would be a write the requester never got
// to cancel, which is the whole hazard.
reg no_more_wr = 1'b0;
always @(negedge bank0[6]) begin
    #1;
    if (no_more_wr)
        $fatal(1, "WR# fell after the transaction was interrupted (n=%0d)", n);
end

integer done_count = 0;
always @(posedge clk) begin
    #1;
    if (done) done_count = done_count + 1;
end

// Width of the last completed WR# low pulse, in clk cycles.
integer wr_low_run = 0;
integer wr_low_width = 0;
always @(posedge clk) begin
    #1;
    if (bank0[6] === 1'b0) begin
        wr_low_run = wr_low_run + 1;
    end else if (wr_low_run != 0) begin
        wr_low_width = wr_low_run;
        wr_low_run = 0;
    end
end

// --- safe-state checks ----------------------------------------------------

// With cart_mode still high the module owns the strobes and has to park them
// deasserted, per docs/HARDWARE-NOTES.md section 3: driving a strobe inactive
// is safer than letting it float behind a level translator.
task check_safe_in_cart_mode(input [511:0] why);
begin
    if (busy !== 1'b0)
        $fatal(1, "%0s: busy still high", why);
    if (bank0[4] !== 1'b1 || bank0[5] !== 1'b1 || bank0[6] !== 1'b1)
        $fatal(1, "%0s: bank0 left at %b, a strobe is still asserted", why,
               bank0);
    if (bank0_dir !== 1'b1)
        $fatal(1, "%0s: strobes left floating, bank0_dir is %b", why,
               bank0_dir);
    if (pin30 !== 1'b1 || pin30_dir !== 1'b1)
        $fatal(1, "%0s: CS2# left at %b with dir %b", why, pin30, pin30_dir);
    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0)
        $fatal(1, "%0s: a data bank is still an output (%b%b%b)", why,
               bank1_dir, bank2_dir, bank3_dir);
    if (bank1 !== 8'hzz || bank2 !== 8'hzz || bank3 !== 8'hzz)
        $fatal(1, "%0s: a data bank is still driven (%h %h %h)", why,
               bank1, bank2, bank3);
    if (pin31 !== 1'bz || pin31_dir !== 1'b0)
        $fatal(1, "%0s: pin31 is driven", why);
end
endtask

// Out of cart_mode the pins must fall all the way back to the idle of
// docs/HARDWARE-NOTES.md section 3: banks released, strobes parked at 4'hf,
// pin30 at 0 with its translator an input and the clamp still asserted.
task check_safe_out_of_cart_mode(input [511:0] why);
begin
    if (bank0 !== 4'hf || bank0_dir !== 1'b1)
        $fatal(1, "%0s: bank0 is %b with dir %b, expected f driven", why,
               bank0, bank0_dir);
    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0)
        $fatal(1, "%0s: a data bank is still an output (%b%b%b)", why,
               bank1_dir, bank2_dir, bank3_dir);
    if (bank1 !== 8'hzz || bank2 !== 8'hzz || bank3 !== 8'hzz)
        $fatal(1, "%0s: a data bank is still driven (%h %h %h)", why,
               bank1, bank2, bank3);
    if (pin30 !== 1'b0 || pin30_dir !== 1'b0)
        $fatal(1, "%0s: pin30 is %b with dir %b, expected 0 with dir 0", why,
               pin30, pin30_dir);
    if (pin30_pwroff !== 1'b0)
        $fatal(1, "%0s: cart_pin30_pwroff_reset still released the clamp", why);
    if (pin31 !== 1'bz || pin31_dir !== 1'b0)
        $fatal(1, "%0s: pin31 is driven", why);
end
endtask

// --- stimulus helpers -----------------------------------------------------

task automatic start_req(input is_write, input [27:0] a, input [1:0] size,
                         input [31:0] d);
begin
    @(posedge clk);
    wr <= is_write;
    addr <= a;
    acc <= size;
    wdata <= d;
    req <= 1'b1;
    @(posedge clk);
    req <= 1'b0;
end
endtask

task automatic finish_req;
begin
    wait (busy);
    wait (!busy);
    repeat (2) @(posedge clk);
end
endtask

// A plain transaction, used after every interruption to prove the module came
// back rather than merely stopped.
task automatic check_recovery;
begin
    done_count = 0;
    start_req(1'b0, 28'h0000120, 2'b01, 32'd0);
    finish_req;
    if (rdata[15:0] !== rom_word(24'h000090))
        $fatal(1, "recovery read returned %h, expected %h", rdata[15:0],
               rom_word(24'h000090));
    if (done_count !== 1)
        $fatal(1, "recovery read reported done %0d times", done_count);
end
endtask

integer n;
integer i;

initial begin
    repeat (2) @(posedge clk);
    reset <= 1'b0;
    pins_reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(posedge clk);

    // --- reset in the middle of a transaction ------------------------------
    // Swept past the end of the longest transaction here, a 32-bit write,
    // which is 2*(3+5+1+13+9)+1 = 63 cycles.
    for (n = 1; n <= 66; n = n + 1) begin
        start_req(1'b1, 28'hE000100, 2'b10, 32'h11223344);
        repeat (n) @(posedge clk);
        reset <= 1'b1;
        // Armed only once the reset edge has been taken. Arming it before that
        // edge would flag the WR# fall the module had already committed to on
        // the same edge, which is not a strobe that escaped the reset.
        @(posedge clk);
        #1;
        no_more_wr = 1'b1;
        check_safe_in_cart_mode("reset during a 32-bit save write");
        reset <= 1'b0;
        repeat (2) @(posedge clk);
        no_more_wr = 1'b0;
        check_recovery;
    end

    for (n = 1; n <= 55; n = n + 1) begin
        start_req(1'b0, 28'h0000120, 2'b10, 32'd0);
        repeat (n) @(posedge clk);
        reset <= 1'b1;
        @(posedge clk);
        #1;
        no_more_wr = 1'b1;
        check_safe_in_cart_mode("reset during a 32-bit ROM read");
        reset <= 1'b0;
        repeat (2) @(posedge clk);
        no_more_wr = 1'b0;
        check_recovery;
    end

    // --- cart_mode dropping in the middle of a transaction -----------------
    // The pin assignments are combinational in cart_mode, so the bus has to be
    // safe before the next clock edge, not after it. That is checked first,
    // then busy is checked once the state machine has had its edge.
    for (n = 1; n <= 66; n = n + 1) begin
        start_req(1'b1, 28'hE000100, 2'b10, 32'h11223344);
        repeat (n) @(posedge clk);
        no_more_wr = 1'b1;
        cart_mode = 1'b0;
        #1 check_safe_out_of_cart_mode("cart_mode dropped during a save write");
        @(posedge clk);
        #1;
        if (busy !== 1'b0)
            $fatal(1, "cart_mode dropped during a save write left busy high");
        check_safe_out_of_cart_mode("cart_mode dropped, one clock later");
        cart_mode = 1'b1;
        // cart_pins passes a mode change through idle before driving anything.
        wait (mode_ready);
        no_more_wr = 1'b0;
        repeat (2) @(posedge clk);
        check_recovery;
    end

    for (n = 1; n <= 55; n = n + 1) begin
        start_req(1'b0, 28'h0000120, 2'b10, 32'd0);
        repeat (n) @(posedge clk);
        no_more_wr = 1'b1;
        cart_mode = 1'b0;
        #1 check_safe_out_of_cart_mode("cart_mode dropped during a ROM read");
        @(posedge clk);
        #1;
        if (busy !== 1'b0)
            $fatal(1, "cart_mode dropped during a ROM read left busy high");
        cart_mode = 1'b1;
        // cart_pins passes a mode change through idle before driving anything.
        wait (mode_ready);
        no_more_wr = 1'b0;
        repeat (2) @(posedge clk);
        check_recovery;
    end

    // --- req while busy ----------------------------------------------------
    // The intruding request is a save-space write, so if the module ever
    // latched it mid-transaction the WR# monitor would see a pulse that the
    // outer 32-bit ROM read can never produce.
    for (n = 1; n <= 40; n = n + 1) begin
        clr <= 1'b1;
        @(posedge clk);
        clr <= 1'b0;
        done_count = 0;
        start_req(1'b0, 28'h0000120, 2'b10, 32'd0);
        repeat (n) @(posedge clk);
        wr <= 1'b1;
        addr <= 28'hE000200;
        acc <= 2'b00;
        wdata <= 32'h000000FF;
        req <= 1'b1;
        repeat (3) @(posedge clk);
        req <= 1'b0;
        wr <= 1'b0;
        finish_req;
        if (rdata !== {rom_word(24'h000091), rom_word(24'h000090)})
            $fatal(1, "req at cycle %0d of a busy transaction corrupted rdata: %h",
                   n, rdata);
        if (done_count !== 1)
            $fatal(1, "req at cycle %0d of a busy transaction produced %0d done pulses",
                   n, done_count);
        if (wr_pulse_count !== 32'd0)
            $fatal(1, "req at cycle %0d of a busy transaction let a write through",
                   n);
        if (cs1_latch_count !== 32'd1)
            $fatal(1, "req at cycle %0d of a busy transaction caused %0d address phases",
                   n, cs1_latch_count);
        if (rom_rd_count !== 32'd2)
            $fatal(1, "req at cycle %0d of a busy transaction caused %0d reads",
                   n, rom_rd_count);
    end

    // --- req held high across done -----------------------------------------
    // Pinned behaviour, and a trap worth knowing about: `req` is a level in
    // ST_IDLE, and ST_DONE returns to ST_IDLE the cycle after it raises
    // `done`. A requester that waits for `done` before dropping `req` is
    // already one cycle too late, so it gets another transaction. Anything
    // driving this module has to deassert req on the cycle it asserts it.
    done_count = 0;
    @(posedge clk);
    wr <= 1'b0;
    addr <= 28'h0000120;
    acc <= 2'b01;
    wdata <= 32'd0;
    req <= 1'b1;
    i = 0;
    while (done_count < 3 && i < 400) begin
        @(posedge clk);
        i = i + 1;
    end
    if (done_count < 3)
        $fatal(1, "req held high produced only %0d transactions in 400 cycles",
               done_count);
    @(posedge clk);
    req <= 1'b0;
    // One transaction may already be in flight; a 16-bit read is about 30
    // cycles, so 80 is well past the last one that req could have started.
    repeat (80) @(posedge clk);
    i = done_count;
    repeat (80) @(posedge clk);
    if (done_count !== i)
        $fatal(1, "%0d more transactions started after req was dropped",
               done_count - i);
    if (busy !== 1'b0)
        $fatal(1, "bus never went idle after req was dropped");

    // --- reset and cart_mode against a held EEPROM chip select -------------
    // After an EEPROM access the module parks with CS1# still low, on purpose,
    // so consecutive serial bits stay inside one selection. That leaves an
    // asserted chip select across an idle bus, which both escapes have to
    // clear.
    check_recovery;
    start_req(1'b1, 28'hD000000, 2'b01, 32'h00000001);
    finish_req;
    if (bank0[4] !== 1'b0)
        $fatal(1, "EEPROM access did not leave CS1# held low");
    reset <= 1'b1;
    @(posedge clk);
    #1;
    if (bank0[4] !== 1'b1)
        $fatal(1, "reset did not release the held EEPROM CS1#");
    check_safe_in_cart_mode("reset with EEPROM CS1# held");
    reset <= 1'b0;
    repeat (2) @(posedge clk);

    check_recovery;
    start_req(1'b1, 28'hD000000, 2'b01, 32'h00000001);
    finish_req;
    if (bank0[4] !== 1'b0)
        $fatal(1, "EEPROM access did not leave CS1# held low");
    cart_mode = 1'b0;
    #1 check_safe_out_of_cart_mode("cart_mode dropped with EEPROM CS1# held");
    cart_mode = 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (2) @(posedge clk);
    check_recovery;

    // --- KNOWN DEFECT: aborting inside ST_WRITE ---------------------------
    // Reported, not fixed: gba_cart_bus.sv is not modified by this testbench.
    //
    // A reset or a cart_mode drop inside ST_WRITE raises WR# and removes the
    // write data on the same instant. A cartridge latches write data on the
    // WR# rising edge, so what it captures is whatever the released bus
    // settles to, at the address the module already selected. In save space
    // that is a corrupted byte in the player's save file, and it happens
    // exactly in the hot-unplug and mode-change cases this file exists for.
    //
    // The checks below assert what the module does today, so this stays a
    // passing description of the defect rather than a red suite. If the module
    // is ever changed to hold data for a cycle after WR# rises, or to refuse
    // to start a beat it cannot finish, these two checks fail and should be
    // updated to the new behaviour.

    // Baseline first: an uninterrupted save write is 12 clocks of WR# low and
    // the cart captures the byte that was asked for.
    check_recovery;
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    start_req(1'b1, 28'hE000100, 2'b01, 32'h000000A3);
    finish_req;
    if (wr_low_width !== 12)
        $fatal(1, "uninterrupted save write held WR# low for %0d clk, expected 12",
               wr_low_width);
    if (last_save_wr_data !== 8'hA3)
        $fatal(1, "uninterrupted save write delivered %h, expected A3",
               last_save_wr_data);

    // Now the same write, reset two cycles after WR# falls.
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    start_req(1'b1, 28'hE000100, 2'b01, 32'h000000A3);
    @(negedge bank0[6]);
    repeat (2) @(posedge clk);
    reset <= 1'b1;
    @(posedge clk);
    #1;
    no_more_wr = 1'b1;
    check_safe_in_cart_mode("reset two cycles into WR# low");
    reset <= 1'b0;
    repeat (4) @(posedge clk);
    no_more_wr = 1'b0;
    if (wr_low_width !== 3)
        $fatal(1, "reset inside ST_WRITE gave a %0d clk WR# pulse, expected the 3 clk runt",
               wr_low_width);
    if (wr_pulse_count !== 32'd1)
        $fatal(1, "the truncated write made %0d WR# pulses, expected 1",
               wr_pulse_count);
    // The model cannot attribute this pulse to save space, because CS2# rose
    // on the very same edge as WR#. That is the point: the cartridge is left
    // to decide what a simultaneous WR# and CS2# release means, with the data
    // bus already let go.
    if (save_wr_count !== 32'd0)
        $fatal(1, "the truncated write was still attributable to save space (%0d)",
               save_wr_count);
    $display("note: reset inside ST_WRITE cut WR# to a %0d clk pulse and released CS2# and bank1 on the same edge",
             wr_low_width);

    // The same through a cart_mode drop, which is worse: no clock edge is
    // involved at all, so WR# rises and bank1 is released in the same instant.
    check_recovery;
    clr <= 1'b1;
    @(posedge clk);
    clr <= 1'b0;
    start_req(1'b1, 28'hE000100, 2'b01, 32'h000000A3);
    @(negedge bank0[6]);
    repeat (2) @(posedge clk);
    #1;
    cart_mode = 1'b0;
    no_more_wr = 1'b1;
    #1 check_safe_out_of_cart_mode("cart_mode dropped two cycles into WR# low");
    // Restored only after the module has taken an edge with cart_mode low, so
    // it actually resets rather than resuming the write it was in the middle
    // of.
    @(posedge clk);
    #1;
    if (busy !== 1'b0)
        $fatal(1, "cart_mode dropped inside WR# low left busy high");
    cart_mode = 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(posedge clk);
    no_more_wr = 1'b0;
    if (wr_pulse_count !== 32'd1)
        $fatal(1, "cart_mode drop inside ST_WRITE made %0d WR# pulses, expected 1",
               wr_pulse_count);
    if (save_wr_count !== 32'd0)
        $fatal(1, "cart_mode drop inside ST_WRITE was still attributable to save space (%0d)",
               save_wr_count);
    $display("note: a cart_mode drop inside ST_WRITE raises WR# and releases CS2# and bank1 with no clock edge at all");
    check_recovery;

    $display("TB PASS: tb_gba_cart_async");
    $finish;
end

endmodule
