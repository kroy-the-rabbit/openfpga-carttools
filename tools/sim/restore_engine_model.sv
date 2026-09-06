// Shared synthetic cartridge and file model for restore transaction tests.
`default_nettype none
`timescale 1ns/1ps

// Full restore transaction against a writable, synthetic MBC1 cartridge.
// The file transport is modeled here; its actual APF bridge and byte order
// are independently exercised by tb_restore_file_io. No corpus bytes enter
// this fixture. Run a clamped-off candidate and enabled writer independently.
module restore_engine_case #(
    parameter bit WRITE_ENABLED = 1'b0,
    parameter integer ROM_CODE = 0
) (
    input wire clk, clk_io,
    output reg finished = 0,
    output integer errors = 0
);
reg reset = 1, preflight_start = 0, commit_start = 0, cancel = 0;
reg cart_powered = 1, mode_ready = 1, target_ok = 1;
reg [7:0] cart_type = 3, ram_size_code = 2, rom_size_code = ROM_CODE, cgb_flag = 0;
reg [7:0] header_checksum = 0, sw_version = 0;
wire busy, preflight_done, preflight_ok, done, failed;
wire [1:0] want_mode;
wire [5:0] phase;
wire [4:0] error;
wire [31:0] rom_crc, save_crc;
wire [12:0] mismatch_offset;
wire reprobe_start;
reg reprobe_done = 0, reprobe_ok = 1;
wire io_start;
wire [1:0] io_op;
reg io_done = 0, io_failed = 0;
reg input_we = 0;
reg [1:0] input_kind = 0;
reg [10:0] input_index = 0, backup_addr = 0;
reg [31:0] input_data = 0;
wire [31:0] backup_data;
wire bus_req, bus_wr;
wire [15:0] bus_addr;
wire [7:0] bus_wdata;
reg [7:0] bus_rdata = 0;
reg bus_done = 0, bus_busy = 0;

localparam integer ROM_BYTES = 32768 << ROM_CODE;
localparam integer TRANSACTION_LIMIT = ROM_BYTES*20 + 2000000;
restore_engine #(.WRITE_ENABLED(WRITE_ENABLED), .WAKE_CYCLES(12),
                 .TIMEOUT_CYCLES(TRANSACTION_LIMIT-100000)) dut (
    .clk(clk), .reset(reset), .clk_io(clk_io),
    .preflight_start(preflight_start), .commit_start(commit_start), .cancel(cancel),
    .reprobe_start(reprobe_start), .reprobe_done(reprobe_done), .reprobe_ok(reprobe_ok),
    .cart_powered(cart_powered), .mode_ready(mode_ready), .target_ok(target_ok),
    .cart_type(cart_type), .ram_size_code(ram_size_code), .rom_size_code(rom_size_code),
    .cgb_flag(cgb_flag), .header_checksum(header_checksum), .sw_version(sw_version),
    .busy(busy), .want_mode(want_mode), .preflight_done(preflight_done),
    .preflight_ok(preflight_ok), .done(done), .failed(failed), .phase(phase),
    .error(error), .rom_crc(rom_crc), .save_crc(save_crc), .mismatch_offset(mismatch_offset),
    .io_start(io_start), .io_op(io_op), .io_done(io_done), .io_failed(io_failed),
    .input_we(input_we), .input_kind(input_kind), .input_index(input_index),
    .input_data(input_data), .backup_addr(backup_addr), .backup_data(backup_data),
    .bus_req(bus_req), .bus_wr(bus_wr), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata), .bus_done(bus_done), .bus_busy(bus_busy)
);

localparam [127:0] SYNTH_TITLE = {"RESTORE TEST",32'd0};
reg [7:0] ram [0:8191];
reg [31:0] metadata [0:15];
reg [31:0] retained_backup [0:2047];
reg [31:0] baseline_rom_crc, baseline_save_crc;
reg ram_enabled = 0, mapper_mode = 0;
reg [4:0] rom_bank = 1;
reg [1:0] bank_upper = 0;
reg accepted_wr;
reg [15:0] accepted_addr;
reg [7:0] accepted_data;
integer bus_delay = 0;
integer ram_writes = 0, rom_reads = 0, verify_reads = 0, original_reads = 0;
integer backup_calls = 0, metadata_calls = 0, save_calls = 0, reprobe_calls = 0;
integer io_error_op = -1, saved_write_count = 0;
reg backup_bad = 0, original_unstable = 0, changed_rom = 0, verify_bad = 0;
reg io_active = 0, retained_complete = 0, commit_permitted = 0;
reg [5:0] last_phase;
integer scenario = 0;

function automatic [31:0] add_crc(input [31:0] value, input [7:0] byte_value);
    reg [31:0] c;
    integer bit_number;
    begin
        c = value ^ byte_value;
        for (bit_number=0; bit_number<8; bit_number=bit_number+1)
            if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
            else c = c >> 1;
        add_crc = c;
    end
endfunction

function automatic [7:0] rom_content(input integer address);
    begin
        if (address >= 'h134 && address < 'h144)
            rom_content = SYNTH_TITLE[127-(address-'h134)*8 -: 8];
        else case(address)
            'h147: rom_content = 3;
            'h148: rom_content = ROM_CODE;
            'h149: rom_content = 2;
            'h14C: rom_content = 0;
            'h14D: rom_content = header_checksum;
            // Include high address bits so all 32 banks of a 512 KiB ROM
            // differ. A bank-select bug must not pass against repeated data.
            default: rom_content = (address*7) ^ (address >> 8) ^ (address >> 16) ^ 8'h39;
        endcase
    end
endfunction
function automatic [7:0] original_content(input integer address);
    original_content = (address*19) ^ (address >> 3) ^ 8'h52;
endfunction
function automatic [7:0] staged_content(input integer address);
    staged_content = (address*13) ^ (address >> 5) ^ 8'hA7;
endfunction
function automatic [31:0] staged_word(input integer word_index);
    staged_word = {staged_content(word_index*4+3), staged_content(word_index*4+2),
                   staged_content(word_index*4+1), staged_content(word_index*4)};
endfunction
function automatic [31:0] original_word(input integer word_index);
    original_word = {original_content(word_index*4+3), original_content(word_index*4+2),
                     original_content(word_index*4+1), original_content(word_index*4)};
endfunction

task automatic check(input integer condition, input [511:0] description);
    begin
        if (!condition) begin
            if (errors < 20)
                $display("ERROR: enabled=%0d scenario=%0d phase=%0d error=%0d: %0s",
                         WRITE_ENABLED, scenario, phase, error, description);
            errors = errors + 1;
        end
    end
endtask

task automatic update_meta_crc;
    integer k;
    reg [31:0] c;
    begin
        c = 32'hFFFFFFFF;
        for (k=0; k<60; k=k+1)
            c = add_crc(c, metadata[k/4] >> (8*(k%4)));
        metadata[15] = ~c;
    end
endtask

// A transaction is accepted with req while idle, then completes after an
// independently modeled latency. Mapper and RAM writes take effect only at
// completion, ensuring cancellation must drain an accepted write.
integer physical_address;
reg [7:0] read_value;
always @(posedge clk) begin
    bus_done <= 0;
    if (reset) begin
        bus_busy <= 0;
        bus_delay <= 0;
        ram_enabled <= 0;
        mapper_mode <= 0;
        rom_bank <= 1;
        bank_upper <= 0;
    end else if (bus_busy) begin
        if (bus_delay != 0) bus_delay <= bus_delay - 1;
        else begin
            if (accepted_wr) begin
                if (accepted_addr < 'h2000) ram_enabled <= accepted_data[3:0] == 'hA;
                else if (accepted_addr < 'h4000)
                    rom_bank <= accepted_data[4:0] == 0 ? 5'd1 : accepted_data[4:0];
                else if (accepted_addr < 'h6000) bank_upper <= accepted_data[1:0];
                else if (accepted_addr < 'h8000) mapper_mode <= accepted_data[0];
                else if (accepted_addr >= 'hA000 && accepted_addr < 'hC000) begin
                    check(ram_enabled && (!mapper_mode || bank_upper == 0),
                          "RAM write requires correct enabled bank zero");
                    ram[accepted_addr-'hA000] <= accepted_data;
                    ram_writes = ram_writes + 1;
                end else check(0, "write outside mapper registers and cartridge RAM");
            end else if (accepted_addr < 'h8000) begin
                physical_address = accepted_addr < 'h4000 ? accepted_addr
                    : (rom_bank * 16384) + (accepted_addr & 'h3FFF);
                check(physical_address < ROM_BYTES, "synthetic ROM read stays within known image");
                read_value = rom_content(physical_address);
                if (changed_rom && physical_address == 'h234) read_value = read_value ^ 8'h01;
                bus_rdata <= read_value;
                rom_reads = rom_reads + 1;
            end else if (accepted_addr >= 'hA000 && accepted_addr < 'hC000) begin
                read_value = ram_enabled ? ram[accepted_addr-'hA000] : 8'hFF;
                if (ram_enabled && phase == 9 && original_unstable && accepted_addr == 'hA1F4)
                    read_value = read_value ^ 8'h01;
                if (ram_enabled && phase == 16 && verify_bad && accepted_addr == 'hA14D)
                    read_value = read_value ^ 8'h01;
                bus_rdata <= read_value;
                if (ram_enabled && (phase == 16 || phase == 17)) verify_reads = verify_reads + 1;
                if (ram_enabled && (phase == 8 || phase == 9)) original_reads = original_reads + 1;
            end else check(0, "read outside cartridge ROM and RAM");
            bus_done <= 1;
            bus_busy <= 0;
        end
    end else if (bus_req) begin
        check(cart_powered && want_mode == 2, "bus request owns the powered GB connector");
        if (bus_wr && bus_addr >= 'hA000 && bus_addr < 'hC000) begin
            check(WRITE_ENABLED && phase == 15 && commit_permitted && preflight_ok
                  && retained_complete && !failed && !cancel,
                  "all authorization and backup gates precede every RAM request");
            check(bus_wdata === staged_content(bus_addr-'hA000),
                  "writer sources the intended staged byte at the intended address");
        end
        accepted_wr <= bus_wr;
        accepted_addr <= bus_addr;
        accepted_data <= bus_wdata;
        bus_busy <= 1;
        bus_delay <= 2;
    end
end

task automatic load_word(input [1:0] kind, input integer index, input [31:0] data_word);
    begin
        @(negedge clk_io);
        input_kind = kind;
        input_index = index;
        input_data = data_word;
        input_we = 1;
        @(negedge clk_io);
        input_we = 0;
    end
endtask

task automatic model_io(input [1:0] operation);
    integer w;
    reg [31:0] read_word;
    begin
        io_active = 1;
        io_failed = 0;
        // Request/response CDC and memory-owner synchronization settle first.
        repeat (8) @(negedge clk_io);
        if (operation == 0) begin
            metadata_calls = metadata_calls + 1;
            for (w=0; w<16; w=w+1) load_word(0,w,metadata[w]);
        end else if (operation == 1) begin
            save_calls = save_calls + 1;
            for (w=0; w<2048; w=w+1) load_word(1,w,staged_word(w));
        end else begin
            backup_calls = backup_calls + 1;
            // Capture the original through the actual synchronous read port.
            for (w=0; w<2048; w=w+1) begin
                @(negedge clk_io);
                backup_addr = w;
                repeat (2) @(negedge clk_io);
                read_word = backup_data;
                check(read_word === original_word(w), "recovery file retains every original byte");
                retained_backup[w] = read_word;
            end
            retained_complete = 1;
            for (w=0; w<2048; w=w+1) begin
                read_word = retained_backup[w];
                if (backup_bad && w == 100) read_word = read_word ^ 32'h01000000;
                load_word(2,w,read_word);
            end
        end
        repeat (5) @(negedge clk);
        io_failed = io_error_op == operation;
        io_done = 1;
        @(negedge clk);
        io_done = 0;
        io_active = 0;
    end
endtask
always @(posedge clk) begin
    if (!reset && io_start) model_io(io_op);
end

always @(posedge clk) begin
    if (!reset && reprobe_start) begin
        check(want_mode == 0, "final reprobe releases restore connector ownership");
        reprobe_calls = reprobe_calls + 1;
        repeat (5) @(negedge clk);
        reprobe_done = 1;
        @(negedge clk);
        reprobe_done = 0;
    end
end

task automatic fresh(input integer number);
    integer k;
    begin
        @(negedge clk);
        reset = 1;
        preflight_start = 0; commit_start = 0; cancel = 0;
        cart_powered = 1; mode_ready = 1; target_ok = 1;
        cart_type = 3; ram_size_code = 2; rom_size_code = ROM_CODE; cgb_flag = 0;
        reprobe_ok = 1; reprobe_done = 0;
        io_failed = 0; io_done = 0; input_we = 0;
        ram_writes = 0; rom_reads = 0; verify_reads = 0; original_reads = 0;
        backup_calls = 0; metadata_calls = 0; save_calls = 0; reprobe_calls = 0;
        io_error_op = -1; backup_bad = 0; original_unstable = 0;
        changed_rom = 0; verify_bad = 0; retained_complete = 0; commit_permitted = 0;
        scenario = number;
        $display("restore engine enabled=%0d ROM=%0d scenario=%0d", WRITE_ENABLED, ROM_BYTES, number);
        $fflush();
        for (k=0; k<8192; k=k+1) ram[k] = original_content(k);
        for (k=0; k<16; k=k+1) metadata[k] = 0;
        metadata[0] = 32'h53525443;
        metadata[1] = 1;
        metadata[2] = 8192;
        metadata[3] = baseline_save_crc;
        metadata[4] = ROM_BYTES;
        metadata[5] = baseline_rom_crc;
        metadata[6] = (ROM_CODE << 16) | 32'h00000203;
        metadata[7] = header_checksum;
        for (k=0; k<16; k=k+1) metadata[8+k/4][8*(k%4) +: 8] = rom_content('h134+k);
        update_meta_crc();
        repeat (6) @(negedge clk);
        reset = 0;
        repeat (6) @(negedge clk);
    end
endtask

task automatic launch_preflight;
    begin
        @(negedge clk); preflight_start = 1;
        @(negedge clk); preflight_start = 0;
    end
endtask
task automatic wait_preflight;
    integer cycles;
    begin
        cycles = 0;
        while (!preflight_done && cycles < TRANSACTION_LIMIT) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(preflight_done, "preflight reaches an explicit result");
        check(ram_writes == 0, "preflight never changes cartridge save RAM");
        @(negedge clk);
    end
endtask
task automatic preflight;
    begin
        launch_preflight();
        wait_preflight();
    end
endtask
task automatic launch_commit;
    begin
        check(preflight_ok && phase == 12, "commit starts from verified READY only");
        commit_permitted = 1;
        @(negedge clk); commit_start = 1;
        @(negedge clk); commit_start = 0;
    end
endtask
task automatic wait_complete;
    integer cycles;
    begin
        cycles = 0;
        while (!done && cycles < TRANSACTION_LIMIT) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(done, "commit reaches an explicit result");
        check(!busy && want_mode == 0 && !ram_enabled && !mapper_mode,
              "completed operation releases the bus and disables RAM");
        @(negedge clk);
    end
endtask
task automatic expect_preflight_failure(input integer expected_error);
    begin
        preflight();
        check(failed && !preflight_ok && error == expected_error,
              "preflight rejects the injected fault");
        check(!busy && want_mode == 0 && !ram_enabled && !mapper_mode,
              "preflight failure cleans up mapper and connector");
    end
endtask
task automatic check_original;
    integer k;
    begin
        for (k=0; k<8192; k=k+1)
            check(ram[k] === original_content(k), "original save remains unchanged");
    end
endtask

integer k;
reg [31:0] c;
initial begin
    header_checksum = 0;
    for (k='h134; k<'h14D; k=k+1)
        header_checksum = header_checksum - rom_content(k) - 1;
    c = 32'hFFFFFFFF;
    for (k=0; k<ROM_BYTES; k=k+1) c = add_crc(c,rom_content(k));
    baseline_rom_crc = ~c;
    c = 32'hFFFFFFFF;
    for (k=0; k<8192; k=k+1) c = add_crc(c,staged_content(k));
    baseline_save_crc = ~c;

    // Both real parameter settings traverse the entire preflight and final
    // identity check. An early commit pulse has no authority.
    fresh(1);
    launch_preflight();
    wait (phase == 3 || phase == 19);
    if (phase == 19) $fatal(1, "initial metadata failed: enabled=%0d error=%0d", WRITE_ENABLED, error);
    @(negedge clk); commit_start = 1;
    repeat (5) @(negedge clk);
    commit_start = 0;
    wait_preflight();
    check(preflight_ok && !failed && phase == 12, "clean preflight passes");
    check(rom_crc == baseline_rom_crc && save_crc == baseline_save_crc,
          "reported CRCs match independent fixture expectations");
    check(rom_reads == ROM_BYTES, "preflight reads every ROM byte across all banks");
    check(metadata_calls == 1 && save_calls == 1 && backup_calls == 1,
          "preflight loads the single package and retains one recovery file");
    check(original_reads >= 16384, "two complete original-save passes precede backup");
    // Spoof incoming packets after ownership has left the loading phases.
    load_word(0,0,32'd0);
    load_word(1,0,32'd0);
    load_word(2,0,32'd0);
    check(dut.meta[0] == 32'h53525443 && dut.staged[0] == staged_word(0)
          && dut.readback[0] == original_word(0), "late inputs cannot change sealed buffers");
    if (preflight_ok) begin
        launch_commit();
        wait_complete();
        check(!failed && error == 0 && reprobe_calls == 1, "full restore completes after fresh reprobe");
        check(rom_reads == ROM_BYTES*2, "final ROM verification rereads every bank");
        check(ram_writes == (WRITE_ENABLED ? 8192 : 0), "compile-time write clamp controls physical writes");
        for (k=0; k<8192; k=k+1)
            check(ram[k] === (WRITE_ENABLED ? staged_content(k) : original_content(k)),
                  "completed save has exactly the expected bytes");
        if (WRITE_ENABLED) check(verify_reads >= 16384, "two complete post-write verification passes");
        for (k=0; k<2048; k=k+1)
            check(retained_backup[k] === original_word(k), "successful restore preserves recovery backup");
    end

    if (WRITE_ENABLED) begin
        fresh(2);
        metadata[15] = metadata[15] ^ 1;
        expect_preflight_failure(1);
        check_original();
        fresh(3);
        metadata[6] = metadata[6] ^ 32'h100;
        update_meta_crc();
        expect_preflight_failure(1);
        fresh(4);
        metadata[8] = metadata[8] ^ 1;
        update_meta_crc();
        expect_preflight_failure(4);
        fresh(5);
        metadata[3] = metadata[3] ^ 1;
        update_meta_crc();
        expect_preflight_failure(3);
        fresh(6);
        metadata[5] = metadata[5] ^ 1;
        update_meta_crc();
        expect_preflight_failure(4);
        fresh(7);
        backup_bad = 1;
        expect_preflight_failure(7);
        check(mismatch_offset == 403, "backup mismatch reports exact byte offset");
        fresh(8);
        io_error_op = 2;
        expect_preflight_failure(6);
        fresh(9);
        original_unstable = 1;
        expect_preflight_failure(5);
        check(backup_calls == 0 && mismatch_offset == 500,
              "unstable original blocks backup and reports differing byte");
        fresh(10);
        preflight();
        changed_rom = 1;
        launch_commit();
        wait_complete();
        check(failed && error == 8 && ram_writes == 0, "cart ROM changed after READY is refused");
        fresh(11);
        preflight();
        ram[511] = ram[511] ^ 1;
        launch_commit();
        wait_complete();
        check(failed && error == 8 && ram_writes == 0 && mismatch_offset == 511,
              "save changed after READY requires a new recovery backup");
        fresh(12);
        preflight();
        reprobe_ok = 0;
        launch_commit();
        wait_complete();
        check(failed && error == 8 && ram_writes == 0, "reprobe failure prevents all writes");
        fresh(13);
        preflight();
        verify_bad = 1;
        launch_commit();
        wait_complete();
        check(failed && error == 9 && ram_writes == 8192 && mismatch_offset == 333,
              "post-write mismatch is failure and never schedules another write");
        fresh(14);
        launch_preflight();
        wait (phase == 7 && rom_reads > 100);
        @(negedge clk); cancel = 1;
        repeat (5) @(negedge clk);
        cancel = 0;
        wait_preflight();
        check(failed && error == 10 && !ram_enabled && !busy, "cancel during ROM read drains and cleans up");
        fresh(15);
        launch_preflight();
        wait (phase == 10 && io_active);
        repeat (12) @(negedge clk);
        cancel = 1;
        repeat (8) @(negedge clk);
        check(busy && io_active && !preflight_done, "cancel waits for outstanding backup I/O");
        cancel = 0;
        wait_preflight();
        check(failed && error == 10 && !io_active && !ram_enabled,
              "soft reset represented by cancel drains APF before release");
        fresh(16);
        preflight();
        launch_commit();
        wait (phase == 15 && ram_writes >= 100);
        @(negedge clk); cancel = 1;
        saved_write_count = ram_writes;
        repeat (5) @(negedge clk);
        cancel = 0;
        wait_complete();
        check(failed && error == 10 && ram_writes <= saved_write_count+1,
              "cancel drains at most one accepted save write then stops");
        for (k=0; k<2048; k=k+1)
            check(retained_backup[k] === original_word(k), "cancel retains the complete original backup");
        fresh(17);
        metadata[12] = 1;
        update_meta_crc();
        expect_preflight_failure(1);
        fresh(18);
        cart_type = 'h1B;
        expect_preflight_failure(2);
        check(metadata_calls == 0 && save_calls == 0 && backup_calls == 0,
              "unsupported mapper rejected before file I/O");
    end
    finished = 1;
end
endmodule
`default_nettype wire
