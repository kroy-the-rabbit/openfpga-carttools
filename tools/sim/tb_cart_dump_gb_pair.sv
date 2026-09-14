// SOURCES: src/fpga/services/dump/cart_dump_gb.sv
// Adjacent-read diagnostic against an independent bus transaction schedule.
`default_nettype none
`timescale 1ns/1ps
module tb_cart_dump_gb_pair;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0;
reg [7:0] size_code = 6;
wire busy, done, bus_req, bus_wr, out_valid;
wire [31:0] total_bytes;
wire [15:0] bus_addr;
wire [7:0] bus_wdata, out_data;
reg [7:0] bus_rdata = 0;
reg bus_done = 0, out_ready = 0;
wire [23:0] pair_mismatches, pair_even, pair_odd;
wire [22:0] pair_first_addr;
wire [7:0] pair_first_a, pair_first_b;
cart_dump_gb #(.PAIR_READS(1'b1)) dut (
    .clk(clk), .reset(reset), .start(start), .cart_type(8'h10),
    .rom_size_code(size_code), .busy(busy), .done(done),
    .total_bytes(total_bytes), .bus_req(bus_req), .bus_wr(bus_wr),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata), .bus_done(bus_done),
    .out_data(out_data), .out_valid(out_valid), .out_ready(out_ready),
    .pair_mismatches(pair_mismatches), .pair_even(pair_even),
    .pair_odd(pair_odd), .pair_first_addr(pair_first_addr),
    .pair_first_a(pair_first_a), .pair_first_b(pair_first_b)
);

function [7:0] content(input [22:0] a);
    content = a[7:0] ^ a[15:8] ^ {1'b0, a[22:16]};
endfunction
reg inject = 1;
// Two second-sample faults, one first-sample fault, and one stable wrong byte.
function [7:0] sample(input [22:0] a, input second);
    begin
        sample = content(a);
        if (inject) begin
            if ((a == 23'h00408B || a == 23'h1FC091) && second)
                sample = sample ^ 8'h01;
            if (a == 23'h008042 && !second)
                sample = sample ^ 8'h40;
            if (a == 23'h100203)
                sample = sample ^ 8'h80;
        end
    end
endfunction

integer reads = 0, writes = 0, emitted = 0;
integer cycles = 0, stalls = 0;
reg [7:0] selected_bank = 1;
reg [22:0] expected_addr, actual_addr;
reg [7:0] response;
reg was_stalled = 0;
reg [7:0] stalled_data;

always @(negedge clk) begin
    cycles = cycles + 1;
    out_ready = cycles % 13 >= 4;
end

// Expected address comes from the transaction count, not DUT internals.
// The model latches the response when a request is accepted, then delays done.
always @(posedge clk) begin
    bus_done <= 0;
    if (bus_req && !reset) begin
        if (bus_wr) begin
            writes = writes + 1;
            if (reads % 32768 != 0 || bus_addr !== 16'h2000 ||
                bus_wdata !== writes[7:0])
                $fatal(1, "mapper write %0d at read %0d: %04h=%02h",
                       writes, reads, bus_addr, bus_wdata);
            selected_bank = bus_wdata;
            response = 0;
        end else begin
            expected_addr = reads / 2;
            actual_addr = bus_addr < 16'h4000 ? {9'd0, bus_addr[13:0]} :
                          {1'b0, selected_bank, bus_addr[13:0]};
            if (actual_addr !== expected_addr || bus_addr[15] ||
                bus_addr[14] !== (expected_addr >= 23'h4000))
                $fatal(1, "read %0d: linear %06h bus %04h, expected %06h",
                       reads, actual_addr, bus_addr, expected_addr);
            response = sample(actual_addr, reads[0]);
            reads = reads + 1;
        end
        repeat (3) @(posedge clk);
        bus_rdata <= response;
        bus_done <= 1;
        @(posedge clk);
    end
end

always @(posedge clk) begin
    if (reset) was_stalled <= 0;
    else begin
        if (was_stalled && (!out_valid || out_data !== stalled_data))
            $fatal(1, "stream changed while stalled at byte %0d", emitted);
        was_stalled <= out_valid && !out_ready;
        stalled_data <= out_data;
        if (out_valid && !out_ready) begin
            stalls = stalls + 1;
            if (bus_req) $fatal(1, "new bus request while output stalled");
        end
        if (out_valid && out_ready) begin
            if (reads !== 2 * (emitted + 1))
                $fatal(1, "byte %0d emitted after %0d reads", emitted, reads);
            if (out_data !== sample(emitted, 1'b0))
                $fatal(1, "byte %0d did not retain first read: %02h", emitted, out_data);
            emitted = emitted + 1;
        end
    end
end

task launch(input [7:0] code, input faults);
    begin
        @(negedge clk);
        size_code = code;
        inject = faults;
        reads = 0; writes = 0; emitted = 0; stalls = 0;
        selected_bank = 1;
        start = 1;
        @(negedge clk);
        start = 0;
    end
endtask

task expect_clear;
    begin
        if ({pair_mismatches, pair_even, pair_odd, pair_first_addr,
             pair_first_a, pair_first_b} !== 111'd0)
            $fatal(1, "diagnostics did not clear");
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    launch(6, 1);
    wait(done);
    @(negedge clk);
    if (emitted != 2097152 || reads != 4194304 || writes != 127 ||
        total_bytes !== 32'd2097152 || stalls == 0)
        $fatal(1, "2 MB coverage: emitted=%0d reads=%0d writes=%0d stalls=%0d",
               emitted, reads, writes, stalls);
    if (pair_mismatches !== 24'd3 || pair_even !== 24'd1 || pair_odd !== 24'd2 ||
        pair_first_addr !== 23'h00408B || pair_first_a !== content(23'h00408B) ||
        pair_first_b !== (content(23'h00408B) ^ 8'h01))
        $fatal(1, "wrong mismatch evidence: %0d/%0d/%0d first=%06h %02h/%02h",
               pair_mismatches, pair_even, pair_odd, pair_first_addr,
               pair_first_a, pair_first_b);
    // Later mismatches, idle cycles and even a stable wrong byte must not
    // overwrite or manufacture evidence. Agreement is explicitly limited.
    repeat (20) @(negedge clk);
    if (pair_mismatches !== 24'd3 || pair_first_addr !== 23'h00408B || busy || out_valid)
        $fatal(1, "result not retained after completion");

    // Abort/reset during the second read, before the pair could be emitted.
    launch(0, 0);
    expect_clear;
    wait(reads == 2);
    @(negedge clk);
    reset = 1;
    repeat (12) @(negedge clk);
    if (out_valid || bus_req || busy) $fatal(1, "reader active after reset");
    expect_clear;
    reset = 0;

    // Restart without stale evidence or a late completion from the old pair.
    launch(0, 0);
    wait(done);
    @(negedge clk);
    expect_clear;
    if (reads != 65536 || emitted != 32768 || writes != 1)
        $fatal(1, "restart did not complete exactly one clean ROM");
    $display("TB PASS: tb_cart_dump_gb_pair");
    $finish;
end
initial begin
    #1000000000;
    $fatal(1, "paired reader watchdog: reads=%0d emitted=%0d", reads, emitted);
end
endmodule
`default_nettype wire
