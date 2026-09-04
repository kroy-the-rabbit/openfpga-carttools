// SOURCES: src/fpga/core/cart_action_guard.sv
//
// tb_cart_action_guard.sv - no file starts from cached cartridge identity

`default_nettype none
`timescale 1ns/1ps

module tb_cart_action_guard;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cancel = 1'b0;
reg request_rom = 1'b0;
reg request_save = 1'b0;
reg rom_available = 1'b0;
reg save_available = 1'b0;
reg validation_complete = 1'b0;
reg validated_rom_available = 1'b0;
reg validated_save_available = 1'b0;

wire scan_start;
wire dump_start;
wire save_mode;
wire pending;

integer errors = 0;

cart_action_guard dut (
    .clk                      ( clk ),
    .reset                    ( reset ),
    .cancel                   ( cancel ),
    .request_rom              ( request_rom ),
    .request_save             ( request_save ),
    .rom_available            ( rom_available ),
    .save_available           ( save_available ),
    .validation_complete      ( validation_complete ),
    .validated_rom_available  ( validated_rom_available ),
    .validated_save_available ( validated_save_available ),
    .scan_start               ( scan_start ),
    .dump_start               ( dump_start ),
    .save_mode                ( save_mode ),
    .pending                  ( pending )
);

task step;
    begin
        @(negedge clk);
    end
endtask

task expect_bit(input [255:0] what, input got, input want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s got %b expected %b", what, got, want);
            errors = errors + 1;
        end
    end
endtask

initial begin
    repeat (2) step();
    reset = 1'b0;
    step();

    // Cached readiness accepts the intent, but must never start a file.
    rom_available = 1'b1;
    request_rom = 1'b1;
    step();
    request_rom = 1'b0;
    expect_bit("ROM request starts scan", scan_start, 1'b1);
    expect_bit("ROM request is pending", pending, 1'b1);
    expect_bit("cached ROM does not start dump", dump_start, 1'b0);

    // The old metadata disappears during the scan. Waiting must not be
    // mistaken for a refusal and must not open a file.
    rom_available = 1'b0;
    repeat (3) begin
        step();
        expect_bit("ROM waits for validation", dump_start, 1'b0);
        expect_bit("ROM remains pending", pending, 1'b1);
    end

    // The newly scanned cartridge, not the cached one, authorizes the dump.
    validated_rom_available = 1'b1;
    validation_complete = 1'b1;
    step();
    validation_complete = 1'b0;
    expect_bit("validated ROM starts dump", dump_start, 1'b1);
    expect_bit("ROM dump is not save mode", save_mode, 1'b0);
    expect_bit("ROM request clears", pending, 1'b0);
    step();
    expect_bit("dump start is a pulse", dump_start, 1'b0);

    // A replacement cartridge that fails validation cancels safely. This is
    // the overwrite regression: no file may be opened under the old name.
    validated_rom_available = 1'b0;
    rom_available = 1'b1;
    request_rom = 1'b1;
    step();
    request_rom = 1'b0;
    expect_bit("replacement scan starts", scan_start, 1'b1);
    expect_bit("replacement does not dump cached cart", dump_start, 1'b0);
    validation_complete = 1'b1;
    step();
    validation_complete = 1'b0;
    expect_bit("invalid replacement does not dump", dump_start, 1'b0);
    expect_bit("invalid replacement clears request", pending, 1'b0);

    // Saves take the same guarded route and preserve the requested kind.
    save_available = 1'b1;
    request_save = 1'b1;
    step();
    request_save = 1'b0;
    expect_bit("save request starts scan", scan_start, 1'b1);
    expect_bit("save request waits", dump_start, 1'b0);
    expect_bit("save mode is latched", save_mode, 1'b1);
    repeat (2) step();
    validated_save_available = 1'b1;
    validation_complete = 1'b1;
    step();
    validation_complete = 1'b0;
    expect_bit("validated save starts dump", dump_start, 1'b1);
    expect_bit("validated save keeps mode", save_mode, 1'b1);
    step();

    // A mode change or explicit rescan abandons an outstanding action.
    request_save = 1'b1;
    step();
    request_save = 1'b0;
    cancel = 1'b1;
    step();
    cancel = 1'b0;
    expect_bit("cancel clears pending action", pending, 1'b0);
    validation_complete = 1'b1;
    step();
    validation_complete = 1'b0;
    expect_bit("cancelled action cannot dump", dump_start, 1'b0);

    // An unavailable action remains inert and does not launch a scan.
    save_available = 1'b0;
    request_save = 1'b1;
    step();
    request_save = 1'b0;
    expect_bit("unavailable save does not scan", scan_start, 1'b0);
    expect_bit("unavailable save does not pend", pending, 1'b0);

    if (errors != 0) begin
        $display("tb_cart_action_guard: %0d checks failed", errors);
        $finish(1);
    end
    $display("TB PASS: tb_cart_action_guard");
    $finish;
end

initial begin
    #20000;
    $display("ERROR: tb_cart_action_guard watchdog expired");
    $finish(1);
end

endmodule

`default_nettype wire
