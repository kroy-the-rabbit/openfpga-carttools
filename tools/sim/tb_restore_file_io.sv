// SOURCES: src/fpga/services/restore/restore_file_io.sv
`default_nettype none
`timescale 1ns/1ps

module tb_restore_file_io;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0;
reg [1:0] op = 0;
wire busy, done, failed, poisoned;
wire [3:0] err;
wire [15:0] backup_index;
wire [108:0] debug_status;
wire [1:0] debug_op;
wire [3:0] debug_stage;
wire [6:0] debug_reads;
wire [31:0] debug_first, debug_tail, debug_flags;
assign {debug_op, debug_stage, debug_reads, debug_first, debug_tail, debug_flags} = debug_status;
reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
reg bridge_rd = 0, bridge_wr = 0, bridge_endian_little = 0;
wire [31:0] bridge_rd_data;
wire bridge_rd_hit;
wire [10:0] backup_rd_addr;
reg [31:0] backup_rd_q;
wire input_we;
wire [10:0] input_index;
wire [31:0] input_data;
wire [1:0] input_kind;
wire [9:0] datatable_addr;
reg [31:0] datatable_q;
wire t_read, t_write, t_open;
wire [15:0] t_id;
wire [31:0] t_offset, t_address, t_length, t_struct;
reg t_done = 1;
reg [2:0] t_err = 0;

restore_file_io #(.TIMEOUT_CYCLES(30000)) dut (
    .clk(clk), .reset(reset), .start(start), .op(op),
    .busy(busy), .done(done), .failed(failed), .err(err),
    .poisoned(poisoned), .backup_index(backup_index),
    .debug_status(debug_status),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_endian_little(bridge_endian_little),
    .bridge_rd_data(bridge_rd_data), .bridge_rd_hit(bridge_rd_hit),
    .backup_rd_addr(backup_rd_addr), .backup_rd_q(backup_rd_q),
    .input_we(input_we), .input_index(input_index), .input_data(input_data),
    .input_kind(input_kind), .datatable_addr(datatable_addr), .datatable_q(datatable_q),
    .target_dataslot_read(t_read), .target_dataslot_write(t_write),
    .target_dataslot_openfile(t_open), .target_dataslot_id(t_id),
    .target_dataslot_slotoffset(t_offset), .target_dataslot_bridgeaddr(t_address),
    .target_dataslot_length(t_length), .target_buffer_param_struct(t_struct),
    .target_dataslot_done(t_done), .target_dataslot_err(t_err)
);

reg [31:0] datatable [0:15];
reg [31:0] backup_memory [0:2047];
reg [31:0] written_file [0:2047];
reg [31:0] received [0:2047];
reg [7:0] structure [0:263];
integer errors = 0, n_open = 0, n_read = 0, n_write = 0, n_inputs = 0, n_resize = 0;
integer occupied_names = 0, created_name = -1, last_open_name = -1, created_size = 0;
integer wrong_table_id = 0, size_delta = 0, reopen_size_delta = 0, open_error = -1;
integer read_error = 0, write_error = 0, resize_error = 0, mute_command = 0;
integer short_words = 0, malformed_receive = 0, create_race = 0;
integer read_kind_errors = 0;

function automatic [31:0] swap(input [31:0] word_value);
    swap = {word_value[7:0], word_value[15:8], word_value[23:16], word_value[31:24]};
endfunction
function automatic [31:0] input_word(input integer slot, input integer index);
    input_word = slot == 21 ? (32'hAC390571 ^ (index * 32'h07130503))
                           : (32'h873421AD ^ (index * 32'h05130711));
endfunction
function automatic integer unhex(input [7:0] character);
    begin
        if (character >= "0" && character <= "9") unhex = character - "0";
        else if (character >= "A" && character <= "F") unhex = character - "A" + 10;
        else unhex = -100000;
    end
endfunction

always @(posedge clk) begin
    backup_rd_q <= backup_memory[backup_rd_addr];
    datatable_q <= datatable[datatable_addr[3:0]];
    if (input_we) begin
        received[input_index] = input_data;
        n_inputs = n_inputs + 1;
        if (input_kind !== op) read_kind_errors = read_kind_errors + 1;
    end
end

task automatic check(input integer condition, input [511:0] label_text);
    begin
        if (!condition) begin
            $display("ERROR: %0s at %0t", label_text, $time);
            errors = errors + 1;
        end
    end
endtask

// Reproduce the empirically established tb_dump_engine APF model: settle
// address, sample BEFORE bridge_rd, then pulse. A burst primes its first
// address, discards that response, and consumes it on the next transaction.
task automatic host_word(input [31:0] address, output [31:0] stream_word,
                         input check_previous);
    reg [31:0] held_before;
    begin
        @(negedge clk);
        held_before = bridge_rd_data;
        bridge_addr = address;
        repeat (4) @(negedge clk);
        check(bridge_rd_data === held_before, "bridge response changes only on bridge_rd");
        if (check_previous)
            check(bridge_rd_hit, "bridge window claimed previous response");
        stream_word = bridge_endian_little ? swap(bridge_rd_data) : bridge_rd_data;
        @(negedge clk);
        bridge_rd = 1;
        @(negedge clk);
        bridge_rd = 0;
        @(negedge clk);
    end
endtask

task automatic check_open_struct(output integer flags, output integer name);
    integer w, j, expected_length;
    reg [31:0] word_value;
    reg [199:0] prefix;
    reg [95:0] meta_name;
    reg [87:0] save_name;
    begin
        check(t_struct === 32'h90000000, "open struct address");
        host_word(t_struct, word_value, 0);
        for (w = 0; w < 66; w = w + 1) begin
            host_word(t_struct + (w+1)*4, word_value, 1);
            for (j = 0; j < 4; j = j + 1)
                structure[w*4+j] = word_value[j*8 +: 8];
        end
        prefix = "/Assets/carttools/common/";
        for (j = 0; j < 25; j = j + 1)
            check(structure[j] === prefix[199-j*8 -: 8], "correct absolute Assets prefix");
        flags = {structure[259], structure[258], structure[257], structure[256]};
        check(flags == 0 || flags == 1 || flags == 2, "never combine create and resize");
        check({structure[263], structure[262], structure[261], structure[260]}
              == (flags ? 8192 : 0), "little-endian desired size");
        name = -1;
        if (t_id == 21) begin
            meta_name = "RESTORE.meta";
            expected_length = 37;
            for (j = 0; j < 12; j = j + 1)
                check(structure[25+j] === meta_name[95-j*8 -: 8], "metadata basename");
        end else if (t_id == 22) begin
            save_name = "RESTORE.sav";
            expected_length = 36;
            for (j = 0; j < 11; j = j + 1)
                check(structure[25+j] === save_name[87-j*8 -: 8], "single save basename");
        end else begin
            check(t_id == 23, "recovery slot identity");
            check({structure[25],structure[26],structure[27]} == "PRE", "recovery prefix");
            check({structure[32],structure[33],structure[34],structure[35]} == ".sav", "recovery extension");
            name = unhex(structure[28])*4096 + unhex(structure[29])*256
                   + unhex(structure[30])*16 + unhex(structure[31]);
            check(name >= 0 && name <= 65535, "four hexadecimal recovery digits");
            expected_length = 36;
        end
        for (j = expected_length; j < 256; j = j + 1)
            check(structure[j] == 0, "path termination and zero padding");
        check(debug_reads == 66, "trace counted responses including the final delayed word");
        check(debug_first === 32'h7373412F, "trace observed first delivered path word");
        check(debug_tail === (t_id == 21 ? 32'h74656D2E : 32'h7661732E),
              "trace observed filename tail rather than the requested next word");
        check(debug_flags === flags, "trace observed actual flag response");
    end
endtask

task automatic model_open;
    integer flags, name, table_index, size;
    begin
        n_open = n_open + 1;
        t_done = 0;
        if (mute_command != 1) begin
            check_open_struct(flags, name);
            table_index = t_id == 21 ? 4 : t_id == 22 ? 6 : 8;
            size = t_id == 21 ? 64 : 8192;
            if (open_error >= 0) t_err = open_error;
            else if (t_id != 23) begin
                check(flags == 0, "input opens never create");
                t_err = 0;
            end else if (flags == 1) begin
                check(name >= occupied_names, "existing recovery file never recreated");
                if (create_race) t_err = 0;
                else begin
                    created_name = name;
                    created_size = 0;
                    t_err = 1;
                end
                size = 0;
            end else if (flags == 2) begin
                n_resize = n_resize + 1;
                check(name == created_name && name == last_open_name && n_write == 0,
                      "only this operation's new pinned backup may be preallocated");
                if (!resize_error) created_size = 8192;
                size = created_size;
                t_err = resize_error;
            end else if (name < occupied_names || name == created_name) begin
                t_err = 0;
                size = name == created_name ? created_size : 17;
            end else t_err = 3;
            if (t_id == 23) last_open_name = name;
            datatable[table_index] = wrong_table_id ? 16'd77 : t_id;
            datatable[table_index+1] = size + size_delta;
            if (t_id == 23 && flags == 0 && name == created_name)
                datatable[table_index+1] = size + reopen_size_delta;
            repeat (3) @(negedge clk);
            if (!(mute_command == 4 && flags == 2)) t_done = 1;
        end
    end
endtask

task automatic model_write;
    integer w;
    reg [31:0] stream_word;
    begin
        n_write = n_write + 1;
        t_done = 0;
        check(t_id == 23 && created_name >= 0 && created_name == last_open_name,
              "write only newly created recovery slot");
        check(created_size == 8192, "zero-length creation must be preallocated before write");
        check(t_offset == 0 && t_address == 32'hA0000000 && t_length == 8192,
              "complete backup transfer arguments");
        if (mute_command != 3) begin
            host_word(t_address, stream_word, 0);
            for (w = 0; w < 2048; w = w + 1) begin
                host_word(t_address + (w+1)*4, stream_word, 1);
                written_file[w] = stream_word;
                check(written_file[w] === backup_memory[w], "outbound RAM word order");
            end
            repeat (3) @(negedge clk);
            t_err = write_error;
            t_done = 1;
        end
    end
endtask

task automatic model_read;
    integer w, words, write_index;
    reg [31:0] data_word, stream_word;
    begin
        n_read = n_read + 1;
        t_done = 0;
        words = t_id == 21 ? 16 : 2048;
        check(t_address == 32'hB0000000 && t_offset == 0 && t_length == words*4,
              "complete input transfer arguments");
        if (t_id == 23) check(last_open_name == created_name, "reopened exact recovery name");
        if (mute_command != 2) begin
            repeat (4) @(negedge clk);
            for (w = 0; w < words-short_words; w = w + 1) begin
                write_index = w;
                if (malformed_receive == 1 && w == 7) write_index = 6;
                data_word = t_id == 23 ? written_file[w] : input_word(t_id, w);
                stream_word = swap(data_word);
                bridge_addr = 32'hB0000000 + write_index*4;
                if (malformed_receive == 2 && w == 7) bridge_addr = bridge_addr + 1;
                if (malformed_receive == 3 && w == 7) bridge_addr = 32'hB0008000;
                bridge_wr_data = bridge_endian_little ? swap(stream_word) : stream_word;
                bridge_wr = 1;
                @(negedge clk);
                bridge_wr = 0;
                @(negedge clk);
            end
            if (malformed_receive == 4) begin
                bridge_addr = 32'hB0000000 + words*4;
                bridge_wr = 1;
                @(negedge clk);
                bridge_wr = 0;
            end
            repeat (3) @(negedge clk);
            t_err = read_error;
            t_done = 1;
        end
    end
endtask

always @(negedge clk) begin
    if (!reset) begin
        if (t_open) model_open();
        if (t_write) model_write();
        if (t_read) model_read();
    end
end

task automatic fresh;
    integer i;
    begin
        @(negedge clk);
        reset = 1;
        start = 0;
        bridge_wr = 0;
        bridge_rd = 0;
        n_open = 0; n_read = 0; n_write = 0; n_inputs = 0; n_resize = 0;
        occupied_names = 0; created_name = -1; last_open_name = -1; created_size = 0;
        wrong_table_id = 0; size_delta = 0; reopen_size_delta = 0; open_error = -1;
        read_error = 0; write_error = 0; resize_error = 0; mute_command = 0;
        short_words = 0; malformed_receive = 0; create_race = 0;
        read_kind_errors = 0;
        t_done = 1; t_err = 0;
        for (i = 0; i < 16; i = i + 1) datatable[i] = 0;
        for (i = 0; i < 2048; i = i + 1) begin
            backup_memory[i] = 32'hBD630127 ^ (i * 32'h01130703);
            written_file[i] = 0;
            received[i] = 0;
        end
        repeat (4) @(negedge clk);
        reset = 0;
        repeat (5) @(negedge clk);
    end
endtask

task automatic run(input [1:0] requested_op);
    integer cycles;
    begin
        @(negedge clk);
        op = requested_op;
        start = 1;
        @(negedge clk);
        start = 0;
        cycles = 0;
        while (!done && cycles < 200000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(done && !busy, "operation completes and releases ownership");
        check(read_kind_errors == 0, "input stream labels the requested operation");
        @(negedge clk);
    end
endtask

integer endian_mode, i, before_count;
initial begin
    for (endian_mode = 0; endian_mode < 2; endian_mode = endian_mode + 1) begin
        bridge_endian_little = endian_mode;
        fresh();
        run(0);
        check(!failed && err == 0 && n_open == 1 && n_read == 1 && n_write == 0,
              "metadata load succeeds from read-only open");
        check(n_inputs == 16, "all metadata words received");
        for (i = 0; i < 16; i = i + 1)
            check(received[i] === input_word(21, i), "metadata bytes preserved");

        fresh();
        run(1);
        check(!failed && n_inputs == 2048 && n_open == 1 && n_read == 1 && n_write == 0,
              "save staged completely with no SD writes");
        for (i = 0; i < 2048; i = i + 1)
            check(received[i] === input_word(22, i), "save bytes preserved");
        before_count = n_inputs;
        bridge_addr = 32'hB0000000;
        bridge_wr = 1;
        repeat (4) @(negedge clk);
        bridge_wr = 0;
        check(n_inputs == before_count, "late bridge traffic cannot alter staged data");

        fresh();
        occupied_names = 2;
        run(2);
        check(!failed && backup_index == 2 && n_open == 6 && n_resize == 1 && n_write == 1 && n_read == 1,
              "probe, create, preallocate, write, reopen, reread sequence");
        for (i = 0; i < 2048; i = i + 1)
            check(received[i] === backup_memory[i], "entire recovery file returned for comparison");
    end

    fresh();
    wrong_table_id = 1;
    run(1);
    check(failed && err == 9 && n_read == 0 && n_inputs == 0, "mismatched slot ID blocks read");
    fresh();
    size_delta = -4;
    run(1);
    check(failed && err == 9 && n_read == 0, "short slot length blocks read");
    fresh();
    size_delta = 4;
    run(0);
    check(failed && err == 9 && n_read == 0, "oversized metadata blocks read");
    fresh();
    open_error = 3;
    run(1);
    check(failed && err == 3 && n_read == 0 && n_write == 0, "missing save never created");
    fresh();
    open_error = 1;
    run(0);
    check(failed && err == 1 && n_read == 0, "created result on input is refused");
    for (i = 0; i < 3; i = i + 1) begin
        fresh();
        open_error = 4;
        run(i);
        check(failed && err == 4 && n_read == 0 && n_write == 0,
              "malformed path refuses all input and recovery operations");
        check(debug_op == i && debug_stage == (i == 2 ? 5 : 1),
              "failure retains the exact operation and failed open stage");
        repeat (5) @(negedge clk);
        check(debug_reads == 66 && debug_first == 32'h7373412F,
              "failure trace survives return to idle");
    end
    fresh();
    short_words = 1;
    run(1);
    check(failed && err == 10, "successful APF status cannot hide a short transfer");
    for (i = 1; i <= 4; i = i + 1) begin
        fresh();
        malformed_receive = i;
        run(0);
        check(failed && err == 10, "duplicate, unaligned, range, or extra input word rejected");
    end
    fresh();
    read_error = 2;
    run(1);
    check(failed && err == 2, "read error preserved after complete data transfer");
    fresh();
    create_race = 1;
    run(2);
    check(failed && err == 13 && n_resize == 0 && n_write == 0 && n_read == 0,
          "racing existing recovery file cannot be overwritten");
    fresh();
    resize_error = 5;
    run(2);
    check(failed && err == 5 && n_resize == 1 && n_write == 0 && n_read == 0,
          "failed preallocation prevents write");
    fresh();
    write_error = 2;
    run(2);
    check(failed && err == 2 && n_write == 1 && n_read == 0, "failed backup write blocks readback success");
    fresh();
    size_delta = 4;
    run(2);
    check(failed && err == 9 && n_write == 0 && n_read == 0,
          "preallocated length must match before write");
    fresh();
    reopen_size_delta = -4;
    run(2);
    check(failed && err == 9 && n_write == 1 && n_read == 0,
          "reopened recovery length must match before readback");
    fresh();
    dut.backup_index = 16'hFFFF;
    occupied_names = 65536;
    run(2);
    check(failed && err == 11 && n_open == 1 && n_write == 0,
          "full recovery namespace never wraps or overwrites");

    for (i = 1; i <= 4; i = i + 1) begin
        fresh();
        mute_command = i;
        run(i >= 3 ? 2 : 1);
        check(failed && err == 8 && poisoned, "timeout permanently poisons command service");
        before_count = n_open + n_read + n_write;
        t_done = 1;
        t_err = 0;
        mute_command = 0;
        bridge_addr = 32'hB0000000;
        bridge_wr = 1;
        repeat (5) @(negedge clk);
        bridge_wr = 0;
        run(0);
        check(failed && err == 8 && before_count == n_open+n_read+n_write,
              "late done cannot authorize service reuse");
    end
    fresh();
    run(3);
    check(failed && err == 12 && n_open == 0, "undefined operation is refused");
    if (errors) $fatal(1, "%0d failures", errors);
    $display("TB PASS: tb_restore_file_io");
    $finish;
end

initial begin
    #100000000;
    $fatal(1, "testbench watchdog");
end
endmodule
`default_nettype wire
