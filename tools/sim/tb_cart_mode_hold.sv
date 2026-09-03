// SOURCES: src/fpga/core/cart_mode_hold.sv
//
// tb_cart_mode_hold.sv - the request must not move while WR# is low
//
// What this protects is a byte in somebody's save file. A mode change tears
// the connector down, and gba_cart_bus cannot make that safe from the inside
// once WR# has fallen: raising WR# and releasing the data together hands the
// cartridge whatever the floating bus settles to. So the request is frozen
// for the length of the beat instead.
//
// The interesting case is not that the request is held. It is that the value
// held is the one that was in force when the beat started, rather than the one
// that arrived a cycle later and caused the problem.

`default_nettype none
`timescale 1ns/1ps

module tb_cart_mode_hold;

reg clk = 1'b0;
always #5 clk = ~clk;

reg  [1:0] req_in = 2'b00;
reg        write_active = 1'b0;
wire [1:0] req_out;

integer errors = 0;

task expect_eq(input [31:0] got, input [31:0] want, input [255:0] what);
begin
    if (got !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
    end
end
endtask

cart_mode_hold dut (
    .clk          ( clk ),
    .req_in       ( req_in ),
    .write_active ( write_active ),
    .req_out      ( req_out )
);

initial begin
    // --- it follows the request, one cycle behind ------------------------
    //
    // Registered rather than muxed, so req_out is always a cycle behind
    // req_in. cart_pins runs a settle counter of tens of cycles behind this
    // and holds mode_ready low across it, so the cycle is not observable
    // downstream. It is asserted here because it is the shape of the module.
    @(negedge clk);
    req_in = 2'b01;
    #1 expect_eq(req_out, 2'b00, "req_out is a cycle behind");
    @(negedge clk);
    #1 expect_eq(req_out, 2'b01, "req arrives on the next edge");

    @(negedge clk);
    req_in = 2'b10;
    @(negedge clk);
    #1 expect_eq(req_out, 2'b10, "a changed req arrives with no write");

    // --- frozen for the length of a beat ---------------------------------
    //
    // GBA mode is in force, a write beat starts, and only then does a
    // requester ask for GB. That is the sequence that corrupts a byte.
    @(negedge clk);
    req_in = 2'b01;
    @(negedge clk);
    #1 expect_eq(req_out, 2'b01, "req in force when the beat starts");
    write_active = 1'b1;

    @(negedge clk);
    req_in = 2'b10;
    #1 expect_eq(req_out, 2'b01, "req changed during a beat");
    repeat (20) begin
        @(negedge clk);
        #1 expect_eq(req_out, 2'b01, "req during a long beat");
    end

    // Parked idle is a mode change too: it is what a requester falls back to
    // when it finishes, and it tears the pins down exactly the same way.
    @(negedge clk);
    req_in = 2'b00;
    #1 expect_eq(req_out, 2'b01, "req dropped to idle during a beat");

    // --- released when the beat is over ----------------------------------
    @(negedge clk);
    write_active = 1'b0;
    #1 expect_eq(req_out, 2'b01, "still held on the cycle the beat ends");
    @(negedge clk);
    #1 expect_eq(req_out, 2'b00, "follows again on the next edge");

    // --- a beat that starts on the same edge the request changes ---------
    //
    // The engine raises write_active because it accepted a request; the value
    // held has to be the one that beat was started under. A register that
    // loads on the edge write_active rises would take the new one instead.
    @(negedge clk);
    req_in = 2'b01;
    @(negedge clk);
    #1 expect_eq(req_out, 2'b01, "settled before the beat");
    write_active = 1'b1;
    req_in = 2'b10;
    @(negedge clk);
    #1 expect_eq(req_out, 2'b01, "the beat's own mode, not the one arriving with it");

    @(negedge clk);
    write_active = 1'b0;
    #1;

    if (errors != 0) begin
        $display("TB FAIL: tb_cart_mode_hold, %0d error(s)", errors);
        $fatal(1);
    end
    $display("TB PASS: tb_cart_mode_hold");
    $finish;
end

endmodule

`default_nettype wire
