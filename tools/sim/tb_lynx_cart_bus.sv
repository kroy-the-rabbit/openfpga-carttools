// SOURCES: src/fpga/core/lynx_cart_bus.sv
`default_nettype none
`timescale 1ns/1ps
module tb_lynx_cart_bus;
reg clk=0;
always #5 clk=~clk;
reg reset=1, lynx_mode=0, req=0, wr=0;
reg [15:0] addr=0;
reg [7:0] wdata=0;
wire [7:0] rdata;
wire done,busy,write_active,rejected;
wire [15:0] e_ad_out;
wire e_ad_oe,e_hi_oe,e_p30_out,e_p30_oe;
wire [7:0] e_hi_out, e_hi_in;
wire [3:0] e_ctl_out;
localparam integer POWER=40;
lynx_cart_bus #(.POWER_CYCLES(POWER),.SHIFT_CYCLES(2),.SETTLE_CYCLES(6),
                .ADDR_SETUP_CYCLES(3),.STROBE_CYCLES(5),.HOLD_CYCLES(3)) dut (
    .clk(clk),.reset(reset),.lynx_mode(lynx_mode),.req(req),.wr(wr),.addr(addr),.wdata(wdata),
    .rdata(rdata),.done(done),.busy(busy),.write_active(write_active),.rejected(rejected),
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_hi_in(e_hi_in),.e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe)
);

// Adapter model: HC164 with QA=A12 .. QH=A19, IODAT low powers the cartridge.
wire iodat=e_ctl_out[3], cs1_n=e_ctl_out[2], cs0_n=e_ctl_out[1], sysctl1=e_ctl_out[0];
reg [7:0] sr=8'hA5;
integer shifts=0, reads=0;
always @(posedge sysctl1) if (lynx_mode) begin sr<={sr[6:0],iodat}; shifts=shifts+1; end
function [7:0] rom(input [18:0] a);
    rom = a[7:0] ^ a[15:8] ^ {5'd0,a[18:16]} ^ 8'h5A;
endfunction
wire selected = lynx_mode && !cs0_n && !iodat && e_ad_oe;
assign e_hi_in = selected ? rom({sr,e_ad_out[10:0]}) : 8'hFF;
always @(negedge cs0_n) if (lynx_mode) reads=reads+1;
always @(negedge cs1_n) if (lynx_mode) $fatal(1,"Lynx /CS1 asserted");
always @(posedge clk) begin
    if (e_hi_oe) $fatal(1,"Lynx data pins driven");
    if (write_active) $fatal(1,"Lynx write_active");
    if (lynx_mode && !cs0_n && iodat) $fatal(1,"read strobe with cartridge power off");
    if (e_ad_out[15:11]!=0) $fatal(1,"Lynx address above A10");
end

task automatic rd(input [15:0] a, input [18:0] linear);
    begin
        wait(!busy); @(negedge clk); req=1; wr=0; addr=a;
        @(negedge clk); req=0;
        wait(done); @(negedge clk);
        if (rejected) $fatal(1,"read %h rejected",a);
        if (rdata!==rom(linear)) $fatal(1,"read %h got %h want %h",a,rdata,rom(linear));
    end
endtask
task automatic wrt(input [15:0] a, input [7:0] d);
    begin
        wait(!busy); @(negedge clk); req=1; wr=1; addr=a; wdata=d;
        @(negedge clk); req=0;
        wait(done); @(negedge clk);
    end
endtask

integer i, prev, t0;
initial begin
    repeat(4) @(negedge clk); reset=0;
    if (e_ctl_out!==4'hF || e_ad_oe || e_p30_oe) $fatal(1,"Lynx pins not idle prev mode");
    @(negedge clk); lynx_mode=1; t0=$time;
    wait(!busy); @(negedge clk); req=1; wr=0; addr=16'h0000;
    @(negedge clk); req=0;
    wait(reads==1);
    if (($time-t0)/10 < POWER) $fatal(1,"read prev power-up wait");
    wait(done); @(negedge clk);
    if (rdata!==rom(0)) $fatal(1,"first read");
    if (shifts!=8) $fatal(1,"first read shifted %0d bits",shifts);

    prev=shifts;
    rd(16'h07FF,19'h007FF);
    if (shifts!=prev) $fatal(1,"reshifted inside a block");
    rd(16'h0800,19'h00800);
    if (shifts!=prev+8) $fatal(1,"block change did not shift 8 bits");
    rd(16'h1FF0,19'h01FF0);
    rd(16'h7FF0,19'h07FF0);

    // Sega reader sequence: init writes, bank select, slot 2 reads.
    wrt(16'hFFFC,8'h00); wrt(16'hFFFD,8'h00); wrt(16'hFFFE,8'h01);
    for (i=0;i<32;i=i+7) begin
        wrt(16'hFFFF,i[7:0]);
        rd(16'h8000,{i[4:0],14'h0000});
        rd(16'hA345,{i[4:0],14'h2345});
        rd(16'hBFFF,{i[4:0],14'h3FFF});
    end
    wrt(16'hFFFF,8'h1F);
    rd(16'hBFFF,19'h7FFFF);

    prev=reads;
    wrt(16'h8000,8'h55);
    if (!rejected) $fatal(1,"data-window write accepted");
    wait(!busy); @(negedge clk); req=1; wr=0; addr=16'hC000;
    @(negedge clk); req=0; wait(done); @(negedge clk);
    if (!rejected || rdata!==8'hFF) $fatal(1,"read above BFFF accepted");
    if (reads!=prev) $fatal(1,"rejected request reached the cartridge");

    // Mode loss releases the pins and forgets the shifted block.
    wait(!busy); @(negedge clk); req=1; wr=0; addr=16'hBFFF;
    @(negedge clk); req=0;
    wait(!cs0_n); @(negedge clk); lynx_mode=0; #1;
    if (e_ad_oe || e_p30_oe || e_ctl_out!==4'hF) $fatal(1,"Lynx pins not released on mode loss");
    repeat(3) @(negedge clk); lynx_mode=1;
    prev=shifts;
    rd(16'h0000,19'h00000);
    if (shifts!=prev+8) $fatal(1,"block kept across a power cycle");

    $display("TB PASS: tb_lynx_cart_bus");
    $finish;
end
initial begin #10000000;$fatal(1,"tb_lynx_cart_bus watchdog");end
endmodule
`default_nettype wire
