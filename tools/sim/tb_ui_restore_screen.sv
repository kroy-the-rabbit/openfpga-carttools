// SOURCES: src/fpga/ui/ui_restore_screen.sv
`default_nettype none
`timescale 1ns/1ps

module tb_ui_restore_screen;

reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1;
reg active = 1'b0;
reg [3:0] guard_state = 4'd0;
reg [1:0] hold_progress = 2'd0;
reg [5:0] phase = 6'd0;
reg [4:0] error = 5'd0;
reg [3:0] io_error = 4'hD;
reg [108:0] io_debug = {2'd0, 4'd11, 7'd64, 32'h7373412F, 32'h74656D2E, 32'd0};
reg [475:0] io_detail = {320'd0, 10'h3FF, 7'd64, 7'd0,
                        {4{7'h7F}}, 1'b0, 7'd0,
                        32'd0, 32'd0, 32'd0};
reg [99:0] io_sequence = {4'd0,32'hFFFFFFFF,64'd0};
task set_trace_path(input string path);
    integer i;
    begin
        for (i = 0; i < 40; i = i + 1)
            io_detail[156+i*8 +: 8] = i < path.len() ? path[i] : 8'd0;
    end
endtask
initial set_trace_path("/Assets/carttools/common/RESTORE.meta");
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
    .hold_progress(hold_progress),
    .phase(phase), .error(error), .io_error(io_error), .io_debug(io_debug), .io_detail(io_detail),
    .io_sequence(io_sequence),
    .rom_crc(rom_crc), .save_crc(save_crc),
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

task expect_progress(input [1:0] value);
    begin
        case (value)
            2'd0: expect_row(9, "HOLD PROGRESS [---] 0/3       ");
            2'd1: expect_row(9, "HOLD PROGRESS [#--] 1/3       ");
            2'd2: expect_row(9, "HOLD PROGRESS [##-] 2/3       ");
            2'd3: expect_row(9, "HOLD PROGRESS [###] 3/3       ");
        endcase
    end
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
        expect_row(6, "                              ");
        expect_row(12, "                              ");
        expect_row(13, "                              ");
        expect_row(14, "                              ");
        expect_row(15, "                              ");
        expect_row(16, "                              ");
        expect_row(3, "TARGETS: MBC1 8K / MBC3 32K   ");
        expect_row(4, "LINKS AWAKENING OR SILVER     ");
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
    expect_row(3, "TARGETS: MBC1 8K / MBC3 32K   ");
    expect_row(4, "LINKS AWAKENING OR SILVER     ");
    expect_row(5, "CORE WRITES DISABLED          ");
    expect_row(7, "HOLD SELECT TO ENTER RESTORE  ");
    expect_row(8, "KEEP SELECT HELD FOR 3 SECONDS");
    expect_progress(0);
    expect_row(18, "B: CANCEL HOLD                ");
    expect_row(10, "                              ");
    expect_hidden_evidence();
    if (attrs[5*30] !== 2'd1)
        $fatal(1, "disabled cartridge writer warning is not prominent");
    // A progress change alone must repaint the registered display snapshot.
    for (n = 1; n <= 3; n = n + 1) begin
        hold_progress = n;
        settle();
        expect_progress(n);
        expect_hidden_evidence();
    end

    guard_state = 2;
    settle();
    expect_row(7, "RESTORE READY                 ");
    expect_row(8, "A: CHECK CART AND BACKUP      ");
    expect_row(9, "                              ");
    expect_row(17, "RESTORE PAGE STAYS OPEN       ");
    expect_row(18, "B: CLOSE RESTORE PAGE         ");
    expect_hidden_evidence();

    guard_state = 3;
    settle();
    expect_row(10, "STARTING PREFLIGHT            ");
    expect_row(9, "                              ");
    expect_row(18, "B: REQUEST SAFE STOP          ");
    expect_hidden_evidence();
    for (n = 1; n <= 11; n = n + 1) begin
        phase = n;
        settle();
        expect_nonblank(10);
        expect_row(7, "PREFLIGHT IN PROGRESS         ");
        expect_hidden_evidence();
    end
    expect_row(10, "COMPARING SD RECOVERY BYTES   ");

    guard_state = 6;
    hold_progress = 0;
    phase = 12;
    settle();
    expect_row(7, "PREFLIGHT CHECKS PASSED       ");
    expect_row(8, "HOLD A FOR 3 SECONDS          ");
    expect_progress(0);
    expect_row(12, "ROM CRC  A1B2C3D4             ");
    expect_row(13, "SAVE CRC 87654321             ");
    expect_row(14, "RECOVERY ID 012A              ");
    expect_row(15, "RECOVERY FILE VERIFIED        ");

    for (n = 1; n <= 3; n = n + 1) begin
        hold_progress = n;
        settle();
        expect_progress(n);
        expect_row(7, "PREFLIGHT CHECKS PASSED       ");
        expect_row(12, "ROM CRC  A1B2C3D4             ");
    end
    // Releasing an incomplete hold resets its bar without leaving restore.
    hold_progress = 0;
    settle();
    expect_progress(0);
    expect_row(8, "HOLD A FOR 3 SECONDS          ");
    expect_row(18, "B: REQUEST SAFE STOP          ");

    // Removed confirmation states must not revive old button instructions
    // or expose a previous operation's evidence.
    for (n = 4; n <= 5; n = n + 1) begin
        guard_state = n;
        settle();
        expect_row(7, "RESTORE LOCKED                ");
        expect_row(8, "HOLD SELECT FOR RESTORE       ");
        expect_row(9, "                              ");
        expect_hidden_evidence();
    end

    guard_state = 7;
    hold_progress = 3;
    phase = 13;
    settle();
    expect_row(7, "FINAL CHECKS IN PROGRESS      ");
    expect_row(9, "                              ");
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
    expect_row(18, "B: CLOSE  HOLD SELECT: RETRY  ");
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
        expect_row(18, "B: CLOSE  HOLD SELECT: RETRY  ");
        expect_nonblank(10);
        if (n == 6) begin
            expect_row(1, "BUILD 0000                    ");
            expect_row(2, "FILE: RESTORE.meta            ");
            expect_row(11, "SD ERROR: D                   ");
            expect_row(12, "SD STAGE: GET INPUT PATH      ");
            expect_row(3, "PATH /Assets/carttools/common/");
            expect_row(4, "NAME RESTORE.meta~~~          ");
            expect_row(6, "SEQ P---- C---- N---- R----   ");
            expect_row(9, "NEW SIZE FFFFFFFF             ");
            expect_row(13, "RX    40 UNIQUE 40 RPT 00     ");
            expect_row(14, "REPEAT -- -- -- --            ");
            expect_row(15, "FLAGS 00000000 SIZE 00000000  ");
            expect_row(16, "NO OBSERVED WORD MISMATCH     ");
        end else begin
            expect_hidden_evidence();
            expect_row(11, "                              ");
        end
    end
    expect_row(10, "CARTRIDGE WRITER FAILED       ");
    error = 0;
    settle();
    expect_row(10, "CHECK DID NOT COMPLETE        ");

    error = 6;
    io_error = 9;
    settle();
    expect_row(11, "SD ERROR: 9                   ");
    io_debug[106:103] = 2;
    io_detail[103:32] = {1'b1, 7'd4, 32'd0, 32'd21};
    settle();
    expect_row(12, "SD STAGE: CHECK SLOT ID       ");
    expect_row(16, "TBL 04 GOT 00000000           ");
    expect_row(17, "EXP 00000015                  ");
    io_debug[106:103] = 3;
    io_detail[103:32] = {1'b1, 7'd5, 32'd60, 32'd64};
    settle();
    expect_row(12, "SD STAGE: CHECK FILE SIZE     ");
    expect_row(16, "TBL 05 GOT 0000003C           ");
    expect_row(17, "EXP 00000040                  ");
    io_detail[103:32] = 0;
    io_error = 10;
    settle();
    expect_row(11, "SD ERROR: A                   ");
    io_error = 14;
    io_debug[106:103] = 12;
    settle();
    expect_row(11, "SD ERROR: E                   ");
    expect_row(12, "SD STAGE: CHECK INPUT PATH    ");
    // Recovery raw words retain the high-byte-first 0192 path convention.
    // Character snapshots stay normalized low first for the UI renderer.
    io_debug = {2'd2, 4'd7, 7'd66, 32'h2F417373, 32'h2E736176, 32'd2};
    io_sequence = {4'hF,32'd0,16'd3,16'd1,16'd0,16'd3};
    io_detail[145:139] = 66;
    set_trace_path("/Assets/carttools/common/PRE012A.sav");
    io_detail[31:0] = 8192;
    settle();
    expect_row(2, "FILE: PRE012A.sav             ");
    expect_row(12, "SD STAGE: SIZE NEW BACKUP     ");
    expect_row(4, "NAME PRE012A.sav~~~~          ");
    expect_row(6, "SEQ P0003 C0001 N0000 R0003   ");
    expect_row(9, "NEW SIZE 00000000             ");
    expect_row(15, "FLAGS 00000002 SIZE 00002000  ");

    // Sequence changes alone repaint. Unseen results are not confused with
    // actual zero, an undocumented full-width value, or observed FFFF.
    io_sequence = {4'hE,32'd37,16'd3,16'd1,16'd0,16'h9999};
    settle();
    expect_row(6, "SEQ P0003 C0001 N0000 R----   ");
    expect_row(9, "NEW SIZE 00000025             ");
    io_sequence = {4'hC,32'hFFFFFFFF,16'd3,16'd9,16'd0,16'd0};
    settle();
    expect_row(6, "SEQ P0003 C0009 N---- R----   ");
    expect_row(9, "NEW SIZE FFFFFFFF             ");
    io_sequence = {4'hF,32'd0,16'hABCD,16'hFFFF,16'd8,16'd9};
    settle();
    expect_row(6, "SEQ PABCD CFFFF N0008 R0009   ");
    io_sequence[99:96] = 0;
    settle();
    expect_row(6, "SEQ P---- C---- N---- R----   ");

    io_sequence = {4'hE,32'd0,16'd3,16'd1,16'd0,16'd0};
    io_debug[106:103] = 13;
    io_debug[102:96] = 64;
    io_detail[145:139] = 64;
    settle();
    expect_row(12, "SD STAGE: GET BACKUP PATH     ");
    expect_row(13, "RX    40 UNIQUE 40 RPT 00     ");
    io_debug[106:103] = 14;
    settle();
    expect_row(12, "SD STAGE: CHECK BACKUP PATH   ");
    io_debug[106:103] = 2;
    settle();
    expect_row(13, "RX    40 UNIQUE 40 RPT 00     ");
    io_debug[106:103] = 7;
    io_debug[102:96] = 66;
    io_detail[145:139] = 66;
    io_sequence = {4'hF,32'd0,16'd3,16'd1,16'd0,16'd3};
    io_detail[103:0] = {1'b1, 7'd5, 32'h6C6D6F6E, 32'h6D6D6F6E, 32'd8192};
    settle();
    expect_row(16, "BAD 05 GOT 6C6D6F6E           ");
    expect_row(17, "EXP 6D6D6F6E                  ");
    io_debug[102:96] = 127;
    io_detail[138:132] = 127;
    io_detail[131:104] = {4{7'h7F}};
    settle();
    expect_row(13, "READS 7F UNIQUE 42 RPT 7F     ");
    expect_row(14, "REPEAT -- -- -- --            ");
    for (n = 1; n <= 14; n = n + 1) begin
        io_debug[106:103] = n;
        settle();
        expect_nonblank(12);
    end
    guard_state = 1;
    hold_progress = 0;
    settle();
    expect_row(11, "                              ");
    expect_row(2, "FILE: RESTORE.sav             ");
    expect_hidden_evidence();
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
    expect_row(7, "HOLD SELECT TO ENTER RESTORE  ");
    expect_progress(0);
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
    expect_row(7, "RESTORE READY                 ");
    expect_row(9, "                              ");
    expect_hidden_evidence();

    // Repainting also tracks metadata and the build switch alone.
    guard_state = 6;
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
