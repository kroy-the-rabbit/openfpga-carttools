// SOURCES: src/fpga/services/dump/cart_dump_gg.sv src/fpga/core/gg_cart_bus.sv tools/sim/gg_cart_model.sv
`default_nettype none
`timescale 1ns/1ps
module tb_cart_dump_gg;
reg clk=0;
always #5 clk=~clk;
reg reset=1,cancel=0,start=0,verify_enable=0;
reg [31:0] size_bytes=32'h40000;
wire busy,done,aborted,verify_checked,verify_ok;
wire [2:0] error;
wire [31:0] total_bytes,first_crc32,verify_crc32;
wire bus_req,bus_wr,bus_done,bus_busy,write_active,rejected;
wire [15:0] bus_addr;
wire [7:0] bus_wdata,bus_rdata,out_data;
wire out_valid;
reg out_ready=0;
wire [15:0] e_ad_out;
wire e_ad_oe,e_hi_oe,e_p30_out,e_p30_oe;
wire [7:0] e_hi_out,e_hi_in;
wire [3:0] e_ctl_out;
wire [31:0] reads,writes,save_writes,ee_enables,ee_commands;
wire [7:0] selected_bank;
cart_dump_gg dut (
    .clk(clk),.reset(reset),.cancel(cancel),.start(start),.size_bytes(size_bytes),.verify_enable(verify_enable),
    .busy(busy),.done(done),.aborted(aborted),.error(error),.total_bytes(total_bytes),
    .bus_req(bus_req),.bus_wr(bus_wr),.bus_addr(bus_addr),.bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata),.bus_done(bus_done),.bus_busy(bus_busy),
    .out_data(out_data),.out_valid(out_valid),.out_ready(out_ready),
    .verify_checked(verify_checked),.verify_ok(verify_ok),.first_crc32(first_crc32),.verify_crc32(verify_crc32)
);
gg_cart_bus #(.ADDR_SETUP_CYCLES(2),.STROBE_CYCLES(2),.HOLD_CYCLES(3)) bus (
    .clk(clk),.reset(reset),.gg_mode(!reset),.req(bus_req),.wr(bus_wr),.addr(bus_addr),.wdata(bus_wdata),
    .rdata(bus_rdata),.done(bus_done),.busy(bus_busy),.write_active(write_active),.rejected(rejected),
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_hi_in(e_hi_in),.e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe)
);
gg_cart_model #(.SLOT1_FIXED(1),.MIN_HOLD_NS(30)) cart (
    .e_ad_out(e_ad_out),.e_ad_oe(e_ad_oe),.e_hi_out(e_hi_out),.e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out),.e_p30_out(e_p30_out),.e_p30_oe(e_p30_oe),.e_hi_in(e_hi_in),
    .rom_read_count(reads),.mapper_write_count(writes),.save_write_count(save_writes),
    .eeprom_enable_count(ee_enables),.eeprom_command_count(ee_commands),.bank2(selected_bank)
);

function [7:0] image_byte(input integer a);
    image_byte = ((a >> 14)*37) ^ (a & 255) ^ ((a >> 8) & 63) ^ 8'h5A;
endfunction
integer emitted=0;
integer clock_count=0;
reg check_stream=0;
reg stalled=0;
reg [7:0] stalled_data;
reg inject_verify_fault=0;
reg injected=0;
reg force_stall=0;
always @(negedge clk) begin
    clock_count=clock_count+1;
    // Repeated short and long backpressure, including around bank boundaries.
    out_ready = !force_stall && clock_count % 11 != 0 && clock_count % 11 != 1 && clock_count % 97 < 80;
end
always @(posedge clk) begin
    if(!reset) begin
        if(stalled && !cancel && (!out_valid || out_data!==stalled_data))
            $fatal(1,"GG stream changed under backpressure");
        stalled=out_valid && !out_ready && !cancel;
        stalled_data=out_data;
        if(out_valid && out_ready) begin
            if(check_stream && out_data!==image_byte(emitted))
                $fatal(1,"GG stream byte%0d bank%0d got%02x expected%02x",emitted,emitted>>14,out_data,image_byte(emitted));
            emitted=emitted+1;
            if(emitted>total_bytes) $fatal(1,"GG emitted verification pass or extra byte");
            // Change a byte already captured, before verification starts.
            if(inject_verify_fault && !injected && emitted==total_bytes) begin
                cart.rom[0]=image_byte(0)^8'h01;
                injected=1;
            end
        end
        if(bus_req && !bus_wr && bus_addr[15:14]!==2'b10)
            $fatal(1,"GG reader used a fixed slot instead of slot2");
        if(bus_done && rejected) $fatal(1,"GG reader requested blocked operation");
        if(done && (bus_busy || write_active || bus_req)) $fatal(1,"GG completed before draining bus");
    end else stalled=0;
end

integer reads_before,writes_before,i,phase,iteration;
reg [31:0] crc_saved;
task begin_dump(input [31:0] length,input verification);
    begin
        @(negedge clk);
        emitted=0;
        size_bytes=length;
        verify_enable=verification;
        injected=0;
        cancel=0;
        start=1;
        @(negedge clk);start=0;
    end
endtask
task complete_dump(input [31:0] length,input verification,input [31:0] expected_crc);
    begin
        reads_before=reads;
        writes_before=writes;
        check_stream=1;
        begin_dump(length,verification);
        wait(done);@(negedge clk);
        if(busy || aborted || error || emitted!=length || total_bytes!==length)
            $fatal(1,"GG dump status/length incorrect emitted%0d length%0d error%0d",emitted,length,error);
        if(first_crc32!==expected_crc) $fatal(1,"GG first CRC got%08x expected%08x",first_crc32,expected_crc);
        if(verify_checked!==verification || verify_ok!==verification)
            $fatal(1,"GG verification flags incorrect");
        if(verification && verify_crc32!==expected_crc) $fatal(1,"GG reread CRC wrong");
        if(reads-reads_before!=length*(verification?2:1)) $fatal(1,"GG skipped/duplicated physical reads");
        if(writes-writes_before!=(4+(length/16384))*(verification?2:1))
            $fatal(1,"GG missing mapper initialization or bank selection");
        crc_saved=first_crc32;
        repeat(5) @(negedge clk);
        if(first_crc32!==crc_saved || verify_checked!==verification || done)
            $fatal(1,"GG result did not persist after done");
    end
endtask

initial begin
    for(i=0;i<524288;i=i+1) cart.rom[i]=image_byte(i);
    repeat(4) @(negedge clk);reset=0;
    repeat(4) @(negedge clk);

    // Unsupported lengths must finish without any cartridge access.
    reads_before=reads;writes_before=writes;
    begin_dump(32'h20000,1);
    wait(done);@(negedge clk);
    if(error!==1 || aborted || emitted || reads!=reads_before || writes!=writes_before || verify_checked)
        $fatal(1,"GG accepted an unsupported length");

    // Expected CRC values were derived using Python zlib.crc32 over the
    // independent image fixture, not the HDL's CRC implementation.
    complete_dump(32'h40000,0,32'h8AD3CE05);
    complete_dump(32'h80000,1,32'hE5572A67);

    // A second-pass-only fault must fail verification without changing the
    // file stream, its CRC, or its length.
    inject_verify_fault=1;
    begin_dump(32'h40000,1);
    wait(done);@(negedge clk);
    if(error!==2 || aborted || !verify_checked || verify_ok || emitted!=32'h40000 ||
       first_crc32!==32'h8AD3CE05 || verify_crc32===first_crc32 || !injected)
        $fatal(1,"GG failed to report an independent reread mismatch");
    cart.rom[0]=image_byte(0);
    inject_verify_fault=0;
    check_stream=0;

    // Normal cancellation in the request-acceptance gap and in every write
    // phase must finish the one mapper transaction and issue nothing after it.
    for(iteration=0;iteration<4;iteration=iteration+1) begin
        begin_dump(32'h40000,1);
        if(iteration==0) wait(bus_req && !bus_busy);
        else wait(bus.state==iteration && write_active);
        @(negedge clk);cancel=1;
        #1;
        if(!busy) $fatal(1,"GG cancelled before mapper write drained");
        wait(done);@(negedge clk);
        if(!aborted || error!==3 || bus_busy || write_active || out_valid || verify_checked)
            $fatal(1,"GG cancellation did not drain write phase%0d",iteration);
        writes_before=writes;reads_before=reads;
        repeat(20) @(negedge clk);
        if(writes!=writes_before || reads!=reads_before) $fatal(1,"GG accessed cartridge after cancellation");
        cancel=0;
    end

    // Cancellation of a ROM read and a held stream byte must also terminate.
    begin_dump(32'h40000,1);
    wait(!e_ctl_out[1]);
    @(negedge clk);cancel=1;
    wait(done);@(negedge clk);
    if(!aborted || error!==3 || bus_busy || out_valid) $fatal(1,"GG read cancellation hung");
    cancel=0;
    force_stall=1;
    begin_dump(32'h40000,1);
    wait(out_valid);
    repeat(10) @(negedge clk);
    cancel=1;
    wait(done);@(negedge clk);
    if(!aborted || error!==3 || out_valid || bus_busy) $fatal(1,"GG stalled-output cancellation hung");
    force_stall=0;cancel=0;

    if(save_writes || ee_enables || ee_commands)
        $fatal(1,"GG ROM capture touched SRAM/EEPROM");
    $display("TB PASS: tb_cart_dump_gg");
    $finish;
end
initial begin #1500000000;$fatal(1,"tb_cart_dump_gg watchdog");end
endmodule
`default_nettype wire
