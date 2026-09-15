// SOURCES: src/fpga/core/cart_adapter_state.sv
`timescale 1ns/1ps
module tb_cart_adapter_state;
reg clk_host=0, clk_sys=0;
always #7 clk_host=~clk_host;
always #5 clk_sys=~clk_sys;
reg reset_host=1, reset_sys=1;
reg [31:0] report_host=0;
reg valid_host=0;
wire [31:0] report;
wire valid, changed;
wire [3:0] report_seq;
cart_adapter_state dut(.*);
reg pending=0;
reg [31:0] held;
reg held_valid;
reg request_before;
always @(negedge clk_host) begin
    if (reset_host) pending=0;
    else begin
        if (pending && (dut.request !== request_before ||
            dut.payload_hold !== held || dut.payload_valid_hold !== held_valid))
            $fatal(1,"mailbox payload changed before acknowledgement");
        pending = dut.ack_sync[2] != dut.request;
        held = dut.payload_hold;
        held_valid = dut.payload_valid_hold;
        request_before = dut.request;
    end
end
task await_report(input [31:0] expected, input expected_valid);
    integer n;
    begin
        n=0;
        while ((report !== expected || valid !== expected_valid) && n<200) begin
            @(negedge clk_sys); n=n+1;
        end
        if (n==200) $fatal(1,"report did not converge: %08x expected %08x",report,expected);
    end
endtask
integer i;
initial begin
    repeat(4) @(negedge clk_host);
    reset_host=0; reset_sys=0;
    repeat(12) @(negedge clk_sys);
    if(valid || changed || report_seq) $fatal(1,"fabricated APF report after reset");
    @(negedge clk_host); valid_host=1; report_host=32'h01010000;
    await_report(32'h01010000,1);
    @(negedge clk_host); report_host=32'h01010001;
    // Force rapid, distinct complete reports while the first is in flight.
    for(i=2;i<12;i=i+1) begin
        @(negedge clk_host); report_host=32'h01010000 | i;
    end
    await_report(32'h0101000B,1);
    @(negedge clk_host); report_host=0; valid_host=0;
    await_report(0,0);
    repeat(12) @(negedge clk_sys);
    $display("TB PASS: tb_cart_adapter_state");
    $finish;
end
initial begin #100000; $fatal(1,"adapter state timeout"); end
endmodule
