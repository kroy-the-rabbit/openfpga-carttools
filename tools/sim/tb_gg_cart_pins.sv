// SOURCES: src/fpga/core/cart_pins.sv
`default_nettype none
`timescale 1ns/1ps
module tb_gg_cart_pins;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;
reg [1:0] mode = 0;
wire mode_ready;
reg [15:0] gg_addr = 0;
reg gg_addr_oe = 1;
reg [7:0] gg_data = 8'h3C;
reg gg_data_oe = 0;
reg [3:0] gg_ctl = 4'hF;
wire [7:0] gg_data_in;
wire [7:0] bank2, bank3, bank1;
wire [7:4] bank0;
wire pin30, pin31;
wire b2dir, b3dir, b1dir, b0dir, p30dir, p31dir, clamp_release;
reg [7:0] cart_data = 8'h96;
reg cart_drive = 0;
reg gg_sense = 0;
assign bank1 = cart_drive ? cart_data : 8'hZZ;
assign pin31 = gg_sense;

cart_pins dut (
    .clk(clk), .reset(reset), .mode(mode), .mode_ready(mode_ready),
    .gba_ad_out(16'h1357), .gba_ad_oe(1'b1), .gba_hi_out(8'h24), .gba_hi_oe(1'b1),
    .gba_ctl_out(4'hF), .gba_p30_out(1'b1), .gba_p30_oe(1'b1), .gba_ad_in(), .gba_hi_in(),
    .gb_ad_out(16'hA55A), .gb_ad_oe(1'b1), .gb_hi_out(8'hD6), .gb_hi_oe(1'b1),
    .gb_ctl_out(4'hF), .gb_p30_out(1'b1), .gb_p30_oe(1'b1), .gb_ad_in(), .gb_hi_in(),
    .gg_ad_out(gg_addr), .gg_ad_oe(gg_addr_oe), .gg_hi_out(gg_data), .gg_hi_oe(gg_data_oe),
    .gg_ctl_out(gg_ctl), .gg_p30_out(1'b1), .gg_p30_oe(1'b1), .gg_hi_in(gg_data_in),
    .cart_tran_bank2(bank2), .cart_tran_bank2_dir(b2dir),
    .cart_tran_bank3(bank3), .cart_tran_bank3_dir(b3dir),
    .cart_tran_bank1(bank1), .cart_tran_bank1_dir(b1dir),
    .cart_tran_bank0(bank0), .cart_tran_bank0_dir(b0dir),
    .cart_tran_pin30(pin30), .cart_tran_pin30_dir(p30dir),
    .cart_pin30_pwroff_reset(clamp_release),
    .cart_tran_pin31(pin31), .cart_tran_pin31_dir(p31dir)
);

task check_idle;
    begin
        #1;
        if (b2dir !== 0 || b3dir !== 0 || b1dir !== 0 || p30dir !== 0 ||
            clamp_release !== 0 || bank0 !== 4'hF || b0dir !== 1)
            $fatal(1, "pins not safely idle during mode transition/reset");
    end
endtask
task select_mode(input [1:0] next_mode);
    begin
        @(negedge clk); mode = next_mode;
        check_idle();
        if (mode_ready !== 0) $fatal(1, "mode change skipped settle window");
        wait (mode_ready);
        @(negedge clk);
    end
endtask
task vector(input [15:0] logical_addr, input [15:0] physical_addr);
    begin
        @(negedge clk); gg_addr = logical_addr;
        #1;
        if ({bank2, bank3} !== physical_addr || b2dir !== 1 || b3dir !== 1)
            $fatal(1, "GG address %04x mapped to %04x, expected %04x", logical_addr, {bank2, bank3}, physical_addr);
    end
endtask

// Independent one-hot vectors derived from GG pin numbers, in logical A0..15
// order. No copy of the implementation's concatenation is used as an oracle.
reg [15:0] expected_one [0:15];
integer i;
initial begin
    expected_one[0]=16'h0100; expected_one[1]=16'h0080;
    expected_one[2]=16'h0040; expected_one[3]=16'h0020;
    expected_one[4]=16'h0010; expected_one[5]=16'h0008;
    expected_one[6]=16'h0004; expected_one[7]=16'h0002;
    expected_one[8]=16'h2000; expected_one[9]=16'h1000;
    expected_one[10]=16'h0200; expected_one[11]=16'h0800;
    expected_one[12]=16'h0001; expected_one[13]=16'h4000;
    expected_one[14]=16'h8000; expected_one[15]=16'h0400;
    repeat (4) @(negedge clk);
    check_idle();
    reset = 0;
    select_mode(2'b11);
    if (pin30 !== 1 || p30dir !== 1 || clamp_release !== 1)
        $fatal(1, "GG reset clamp did not release");
    for (i=0; i<16; i=i+1) begin
        vector(16'h0001 << i, expected_one[i]);
        vector(~(16'h0001 << i), ~expected_one[i]);
    end
    vector(16'h0000,16'h0000);
    vector(16'h7FF0,16'hFA1F);
    vector(16'hFFFC,16'hFE7F);
    vector(16'hFFFD,16'hFF7F);
    vector(16'hFFFE,16'hFEFF);
    vector(16'hFFFF,16'hFFFF);
    @(negedge clk); cart_drive = 1;
    #1;
    if (b1dir !== 0 || gg_data_in !== 8'h96) $fatal(1, "GG read-data direction/order");
    @(negedge clk); cart_drive = 0; gg_data_oe = 1;
    #1;
    if (b1dir !== 1 || bank1 !== 8'h3C) $fatal(1, "GG write-data direction/order");
    gg_ctl = 4'b1100; #1;
    if (bank0 !== 4'b1100) $fatal(1, "GG /IOREQ /WR /RD /CE order");
    gg_ctl = 4'b1010; #1;
    if (bank0 !== 4'b1010) $fatal(1, "GG mapper-write control order");
    gg_ctl = 4'hF;
    gg_sense = 1; #1;
    if (p31dir !== 0 || pin31 !== 1) $fatal(1, "GG mode-sense must be input");
    gg_sense = 0; #1;
    if (p31dir !== 0 || pin31 !== 0) $fatal(1, "GG mode-sense low is contended");

    // Unselected engines deliberately request every output throughout this
    // test. The mux must isolate them and preserve both native permutations.
    select_mode(2'b10);
    if ({bank2,bank3} !== 16'hA55A || bank1 !== 8'hD6) $fatal(1, "GB pin mapping changed");
    select_mode(2'b01);
    if ({bank2,bank3} !== 16'h1357 || bank1 !== 8'h24) $fatal(1, "GBA pin mapping changed");
    select_mode(2'b11);
    @(negedge clk); reset = 1;
    check_idle();
    repeat (3) @(negedge clk);
    reset = 0;
    wait (mode_ready);
    @(negedge clk); mode = 0;
    check_idle();
    if (p31dir !== 0) $fatal(1, "pin31 output in idle");
    $display("TB PASS: tb_gg_cart_pins");
    $finish;
end
initial begin #100000; $fatal(1, "tb_gg_cart_pins watchdog"); end
endmodule
`default_nettype wire
