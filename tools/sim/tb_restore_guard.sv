// SOURCES: src/fpga/services/restore/restore_guard.sv
`default_nettype none
`timescale 1ns/1ps

module tb_restore_guard;
localparam integer DEBOUNCE = 3;
localparam integer ENTRY = 18;
localparam integer HOLD = 12;
localparam [4:0] SELECT = 5'b10000, X = 5'b01000, Y = 5'b00100;
localparam [4:0] A = 5'b00010, B = 5'b00001;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;
reg [4:0] keys = 0;
reg cancel = 0, available = 1, transaction_busy = 0;
reg preflight_done = 0, preflight_ok = 0;
reg operation_done = 0, operation_failed = 0;
wire preflight_start, write_start, unlocked, active, busy, authorized;
wire [3:0] state;
wire [1:0] hold_progress;
integer preflight_pulses = 0, write_pulses = 0;
integer before_preflight, before_write;
integer i;
reg previous_preflight = 0, previous_write = 0;

restore_guard #(.DEBOUNCE_CYCLES(DEBOUNCE), .ENTRY_HOLD_CYCLES(ENTRY),
                .HOLD_CYCLES(HOLD)) dut (
    .clk(clk), .reset(reset), .key_select(keys[4]), .key_x(keys[3]),
    .key_y(keys[2]), .key_a(keys[1]), .key_b(keys[0]), .cancel(cancel),
    .available(available), .transaction_busy(transaction_busy),
    .preflight_done(preflight_done), .preflight_ok(preflight_ok),
    .operation_done(operation_done), .operation_failed(operation_failed),
    .preflight_start(preflight_start), .write_start(write_start),
    .unlocked(unlocked), .active(active), .busy(busy), .state(state),
    .hold_progress(hold_progress), .authorized(authorized)
);

always @(posedge clk) begin
    if (!reset) begin
        if (write_start && !authorized) $fatal(1, "write pulse without authorization");
        if (authorized && state != 7) $fatal(1, "authorization outside RUN");
        if (active !== (state != 0)) $fatal(1, "visible restore page lost active exclusion");
        if (preflight_start && previous_preflight) $fatal(1, "preflight pulse exceeded one clock");
        if (write_start && previous_write) $fatal(1, "write pulse exceeded one clock");
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
    begin keys = value; tick(DEBOUNCE + 3); end
endtask
task tap(input [4:0] value);
    begin settle(value); settle(0); end
endtask
task check_state(input [3:0] expected, input [511:0] message);
    if (state !== expected)
        $fatal(1, "%0s: expected state %0d, got %0d", message, expected, state);
endtask
task initialize;
    begin
        reset = 1;
        keys = 0;
        cancel = 0;
        available = 1;
        transaction_busy = 0;
        preflight_done = 0;
        preflight_ok = 0;
        operation_done = 0;
        operation_failed = 0;
        tick(2);
        reset = 0;
        settle(0);
        check_state(0, "reset locks");
    end
endtask
task enter_ready;
    begin
        keys = SELECT;
        tick(DEBOUNCE + ENTRY + 5);
        check_state(2, "Select hold opens latched page");
        if (!unlocked || !active || busy || authorized)
            $fatal(1, "READY ownership signals incorrect");
        settle(0);
    end
endtask
task begin_preflight;
    begin
        before_preflight = preflight_pulses;
        tap(A);
        check_state(3, "fresh A press/release requests preflight");
        if (preflight_pulses != before_preflight + 1 || !busy || authorized)
            $fatal(1, "preflight request or ownership incorrect");
        transaction_busy = 1;
        available = 0;
    end
endtask
task pass_preflight;
    begin
        preflight_ok = 1;
        preflight_done = 1;
        tick(1);
        preflight_done = 0;
        tick(2);
        check_state(6, "preflight success requests a new A hold");
        if (!busy || authorized) $fatal(1, "confirmation lost owned preflight or authorized early");
    end
endtask
task reach_confirm;
    begin enter_ready(); begin_preflight(); pass_preflight(); end
endtask
task start_write;
    begin
        before_write = write_pulses;
        settle(0);
        keys = A;
        tick(DEBOUNCE + HOLD + 5);
        check_state(7, "fresh continuous A hold authorizes one transaction");
        if (!authorized || !busy || write_pulses != before_write + 1)
            $fatal(1, "RUN pulse or authorization incorrect");
    end
endtask
task drain_abort;
    begin
        transaction_busy = 0;
        tick(1);
        check_state(9, "drained cancellation reports failure");
        if (!active || busy || authorized || unlocked)
            $fatal(1, "stopped result retained authorization or lost its page");
    end
endtask

initial begin
    initialize();
    // Aggregate ownership can describe an ordinary scan while restore has
    // never been opened. B and global cancellation must leave that UI alone.
    transaction_busy = 1;
    available = 0;
    before_preflight = preflight_pulses;
    before_write = write_pulses;
    tap(B);
    check_state(0, "B during ordinary scan does not enter restore");
    if (active || busy || authorized) $fatal(1, "locked B claimed ordinary scan ownership");
    cancel = 1;
    tick(3);
    cancel = 0;
    check_state(0, "global cancel during ordinary scan does not enter restore");
    if (active || busy || authorized || preflight_pulses != before_preflight ||
        write_pulses != before_write)
        $fatal(1, "locked cancellation launched or claimed restore work");
    transaction_busy = 0;
    tick(3);
    check_state(0, "ordinary scan drain does not leave a restore failure result");

    initialize();
    reset = 1;
    keys = SELECT;
    tick(2);
    reset = 0;
    tick(DEBOUNCE + ENTRY + 5);
    check_state(0, "boot-held Select requires release");
    settle(0);
    repeat (8) begin
        keys = SELECT; tick(1);
        keys = 0; tick(1);
    end
    settle(0);
    check_state(0, "Select bounce cannot open restore");

    // Show one-third and two-thirds progress only after continuous holding.
    keys = SELECT;
    while (state == 0) tick(1);
    check_state(1, "entry page latched after stable Select");
    tick(ENTRY / 3);
    if (hold_progress != 1) $fatal(1, "entry first-third progress incorrect");
    tick(ENTRY / 3);
    if (hold_progress != 2) $fatal(1, "entry second-third progress incorrect");
    tick(ENTRY / 3);
    check_state(2, "entry threshold reaches READY");
    if (hold_progress != 3) $fatal(1, "entry completion progress missing");

    // Neither the still-held entry key nor a direct switch to A may start work.
    before_preflight = preflight_pulses;
    settle(A);
    settle(0);
    if (preflight_pulses != before_preflight)
        $fatal(1, "entry hold carried into preflight acceptance");
    tap(B);
    check_state(0, "B exits idle READY");

    // An abandoned entry cannot reveal ordinary controls while any key from
    // the interrupted gesture is still held.
    settle(SELECT);
    settle(SELECT | X);
    settle(X);
    tick(ENTRY + 5);
    check_state(1, "abandoned entry retains overlay until full release");
    if (hold_progress != 0) $fatal(1, "abandoned entry retained progress");
    settle(0);
    check_state(0, "released abandoned entry returns to normal controls");

    available = 0;
    keys = SELECT;
    tick(DEBOUNCE + ENTRY + 5);
    check_state(0, "unavailable entry refused");
    settle(0);
    available = 1;
    settle(0);
    enter_ready();

    // READY survives all unrelated keys and an availability change. There
    // is no automatic return to ordinary dump controls on an input mistake.
    before_preflight = preflight_pulses;
    tap(X);
    tap(Y);
    tap(SELECT);
    tap(A | X);
    available = 0;
    tap(A);
    tick(500);
    check_state(2, "READY remains latched after mistakes and waiting");
    if (preflight_pulses != before_preflight) $fatal(1, "invalid READY input requested work");
    available = 1;
    settle(0);
    begin_preflight();
    tap(X);
    tap(Y);
    tap(SELECT);
    check_state(3, "unrelated keys do not abandon working preflight");

    // Holding A while preflight completes never supplies the final hold.
    keys = A;
    tick(DEBOUNCE + 4);
    pass_preflight();
    tick(HOLD + 20);
    check_state(6, "A held during preflight must be released again");
    if (hold_progress != 0 || write_pulses != 0)
        $fatal(1, "preflight held input supplied final authorization");
    settle(0);
    tap(X);
    tap(Y);
    tap(SELECT);
    tap(A | Y);
    check_state(6, "wrong confirmation keys retain page");
    tick(500);
    check_state(6, "confirmation page remains latched");
    before_write = write_pulses;
    settle(A);
    tick(1);
    settle(0);
    settle(A);
    tick(1);
    settle(0);
    if (write_pulses != before_write || hold_progress != 0)
        $fatal(1, "separate short A holds accumulated");

    keys = A;
    while (dut.hold_timer < HOLD - 1) tick(1);
    cancel = 1;
    tick(1);
    cancel = 0;
    check_state(10, "cancel wins final hold and drains preflight owner");
    if (authorized || write_pulses != before_write)
        $fatal(1, "final-cycle cancellation authorized writing");
    operation_done = 1;
    preflight_done = 1;
    tick(2);
    check_state(10, "completion cannot release ongoing aggregate work");
    operation_done = 0;
    preflight_done = 0;
    drain_abort();
    settle(0);

    // The failed result is itself latched, then a new complete Select hold
    // retries without an intervening return to the ordinary dump page.
    available = 1;
    tap(X);
    tap(Y);
    check_state(9, "failure result retains overlay on unrelated input");
    settle(SELECT);
    settle(0);
    check_state(9, "short retry hold returns to its prior result");
    enter_ready();
    begin_preflight();
    pass_preflight();
    start_write();
    operation_failed = 1;
    tick(3);
    check_state(7, "failure flag alone is not cleanup completion");
    operation_failed = 0;
    operation_done = 1;
    transaction_busy = 0;
    tick(1);
    operation_done = 0;
    check_state(8, "successful operation reports DONE");
    if (!active || busy || authorized) $fatal(1, "DONE lost page exclusion or retained authorization");
    tick(HOLD + 10);
    if (write_pulses != before_write + 1) $fatal(1, "held A reused one-shot authorization");
    settle(0);
    tap(B);
    check_state(0, "fresh B dismisses completed result");

    // A stale preflight completion must fall before another one is accepted.
    initialize();
    enter_ready();
    preflight_done = 1;
    preflight_ok = 1;
    begin_preflight();
    tick(10);
    check_state(3, "stale preflight completion ignored");
    preflight_done = 0;
    tick(1);
    pass_preflight();
    operation_done = 1;
    start_write();
    tick(5);
    check_state(7, "stale operation completion ignored");
    operation_done = 0;
    tick(1);
    operation_failed = 1;
    operation_done = 1;
    transaction_busy = 0;
    tick(1);
    operation_done = 0;
    check_state(9, "fresh failed completion reports failure");

    // Cancel every work phase. PREFLIGHT can have only a pending electrical
    // probe, or no dispatched work at all; no artificial done is required.
    for (i = 0; i < 3; i = i + 1) begin
        initialize();
        enter_ready();
        begin_preflight();
        if (i >= 1) pass_preflight();
        if (i >= 2) start_write();
        keys = B;
        #1;
        if (authorized) $fatal(1, "raw B did not revoke immediately");
        tick(1);
        check_state(10, "busy B enters safe stop");
        preflight_done = 1;
        operation_done = 1;
        tick(3);
        check_state(10, "safe stop retains ownership until aggregate drain");
        preflight_done = 0;
        operation_done = 0;
        drain_abort();
        tick(5);
        check_state(9, "held cancel B does not dismiss its own failure result");
        settle(0);
        tap(B);
        check_state(0, "new B can dismiss cancellation result");
    end

    initialize();
    enter_ready();
    begin_preflight();
    transaction_busy = 0;
    cancel = 1;
    tick(1);
    check_state(10, "no-dispatch cancellation still enters stop for one clock");
    cancel = 0;
    tick(1);
    check_state(9, "no-dispatch cancellation does not wait for impossible done");

    initialize();
    enter_ready();
    begin_preflight();
    preflight_done = 1;
    preflight_ok = 0;
    transaction_busy = 0;
    tick(1);
    preflight_done = 0;
    check_state(9, "preflight refusal keeps failure page");
    if (authorized) $fatal(1, "preflight refusal authorized writes");

    $display("TB PASS: tb_restore_guard");
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "restore guard watchdog expired");
end
endmodule
`default_nettype wire
