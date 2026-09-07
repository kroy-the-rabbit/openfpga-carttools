// Harness compiled by check_restore_bridge.py, with actual core_top muxes.
`default_nettype none
`timescale 1ns/1ps
module tb_restore_bridge;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0;
reg [1:0] op = 0;
reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
reg bridge_rd = 0, bridge_wr = 0, bridge_endian_little = 0;
wire [31:0] bridge_rd_data, cmd_bridge_rd_data, restore_bridge_rd_data;
wire restore_bridge_rd_hit, restore_io_busy, done, failed;
wire [3:0] err;
wire [108:0] debug_status;
wire [9:0] table_address;
wire [31:0] table_data;
wire r_target_read, r_target_write, r_target_open;
wire [15:0] r_target_id;
wire [31:0] r_target_offset, r_target_bridge, r_target_length, r_target_struct;
wire target_dataslot_read, target_dataslot_write, target_dataslot_openfile;
wire target_dataslot_getfile, target_dataslot_flush, target_dataslot_done;
wire [2:0] target_dataslot_err;
wire [15:0] target_dataslot_id;
wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
wire [31:0] target_buffer_param_struct, target_buffer_resp_struct;
// Idle dumper values are intentionally different from restore's parameters.
wire d_target_write = 0, d_target_open = 0, d_target_get = 0, d_target_flush = 0;
wire [15:0] d_target_id = 20;
wire [31:0] d_target_offset = 32'hCAFE, d_target_bridge = 32'h60000000;
wire [31:0] d_target_length = 32'h8000, d_target_struct = 32'h70000000;
wire [31:0] d_target_response = 32'h80000000, dump_bridge_rd_data = 32'hBAD0BAD0;
wire dump_bridge_rd_hit = 0;
integer completions = 0;
always @(posedge clk) if (done) completions = completions + 1;
// TOP_MUX

restore_file_io #(.TIMEOUT_CYCLES(20000)) files (
    .clk(clk), .reset(reset), .start(start), .op(op), .busy(restore_io_busy),
    .done(done), .failed(failed), .err(err), .debug_status(debug_status),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_endian_little(bridge_endian_little),
    .bridge_rd_data(restore_bridge_rd_data), .bridge_rd_hit(restore_bridge_rd_hit),
    .backup_rd_q(32'h12345678), .datatable_addr(table_address), .datatable_q(table_data),
    .target_dataslot_read(r_target_read), .target_dataslot_write(r_target_write),
    .target_dataslot_openfile(r_target_open), .target_dataslot_id(r_target_id),
    .target_dataslot_slotoffset(r_target_offset), .target_dataslot_bridgeaddr(r_target_bridge),
    .target_dataslot_length(r_target_length), .target_buffer_param_struct(r_target_struct),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err)
);
core_bridge_cmd command (
    .clk(clk), .bridge_endian_little(bridge_endian_little),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_rd_data(cmd_bridge_rd_data),
    .status_boot_done(1'b1), .status_setup_done(1'b0), .status_running(1'b1),
    .target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
    .target_dataslot_openfile(target_dataslot_openfile),
    .target_dataslot_getfile(target_dataslot_getfile), .target_dataslot_flush(target_dataslot_flush),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err),
    .target_dataslot_id(target_dataslot_id), .target_dataslot_slotoffset(target_dataslot_slotoffset),
    .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr), .target_dataslot_length(target_dataslot_length),
    .target_buffer_param_struct(target_buffer_param_struct),
    .target_buffer_resp_struct(target_buffer_resp_struct),
    .datatable_addr(table_address), .datatable_q(table_data),
    .datatable_wren(1'b0), .datatable_data(32'd0)
);
function [31:0] swap(input [31:0] value);
    swap = {value[7:0], value[15:8], value[23:16], value[31:24]};
endfunction
task tick(input integer count);
    repeat(count) @(negedge clk);
endtask
// APF samples the old held response before pulsing bridge_rd. Every burst
// primes once, then consumes that first word on its next bus transaction.
task host_read(input [31:0] address, output [31:0] value);
    begin
        bridge_addr = address;
        tick(4);
        value = bridge_endian_little ? swap(bridge_rd_data) : bridge_rd_data;
        tick(1);
        bridge_rd = 1;
        tick(1);
        bridge_rd = 0;
        tick(1);
    end
endtask
task host_write(input [31:0] address, input [31:0] value);
    begin
        bridge_addr = address;
        bridge_wr_data = bridge_endian_little ? swap(value) : value;
        tick(2);
        bridge_wr = 1;
        tick(1);
        bridge_wr = 0;
        tick(4);
    end
endtask
task register_read(input [31:0] address, output [31:0] value);
    reg [31:0] discarded;
    begin host_read(address, discarded); host_read(address, value); end
endtask
reg [31:0] value, pointer, ignored_word;
reg [7:0] path [0:263];
reg [7:0] expected;
string expected_path;
integer endian_mode, operation, w, b, polls, before_completion;
initial begin
    // Cyclone registers without explicit initializers power up at zero.
    // Model only that startup here, not a runtime reset or a command response.
    #1;
    command.hstate = 0;
    command.tstate = 0;
    command.host_cmd_start = 0;
    command.target_0 = 0;
    tick(8);
    reset = 0;
    for (endian_mode = 0; endian_mode < 2; endian_mode = endian_mode + 1) begin
        bridge_endian_little = endian_mode;
        tick(8);
        for (operation = 0; operation < 3; operation = operation + 1) begin
            op = operation;
            before_completion = completions;
            start = 1;
            tick(1);
            start = 0;
            polls = 0;
            value = 0;
            while (value != 32'h636D0192 && polls < 20) begin
                register_read(32'hF8001000, value);
                polls = polls + 1;
            end
            if (value != 32'h636D0192) $fatal(1, "real command register did not publish open");
            register_read(32'hF8001020, value);
            if (value != 21 + operation) $fatal(1, "open command selected wrong slot");
            register_read(32'hF8001024, pointer);
            if (pointer != 32'h90000000) $fatal(1, "open command selected wrong struct pointer");
            host_write(32'hF8001000, 32'h62750000);
            host_read(pointer, ignored_word);
            for (w = 0; w < 66; w = w + 1) begin
                host_read(pointer + 4*(w+1), value);
                for (b = 0; b < 4; b = b + 1) path[w*4+b] = value[b*8 +: 8];
            end
            expected_path = operation == 0 ? "/Assets/carttools/common/RESTORE.meta" :
                            operation == 1 ? "/Assets/carttools/common/RESTORE.sav" :
                                             "/Assets/carttools/common/PRE0000.sav";
            for (b = 0; b < 264; b = b + 1) begin
                expected = b < expected_path.len() ? expected_path[b] : 8'd0;
                if (path[b] !== expected)
                    $fatal(1, "delivered open structure byte %0d expected %02x got %02x", b, expected, path[b]);
            end
            // This is an injected firmware refusal, not a reproduced parser.
            host_write(32'hF8001000, 32'h6F6B0004);
            polls = 0;
            while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
            if (completions != before_completion + 1 || !failed || err != 4 || restore_io_busy)
                $fatal(1, "real command refusal did not reach file-service result");
            if (debug_status[108:107] != operation || debug_status[102:96] != 66 ||
                debug_status[95:64] != 32'h7373412F)
                $fatal(1, "refusal lost delivered-path evidence");
            tick(4);
        end
    end
    $display("TB PASS: restore bridge command integration");
    $finish;
end
initial begin #2000000; $fatal(1, "restore bridge watchdog"); end
endmodule

// Vendor RAM replacement only. The command RTL itself is unchanged.
module mf_datatable (
    input wire [9:0] address_a, address_b,
    input wire clock_a, clock_b,
    input wire [31:0] data_a, data_b,
    input wire wren_a, wren_b,
    output reg [31:0] q_a, q_b
);
reg [31:0] memory [0:1023];
always @(posedge clock_a) begin
    if (wren_a) memory[address_a] <= data_a;
    q_a <= memory[address_a];
end
always @(posedge clock_b) begin
    if (wren_b) memory[address_b] <= data_b;
    q_b <= memory[address_b];
end
endmodule
`default_nettype wire
