// SOURCES: src/fpga/core/gg_cart_bus.sv tools/sim/gg_cart_model.sv
`default_nettype none
`timescale 1ns/1ps
module tb_gg_cart_bus;
reg clk=0;
always #5 clk=~clk;
reg reset=1, gg_mode=0, req=0, wr=0;
reg [15:0] addr=0;
reg [7:0] wdata=0;
wire [7:0] rdata;
wire done,busy,write_active,rejected;
wire [15:0] e_ad_out;
wire e_ad_oe,e_hi_oe,e_p30_out,e_p30_oe;
wire [7:0] e_hi_out,e_hi_in;
wire [3:0] e_ctl_out;
wire [31:0] reads,writes,save_writes,ee_enables,ee_commands;
gg_cart_bus #(.ADDR_SETUP_CYCLES(3),.STROBE_CYCLES(5),.HOLD_CYCLES(3)) dut (
    .clk(clk),.reset(reset),.gg_mode(gg_mode),.req(req),.wr(wr),.addr(addr),.wdata(wdata),
    .rdata(rdata),.done(done),.busy(busy),.write_active(write_active),.rejected(rejected),
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_hi_in(e_hi_in),.e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe)
);
gg_cart_model #(.MIN_HOLD_NS(30)) cart (
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe),.e_hi_in(e_hi_in),
    .rom_read_count(reads),.mapper_write_count(writes),.save_write_count(save_writes),
    .eeprom_enable_count(ee_enables),.eeprom_command_count(ee_commands),.bank2()
);
integer cycles=0;
integer rd_start=0,wr_start=0,addr_start=0;
reg in_read=0,in_write=0;
always @(posedge clk) cycles=cycles+1;
always @(posedge e_ad_oe) addr_start=cycles;
always @(negedge e_ctl_out[1]) begin
    if (gg_mode && !reset) begin
        rd_start=cycles; in_read=1;
        if (cycles-addr_start != 3) $fatal(1,"GG read setup width");
    end
end
always @(negedge e_ctl_out[2]) begin
    if (gg_mode && !reset) begin
        wr_start=cycles; in_write=1;
        if (cycles-addr_start != 3) $fatal(1,"GG write setup width");
    end
end
always @(posedge e_ctl_out[1]) begin
    if (in_read && gg_mode && !reset && cycles-rd_start != 5) $fatal(1,"GG read strobe width");
    in_read=0;
end
always @(posedge e_ctl_out[2]) begin
    if (in_write && gg_mode && !reset) begin
        if (cycles-wr_start != 5) $fatal(1,"GG write strobe width");
        if (!write_active || !e_hi_oe || !e_ad_oe || e_ctl_out[0])
            $fatal(1,"GG released write data or mode ownership at /WR rise");
    end
    in_write=0;
end
always @(negedge clk) begin
    if (gg_mode && !reset && e_ctl_out[3] !== 1'b1) $fatal(1,"GG /IOREQ toggled");
    if (e_hi_oe && (!e_ctl_out[1] || !write_active)) $fatal(1,"GG data output during read");
    if (done && (e_ad_oe || e_hi_oe || write_active || e_ctl_out !== 4'hF))
        $fatal(1,"GG done before pins drained");
end
task xfer(input w,input [15:0] a,input [7:0] d,input blocked);
    begin
        @(negedge clk); req=1; wr=w; addr=a; wdata=d;
        @(negedge clk); req=0;
        wait(done); @(negedge clk);
        if (rejected !== blocked) $fatal(1,"GG whitelist result for %04x=%02x: %b",a,d,rejected);
    end
endtask
task read_byte(input [15:0] a,input [7:0] want);
    begin
        xfer(0,a,0,0);
        if (rdata !== want) $fatal(1,"GG read %04x got %02x expected %02x",a,rdata,want);
    end
endtask
integer i,phase;
integer reads_before,writes_before;
initial begin
    for(i=0;i<524288;i=i+1) cart.rom[i] = ((i>>14)*37) ^ i ^ (i>>8) ^ 8'h5A;
    repeat(4) @(negedge clk);
    reset=0;
    #1;
    if(e_ad_oe || e_hi_oe || e_p30_oe || e_ctl_out !== 4'hF) $fatal(1,"unpowered GG bus drives");
    gg_mode=1;
    repeat(3) @(negedge clk);
    read_byte(16'h0000,8'h5A);
    read_byte(16'h0001,8'h5B);
    read_byte(16'h7FFF,cart.rom[16'h7FFF]);
    xfer(1,16'hFFFC,0,0);
    xfer(1,16'hFFFD,0,0);
    xfer(1,16'hFFFE,1,0);
    for(i=0;i<32;i=i+1) begin
        xfer(1,16'hFFFF,i[7:0],0);
        read_byte(16'h8000,cart.rom[i*16384]);
        read_byte(16'hBFFF,cart.rom[i*16384+16383]);
    end
    writes_before=writes;
    // Exhaust every disallowed data value on all four mapper registers.
    for(i=0;i<256;i=i+1) begin
        if(i!=0) xfer(1,16'hFFFC,i[7:0],1);
        if(i!=0) xfer(1,16'hFFFD,i[7:0],1);
        if(i!=1) xfer(1,16'hFFFE,i[7:0],1);
        if(i>31) xfer(1,16'hFFFF,i[7:0],1);
    end
    xfer(1,16'h0000,0,1);
    xfer(1,16'h4000,1,1);
    xfer(1,16'h8000,8'hFF,1);
    xfer(1,16'hA000,8'hA5,1);
    xfer(1,16'hBFFF,8'h5A,1);
    xfer(1,16'hFFFB,0,1);
    xfer(0,16'hC000,0,1);
    xfer(0,16'hFFFF,0,1);
    if(writes!=writes_before || save_writes || ee_enables || ee_commands)
        $fatal(1,"GG write guard allowed save/EEPROM/unlisted mapper command");

    reads_before=reads;
    @(negedge clk); req=1;wr=0;addr=0;
    wait(done);
    repeat(20) @(negedge clk);
    if(reads!=reads_before+1) $fatal(1,"held GG req duplicated transaction");
    req=0;
    repeat(3) @(negedge clk);

    // Actual power loss is distinct from normal cancel: outputs must release
    // immediately in setup, strobe and hold, even during a write.
    for(phase=1;phase<=3;phase=phase+1) begin
        @(negedge clk); req=1;wr=1;addr=16'hFFFF;wdata=3;
        @(negedge clk);req=0;
        wait(dut.state==phase);
        @(negedge clk);gg_mode=0;
        #1;
        if(e_ad_oe || e_hi_oe || e_p30_oe || write_active || e_ctl_out!==4'hF)
            $fatal(1,"GG pins not released on power loss in phase%0d",phase);
        repeat(3) @(negedge clk);
        gg_mode=1;
        repeat(3) @(negedge clk);
    end
    $display("TB PASS: tb_gg_cart_bus");
    $finish;
end
initial begin #10000000;$fatal(1,"tb_gg_cart_bus watchdog");end
endmodule
`default_nettype wire
