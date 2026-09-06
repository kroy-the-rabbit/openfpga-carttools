// SOURCES: tools/sim/restore_engine_model.sv src/fpga/services/restore/restore_engine.sv src/fpga/services/restore/cart_restore_gb.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_save_gb.sv
`default_nettype none
`timescale 1ns/1ps
module tb_restore_engine;
reg clk = 0, clk_io = 0;
always #5 clk = ~clk;
always #7 clk_io = ~clk_io;
wire dry_finished, write_finished;
wire [31:0] dry_errors, write_errors;
restore_engine_case #(.WRITE_ENABLED(0)) dry_case(
    .clk(clk), .clk_io(clk_io), .finished(dry_finished), .errors(dry_errors));
restore_engine_case #(.WRITE_ENABLED(1)) write_case(
    .clk(clk), .clk_io(clk_io), .finished(write_finished), .errors(write_errors));
initial begin
    wait (dry_finished && write_finished);
    if (dry_errors || write_errors)
        $fatal(1, "restore engine failures: dry=%0d enabled=%0d", dry_errors, write_errors);
    $display("TB PASS: tb_restore_engine");
    $finish;
end
initial begin
    #1000000000;
    $fatal(1, "restore engine watchdog");
end
endmodule
`default_nettype wire
