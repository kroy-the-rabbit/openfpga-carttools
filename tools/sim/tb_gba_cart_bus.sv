// SOURCES: src/fpga/core/cart_pins.sv src/fpga/core/gba_cart_bus.sv
//
// Inherited from Rai's fork, where it lived next to the RTL in
// src/fpga/core/. It is here so Quartus never sees it, and so run_all.py can
// find it. Behaviour is unchanged apart from the pass line; see
// tools/sim/README.md for what it does and does not cover.
`timescale 1ns/1ps
`default_nettype none

module tb_gba_cart_bus;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg req = 1'b0;
reg wr = 1'b0;
reg [27:0] addr = 28'd0;
reg [1:0] acc = 2'b01;
reg [31:0] wdata = 32'd0;
wire [31:0] rdata;
wire done;
wire busy;

tri [7:0] bank2;
tri [7:0] bank3;
wire bank2_dir;
wire bank3_dir;
tri [7:0] bank1;
wire bank1_dir;
tri [7:4] bank0;
wire bank0_dir;
tri pin30;
wire pin30_dir;
wire pin30_pwroff_reset;
tri pin31;
wire pin31_dir;

// gba_cart_bus presents a flat engine interface; cart_pins owns the pins and
// every assertion below still reads them.
wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

reg [15:0] cart_drive_data = 16'hCAFE;
wire cart_read_active = cart_mode && !bank3_dir && !bank2_dir && (bank0[5] == 1'b0);
assign bank3 = cart_read_active ? cart_drive_data[7:0] : 8'hzz;
assign bank2 = cart_read_active ? cart_drive_data[15:8] : 8'hzz;

reg use_rom_sequence = 1'b0;
integer rom_rd_count = 0;
reg cs_rose_between_seq = 1'b0;
reg monitor_eeprom_hold = 1'b0;
reg eeprom_cs_rose = 1'b0;

always @(negedge bank0[5]) begin
    #1;
    if (use_rom_sequence && cart_mode && pin30 === 1'b1 && bank0[4] === 1'b0) begin
        case (rom_rd_count)
            0: cart_drive_data <= 16'h1122;
            1: cart_drive_data <= 16'h3344;
            default: cart_drive_data <= 16'h5566;
        endcase
        rom_rd_count <= rom_rd_count + 1;
    end
end

always @(posedge bank0[4]) begin
    #1;
    if (use_rom_sequence && busy && rom_rd_count == 1)
        cs_rose_between_seq <= 1'b1;
    if (monitor_eeprom_hold)
        eeprom_cs_rose <= 1'b1;
end

reg [7:0] save_drive_data = 8'hA5;
wire save_read_active = cart_mode && !bank1_dir && (pin30 == 1'b0) && (bank0[5] == 1'b0);
assign bank1 = save_read_active ? save_drive_data : 8'hzz;

reg monitor_eeprom_write = 1'b0;
reg eeprom_write_seen = 1'b0;
reg eeprom_write_setup_seen = 1'b0;
reg [15:0] eeprom_expected_write = 16'h0000;
always @(posedge clk) begin
    #1;
    if (monitor_eeprom_write && bank0[6] === 1'b1 && bank0[4] === 1'b0 &&
        bank3_dir === 1'b1 && bank2_dir === 1'b1 && {bank2, bank3} === eeprom_expected_write) begin
        eeprom_write_setup_seen <= 1'b1;
    end
    if (monitor_eeprom_write && bank0[6] === 1'b0) begin
        eeprom_write_seen <= 1'b1;
        if (!eeprom_write_setup_seen)
            $fatal(1, "EEPROM write data was not setup before WR# asserted");
        if (bank0[4] !== 1'b0 || pin30 !== 1'b1)
            $fatal(1, "EEPROM write did not select CS1 only");
        if (bank3_dir !== 1'b1 || bank2_dir !== 1'b1)
            $fatal(1, "EEPROM write did not drive AD data");
        if ({bank2, bank3} !== eeprom_expected_write)
            $fatal(1, "EEPROM write data was %h", {bank2, bank3});
    end
end

// A non-sequential ROM access presents the low address halfword on AD and the
// cart latches it while CS1 is low and RD# is still high. Releasing AD inside
// that window loses the address, so guard it.
//
// The window has to be bounded at both ends, because AD is legitimately
// undriven with CS1 low and RD# high in three other places: after RD# rises at
// the end of a beat, throughout a sequential beat, where the cart increments
// the address itself and the host must stay off the bus, and between EEPROM
// serial bits, where CS1 stays low across transactions by design. So arm on AD
// actually being driven with CS1 low, and disarm on RD# falling, on CS1
// releasing, or on the transaction ending. What is left is the latch window.
reg latch_armed = 1'b0;
wire ad_driven = (bank3_dir === 1'b1) && (bank2_dir === 1'b1);
wire latch_window = cart_mode && busy && pin30 === 1'b1 &&
                    bank0[4] === 1'b0 && bank0[5] === 1'b1;
always @(posedge clk) begin
    #1;
    if (latch_armed && latch_window && !ad_driven)
        $fatal(1, "ROM address bus released before RD# asserted");
    if (latch_window && ad_driven)
        latch_armed <= 1'b1;
    else if (!latch_window)
        latch_armed <= 1'b0;
end

// Watchdog. A testbench that stops making progress has to fail with a message
// naming itself, not stall until run_all.py's own timeout, where the only
// evidence left is a dead process.
initial begin
    #100_000;
    $fatal(1, "%m: watchdog expired at %0t with busy=%b; the run never reached its end",
           $time, busy);
end

gba_cart_bus #(
    .ADDR_HOLD_CYCLES  (1),
    .ADDR_LATCH_CYCLES (1),
    .READ_TURNAROUND_CYCLES(1),
    .READ_SETUP_CYCLES (2),
    .WRITE_SETUP_CYCLES(1),
    .WRITE_HOLD_CYCLES (1)
) dut (
    .clk(clk),
    .reset(reset),
    .cart_mode(cart_mode),
    .req(req),
    .wr(wr),
    .addr(addr),
    .acc(acc),
    .wdata(wdata),
    .rdata(rdata),
    .done(done),
    .busy(busy),
    .e_ad_out(e_ad_out),
    .e_ad_oe(e_ad_oe),
    .e_hi_out(e_hi_out),
    .e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),
    .e_p30_out(e_p30_out),
    .e_p30_oe(e_p30_oe),
    .e_ad_in(e_ad_in),
    .e_hi_in(e_hi_in)
);

cart_pins pins (
    .clk(clk),
    .reset(reset),
    .mode(cart_mode ? 2'b01 : 2'b00),
    .mode_ready(mode_ready),
    .gba_ad_out(e_ad_out),
    .gba_ad_oe(e_ad_oe),
    .gba_hi_out(e_hi_out),
    .gba_hi_oe(e_hi_oe),
    .gba_ctl_out(e_ctl_out),
    .gba_p30_out(e_p30_out),
    .gba_p30_oe(e_p30_oe),
    .gba_ad_in(e_ad_in),
    .gba_hi_in(e_hi_in),
    .cart_tran_bank2(bank2),
    .cart_tran_bank2_dir(bank2_dir),
    .cart_tran_bank3(bank3),
    .cart_tran_bank3_dir(bank3_dir),
    .cart_tran_bank1(bank1),
    .cart_tran_bank1_dir(bank1_dir),
    .cart_tran_bank0(bank0),
    .cart_tran_bank0_dir(bank0_dir),
    .cart_tran_pin30(pin30),
    .cart_tran_pin30_dir(pin30_dir),
    .cart_pin30_pwroff_reset(pin30_pwroff_reset),
    .cart_tran_pin31(pin31),
    .cart_tran_pin31_dir(pin31_dir)
);

task automatic pulse_req(input bit is_write, input [27:0] a, input [1:0] size, input [31:0] d);
begin
    @(posedge clk);
    wr <= is_write;
    addr <= a;
    acc <= size;
    wdata <= d;
    req <= 1'b1;
    @(posedge clk);
    req <= 1'b0;
    wait (done == 1'b1);
    @(posedge clk);
end
endtask

initial begin
    repeat (2) @(posedge clk);
    if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0 || pin30_dir !== 1'b0)
        $fatal(1, "idle outside cart_mode drives bidirectional pins");

    reset <= 1'b0;
    cart_mode <= 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (2) @(posedge clk);
    if (pin30_pwroff_reset !== 1'b1)
        $fatal(1, "cart power/reset release not asserted in cart_mode");

    cart_drive_data <= 16'hBEEF;
    pulse_req(1'b0, 28'h0000120, 2'b01, 32'd0);
    if (rdata[15:0] !== 16'hBEEF)
        $fatal(1, "ROM read returned %h", rdata);
    if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0)
        $fatal(1, "AD bus still driven after read completion");

    use_rom_sequence <= 1'b1;
    rom_rd_count <= 0;
    cs_rose_between_seq <= 1'b0;
    pulse_req(1'b0, 28'h0000120, 2'b10, 32'd0);
    use_rom_sequence <= 1'b0;
    if (rdata !== 32'h33441122)
        $fatal(1, "32-bit ROM read returned %h", rdata);
    if (rom_rd_count !== 2)
        $fatal(1, "32-bit ROM read used %0d RD pulses", rom_rd_count);
    if (cs_rose_between_seq)
        $fatal(1, "CS# rose between sequential ROM word beats");

    save_drive_data <= 8'hA5;
    pulse_req(1'b0, 28'hE000123, 2'b00, 32'd0);
    if (rdata !== 32'hA5A5A5A5)
        $fatal(1, "save read returned %h", rdata);
    if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0 || bank1_dir !== 1'b0)
        $fatal(1, "save read bus still driven after completion");

    pulse_req(1'b1, 28'hE000123, 2'b00, 32'h0000005A);
    if (pin30 !== 1'b1 || pin30_dir !== 1'b1)
        $fatal(1, "CS2 did not return high after save write");
    if (bank0[6] !== 1'b1)
        $fatal(1, "WR# did not return high after write");

    eeprom_write_seen <= 1'b0;
    eeprom_write_setup_seen <= 1'b0;
    eeprom_expected_write <= 16'h0001;
    monitor_eeprom_write <= 1'b1;
    pulse_req(1'b1, 28'hD000000, 2'b01, 32'h00000001);
    monitor_eeprom_write <= 1'b0;
    if (!eeprom_write_seen)
        $fatal(1, "EEPROM write never asserted WR#");
    if (bank0[4] !== 1'b0)
        $fatal(1, "EEPROM CS1 was not held after first serial bit");

    eeprom_cs_rose <= 1'b0;
    monitor_eeprom_hold <= 1'b1;
    eeprom_write_seen <= 1'b0;
    eeprom_write_setup_seen <= 1'b0;
    eeprom_expected_write <= 16'h0000;
    monitor_eeprom_write <= 1'b1;
    pulse_req(1'b1, 28'hD000000, 2'b01, 32'h00000000);
    monitor_eeprom_write <= 1'b0;
    monitor_eeprom_hold <= 1'b0;
    if (!eeprom_write_seen)
        $fatal(1, "second EEPROM write never asserted WR#");
    if (eeprom_cs_rose)
        $fatal(1, "EEPROM CS1 rose between serial bit writes");
    if (bank0[4] !== 1'b0)
        $fatal(1, "EEPROM CS1 was not held after second serial bit");

    eeprom_cs_rose <= 1'b0;
    monitor_eeprom_hold <= 1'b1;
    pulse_req(1'b0, 28'hD000000, 2'b01, 32'd0);
    monitor_eeprom_hold <= 1'b0;
    if (!eeprom_cs_rose)
        $fatal(1, "EEPROM CS1 did not release on write-to-read direction change");
    if (bank0[4] !== 1'b0)
        $fatal(1, "EEPROM CS1 was not held after first read bit");

    cart_drive_data <= 16'h1234;
    pulse_req(1'b0, 28'h0000120, 2'b01, 32'd0);
    if (bank0[4] !== 1'b1)
        $fatal(1, "EEPROM CS1 did not release on non-EEPROM access");

    cart_mode <= 1'b0;
    repeat (2) @(posedge clk);
    if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0 || pin30_dir !== 1'b0)
        $fatal(1, "cart_mode deassert did not tri-state bidirectional pins");

    $display("TB PASS: tb_gba_cart_bus");
    $finish;
end

endmodule
