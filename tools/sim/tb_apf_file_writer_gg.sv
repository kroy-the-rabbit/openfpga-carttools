// SOURCES: src/fpga/services/dump/apf_file_writer.sv
// GG allocation must distinguish an existing name, an absent name, and an
// unexpected full-width result before requesting even one byte of payload.
`default_nettype none
`timescale 1ns/1ps
module tb_apf_file_writer_gg;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0, abort = 0;
reg probe_only = 0, require_created = 1, skip_open = 0;
reg [31:0] size = 20;
wire busy, done, failed, failed_open, exists;
wire [2:0] err;
wire [1:0] stall;
wire [15:0] fail_chunk, chunk_index;
wire chunk_req;
reg chunk_ack = 0;
wire [31:0] chunk_len;
wire t_open, t_write, t_flush;
wire [15:0] t_id;
wire [31:0] t_offset, t_length, t_addr, t_struct;
reg t_done = 1;
reg [15:0] t_result = 0;
reg [15:0] open_result = 1, write_result = 0;
reg mute = 0;
integer opens = 0, writes = 0, asks = 0, elapsed = 0;
integer pending = 0;
reg was_write = 0, old_req = 0;

apf_file_writer #(.CHUNK_BYTES(16), .TIMEOUT_CYCLES(64)) dut (
    .clk(clk), .reset(reset), .start(start), .total_bytes(size), .abort(abort),
    .skip_open(skip_open), .probe_only(probe_only), .require_created(require_created),
    .file_exists(exists), .busy(busy), .done(done), .failed(failed),
    .failed_open(failed_open), .stall_at(stall), .err(err), .fail_chunk(fail_chunk),
    .chunk_req(chunk_req), .chunk_index(chunk_index), .chunk_len(chunk_len),
    .chunk_ack(chunk_ack), .target_dataslot_write(t_write),
    .target_dataslot_openfile(t_open), .target_dataslot_flush(t_flush),
    .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
    .target_dataslot_bridgeaddr(t_addr), .target_dataslot_length(t_length),
    .target_buffer_param_struct(t_struct), .target_dataslot_done(t_done),
    .target_dataslot_err(t_result[2:0]), .target_dataslot_result(t_result)
);

always @(posedge clk) begin
    chunk_ack <= chunk_req;
    old_req <= chunk_req;
    if (chunk_req && !old_req) asks = asks + 1;
    if (t_flush) $fatal(1, "GG unexpectedly issued flush");
    if (t_open || t_write) begin
        if (pending != 0) $fatal(1, "overlapping APF commands");
        if (t_id != 20) $fatal(1, "wrong output slot");
        if (t_write) begin
            if (t_offset !== writes*16 || t_length !== (writes == 0 ? 16 : 4))
                $fatal(1, "wrong chunk offset or trailing length");
            writes = writes + 1;
        end else opens = opens + 1;
        t_done <= 0;
        was_write <= t_write;
        if (!mute) pending = 5;
    end else if (pending > 0) begin
        pending = pending - 1;
        if (pending == 0) begin
            t_result <= was_write ? write_result : open_result;
            t_done <= 1;
        end
    end
end

task run;
begin
    @(negedge clk);
    opens = 0; writes = 0; asks = 0;
    start = 1;
    @(negedge clk); start = 0;
    wait(done);
    @(negedge clk);
    repeat (3) @(negedge clk);
end
endtask

task refuse_probe(input [15:0] result);
begin
    open_result = result;
    run;
    if (!failed || !failed_open || asks != 0 || writes != 0 || opens != 1)
        $fatal(1, "unexpected full probe result %04x authorized payload", result);
end
endtask

task refuse_create(input [15:0] result);
begin
    open_result = result;
    run;
    if (!failed || !failed_open || asks != 0 || writes != 0 || opens != 1)
        $fatal(1, "existing or unexpected create result %04x wrote payload", result);
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    probe_only = 1;
    open_result = 0;
    run;
    if (failed || !exists || asks != 0 || writes != 0 || opens != 1)
        $fatal(1, "existing probe did not finish without payload");
    open_result = 3;
    run;
    if (failed || exists || asks != 0 || writes != 0 || opens != 1)
        $fatal(1, "absent probe did not finish without payload");
    refuse_probe(1);
    refuse_probe(2);
    refuse_probe(4);
    refuse_probe(5);
    refuse_probe(16'h0008); // low three bits falsely say opened
    refuse_probe(16'h000B); // low three bits falsely say absent
    refuse_probe(16'h0100);
    refuse_probe(16'hFFFF);

    probe_only = 0;
    refuse_create(0);
    refuse_create(2);
    refuse_create(3);
    refuse_create(4);
    refuse_create(5);
    refuse_create(16'h0009); // low three bits falsely say newly created
    refuse_create(16'h0101);
    open_result = 1;
    run;
    if (failed || asks != 2 || writes != 2 || opens != 1)
        $fatal(1, "new GG file did not write exact chunks");

    write_result = 16'h0008; // zero summary must not authorize another chunk
    run;
    if (!failed || failed_open || writes != 1 || fail_chunk != 0)
        $fatal(1, "full-width write error was hidden");
    write_result = 0;
    skip_open = 1;
    run;
    if (!failed || opens != 0 || asks != 0 || writes != 0)
        $fatal(1, "GG allowed unnamed-slot fallback");
    skip_open = 0;

    // Cancel while an open is outstanding: await its response, never emit
    // payload, and do not leave the following command paired with that reply.
    fork
        begin run; end
        begin wait(t_open); @(negedge clk); abort = 1; end
    join
    if (!failed || err != 7 || writes != 0 || asks != 0)
        $fatal(1, "GG open cancellation reached payload");
    abort = 0;
    run;
    if (failed || writes != 2) $fatal(1, "bounded cancel poisoned next file");

    probe_only = 1;
    mute = 1;
    run;
    if (!failed || err != 6 || stall != 1 || writes != 0)
        $fatal(1, "GG timeout was not reported");
    mute = 0;
    t_done = 1; t_result = 3; // a late response cannot authorize a fresh file
    run;
    if (!failed || err != 6 || opens != 0 || writes != 0 || asks != 0)
        $fatal(1, "GG reused a timed-out APF channel");

    $display("TB PASS: tb_apf_file_writer_gg");
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "GG writer test watchdog");
end
endmodule
`default_nettype wire
