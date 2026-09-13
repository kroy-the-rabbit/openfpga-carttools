// SOURCES: tools/sim/restore_engine_model.sv src/fpga/services/restore/restore_engine.sv src/fpga/services/restore/cart_restore_gb.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_save_gb.sv
// Part 2 of the MBC3 restore engine scenarios: post-READY refusals, the
// enabled writer, verification mismatches, cancellation, the last-bank fault
// and the geometry refusals. See tb_restore_engine_mbc3.
`default_nettype none
`timescale 1ns/1ps
module tb_restore_engine_mbc3_commit;
reg clk = 0, clk_io = 0;
always #5 clk = ~clk;
always #7 clk_io = ~clk_io;
wire write_finished;
wire [31:0] write_errors;
restore_engine_case #(.WRITE_ENABLED(1), .MBC3(1), .PART(2)) write_case(
    .clk(clk), .clk_io(clk_io), .finished(write_finished), .errors(write_errors));
initial begin
    wait (write_finished);
    if (write_errors)
        $fatal(1, "MBC3 restore engine commit failures: %0d", write_errors);
    $display("TB PASS: tb_restore_engine_mbc3_commit");
    $finish;
end
initial begin
    #2000000000;
    $fatal(1, "MBC3 restore engine commit watchdog");
end
endmodule
`default_nettype wire
