// SOURCES: tools/sim/restore_engine_model.sv src/fpga/services/restore/restore_engine.sv src/fpga/services/restore/cart_restore_gb.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_save_gb.sv
// TIMEOUT: 900
`default_nettype none
`timescale 1ns/1ps
module tb_restore_engine_max;
reg clk = 0, clk_io = 0;
always #5 clk = ~clk;
always #7 clk_io = ~clk_io;
wire finished;
wire [31:0] errors;
// Same ROM and RAM geometry as the first physical target, with entirely
// synthetic bytes. Both preflight and final verification read all 32 banks.
restore_engine_case #(.WRITE_ENABLED(0), .ROM_CODE(4)) max_case(
    .clk(clk), .clk_io(clk_io), .finished(finished), .errors(errors));
initial begin
    wait (finished);
    if (errors) $fatal(1, "maximum restore geometry failures: %0d", errors);
    $display("TB PASS: tb_restore_engine_max");
    $finish;
end
initial begin
    #500000000;
    $fatal(1, "maximum restore geometry watchdog");
end
endmodule
`default_nettype wire
