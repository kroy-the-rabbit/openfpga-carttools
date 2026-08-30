// SOURCES: src/fpga/services/dump/apf_file_writer.sv
//
// tb_apf_file_writer.sv - the target command sequence that writes a file
//
// The model can also be told to say nothing at all, which is what the real
// one did: two hardware sessions ended with the screen reading DUMPING, the
// bar full, and nothing ever moving again. There is no cancel in the
// protocol and no documented upper bound on a command, so the only thing a
// core can do is stop waiting.
//
// APF is modelled here, not the SD card. What this proves is the protocol
// shape a dump depends on: that the file is opened before it is written, that
// every chunk carries the right slot offset and length, that the last chunk is
// short rather than padded, that a flush follows the last write, and that a
// failure anywhere is reported rather than swallowed.
//
// The error cases matter more than the happy one. target_dataslot_err is the
// only failure channel that exists and a full card looks exactly like a bad
// slot id, so a dumper that checks once at the end will hand back a truncated
// file that looks finished.
//
`default_nettype none
`timescale 1ns/1ps

module tb_apf_file_writer;

localparam integer CHUNK = 4096;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg start = 1'b0;
reg [31:0] total_bytes = 32'd0;
reg abort = 1'b0;
reg skip_open = 1'b0;

wire        busy, done, failed;
wire [2:0]  err;
wire [15:0] fail_chunk;
wire [1:0]  stall_at;

wire        chunk_req;
wire [15:0] chunk_index;
wire [31:0] chunk_len;
reg         chunk_ack = 1'b0;

wire        t_write, t_openfile, t_flush;
wire [15:0] t_id;
wire [31:0] t_slotoffset, t_bridgeaddr, t_length;
wire [31:0] t_param_struct;

reg         t_done = 1'b0;
reg  [2:0]  t_err  = 3'd0;

apf_file_writer #(
    .SLOT_ID     (16'd20),
    .BUF_BASE    (32'h6000_0000),
    .STRUCT_BASE (32'h7000_0000),
    .CHUNK_BYTES (CHUNK),
    .TIMEOUT_CYCLES (300),
    // Kept on here so the flush path stays tested. It is off in the shipped
    // configuration because APF does not answer it; tb_dump_engine asserts
    // that, since dump_engine takes the default.
    .USE_FLUSH   (1'b1)
) dut (
    .clk (clk), .reset (reset),
    .start (start), .total_bytes (total_bytes), .abort (abort),
    .skip_open (skip_open),
    .busy (busy), .done (done), .failed (failed),
    .err (err), .fail_chunk (fail_chunk), .stall_at (stall_at),
    .chunk_req (chunk_req), .chunk_index (chunk_index),
    .chunk_len (chunk_len), .chunk_ack (chunk_ack),
    .target_dataslot_write      (t_write),
    .target_dataslot_openfile   (t_openfile),
    .target_dataslot_flush      (t_flush),
    .target_dataslot_id         (t_id),
    .target_dataslot_slotoffset (t_slotoffset),
    .target_dataslot_bridgeaddr (t_bridgeaddr),
    .target_dataslot_length     (t_length),
    .target_buffer_param_struct (t_param_struct),
    .target_dataslot_done       (t_done),
    .target_dataslot_err        (t_err)
);

integer errors = 0;

// --- the producer -----------------------------------------------------------
// Answers every chunk request after a delay, the way a cartridge reader would.
always @(posedge clk) begin
    chunk_ack <= 1'b0;
    if (chunk_req && !chunk_ack) begin
        repeat (7) @(posedge clk);
        chunk_ack <= 1'b1;
    end
end

// --- the APF model ----------------------------------------------------------
// core_bridge_cmd drops done when a command starts and leaves it asserted
// after completion until the next command is issued. A writer that samples
// done as a level on entry sees the previous command's and runs away, so the
// model reproduces that exactly rather than pulsing.
integer  n_open = 0, n_write = 0, n_flush = 0;
reg [2:0] next_open_err  = 3'd0;
reg [2:0] next_write_err = 3'd0;
reg [2:0] next_flush_err = 3'd0;
integer  fail_write_at = -1;   // chunk index to fail, -1 for none

// Commands to simply never answer.
reg mute_open  = 1'b0;
reg mute_write = 1'b0;
reg mute_flush = 1'b0;

// recorded for checking
integer  last_off [0:15];
integer  last_len [0:15];

always @(posedge clk) begin
    if (t_openfile && !mute_open) begin
        t_done <= 1'b0;
        n_open  = n_open + 1;
        repeat (5) @(posedge clk);
        t_err  <= next_open_err;
        t_done <= 1'b1;
    end
    if (t_write && !mute_write) begin
        t_done <= 1'b0;
        if (n_write < 16) begin
            last_off[n_write] = t_slotoffset;
            last_len[n_write] = t_length;
        end
        repeat (5) @(posedge clk);
        if (fail_write_at >= 0 && n_write == fail_write_at) t_err <= 3'd2;
        else                                                t_err <= next_write_err;
        n_write = n_write + 1;
        t_done <= 1'b1;
    end
    if (t_flush && !mute_flush) begin
        t_done <= 1'b0;
        n_flush = n_flush + 1;
        repeat (5) @(posedge clk);
        t_err  <= next_flush_err;
        t_done <= 1'b1;
    end
end

task reset_model;
begin
    n_open = 0; n_write = 0; n_flush = 0;
    next_open_err = 3'd0; next_write_err = 3'd0; next_flush_err = 3'd0;
    fail_write_at = -1;
    mute_open = 0; mute_write = 0; mute_flush = 0;
    t_done = 1'b0; t_err = 3'd0;
end
endtask

task run(input [31:0] size);
begin
    @(negedge clk);
    total_bytes = size;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk);
end
endtask

task expect_eq(input integer got, input integer want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // --- the pointer APF is told to fetch the struct from ---
    if (t_param_struct !== 32'h7000_0000) begin
        $display("ERROR: param struct pointer %h, expected 70000000",
                 t_param_struct);
        errors = errors + 1;
    end

    // --- 10000 bytes: two full chunks and a short one ---
    reset_model;
    run(32'd10000);
    expect_eq(failed, 0, "failed after a clean 10000 byte write");
    expect_eq(n_open,  1, "open count");
    expect_eq(n_write, 3, "write count for 10000 bytes at 4096");
    expect_eq(n_flush, 1, "flush count");
    expect_eq(last_off[0], 0,    "chunk 0 slot offset");
    expect_eq(last_len[0], 4096, "chunk 0 length");
    expect_eq(last_off[1], 4096, "chunk 1 slot offset");
    expect_eq(last_len[1], 4096, "chunk 1 length");
    expect_eq(last_off[2], 8192, "chunk 2 slot offset");
    // The tail is written short. Padding it would put 288 bytes of rubbish on
    // the end of every dump whose size is not a multiple of the chunk.
    expect_eq(last_len[2], 1808, "chunk 2 length, the short tail");

    // --- an exact multiple must not emit an extra empty write ---
    reset_model;
    run(32'd8192);
    expect_eq(n_write, 2, "write count for exactly two chunks");
    expect_eq(failed,  0, "failed on an exact multiple");

    // --- result 1 from open means "created and opened", not an error ---
    reset_model;
    next_open_err = 3'd1;
    run(32'd100);
    expect_eq(failed, 0, "failed when open returned 1 (created ok)");
    expect_eq(n_write, 1, "write count after a created-ok open");

    // --- open failing must not write anything at all ---
    reset_model;
    next_open_err = 3'd5;
    run(32'd100);
    expect_eq(failed,  1, "failed flag after open error 5");
    expect_eq(n_write, 0, "writes attempted after a failed open");
    expect_eq(n_flush, 0, "flushes attempted after a failed open");
    expect_eq(err,     5, "reported err after open error 5");

    // --- a write failing mid-dump stops, and says which chunk ---
    reset_model;
    fail_write_at = 1;
    run(32'd10000);
    expect_eq(failed,     1, "failed flag after a mid-dump write error");
    expect_eq(n_write,    2, "writes attempted after failing at chunk 1");
    expect_eq(n_flush,    0, "flush after a failed write");
    expect_eq(fail_chunk, 1, "reported failing chunk index");

    // --- flush failing is a failure, even though every write said ok ---
    // This is the case that would otherwise leave a file that looks complete.
    reset_model;
    next_flush_err = 3'd2;
    run(32'd100);
    expect_eq(failed, 1, "failed flag when only the flush errored");
    expect_eq(err,    2, "reported err from a failed flush");

    // --- the producer stops producing -------------------------------------
    // A cartridge pulled mid dump leaves gb_cart_bus with no way to report
    // it: the transaction is dropped without done. Everything above waits
    // forever unless this state is reachable, so it is checked by holding
    // abort and confirming the writer still finishes.
    reset_model;
    fail_write_at = -1;
    abort = 1'b1;
    run(32'd10000);
    abort = 1'b0;
    expect_eq(failed, 1, "failed flag after an abort");
    expect_eq(err,    7, "reported err after an abort");
    expect_eq(n_flush, 0, "flush after an abort");

    // And the next dump is unaffected: aborting is not sticky across starts.
    reset_model;
    run(32'd8192);
    expect_eq(failed, 0, "failed on the dump after an aborted one");
    expect_eq(n_write, 2, "write count after an aborted dump");

    // --- writing into a file that is already open ---------------------------
    // The route that needs no 0x0192 at all: the slot has a filename from
    // data.json, so 0x0184 has somewhere to go. No open is issued, and the
    // flush still happens because buffered data still has to be committed.
    reset_model;
    skip_open = 1'b1;
    run(32'd10000);
    skip_open = 1'b0;
    expect_eq(failed,  0, "failed writing without an open");
    expect_eq(n_open,  0, "opens issued when skip_open is set");
    expect_eq(n_write, 3, "writes made without an open");
    expect_eq(n_flush, 1, "flushes made without an open");
    expect_eq(last_len[2], 1808, "short tail, written without an open");

    // --- a command APF never answers ----------------------------------------
    // Each of the three, because a hang that reports which one is a bug
    // report and one that does not is a support ticket.
    reset_model;
    mute_open = 1'b1;
    run(32'd10000);
    mute_open = 1'b0;
    expect_eq(failed,   1, "failed flag when the open never answered");
    expect_eq(err,      6, "reported err when the open never answered");
    expect_eq(stall_at, 1, "stall_at when the open never answered");
    expect_eq(n_write,  0, "writes after an open that never answered");

    reset_model;
    mute_write = 1'b1;
    run(32'd10000);
    mute_write = 1'b0;
    expect_eq(failed,   1, "failed flag when a write never answered");
    expect_eq(err,      6, "reported err when a write never answered");
    expect_eq(stall_at, 2, "stall_at when a write never answered");
    expect_eq(n_flush,  0, "flushes after a write that never answered");

    // The flush is the one that actually happened on hardware, twice, and
    // the one where the bytes are already at APF: every write said ok.
    reset_model;
    mute_flush = 1'b1;
    run(32'd10000);
    mute_flush = 1'b0;
    expect_eq(failed,   1, "failed flag when the flush never answered");
    expect_eq(err,      6, "reported err when the flush never answered");
    expect_eq(stall_at, 3, "stall_at when the flush never answered");
    expect_eq(n_write,  3, "writes completed before the flush stalled");

    // And a stall does not poison the next dump.
    reset_model;
    run(32'd8192);
    expect_eq(failed, 0, "failed on the dump after a stalled one");
    expect_eq(err,    0, "reported err on the dump after a stalled one");

    if (errors != 0) begin
        $display("tb_apf_file_writer: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_apf_file_writer");
    $finish;
end

initial begin
    #5000000;
    $display("ERROR: tb_apf_file_writer watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
