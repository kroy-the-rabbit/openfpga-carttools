// SOURCES: src/fpga/services/restore/restore_file_io.sv
`default_nettype none
`timescale 1ns/1ps

// SAVE_BYTES selects the geometry under test: 8192 (MBC1) or 32768 (MBC3).
// tb_restore_file_io_32k wraps this bench at the larger size.
module tb_restore_file_io #(parameter integer SAVE_BYTES = 8192);
localparam integer SAVE_WORDS = SAVE_BYTES / 4;
localparam [31:0] SAVE_BYTES_W = SAVE_BYTES;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0;
reg [1:0] op = 0;
wire busy, done, failed, poisoned;
wire [3:0] err;
wire [15:0] backup_index;
wire [108:0] debug_status;
wire [475:0] debug_detail;
wire [99:0] debug_sequence;
wire [1:0] debug_op;
wire [3:0] debug_stage;
wire [6:0] debug_reads;
wire [31:0] debug_first, debug_tail, debug_flags;
assign {debug_op, debug_stage, debug_reads, debug_first, debug_tail, debug_flags} = debug_status;
reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
reg bridge_rd = 0, bridge_wr = 0, bridge_endian_little = 0;
wire [31:0] bridge_rd_data;
wire bridge_rd_hit;
wire [12:0] backup_rd_addr;
reg [31:0] backup_rd_q;
wire input_we;
wire [12:0] input_index;
wire [31:0] input_data;
wire [1:0] input_kind;
wire [9:0] datatable_addr;
reg [31:0] datatable_q;
wire t_read, t_write, t_open, t_get;
wire [15:0] t_id;
wire [31:0] t_offset, t_address, t_length, t_struct;
wire [31:0] t_response;
reg t_done = 1;
reg [15:0] t_err = 0;

// The modeled host reads a recovery write one word per eight clocks, so the
// command timeout scales with the file; the real service allows 1.8 s.
restore_file_io #(.TIMEOUT_CYCLES(30000 * (SAVE_BYTES / 8192))) dut (
    .clk(clk), .reset(reset), .start(start), .op(op),
    .save_bytes(SAVE_BYTES_W[15:0]),
    .busy(busy), .done(done), .failed(failed), .err(err),
    .poisoned(poisoned), .backup_index(backup_index),
    .debug_status(debug_status),
    .debug_detail(debug_detail), .debug_sequence(debug_sequence), .observed_bridge_data(bridge_rd_data),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_endian_little(bridge_endian_little),
    .bridge_rd_data(bridge_rd_data), .bridge_rd_hit(bridge_rd_hit),
    .backup_rd_addr(backup_rd_addr), .backup_rd_q(backup_rd_q),
    .input_we(input_we), .input_index(input_index), .input_data(input_data),
    .input_kind(input_kind), .datatable_addr(datatable_addr), .datatable_q(datatable_q),
    .target_dataslot_read(t_read), .target_dataslot_write(t_write),
    .target_dataslot_openfile(t_open), .target_dataslot_id(t_id),
    .target_dataslot_getfile(t_get), .target_buffer_resp_struct(t_response),
    .target_dataslot_slotoffset(t_offset), .target_dataslot_bridgeaddr(t_address),
    .target_dataslot_length(t_length), .target_buffer_param_struct(t_struct),
    .target_dataslot_done(t_done), .target_dataslot_err(t_err[2:0]), .target_dataslot_result(t_err)
);

reg [31:0] datatable [0:15];
reg [31:0] datatable_read;
reg [31:0] backup_memory [0:SAVE_WORDS-1];
reg [31:0] written_file [0:SAVE_WORDS-1];
reg [31:0] received [0:SAVE_WORDS-1];
reg [7:0] structure [0:255];
integer errors = 0, n_open = 0, n_read = 0, n_write = 0, n_inputs = 0, n_resize = 0;
integer n_get = 0, name_error = 0, name_fault = 0, name_transfer_fault = 0;
integer name_length_words = 64, name_padding = 0, name_done_with_last = 0;
integer occupied_names = 0, created_name = -1, last_open_name = -1, created_size = 0;
integer wrong_table_id = 0, size_delta = 0, reopen_size_delta = 0, open_error = -1;
integer read_error = 0, write_error = 0, mute_command = 0;
integer short_words = 0, malformed_receive = 0, create_race = 0;
integer create_result_override = -1, creation_reported_size = SAVE_BYTES, wrong_created_id = 0;
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
// The firmware path is a byte buffer, unlike the numeric flags and size.
// Match against an independent canonical string, never the producer's
// struct_word function. Reversing each word must not produce the same path.
function automatic integer path_matches(input string canonical,
                                         input integer reverse_words);
    integer offset, source_offset;
    reg [7:0] expected_byte;
    begin
        path_matches = 1;
        for (offset = 0; offset < 256; offset = offset + 1) begin
            source_offset = reverse_words ? (offset / 4)*4 + 3 - (offset % 4) : offset;
            expected_byte = offset < canonical.len() ? canonical[offset] : 8'd0;
            if (structure[source_offset] !== expected_byte) path_matches = 0;
        end
    end
endfunction

always @(posedge clk) begin
    backup_rd_q <= backup_memory[backup_rd_addr];
    // mf_datatable has a synchronous read plus a CLOCK0 output register.
    datatable_read <= datatable[datatable_addr[3:0]];
    datatable_q <= datatable_read;
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

// Reproduce the peripheral's buffered-word timing: settle address, sample
// BEFORE bridge_rd, then pulse. A burst primes its first address, discards
// that response, and consumes it on the next transaction. The interpretation
// of the returned numeric word belongs to the command's consumer below.
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
    reg [31:0] word_value, desired_size;
    reg [199:0] prefix;
    reg [95:0] meta_name;
    reg [87:0] save_name;
    string canonical;
    string digits;
    begin
        check(t_struct === 32'h90000000, "open struct address");
        host_word(t_struct, word_value, 0);
        for (w = 0; w < 66; w = w + 1) begin
            host_word(t_struct + (w+1)*4, word_value, 1);
            // 0192 bulk path bytes retain SPI order, first byte high.
            // Its scalar flags and size are separately read numeric words.
            // This differs from 0184's measured file-payload convention.
            if (w < 64) begin
                for (j = 0; j < 4; j = j + 1)
                    structure[w*4+j] = word_value[31-j*8 -: 8];
            end else if (w == 64) flags = word_value;
            else desired_size = word_value;
            if (w == 0) check(word_value === 32'h2F417373, "raw path starts with /Ass in SPI order");
        end
        prefix = "/Assets/carttools/common/";
        for (j = 0; j < 25; j = j + 1)
            check(structure[j] === prefix[199-j*8 -: 8], "correct absolute Assets prefix");
        check(flags == 0 || flags == 3, "a new recovery file is created and sized in one open");
        check(desired_size == (flags == 3 ? SAVE_BYTES : 0), "only the create carries a desired size");
        name = -1;
        if (t_id == 21) begin
            meta_name = "RESTORE.meta";
            canonical = "/Assets/carttools/common/RESTORE.meta";
            expected_length = 37;
            for (j = 0; j < 12; j = j + 1)
                check(structure[25+j] === meta_name[95-j*8 -: 8], "metadata basename");
        end else if (t_id == 22) begin
            save_name = "RESTORE.sav";
            canonical = "/Assets/carttools/common/RESTORE.sav";
            expected_length = 36;
            for (j = 0; j < 11; j = j + 1)
                check(structure[25+j] === save_name[87-j*8 -: 8], "single save basename");
        end else begin
            canonical = "/Assets/carttools/common/PRE0000.sav";
            digits = "0123456789ABCDEF";
            canonical[28] = digits[backup_index[15:12]];
            canonical[29] = digits[backup_index[11:8]];
            canonical[30] = digits[backup_index[7:4]];
            canonical[31] = digits[backup_index[3:0]];
            check(t_id == 23, "recovery slot identity");
            check({structure[25],structure[26],structure[27]} == "PRE", "recovery prefix");
            check({structure[32],structure[33],structure[34],structure[35]} == ".sav", "recovery extension");
            name = unhex(structure[28])*4096 + unhex(structure[29])*256
                   + unhex(structure[30])*16 + unhex(structure[31]);
            check(name >= 0 && name <= 65535, "four hexadecimal recovery digits");
            expected_length = 36;
        end
        check(path_matches(canonical, 0), "0192 byte-buffer parser accepts canonical path");
        check(!path_matches(canonical, 1), "0192 parser rejects legacy word-reversed path");
        for (j = expected_length; j < 256; j = j + 1)
            check(structure[j] == 0, "path termination and zero padding");
        check(debug_reads == 66, "trace counted responses including the final delayed word");
        check(debug_first === 32'h2F417373, "trace observed first delivered path word");
        check(debug_tail === (t_id == 21 ? 32'h2E6D6574 : 32'h2E736176),
              "trace observed filename tail rather than the requested next word");
        check(debug_flags === flags, "trace observed actual flag response");
        check(debug_detail[145:139] == 66 && debug_detail[138:132] == 0,
              "complete unique structure trace with no repeat");
        check(debug_detail[103] == 0, "correct responses never set mismatch latch");
        check(debug_detail[31:0] == (flags == 3 ? SAVE_BYTES : 0), "trace observed actual desired size");
        check(debug_detail[155:146] == 10'h3FF, "trace retained every path word");
        for (j = 0; j < 40; j = j + 1)
            check(debug_detail[156+j*8 +: 8] === structure[j], "full observed path matches host");
    end
endtask

task automatic model_open;
    integer flags, name, table_index, size;
    begin
        n_open = n_open + 1;
        check(t_id == 23, "fixed input slots must never be reopened or created");
        t_done = 0;
        if (mute_command != 1) begin
            check_open_struct(flags, name);
            table_index = t_id == 21 ? 4 : t_id == 22 ? 6 : 8;
            size = t_id == 21 ? 64 : SAVE_BYTES;
            if (open_error >= 0) t_err = open_error;
            else if (t_id != 23) begin
                check(flags == 0, "input opens never create");
                t_err = 0;
            end else if (flags == 3) begin
                check(name >= occupied_names, "existing recovery file never recreated");
                if (create_result_override >= 0) t_err = create_result_override;
                else if (create_race) t_err = 0;
                else begin
                    created_name = name;
                    created_size = creation_reported_size;
                    t_err = 1;
                end
                size = creation_reported_size;
            end else if (name < occupied_names || name == created_name) begin
                t_err = 0;
                size = name == created_name ? created_size : 17;
            end else t_err = 3;
            if (t_id == 23) last_open_name = name;
            datatable[table_index] = wrong_table_id || (flags == 3 && wrong_created_id) ? 16'd77 : t_id;
            datatable[table_index+1] = size + size_delta;
            if (t_id == 23 && flags == 0 && name == created_name)
                datatable[table_index+1] = size + reopen_size_delta;
            repeat (3) @(negedge clk);
            if (!(mute_command == 4 && flags == 3)) t_done = 1;
        end
    end
endtask

task automatic model_get;
    integer w, b, offset, write_index;
    reg [31:0] stream_word;
    reg [7:0] character;
    string canonical;
    string digits;
    begin
        n_get = n_get + 1;
        t_done = 0;
        check(t_id == 21 || t_id == 22 || t_id == 23, "get filename uses assigned restore slot");
        check(t_response == 32'hC0000000, "dedicated filename response pointer");
        canonical = t_id == 21 ? "/Assets/carttools/common/RESTORE.meta" :
                                  "/Assets/carttools/common/RESTORE.sav";
        if (t_id == 23) begin
            check(created_name >= 0 && n_resize == 0 && n_write == 0,
                  "backup association checked after creation but before mutation");
            canonical = "/Assets/carttools/common/PRE0000.sav";
            digits = "0123456789ABCDEF";
            canonical[28] = digits[(created_name / 4096) % 16];
            canonical[29] = digits[(created_name / 256) % 16];
            canonical[30] = digits[(created_name / 16) % 16];
            canonical[31] = digits[created_name % 16];
        end
        if (mute_command != 5) begin
            repeat (4) @(negedge clk);
            t_err = name_error;
            for (w = 0; w < name_length_words; w = w + 1) begin
                stream_word = 0;
                for (b = 0; b < 4; b = b + 1) begin
                    offset = w*4+b;
                    character = offset < canonical.len() ? canonical[offset] :
                                offset == canonical.len() ? 8'd0 : name_padding;
                    if ((name_fault == 1 && offset == 0) ||
                        (name_fault == 2 && offset == 25) ||
                        (name_fault == 3 && offset == canonical.len()) ||
                        (name_fault == 7 && offset == canonical.len()-1)) character = "X";
                    if ((name_fault == 4 && offset == 10) || name_fault == 5) character = 0;
                    stream_word[31-b*8 -: 8] = character;
                end
                if (name_fault == 6) stream_word = swap(stream_word);
                write_index = name_transfer_fault == 1 && w == 7 ? 6 : w;
                bridge_addr = t_response + write_index*4;
                if (name_transfer_fault == 2 && w == 7) bridge_addr = bridge_addr + 1;
                if (name_transfer_fault == 3 && w == 7) bridge_addr = t_response + 32'h8000;
                if (name_transfer_fault == 5) bridge_addr = 32'hB0000000 + w*4;
                bridge_wr_data = bridge_endian_little ? swap(stream_word) : stream_word;
                bridge_wr = 1;
                if (name_done_with_last && w == name_length_words-1) t_done = 1;
                @(negedge clk);
                bridge_wr = 0;
                @(negedge clk);
            end
            if (name_transfer_fault == 4) begin
                bridge_addr = t_response + 256;
                bridge_wr = 1;
                @(negedge clk);
                bridge_wr = 0;
            end
            repeat (3) @(negedge clk);
            t_done = 1;
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
        check(created_size == SAVE_BYTES, "recovery size must be exact before write");
        check(t_offset == 0 && t_address == 32'hA0000000 && t_length == SAVE_BYTES,
              "complete backup transfer arguments");
        if (mute_command != 3) begin
            host_word(t_address, stream_word, 0);
            for (w = 0; w < SAVE_WORDS; w = w + 1) begin
                host_word(t_address + (w+1)*4, stream_word, 1);
                written_file[w] = stream_word;
                check(written_file[w] === swap(backup_memory[w]), "outbound RAM word order, byte zero high");
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
        words = t_id == 21 ? 16 : SAVE_WORDS;
        check(t_address == 32'hB0000000 && t_offset == 0 && t_length == words*4,
              "complete input transfer arguments");
        if (t_id == 23) check(last_open_name == created_name, "reopened exact recovery name");
        if (mute_command != 2) begin
            repeat (4) @(negedge clk);
            for (w = 0; w < words-short_words; w = w + 1) begin
                write_index = w;
                if (malformed_receive == 1 && w == 7) write_index = 6;
                data_word = t_id == 23 ? written_file[w] : input_word(t_id, w);
                // A reread returns the recovery words exactly as they went out;
                // fixed inputs arrive byte zero high from their byte-zero-low content.
                stream_word = t_id == 23 ? data_word : swap(data_word);
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
        if (t_get) model_get();
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
        n_get = 0; name_error = 0; name_fault = 0; name_transfer_fault = 0;
        name_length_words = 64; name_padding = 0; name_done_with_last = 0;
        occupied_names = 0; created_name = -1; last_open_name = -1; created_size = 0;
        wrong_table_id = 0; size_delta = 0; reopen_size_delta = 0; open_error = -1;
        read_error = 0; write_error = 0; mute_command = 0;
        short_words = 0; malformed_receive = 0; create_race = 0;
        create_result_override = -1; creation_reported_size = SAVE_BYTES; wrong_created_id = 0;
        read_kind_errors = 0;
        t_done = 1; t_err = 0;
        for (i = 0; i < 16; i = i + 1) datatable[i] = 0;
        datatable[4] = 21; datatable[5] = 64;
        datatable[6] = 22; datatable[7] = SAVE_BYTES;
        for (i = 0; i < SAVE_WORDS; i = i + 1) begin
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
        if (requested_op < 2) begin
            datatable[requested_op == 0 ? 4 : 6] = wrong_table_id ? 77 : 21 + requested_op;
            datatable[requested_op == 0 ? 5 : 7] = (requested_op == 0 ? 64 : SAVE_BYTES) + size_delta;
        end
        start = 1;
        @(negedge clk);
        start = 0;
        cycles = 0;
        while (!done && cycles < 200000 * (SAVE_BYTES / 8192)) begin
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
    if ($test$plusargs("table_latency_probe")) begin
        fresh();
        run(0);
        $display("Table latency probe: failed=%0d error=%0d stage=%0d reads=%0d",
                 failed, err, debug_stage, n_read);
        if (failed || n_read != 1) $fatal(1, "registered data-table read failed");
        $display("TB PASS: registered data-table latency probe");
        $finish;
    end
    for (endian_mode = 0; endian_mode < 2; endian_mode = endian_mode + 1) begin
        bridge_endian_little = endian_mode;
        fresh();
        run(0);
        check(!failed && err == 0 && n_get == 1 && n_open == 0 && n_read == 1 && n_write == 0,
              "metadata load validates assigned read-only slot without reopening");
        check(n_inputs == 16, "all metadata words received");
        for (i = 0; i < 16; i = i + 1)
            check(received[i] === input_word(21, i), "metadata bytes preserved");

        fresh();
        run(1);
        check(!failed && n_inputs == SAVE_WORDS && n_get == 1 && n_open == 0 && n_read == 1 && n_write == 0,
              "save staged completely with no SD writes");
        for (i = 0; i < SAVE_WORDS; i = i + 1)
            check(received[i] === input_word(22, i), "save bytes preserved");
        before_count = n_inputs;
        bridge_addr = 32'hB0000000;
        bridge_wr = 1;
        repeat (4) @(negedge clk);
        bridge_wr = 0;
        check(n_inputs == before_count, "late bridge traffic cannot alter staged data");

        fresh();
        name_length_words = 10;
        name_padding = 8'hA5;
        name_done_with_last = 1;
        run(0);
        check(!failed && n_inputs == 16 && n_get == 1 && n_open == 0,
              "exact terminated path accepts unspecified padding and final-word done");
        for (i = 1; i <= 7; i = i + 1) begin
            fresh();
            name_fault = i;
            run(1);
            check(failed && err == 14 && n_read == 0 && n_write == 0 && n_inputs == 0,
                  "wrong, unterminated, empty, or reversed canonical path rejected");
        end
        for (i = 1; i <= 5; i = i + 1) begin
            fresh();
            name_transfer_fault = i;
            run(0);
            check(failed && err == 10 && n_read == 0 && n_inputs == 0,
                  "malformed filename transfer cannot authorize a data read");
        end
        fresh();
        name_length_words = 9;
        run(1);
        check(failed && err == 10 && n_read == 0, "missing terminator word fails closed");

        fresh();
        occupied_names = 2;
        run(2);
        check(!failed && backup_index == 2 && n_open == 5 && n_get == 1 && n_write == 1 && n_read == 1,
              "probe, create and size, query association, write, reopen, reread sequence");
        check(debug_sequence === {4'hE,SAVE_BYTES_W,16'd3,16'd1,16'd0,16'd0},
              "all exact completion results and observed creation size retained");
        for (i = 0; i < SAVE_WORDS; i = i + 1)
            check(received[i] === backup_memory[i], "entire recovery file returned for comparison");

        // A new run clears recovery breadcrumbs even without a hardware reset.
        run(0);
        check(!failed && debug_sequence[99:64] === {4'd0,32'hFFFFFFFF},
              "new operation hides stale recovery sequence and creation size");

        for (i = 1; i <= 7; i = i + 1) begin
            fresh();
            name_fault = i;
            run(2);
            check(failed && err == 14 && n_get == 1 && n_resize == 0 && n_write == 0 && n_read == 0,
                  "incorrect or unterminated created backup path blocks resize and writes");
            check(debug_stage == 14 && debug_sequence[99:96] == 4'hE &&
                  debug_sequence[63:16] == {16'd3,16'd1,16'd0},
                  "created-path rejection retains completed probe/create/query breadcrumbs");
        end
        for (i = 1; i <= 5; i = i + 1) begin
            fresh();
            name_transfer_fault = i;
            run(2);
            check(failed && err == 10 && n_resize == 0 && n_write == 0 && n_read == 0,
                  "reordered, unaligned, extra or misrouted backup-name transfer blocks mutation");
        end
        fresh();
        name_length_words = 9;
        run(2);
        check(failed && err == 10 && n_resize == 0 && n_write == 0,
              "truncated backup filename cannot authorize resize");
        fresh();
        name_error = 1;
        run(2);
        check(failed && err == 1 && n_resize == 0 && n_write == 0 &&
              debug_sequence[99:96] == 4'hE && debug_sequence[31:16] == 16'd1,
              "failed backup filename query preserves raw result and blocks mutation");
        fresh();
        wrong_created_id = 1;
        run(2);
        check(failed && err == 9 && n_get == 1 && n_resize == 0 && n_write == 0,
              "wrong post-create slot identity blocks resize");
        check(debug_stage == 2 && debug_detail[103:32] == {1'b1,7'd8,32'd77,32'd23},
              "post-create slot identity diagnostic names actual table entry");
        fresh();
        creation_reported_size = 37;
        run(2);
        check(failed && err == 9 && n_get == 1 && n_write == 0 && n_read == 0 &&
              debug_sequence === {4'hE,32'd37,16'd3,16'd1,16'd0,16'd0},
              "created file reported at the wrong size is recorded and blocks the write");
        fresh();
        creation_reported_size = 0;
        run(2);
        check(failed && err == 9 && debug_stage == 3 && n_write == 0 && n_read == 0 &&
              debug_sequence === {4'hE,32'd0,16'd3,16'd1,16'd0,16'd0},
              "created file left at size zero (the 12CD and C358 hardware result) blocks the write");
    end

    fresh();
    mute_command = 5;
    run(2);
    check(failed && err == 8 && poisoned && n_get == 1 && n_resize == 0 && n_write == 0,
          "backup-name timeout poisons service before resize");
    check(debug_stage == 13 && debug_sequence[99:96] == 4'hC &&
          debug_sequence[63:32] == {16'd3,16'd1},
          "timed-out query remains unseen while completed creation results survive");
    fresh();
    create_result_override = 9;
    run(2);
    check(failed && err == 15 && n_get == 0 && n_resize == 0 && n_write == 0 &&
          debug_sequence[99:96] == 4'hC && debug_sequence[47:32] == 16'd9,
          "full create result0009 is not aliased to created result0001");
    fresh();
    create_result_override = 16'h0101;
    run(2);
    check(failed && err == 15 && n_get == 0 && n_resize == 0 && n_write == 0 &&
          debug_sequence[99:96] == 4'hC && debug_sequence[47:32] == 16'h0101,
          "create result upper byte0101 cannot alias to created result0001");
    fresh();
    open_error = 8;
    run(2);
    check(failed && err == 15 && n_open == 1 && n_get == 0 && n_write == 0 &&
          debug_sequence[99:96] == 4'h8 && debug_sequence[63:48] == 16'd8,
          "full probe result0008 is not aliased to opened result0000");
    fresh();
    open_error = 16'hFFFF;
    run(2);
    check(failed && err == 15 && debug_sequence[99:96] == 4'h8 &&
          debug_sequence[63:48] == 16'hFFFF,
          "observed unknownFFFF is distinguished from an unseen response");
    fresh();
    name_error = 8;
    run(2);
    check(failed && err == 15 && n_resize == 0 && n_write == 0 &&
          debug_sequence[99:96] == 4'hE && debug_sequence[31:16] == 16'd8,
          "full backup query result0008 cannot authorize resize");
    for (i = 6; i <= 7; i = i + 1) begin
        fresh();
        name_error = i;
        run(1);
        check(failed && err == 15 && n_read == 0,
              "undocumented six or seven filename result fails closed");
    end

    fresh();
    wrong_table_id = 1;
    run(1);
    check(failed && err == 9 && n_read == 0 && n_inputs == 0, "mismatched slot ID blocks read");
    check(debug_stage == 2 && debug_detail[103:32] == {1'b1, 7'd6, 32'd77, 32'd22},
          "slot ID failure retains table address, actual word, and expected ID");
    fresh();
    size_delta = -4;
    run(1);
    check(failed && err == 9 && n_read == 0, "short slot length blocks read");
    check(debug_stage == 3 && debug_detail[103:32] == {1'b1, 7'd7, SAVE_BYTES_W - 32'd4, SAVE_BYTES_W},
          "size failure retains table address, actual size, and expected size");
    fresh();
    size_delta = 4;
    run(0);
    check(failed && err == 9 && n_read == 0, "oversized metadata blocks read");
    fresh();
    name_error = 1;
    run(1);
    check(failed && err == 1 && n_read == 0 && n_write == 0 && n_open == 0,
          "undefined input slot never opened or created");
    fresh();
    name_length_words = 0;
    run(0);
    check(failed && err == 10 && n_read == 0, "empty successful filename reply refused");
    for (i = 0; i < 3; i = i + 1) begin
        fresh();
        open_error = 4;
        run(i);
        if (i == 2) begin
            check(failed && err == 4 && n_read == 0 && n_write == 0,
                  "recovery open refusal still prevents all backup writes");
            check(debug_op == 2 && debug_stage == 5, "failed recovery open stage retained");
            repeat (5) @(negedge clk);
            check(debug_reads == 66 && debug_first == 32'h2F417373,
                  "failure trace survives return to idle");
        end else begin
            check(!failed && n_open == 0 && n_get == 1 && n_read == 1 && n_write == 0,
                  "fixed read-only inputs do not depend on open-file support");
        end
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
    create_result_override = 5;
    run(2);
    check(failed && err == 5 && n_open == 2 && n_get == 0 && n_write == 0 && n_read == 0,
          "failed creation prevents write");
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

    for (i = 1; i <= 5; i = i + 1) begin
        fresh();
        mute_command = i;
        run(i == 2 || i == 5 ? 1 : 2);
        check(failed && err == 8 && poisoned, "timeout permanently poisons command service");
        before_count = n_open + n_read + n_write + n_get;
        t_done = 1;
        t_err = 0;
        mute_command = 0;
        bridge_addr = 32'hB0000000;
        bridge_wr = 1;
        repeat (5) @(negedge clk);
        bridge_wr = 0;
        run(0);
        check(failed && err == 8 && before_count == n_open+n_read+n_write+n_get,
              "late done cannot authorize service reuse");
    end
    fresh();
    run(3);
    check(failed && err == 12 && n_open == 0, "undefined operation is refused");
    if (errors) $fatal(1, "%0d failures", errors);
    $display("Geometry: %0d-byte save and recovery file", SAVE_BYTES);
    $display("TB PASS: tb_restore_file_io");
    $finish;
end

initial begin
    #(100000000 * (SAVE_BYTES / 8192));
    $fatal(1, "testbench watchdog");
end
endmodule
`default_nettype wire
