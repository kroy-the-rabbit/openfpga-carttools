// SOURCES: src/fpga/services/restore/restore_guard.sv
`default_nettype none
`timescale 1ns/1ps

module tb_restore_guard;

localparam integer DEBOUNCE = 3;
localparam integer UNLOCK = 180;
localparam integer CONFIRM = 200;
localparam integer HOLD = 12;
localparam [4:0] SELECT = 5'b10000;
localparam [4:0] X = 5'b01000;
localparam [4:0] Y = 5'b00100;
localparam [4:0] A = 5'b00010;
localparam [4:0] B = 5'b00001;

reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1;
reg [4:0] keys = 5'b0;
reg cancel = 1'b0;
reg available = 1'b1;
reg preflight_done = 1'b0;
reg preflight_ok = 1'b0;
reg operation_done = 1'b0;
reg operation_failed = 1'b0;
wire preflight_start, write_start, unlocked, active, busy, authorized;
wire [3:0] state;
wire [2:0] unlock_count;
integer preflight_pulses = 0;
integer write_pulses = 0;
integer before_preflight;
integer before_write;
integer i;
reg previous_preflight = 1'b0;
reg previous_write = 1'b0;

restore_guard #(
    .DEBOUNCE_CYCLES(DEBOUNCE), .UNLOCK_CYCLES(UNLOCK),
    .CONFIRM_CYCLES(CONFIRM), .HOLD_CYCLES(HOLD)
) dut (
    .clk(clk), .reset(reset), .key_select(keys[4]), .key_x(keys[3]),
    .key_y(keys[2]), .key_a(keys[1]), .key_b(keys[0]),
    .cancel(cancel), .available(available), .preflight_done(preflight_done),
    .preflight_ok(preflight_ok), .operation_done(operation_done),
    .operation_failed(operation_failed), .preflight_start(preflight_start),
    .write_start(write_start), .unlocked(unlocked), .active(active),
    .busy(busy), .state(state), .unlock_count(unlock_count),
    .authorized(authorized)
);

always @(posedge clk) begin
    if (!reset) begin
        if (write_start && !authorized)
            $fatal(1, "write pulse without authorization");
        if (authorized && state != 4'd7)
            $fatal(1, "authorization outside running transaction");
        if (preflight_start && previous_preflight)
            $fatal(1, "preflight request exceeded one cycle");
        if (write_start && previous_write)
            $fatal(1, "write request exceeded one cycle");
        if (preflight_start) preflight_pulses = preflight_pulses + 1;
        if (write_start) write_pulses = write_pulses + 1;
    end
    previous_preflight <= preflight_start;
    previous_write <= write_start;
end

task tick(input integer count);
    repeat (count) @(negedge clk);
endtask

task settle(input [4:0] value);
    begin
        keys = value;
        tick(DEBOUNCE + 3);
    end
endtask

task tap(input [4:0] value);
    begin
        settle(value);
        settle(5'b0);
    end
endtask

task check_state(input [3:0] expected, input [511:0] message);
    if (state !== expected)
        $fatal(1, "%0s: expected state %0d, got %0d", message, expected, state);
endtask

task initialize;
    begin
        reset = 1'b1;
        keys = 5'b0;
        cancel = 1'b0;
        available = 1'b1;
        preflight_done = 1'b0;
        preflight_ok = 1'b0;
        operation_done = 1'b0;
        operation_failed = 1'b0;
        tick(2);
        reset = 1'b0;
        tick(DEBOUNCE + 3);
        check_state(0, "reset locks");
    end
endtask

task unlock;
    integer n;
    begin
        for (n = 1; n <= 5; n = n + 1) begin
            tap(SELECT);
            if (unlock_count !== n)
                $fatal(1, "Select complete tap %0d counted as %0d", n, unlock_count);
            if (n < 5 && unlocked)
                $fatal(1, "unlocked before five full Select taps");
        end
        check_state(2, "five full taps open restore screen");
        if (!unlocked || busy || !active || authorized)
            $fatal(1, "wrong readiness signals after unlock");
    end
endtask

task begin_preflight;
    begin
        before_preflight = preflight_pulses;
        tap(X);
        check_state(3, "X requests preflight");
        if (preflight_pulses != before_preflight + 1 || !busy || authorized)
            $fatal(1, "preflight pulse/busy/authorization failure");
    end
endtask

task pass_preflight;
    begin
        preflight_ok = 1'b1;
        preflight_done = 1'b1;
        tick(1);
        preflight_done = 1'b0;
        tick(2);
        check_state(4, "successful preflight awaits Y");
    end
endtask

task reach_hold;
    begin
        unlock();
        begin_preflight();
        pass_preflight();
        tap(Y);
        check_state(5, "Y release advances to X");
        tap(X);
        check_state(6, "X release advances to A hold");
    end
endtask

task start_write;
    begin
        before_write = write_pulses;
        settle(A);
        tick(HOLD + 2);
        check_state(7, "continuous A hold starts transaction");
        if (!authorized || !busy || write_pulses != before_write + 1)
            $fatal(1, "write pulse, authorization or ownership missing");
    end
endtask

initial begin
    initialize();
    // A button held at reset must be released before it can count.
    reset = 1'b1;
    keys = SELECT;
    tick(2);
    reset = 1'b0;
    tick(DEBOUNCE + 10);
    check_state(0, "boot-held Select ignored");
    if (unlock_count != 0) $fatal(1, "boot-held Select counted");
    settle(0);

    // Short edges and contact bounce cannot create affirmative taps.
    repeat (8) begin
        keys = SELECT;
        tick(1);
        keys = 0;
        tick(1);
    end
    settle(0);
    check_state(0, "Select bounce ignored");
    settle(SELECT);
    tick(20);
    if (unlock_count != 0) $fatal(1, "held Select counted before release");
    settle(0);
    if (unlock_count != 1) $fatal(1, "held Select did not count exactly once");
    tap(SELECT | X);
    check_state(0, "Select chord relocks");
    if (unlock_count != 0) $fatal(1, "chord kept partial unlock");

    tap(SELECT);
    tick(UNLOCK + 2);
    check_state(0, "partial unlock timeout");
    available = 0;
    repeat (5) tap(SELECT);
    check_state(0, "unavailable core cannot unlock");
    available = 1;
    settle(0);

    // Preflight completion by itself is not authorization, even if stale.
    preflight_done = 1;
    preflight_ok = 1;
    unlock();
    begin_preflight();
    tick(10);
    check_state(3, "stale preflight completion ignored");
    tap(Y);
    tap(X);
    settle(A);
    tick(HOLD + 2);
    if (authorized || write_pulses != 0)
        $fatal(1, "buttons bypassed unfinished preflight");
    settle(0);
    preflight_done = 0;
    tick(1);
    pass_preflight();
    tap(X);
    check_state(0, "wrong confirmation button relocks");

    initialize();
    unlock();
    begin_preflight();
    preflight_done = 1;
    preflight_ok = 0;
    tick(2);
    check_state(9, "failed preflight relocks with failure result");
    if (unlocked || active || busy || authorized)
        $fatal(1, "failure retained authorization or ownership");
    preflight_done = 0;
    tap(A);
    check_state(9, "failed preflight cannot retry with A");

    initialize();
    unlock();
    tick(CONFIRM + 2);
    check_state(0, "ready screen timeout");
    reach_hold();
    tick(CONFIRM + 2);
    check_state(0, "confirmation timeout");

    // Fresh release must separate Y, X and A. A short hold never accumulates.
    reach_hold();
    before_write = write_pulses;
    settle(A);
    tick(2);
    settle(0);
    if (write_pulses != before_write || authorized)
        $fatal(1, "short A hold started transaction");
    settle(A);
    tick(2);
    settle(0);
    if (write_pulses != before_write)
        $fatal(1, "separate A holds accumulated");

    // Cancel has precedence on the exact clock that would finish the hold.
    keys = A;
    while (dut.hold_timer < HOLD - 1) tick(1);
    cancel = 1;
    tick(1);
    cancel = 0;
    tick(1);
    check_state(0, "cancel wins final hold cycle");
    if (write_pulses != before_write || authorized)
        $fatal(1, "cancel on final hold produced write authorization");
    settle(0);

    reach_hold();
    // Completion left over from a previous operation cannot finish a new one.
    operation_done = 1;
    start_write();
    tick(10);
    check_state(7, "stale operation completion ignored");
    operation_done = 0;
    tick(1);
    operation_done = 1;
    tick(1);
    operation_done = 0;
    check_state(8, "fresh operation completion succeeds");
    if (unlocked || active || busy || authorized)
        $fatal(1, "completed transaction did not relock");
    tick(HOLD + 5);
    if (write_pulses != before_write + 1)
        $fatal(1, "held A reused one-use authorization");
    settle(0);

    // Cancellation cannot hand the cartridge bus to another client before
    // the transaction controller has finished its safe stop.
    reach_hold();
    start_write();
    settle(0);
    cancel = 1;
    #1;
    if (authorized) $fatal(1, "cancel failed to revoke immediately");
    tick(1);
    cancel = 0;
    check_state(10, "running cancel waits for safe stop");
    if (!busy || !active || authorized || unlocked)
        $fatal(1, "safe-stop ownership signals incorrect");
    repeat (5) tap(SELECT);
    check_state(10, "cannot unlock during safe stop");
    operation_done = 1;
    tick(1);
    operation_done = 0;
    check_state(9, "safe stop ends as failure");

    initialize();
    reach_hold();
    start_write();
    operation_failed = 1;
    tick(1);
    operation_failed = 0;
    check_state(9, "operation failure is never success");

    // Cancellation must work from every phase before destructive work.
    for (i = 0; i < 5; i = i + 1) begin
        initialize();
        if (i == 0) tap(SELECT);
        else begin
            unlock();
            if (i >= 2) begin_preflight();
            if (i >= 3) pass_preflight();
            if (i >= 4) tap(Y);
        end
        settle(B);
        check_state(0, "B relocks before write");
        if (authorized || busy || unlocked)
            $fatal(1, "B retained authorization");
    end

    $display("TB PASS: tb_restore_guard");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "restore guard watchdog expired");
end

endmodule

`default_nettype wire
