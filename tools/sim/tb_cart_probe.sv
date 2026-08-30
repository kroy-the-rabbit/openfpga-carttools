// SOURCES: src/fpga/services/identify/cart_probe.sv
//
// tb_cart_probe.sv - probe sequencing
//
// The identifiers are stubbed here; both are tested against real buses
// elsewhere. What this proves is the ordering, and one safety property:
// a GBA probe must never follow a GB probe that found something.
//
`default_nettype none
`timescale 1ns/1ps

module tb_cart_probe;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg start = 1'b0;
reg cart_powered = 1'b1;

wire       busy, done;
wire [1:0] mode;
wire       gb_start, gba_start;
wire [2:0] platform;

reg        gb_done = 1'b0;
reg  [2:0] gb_result = 3'd0;
reg        gba_done = 1'b0;
reg  [2:0] gba_result = 3'd0;

localparam [1:0] MODE_IDLE = 2'b00;
localparam [1:0] MODE_GBA  = 2'b01;
localparam [1:0] MODE_GB   = 2'b10;

localparam [2:0] R_OK = 3'd0, R_NO_CART = 3'd1, R_UNSTABLE = 3'd2,
                 R_NOT_MINE = 3'd3, R_NO_POWER = 3'd4;
localparam [2:0] P_NONE = 3'd0, P_GBA = 3'd1, P_GB = 3'd2,
                 P_UNKNOWN = 3'd3, P_UNSTABLE = 3'd4, P_NO_POWER = 3'd5;

// mode_ready models cart_pins: low for a while after any mode change.
reg [1:0] mode_d;
reg [5:0] settle;
wire mode_ready = (settle == 6'd0);

always @(posedge clk) begin
    if (reset) begin
        mode_d <= MODE_IDLE;
        settle <= 6'd20;
    end else begin
        mode_d <= mode;
        if (mode != mode_d) settle <= 6'd20;
        else if (settle != 0) settle <= settle - 6'd1;
    end
end

cart_probe #(.WAKE_CYCLES(4)) dut (
    .clk (clk), .reset (reset),
    .start (start), .cart_powered (cart_powered),
    .busy (busy), .done (done),
    .mode (mode), .mode_ready (mode_ready),
    .gb_start (gb_start), .gb_done (gb_done), .gb_result (gb_result),
    .gba_start (gba_start), .gba_done (gba_done), .gba_result (gba_result),
    .platform (platform)
);

integer errors = 0;
integer gb_runs, gba_runs;

// Count probes, and catch the unsafe one: GBA mode entered while a Game Boy
// cartridge is in the slot.
always @(posedge clk) begin
    if (gb_start)  gb_runs  = gb_runs + 1;
    if (gba_start) gba_runs = gba_runs + 1;
end

// A probe must not start until the pins are carrying the requested mode.
// Starting early drives the old mode's directions into the new protocol.
always @(posedge clk) begin
    if ((gb_start || gba_start) && !mode_ready)
        $fatal(1, "a probe started with mode_ready low");
    if (gb_start && mode !== MODE_GB)
        $fatal(1, "GB probe started with mode %b", mode);
    if (gba_start && mode !== MODE_GBA)
        $fatal(1, "GBA probe started with mode %b", mode);
end

task expect3(input [255:0] what, input [2:0] got, input [2:0] want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %0d, expected %0d", what, got, want);
            errors = errors + 1;
        end
    end
endtask

task expecti(input [255:0] what, input integer got, input integer want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %0d, expected %0d", what, got, want);
            errors = errors + 1;
        end
    end
endtask

// Run one probe. gb_r is what the GB identifier reports; gba_r is what the
// GBA identifier reports if it is reached at all.
task probe(input [2:0] gb_r, input [2:0] gba_r);
    begin
        gb_runs = 0; gba_runs = 0;
        gb_result = gb_r; gba_result = gba_r;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin : gb_stub
                wait (gb_start == 1'b1);
                repeat (8) @(negedge clk);
                gb_done = 1'b1;
                @(negedge clk);
                gb_done = 1'b0;
            end
            begin : gba_stub
                wait (gba_start == 1'b1);
                repeat (8) @(negedge clk);
                gba_done = 1'b1;
                @(negedge clk);
                gba_done = 1'b0;
            end
            begin : finish
                wait (done == 1'b1);
                @(negedge clk);
                disable gb_stub;
                disable gba_stub;
            end
        join
        gb_done = 1'b0;
        gba_done = 1'b0;
    end
endtask

initial begin
    gb_runs = 0; gba_runs = 0;
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (30) @(negedge clk);

    // ---- 1. A Game Boy cartridge -----------------------------------------
    probe(R_OK, R_OK);
    expect3("gb cart: platform", platform, P_GB);
    expecti("gb cart: gb probes", gb_runs, 1);
    expecti("gb cart: gba probes", gba_runs, 0);

    // ---- 2. Nothing in the slot, so escalate ------------------------------
    probe(R_NO_CART, R_NO_CART);
    expect3("empty: platform", platform, P_NONE);
    expecti("empty: gb probes", gb_runs, 1);
    expecti("empty: gba probes", gba_runs, 1);

    // ---- 3. A GBA cartridge reads as nothing in GB mode -------------------
    probe(R_NO_CART, R_OK);
    expect3("gba cart: platform", platform, P_GBA);
    expecti("gba cart: gba probes", gba_runs, 1);

    // ---- 4. The safety property -------------------------------------------
    //
    // A GB probe that found something must never be followed by a GBA probe,
    // whatever it found. GBA mode drives pins 22-29 as an address output and
    // a Game Boy cartridge drives its data bus there.
    probe(R_NOT_MINE, R_OK);
    expect3("odd cart: platform", platform, P_UNKNOWN);
    expecti("odd cart: gba probes", gba_runs, 0);

    probe(R_UNSTABLE, R_OK);
    expect3("marginal cart: platform", platform, P_UNSTABLE);
    expecti("marginal cart: gba probes", gba_runs, 0);

    // ---- 5. Unpowered slot -------------------------------------------------
    cart_powered = 1'b0;
    probe(R_OK, R_OK);
    expect3("unpowered: platform", platform, P_NO_POWER);
    expecti("unpowered: gb probes", gb_runs, 0);
    expecti("unpowered: gba probes", gba_runs, 0);
    if (mode !== MODE_IDLE) begin
        $display("ERROR: mode %b with the slot unpowered", mode);
        errors = errors + 1;
    end
    cart_powered = 1'b1;

    // ---- 6. The bus is parked idle afterwards ------------------------------
    probe(R_OK, R_OK);
    repeat (4) @(negedge clk);
    if (mode !== MODE_IDLE) begin
        $display("ERROR: mode left at %b after a probe, expected idle", mode);
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("tb_cart_probe: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_cart_probe");
    $finish;
end

initial begin
    #2000000;
    $display("ERROR: tb_cart_probe watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
