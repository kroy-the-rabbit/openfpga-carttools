// SOURCES: src/fpga/services/restore/restore_engine.sv src/fpga/services/restore/cart_restore_gb.sv src/fpga/services/dump/cart_save_gb.sv src/fpga/services/dump/cart_dump_gb.sv
//
// Target the parent/child dispatch clock boundary directly. The fixture places
// the transaction controller immediately after it has scheduled a real child,
// avoiding a full ROM transfer for each adjacent-clock cancellation. Protocol
// and metadata qualification remain covered by their separate testbenches.
`default_nettype none
`timescale 1ns/1ps

module tb_restore_abort_dispatch;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;
reg cancel = 0;
reg cart_powered = 1;
wire busy;
wire [1:0] want_mode;
wire preflight_done, preflight_ok, done, failed;
wire [5:0] phase;
wire [4:0] error;
wire bus_req, bus_wr;
wire [15:0] bus_addr;
wire [7:0] bus_wdata;
reg bus_done = 0, bus_busy = 0;
reg [2:0] latency = 0;
integer ram_writes = 0;
integer cleanup_writes = 0;
integer offset;
integer kind;
integer n;

restore_engine #(.WRITE_ENABLED(1), .WAKE_CYCLES(4), .TIMEOUT_CYCLES(10000)) dut (
    .clk(clk), .reset(reset), .clk_io(clk), .preflight_start(1'b0),
    .commit_start(1'b0), .cancel(cancel), .reprobe_start(),
    .reprobe_done(1'b0), .reprobe_ok(1'b0),
    .cart_powered(cart_powered), .mode_ready(1'b1), .target_ok(1'b1),
    .cart_type(8'h03), .ram_size_code(8'h02), .rom_size_code(8'h00),
    .cgb_flag(8'h00), .header_checksum(8'h00), .sw_version(8'h00),
    .busy(busy), .want_mode(want_mode), .preflight_done(preflight_done),
    .preflight_ok(preflight_ok), .done(done), .failed(failed),
    .phase(phase), .error(error), .rom_crc(), .save_crc(), .mismatch_offset(),
    .io_start(), .io_op(), .io_done(1'b0), .io_failed(1'b0),
    .input_we(1'b0), .input_kind(2'd0), .input_index(11'd0), .input_data(32'd0),
    .backup_addr(11'd0), .backup_data(), .bus_req(bus_req), .bus_wr(bus_wr),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(8'h55),
    .bus_done(bus_done), .bus_busy(bus_busy)
);

// Transaction-level bus acceptance includes several busy clocks and a full
// done cycle. It does not model pin timing, which gb_cart_bus tests cover.
always @(posedge clk) begin
    bus_done <= 0;
    if (reset) begin
        bus_busy <= 0;
        latency <= 0;
        ram_writes <= 0;
        cleanup_writes <= 0;
    end else if (bus_req && !bus_busy) begin
        bus_busy <= 1;
        latency <= 3;
        if (bus_wr && bus_addr >= 16'hA000 && bus_addr <= 16'hBFFF)
            ram_writes <= ram_writes + 1;
        if (bus_wr && bus_wdata == 0 &&
            (bus_addr == 16'h0000 || bus_addr == 16'h6000 || bus_addr == 16'h4000))
            cleanup_writes <= cleanup_writes + 1;
    end else if (bus_busy) begin
        if (latency == 0) begin
            bus_busy <= 0;
            bus_done <= 1;
        end else latency <= latency - 1'b1;
    end

    if (!reset && cart_powered) begin
        if (phase == 21 && (dut.save_busy || dut.writer_busy))
            $fatal(1, "parent entered CLEAN before dispatched child drained");
        if (dut.save_busy && dut.save_req && !dut.use_save)
            $fatal(1, "dispatched save reader lost its bus mux");
        if (dut.writer_busy && dut.writer_req && phase != 15)
            $fatal(1, "dispatched writer lost its bus mux");
        if ((done || preflight_done) && (bus_busy || dut.save_busy || dut.writer_busy))
            $fatal(1, "parent reported completion before child/bus drain");
    end
end

task tick(input integer cycles);
    repeat (cycles) @(negedge clk);
endtask

task initialize;
    begin
        reset = 1;
        cancel = 0;
        cart_powered = 1;
        tick(3);
        reset = 0;
        tick(2);
    end
endtask

task dispatch(input integer child, input integer timeout_value);
    begin
        // These are exactly the parent registers assigned by begin_save,
        // begin_rom, or the transition into PROGRAM, at their dispatch edge.
        dut.mode_owned = 1;
        dut.type_l = 3;
        dut.ram_l = 2;
        dut.rom_l = 0;
        dut.timer = timeout_value;
        dut.preflight_ok = 1;
        dut.committing = child == 1;
        dut.offset = 0;
        dut.reader_count = 0;
        dut.staged[0] = 32'hA5A5A5A5;
        case (child)
            0: begin dut.phase = 8; dut.save_start = 1; end
            1: begin dut.phase = 15; dut.writer_start = 1; end
            2: begin dut.phase = 7; dut.rom_start = 1; end
            default: $fatal(1, "unknown fixture child");
        endcase
    end
endtask

task expect_failure(input bit committing, input [4:0] expected_error);
    integer clocks;
    begin
        clocks = 0;
        while (!(done || preflight_done) && clocks < 5000) begin
            tick(1);
            clocks = clocks + 1;
        end
        if (clocks == 5000) $fatal(1, "dispatch cancellation failed to drain");
        if (phase != 19 || busy || !failed || preflight_ok || want_mode != 0)
            $fatal(1, "dispatch cancellation failed to terminate safely");
        if (error != expected_error)
            $fatal(1, "wrong abort error: expected %0d, got %0d", expected_error, error);
        if (done != committing || preflight_done == committing)
            $fatal(1, "abort used wrong completion channel for transaction phase");
        if (ram_writes != 0)
            $fatal(1, "dispatch cancellation permitted a save RAM write");
        if (cleanup_writes < 3)
            $fatal(1, "dispatch cancellation skipped parent mapper cleanup");
        tick(2);
        if (done || preflight_done) $fatal(1, "completion was not one pulse");
    end
endtask

initial begin
    for (kind = 0; kind < 3; kind = kind + 1) begin
        for (offset = 0; offset < 6; offset = offset + 1) begin
            initialize();
            dispatch(kind, 10000);
            tick(offset);
            cancel = 1;
            tick(1);
            cancel = 0;
            expect_failure(kind == 1, 5'd10);
        end
        // Expiration on, or immediately after, child acceptance must preserve
        // the same ownership ordering as explicit cancellation.
        for (n = 0; n < 2; n = n + 1) begin
            initialize();
            dispatch(kind, n);
            expect_failure(kind == 1, 5'd11);
        end
    end

    // READY has passed preflight but has not consumed the final hold. Its
    // cancellation reports preflight_done and leaves no running guard to wait
    // for an operation_done acknowledgment.
    initialize();
    dut.phase = 12;
    dut.mode_owned = 1;
    dut.preflight_ok = 1;
    dut.committing = 0;
    dut.timer = 10000;
    cancel = 1;
    tick(1);
    cancel = 0;
    expect_failure(0, 5'd10);

    $display("TB PASS: tb_restore_abort_dispatch");
    $finish;
end

initial begin
    #3000000;
    $fatal(1, "restore abort dispatch watchdog expired");
end
endmodule
`default_nettype wire
