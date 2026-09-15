// SOURCES: src/fpga/services/identify/cart_identify_gg.sv src/fpga/core/gg_cart_bus.sv tools/sim/gg_cart_model.sv
`default_nettype none
`timescale 1ns/1ps
module tb_cart_identify_gg;
reg clk=0;
always #5 clk=~clk;
reg reset=1, gg_mode=0, start=0;
wire busy,done,req,wr;
wire [15:0] addr,header_addr,checksum_read;
wire [7:0] wdata,rdata;
wire bus_done,bus_busy;
wire [2:0] result;
wire [127:0] raw_bytes;
wire [19:0] product_code;
wire [3:0] sw_version,region,rom_size_code;
wire [15:0] e_ad_out;
wire e_ad_oe,e_hi_oe,e_p30_out,e_p30_oe;
wire [7:0] e_hi_out,e_hi_in;
wire [3:0] e_ctl_out;
wire [31:0] reads,writes,save_writes,ee_enables,ee_commands;
cart_identify_gg dut (
    .clk(clk),.reset(reset),.gg_mode(gg_mode),.start(start),.busy(busy),.done(done),
    .cart_req(req),.cart_wr(wr),.cart_addr(addr),.cart_wdata(wdata),
    .cart_rdata(rdata),.cart_done(bus_done),.cart_busy(bus_busy),.result(result),
    .raw_bytes(raw_bytes),.header_addr(header_addr),.product_code(product_code),
    .sw_version(sw_version),.region(region),.rom_size_code(rom_size_code),.checksum_read(checksum_read)
);
gg_cart_bus #(.ADDR_SETUP_CYCLES(2),.STROBE_CYCLES(3),.HOLD_CYCLES(2)) bus (
    .clk(clk),.reset(reset),.gg_mode(gg_mode),.req(req),.wr(wr),.addr(addr),.wdata(wdata),
    .rdata(rdata),.done(bus_done),.busy(bus_busy),.write_active(),.rejected(),
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_hi_in(e_hi_in),.e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe)
);
gg_cart_model cart (
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe),.e_hi_in(e_hi_in),
    .rom_read_count(reads),.mapper_write_count(writes),.save_write_count(save_writes),
    .eeprom_enable_count(ee_enables),.eeprom_command_count(ee_commands),.bank2()
);
always @(negedge clk) begin
    if(wr !== 1'b0 || e_ctl_out[2] !== 1'b1 || e_hi_oe)
        $fatal(1,"GG identification attempted a cartridge write");
end
integer i,candidate,base,reads_before;
task fill(input [7:0] value);
    begin
        for(i=0;i<32768;i=i+1) cart.rom[i]=value;
    end
endtask
task load_header(input integer at_addr);
    begin
        cart.rom[at_addr+0]="T";cart.rom[at_addr+1]="M";
        cart.rom[at_addr+2]="R";cart.rom[at_addr+3]=" ";
        cart.rom[at_addr+4]="S";cart.rom[at_addr+5]="E";
        cart.rom[at_addr+6]="G";cart.rom[at_addr+7]="A";
        cart.rom[at_addr+8]=0;cart.rom[at_addr+9]=0;
        // Deliberately not a valid full-ROM checksum. It is diagnostic only.
        cart.rom[at_addr+10]=8'h34;cart.rom[at_addr+11]=8'h12;
        cart.rom[at_addr+12]=8'h45;cart.rom[at_addr+13]=8'h23;
        cart.rom[at_addr+14]=8'h12;cart.rom[at_addr+15]=8'h6E;
    end
endtask
task begin_identify;
    begin
        @(negedge clk);start=1;
        @(negedge clk);start=0;
    end
endtask
task identify(input [2:0] expected_result);
    begin
        reads_before=reads;
        begin_identify();
        wait(done);@(negedge clk);
        if(result !== expected_result || busy)
            $fatal(1,"GG identify result %0d, expected %0d",result,expected_result);
        if(gg_mode && reads!=reads_before+96)
            $fatal(1,"GG must read all three candidate headers twice, got %0d reads",reads-reads_before);
    end
endtask
initial begin
    fill(8'hFF);
    repeat(4) @(negedge clk);reset=0;
    identify(3'd4);
    if(reads || header_addr || raw_bytes) $fatal(1,"no-power GG identify exposed old identity or read bus");
    gg_mode=1;
    repeat(3) @(negedge clk);
    for(candidate=0;candidate<3;candidate=candidate+1) begin
        fill(8'hA5);
        case(candidate)
            0:base=16'h1FF0;
            1:base=16'h3FF0;
            2:base=16'h7FF0;
        endcase
        load_header(base);
        identify(0);
        if(header_addr!==base[15:0] || product_code!==20'h12345 ||
           sw_version!==4'h2 || region!==4'h6 || rom_size_code!==4'hE || checksum_read!==16'h1234)
            $fatal(1,"GG header fields/order wrong at %04x",base);
        for(i=0;i<16;i=i+1)
            if(raw_bytes[i*8 +: 8]!==cart.rom[base+i]) $fatal(1,"GG raw-header byte order");
    end
    // Multiple valid locations choose the first address deterministically.
    load_header(16'h1FF0);
    identify(0);
    if(header_addr!==16'h1FF0) $fatal(1,"GG header-location priority");
    fill(8'hFF);identify(1);
    fill(8'h00);identify(1);
    fill(8'hA5);identify(3);
    if(header_addr!==16'h7FF0 || raw_bytes!=={16{8'hA5}})
        $fatal(1,"GG invalid header did not retain raw diagnostic evidence");

    fill(8'hA5);load_header(16'h1FF0);
    reads_before=reads;
    begin_identify();
    wait(reads==reads_before+16);
    cart.rom[16'h1FF4]="X";
    wait(done);@(negedge clk);
    if(result!==2) $fatal(1,"GG unstable header accepted");

    // A floating first pass followed by changed data is unstable, not absent.
    fill(8'hFF);
    reads_before=reads;
    begin_identify();
    wait(reads==reads_before+16);
    cart.rom[16'h1FF0]=8'h00;
    wait(done);@(negedge clk);
    if(result!==2) $fatal(1,"GG changing open bus reported absent");

    fill(8'hA5);load_header(16'h7FF0);
    begin_identify();
    wait(!e_ctl_out[1]);
    @(negedge clk);gg_mode=0;
    wait(done);@(negedge clk);
    if(result!==4 || raw_bytes || header_addr || product_code)
        $fatal(1,"GG power loss retained identity or hung");
    if(writes || save_writes || ee_enables || ee_commands) $fatal(1,"GG identifier wrote cartridge");
    $display("TB PASS: tb_cart_identify_gg");
    $finish;
end
initial begin #10000000;$fatal(1,"tb_cart_identify_gg watchdog");end
endmodule
`default_nettype wire
