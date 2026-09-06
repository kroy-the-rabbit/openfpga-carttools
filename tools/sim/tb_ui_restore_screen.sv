// SOURCES: src/fpga/ui/ui_restore_screen.sv
`default_nettype none
`timescale 1ns/1ps

module tb_ui_restore_screen;

reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1;
reg active = 1'b0;
reg [3:0] guard_state = 4'd0;
reg [5:0] phase = 6'd0;
reg [4:0] error = 5'd0;
reg [3:0] io_error = 4'hD;
reg [31:0] rom_crc = 32'hA1B2C3D4;
reg [31:0] save_crc = 32'h87654321;
reg [15:0] backup_index = 16'h012A;
reg write_enabled = 1'b0;
wire [9:0] tb_addr;
wire [7:0] tb_char;
wire [1:0] tb_attr;
wire tb_we;
reg [7:0] chars [0:599];
reg [1:0] attrs [0:599];
integer writes = 0;
integer previous_address = 599;
integer before_writes;
integer n;

ui_restore_screen dut (
    .clk(clk), .reset(reset), .active(active), .guard_state(guard_state),
    .phase(phase), .error(error), .io_error(io_error), .rom_crc(rom_crc), .save_crc(save_crc),
    .backup_index(backup_index), .write_enabled(write_enabled),
    .tb_addr(tb_addr), .tb_char(tb_char), .tb_attr(tb_attr), .tb_we(tb_we)
);

always @(posedge clk) begin
    if (tb_we && !reset) begin
        if (tb_addr >= 600)
            $fatal(1, "restore UI wrote outside 30x20 text buffer");
        if (tb_addr != 0 && tb_addr != previous_address + 1)
            $fatal(1, "restore UI skipped or repeated text address");
        if (tb_char < 8'h20 || tb_char > 8'h7E)
            $fatal(1, "restore UI emitted nonprintable or unknown character");
        if (^tb_char === 1'bx || ^tb_attr === 1'bx)
            $fatal(1, "restore UI emitted undefined text or attribute");
        chars[tb_addr] <= tb_char;
        attrs[tb_addr] <= tb_attr;
        previous_address = tb_addr;
        writes = writes + 1;
    end
end

task tick(input integer cycles);
    repeat (cycles) @(negedge clk);
endtask

task settle;
    tick(640);
endtask

task expect_row(input integer row, input [239:0] expected);
    reg [239:0] actual;
    integer col;
    begin
        for (col = 0; col < 30; col = col + 1)
            actual[(29-col)*8 +: 8] = chars[row*30+col];
        if (actual !== expected)
            $fatal(1, "row %0d expected |%0s|, got |%0s|", row, expected, actual);
    end
endtask

task expect_nonblank(input integer row);
    reg [239:0] actual;
    integer col;
    begin
        for (col = 0; col < 30; col = col + 1)
            actual[(29-col)*8 +: 8] = chars[row*30+col];
        if (actual === {30{8'h20}} || ^actual === 1'bx)
            $fatal(1, "row %0d left blank or undefined", row);
    end
endtask

task expect_hidden_evidence;
    begin
        expect_row(12, "                              ");
        expect_row(13, "                              ");
        expect_row(14, "                              ");
        expect_row(15, "                              ");
    end
endtask

initial begin
    tick(3);
    reset = 0;
    settle();
    if (writes != 0) $fatal(1, "inactive overlay changed text buffer");

    // A retained phase from the last run must not appear as current evidence.
    active = 1;
    guard_state = 1;
    phase = 18;
    settle();
    expect_row(0, "CARTRIDGE SAVE RESTORE        ");
    expect_row(2, "FILE: RESTORE.sav             ");
    expect_row(3, "FIRST TARGET: MBC1 8K         ");
    expect_row(4, "LINK'S AWAKENING (NON-DX)     ");
    expect_row(5, "CORE WRITES DISABLED          ");
    expect_row(7, "UNLOCK: SELECT FIVE TIMES     ");
    expect_row(8, "FIVE FULL TAPS WITHIN 10 SEC  ");
    expect_row(10, "                              ");
    expect_hidden_evidence();
    if (attrs[5*30] !== 2'd1)
        $fatal(1, "disabled cartridge writer warning is not prominent");

    guard_state = 2;
    settle();
    expect_row(8, "X: CHECK CART AND BACKUP      ");
    expect_hidden_evidence();

    guard_state = 3;
    settle();
    expect_row(10, "STARTING PREFLIGHT            ");
    expect_hidden_evidence();
    for (n = 1; n <= 11; n = n + 1) begin
        phase = n;
        settle();
        expect_nonblank(10);
        expect_row(7, "PREFLIGHT IN PROGRESS         ");
        expect_hidden_evidence();
    end
    expect_row(10, "COMPARING SD RECOVERY BYTES   ");

    guard_state = 4;
    phase = 12;
    settle();
    expect_row(7, "PREFLIGHT CHECKS PASSED       ");
    expect_row(8, "PRESS AND RELEASE Y           ");
    expect_row(12, "ROM CRC  A1B2C3D4             ");
    expect_row(13, "SAVE CRC 87654321             ");
    expect_row(14, "RECOVERY ID 012A              ");
    expect_row(15, "RECOVERY FILE VERIFIED        ");

    guard_state = 5;
    settle();
    expect_row(8, "PRESS AND RELEASE X           ");
    guard_state = 6;
    settle();
    expect_row(8, "HOLD A FOR 3 SECONDS          ");

    guard_state = 7;
    phase = 13;
    settle();
    expect_row(7, "FINAL CHECKS IN PROGRESS      ");
    expect_row(10, "RECHECKING FULL ROM IDENTITY  ");
    expect_row(18, "B: REQUEST SAFE STOP          ");
    phase = 22;
    settle();
    expect_row(10, "FINAL CART SAFETY SCAN        ");
    phase = 14;
    settle();
    expect_row(10, "RECHECKING ORIGINAL SAVE      ");

    guard_state = 8;
    phase = 18;
    settle();
    expect_row(7, "CHECK COMPLETE                ");
    expect_row(8, "WRITES DISABLED               ");
    expect_row(18, "B: CLOSE  SELECT 5X: RETRY     ");
    expect_row(19, "CHECK BUILD: NO SAVE WRITES   ");
    phase = 17;
    settle();
    expect_row(7, "RESULT NOT VERIFIED           ");
    expect_hidden_evidence();

    write_enabled = 1;
    guard_state = 7;
    for (n = 15; n <= 17; n = n + 1) begin
        phase = n;
        settle();
        expect_row(7, "RESTORE IN PROGRESS           ");
        expect_nonblank(10);
    end
    expect_row(10, "VERIFYING RESTORED SAVE 2/2   ");
    guard_state = 8;
    phase = 18;
    settle();
    expect_row(5, "CARTRIDGE WRITES ENABLED      ");
    expect_row(7, "RESTORE VERIFIED              ");
    expect_row(8, "TWO READBACK CHECKS PASSED    ");
    error = 9;
    settle();
    expect_row(7, "RESULT NOT VERIFIED           ");
    expect_hidden_evidence();

    guard_state = 9;
    phase = 19;
    for (n = 1; n <= 12; n = n + 1) begin
        error = n;
        settle();
        expect_row(7, "RESTORE STOPPED               ");
        expect_row(8, "NO SUCCESS REPORTED           ");
        expect_row(18, "B: CLOSE  SELECT 5X: RETRY     ");
        expect_nonblank(10);
        expect_hidden_evidence();
        if (n == 6) expect_row(11, "SD ERROR: D                   ");
        else expect_row(11, "                              ");
    end
    expect_row(10, "CARTRIDGE WRITER FAILED       ");
    error = 0;
    settle();
    expect_row(10, "CHECK DID NOT COMPLETE        ");

    error = 6;
    io_error = 9;
    settle();
    expect_row(11, "SD ERROR: 9                   ");
    io_error = 10;
    settle();
    expect_row(11, "SD ERROR: A                   ");
    guard_state = 1;
    settle();
    expect_row(11, "                              ");
    guard_state = 3;
    settle();
    expect_row(11, "                              ");

    guard_state = 10;
    phase = 21;
    settle();
    expect_row(7, "STOPPING SAFELY               ");
    expect_row(8, "WAIT FOR CARTRIDGE CLEANUP    ");
    expect_row(10, "WAITING FOR SAFE STOP         ");
    expect_row(11, "                              ");
    expect_hidden_evidence();

    // Start another run with all engine outputs deliberately stale.
    guard_state = 1;
    phase = 18;
    settle();
    expect_row(7, "UNLOCK: SELECT FIVE TIMES     ");
    expect_row(10, "                              ");
    expect_hidden_evidence();

    // A change while painting must result in a complete final snapshot.
    guard_state = 8;
    tick(100);
    guard_state = 2;
    phase = 0;
    error = 0;
    write_enabled = 0;
    settle();
    expect_row(5, "CORE WRITES DISABLED          ");
    expect_row(7, "RESTORE SCREEN UNLOCKED       ");
    expect_hidden_evidence();

    // Repainting also tracks metadata and the build switch alone.
    guard_state = 4;
    phase = 12;
    settle();
    rom_crc = 32'h10203040;
    save_crc = 32'hABCDEF01;
    backup_index = 16'hFFFF;
    settle();
    expect_row(12, "ROM CRC  10203040             ");
    expect_row(13, "SAVE CRC ABCDEF01             ");
    expect_row(14, "RECOVERY ID FFFF              ");

    active = 0;
    tick(3);
    before_writes = writes;
    guard_state = 9;
    settle();
    if (writes != before_writes)
        $fatal(1, "inactive overlay continued painting");
    active = 1;
    settle();
    expect_row(7, "RESTORE STOPPED               ");
    expect_hidden_evidence();

    $display("TB PASS: tb_ui_restore_screen");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "restore UI watchdog expired");
end

endmodule

`default_nettype wire
