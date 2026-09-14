// Harness compiled by check_restore_bridge.py, with actual core_top muxes.
`default_nettype none
`timescale 1ns/1ps
module tb_restore_bridge #(
    parameter integer CHUNK_WORDS = 66,
    parameter integer USE_SPI = 0,
    parameter integer INJECT_WORD = 0,
    parameter integer SPLIT_FIELDS = 0,
    parameter integer RECOVERY_SUCCESS = 0,
    parameter integer BAD_PATH_ORDER = 0,
    parameter integer RECOVERY_FAULT = 0
);
localparam integer EXPECTED_REPEATS = SPLIT_FIELDS ? 4 : 65 / CHUNK_WORDS;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, start = 0;
reg [1:0] op = 0;
reg [31:0] model_addr = 0, model_wr_data = 0;
reg model_rd = 0, model_wr = 0, bridge_endian_little = 0;
wire [31:0] bridge_addr, bridge_wr_data;
wire bridge_rd, bridge_wr;
wire spi_clk, spi_mosi, spi_miso;
reg spi_ss = 0, spi_host_oe = 0, spi_host_clk = 0;
reg [1:0] spi_host_data = 0;
assign spi_clk = spi_host_oe ? spi_host_clk : 1'bz;
assign spi_mosi = spi_host_oe ? spi_host_data[1] : 1'bz;
assign spi_miso = spi_host_oe ? spi_host_data[0] : 1'bz;
generate if (USE_SPI) begin : actual_peripheral
    io_bridge_peripheral peripheral (
        .clk(clk), .reset_n(~reset), .endian_little(bridge_endian_little),
        .pmp_addr(bridge_addr), .pmp_rd(bridge_rd), .pmp_wr(bridge_wr),
        .pmp_rd_data(bridge_rd_data), .pmp_wr_data(bridge_wr_data),
        .phy_spimosi(spi_mosi), .phy_spimiso(spi_miso),
        .phy_spiclk(spi_clk), .phy_spiss(spi_ss)
    );
end else begin : modeled_peripheral
    assign bridge_addr = model_addr;
    assign bridge_wr_data = model_wr_data;
    assign bridge_rd = model_rd;
    assign bridge_wr = model_wr;
end endgenerate
wire [31:0] bridge_rd_data, cmd_bridge_rd_data, restore_bridge_rd_data;
reg inject_active = 0;
wire [31:0] injected_response = restore_bridge_rd_data ^
    ((inject_active && files.reply_word_index == 5) ?
     (bridge_endian_little ? 32'h00000001 : 32'h01000000) : 32'd0);
wire restore_bridge_rd_hit, restore_io_busy, done, failed;
wire [3:0] err;
wire [108:0] debug_status;
wire [475:0] debug_detail;
wire [99:0] debug_sequence;
wire [319:0] observed_path;
wire [9:0] observed_path_seen;
wire [6:0] observed_unique, observed_repeats;
wire [27:0] observed_repeat_indices;
wire observed_bad;
wire [6:0] observed_bad_index;
wire [31:0] observed_bad_word, observed_bad_expected, observed_size;
assign {observed_path, observed_path_seen, observed_unique, observed_repeats,
        observed_repeat_indices, observed_bad, observed_bad_index,
        observed_bad_word, observed_bad_expected, observed_size} = debug_detail;
wire [9:0] table_address;
wire [31:0] table_data;
wire r_target_read, r_target_write, r_target_open, r_target_get;
wire [15:0] r_target_id;
wire [31:0] r_target_offset, r_target_bridge, r_target_length, r_target_struct;
wire [31:0] r_target_response;
wire input_we;
wire [12:0] input_index;
wire [31:0] input_data;
integer input_count = 0;
function [31:0] payload_word(input integer index);
    payload_word = 32'h873421AD ^ (index * 32'h05130711);
endfunction
function [31:0] backup_word(input integer index);
    backup_word = 32'h4937A2E8 ^ (index * 32'h03210517);
endfunction
wire [12:0] backup_rd_addr;
reg [31:0] backup_q1, backup_q;
always @(posedge clk) begin
    backup_q1 <= backup_word(backup_rd_addr);
    backup_q <= backup_q1;
end
always @(posedge clk) if (input_we) begin
    if (input_index != input_count || input_data !==
        (op == 2 ? backup_word(input_count) : payload_word(input_count)))
        $fatal(1, "real bridge input payload arrived in wrong byte order or sequence");
    input_count = input_count + 1;
end
wire target_dataslot_read, target_dataslot_write, target_dataslot_openfile;
wire target_dataslot_getfile, target_dataslot_flush, target_dataslot_done;
wire [2:0] target_dataslot_err;
wire [15:0] target_dataslot_result;
wire [15:0] target_dataslot_id;
wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
wire [31:0] target_buffer_param_struct, target_buffer_resp_struct;
// Idle dumper values are intentionally different from restore's parameters.
wire d_target_write = 0, d_target_open = 0, d_target_get = 0, d_target_flush = 0;
wire [15:0] d_target_id = 20;
wire [31:0] d_target_offset = 32'hCAFE, d_target_bridge = 32'h60000000;
wire [31:0] d_target_length = 32'h8000, d_target_struct = 32'h70000000;
wire [31:0] d_target_response = 32'h80000000;
reg [31:0] dump_bridge_rd_data = 32'hBAD0BAD0;
reg dump_bridge_rd_hit = 0;
// An idle but electrically live dumper retains its previous read response.
// Seed this window between operations to exercise the real held-hit mux.
always @(posedge clk) if (bridge_rd) begin
    dump_bridge_rd_hit <= bridge_addr[31:28] == 6 || bridge_addr[31:28] == 7;
    dump_bridge_rd_data <= 32'hBAD0BAD0 ^ bridge_addr;
end
integer completions = 0;
always @(posedge clk) if (done) completions = completions + 1;
// TOP_MUX

restore_file_io #(.TIMEOUT_CYCLES(1000000)) files (
    .clk(clk), .reset(reset), .start(start), .op(op), .save_bytes(16'd8192),
    .busy(restore_io_busy),
    .done(done), .failed(failed), .err(err), .debug_status(debug_status),
    .debug_detail(debug_detail), .debug_sequence(debug_sequence),
    .observed_bridge_data(bridge_rd_data),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_endian_little(bridge_endian_little),
    .bridge_rd_data(restore_bridge_rd_data), .bridge_rd_hit(restore_bridge_rd_hit),
    .backup_rd_addr(backup_rd_addr), .backup_rd_q(backup_q),
    .datatable_addr(table_address), .datatable_q(table_data),
    .target_dataslot_read(r_target_read), .target_dataslot_write(r_target_write),
    .target_dataslot_openfile(r_target_open), .target_dataslot_id(r_target_id),
    .target_dataslot_getfile(r_target_get), .target_buffer_resp_struct(r_target_response),
    .input_we(input_we), .input_index(input_index), .input_data(input_data),
    .target_dataslot_slotoffset(r_target_offset), .target_dataslot_bridgeaddr(r_target_bridge),
    .target_dataslot_length(r_target_length), .target_buffer_param_struct(r_target_struct),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err),
    .target_dataslot_result(target_dataslot_result)
);
core_bridge_cmd command (
    .clk(clk), .bridge_endian_little(bridge_endian_little),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_rd_data(cmd_bridge_rd_data),
    .status_boot_done(1'b1), .status_setup_done(1'b0), .status_running(1'b1),
    .target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
    .target_dataslot_openfile(target_dataslot_openfile),
    .target_dataslot_getfile(target_dataslot_getfile), .target_dataslot_flush(target_dataslot_flush),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err),
    .target_dataslot_result(target_dataslot_result),
    .target_dataslot_id(target_dataslot_id), .target_dataslot_slotoffset(target_dataslot_slotoffset),
    .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr), .target_dataslot_length(target_dataslot_length),
    .target_buffer_param_struct(target_buffer_param_struct),
    .target_buffer_resp_struct(target_buffer_resp_struct),
    .datatable_addr(table_address), .datatable_q(table_data),
    .datatable_wren(1'b0), .datatable_data(32'd0)
);
function [31:0] swap(input [31:0] value);
    swap = {value[7:0], value[15:8], value[23:16], value[31:24]};
endfunction
task tick(input integer count);
    repeat(count) @(negedge clk);
endtask
task spi_send(input [31:0] value);
    integer bit_pair;
    begin
        for (bit_pair = 15; bit_pair >= 0; bit_pair = bit_pair - 1) begin
            spi_host_clk = 0;
            spi_host_data = value[bit_pair*2 +: 2];
            tick(1);
            spi_host_clk = 1;
            tick(1);
        end
    end
endtask
task spi_begin;
    begin
        spi_ss = 1;
        tick(8);
        spi_host_clk = 0;
        spi_host_oe = 1;
        spi_ss = 0;
        tick(8);
    end
endtask
// APF samples the old held response before pulsing bridge_rd. Every burst
// primes once, then consumes that first word on its next bus transaction.
task host_read(input [31:0] address, output [31:0] value);
    begin
        if (USE_SPI) begin
            spi_begin();
            spi_send(address);
            spi_host_oe = 0;
            #1; // let resolved nets float before waiting for FPGA turnaround
            wait (spi_clk === 1'b1);
            repeat (16) begin
                @(negedge spi_clk); #1;
                value = {value[29:0], spi_mosi, spi_miso};
            end
            tick(4);
            spi_ss = 1;
            tick(8);
        end else begin
        model_addr = address;
        tick(4);
        value = bridge_endian_little ? swap(bridge_rd_data) : bridge_rd_data;
        tick(1);
        model_rd = 1;
        tick(1);
        model_rd = 0;
        tick(1);
        end
    end
endtask
task host_write(input [31:0] address, input [31:0] value);
    begin
        if (USE_SPI) begin
            spi_begin();
            spi_send(address | 32'd1);
            spi_send(value);
            tick(10);
            spi_ss = 1;
            spi_host_oe = 0;
            tick(8);
        end else begin
        model_addr = address;
        model_wr_data = bridge_endian_little ? swap(value) : value;
        tick(2);
        model_wr = 1;
        tick(1);
        model_wr = 0;
        tick(4);
        end
    end
endtask
task register_read(input [31:0] address, output [31:0] value);
    reg [31:0] discarded;
    begin host_read(address, discarded); host_read(address, value); end
endtask
reg [31:0] value, pointer, ignored_word;
reg [7:0] path [0:263];
reg [7:0] stale_path [0:255];
reg [31:0] prime_word;
reg [7:0] expected;
string expected_path;
integer endian_mode, operation, w, b, polls, before_completion;
integer chunk, chunk_end;
reg path_bad;
task await_command(input [31:0] wanted);
    begin
        polls = 0;
        value = 0;
        while (value != wanted && polls < 20) begin
            register_read(32'hF8001000, value);
            polls = polls + 1;
        end
        if (value != wanted) $fatal(1, "real command not published: wanted=%h got=%h", wanted, value);
        register_read(32'hF8001020, value);
        if (value != 21 + operation) $fatal(1, "command selected wrong input slot");
    end
endtask
task fixed_input;
    reg [31:0] response_pointer, stream_word;
    integer word_count, offset;
    begin
        input_count = 0;
        await_command(32'h636D0190);
        register_read(32'hF8001024, response_pointer);
        if (response_pointer != 32'hC0000000) $fatal(1, "get command selected wrong response pointer");
        host_write(32'hF8001000, 32'h62750000);
        expected_path = operation == 0 ? "/Assets/carttools/common/RESTORE.meta" :
                                        "/Assets/carttools/common/RESTORE.sav";
        for (w = 0; w < 64; w = w + 1) begin
            stream_word = 0;
            for (b = 0; b < 4; b = b + 1) begin
                offset = w*4+b;
                stream_word[31-b*8 -: 8] = offset < expected_path.len() ? expected_path[offset] : 8'd0;
            end
            host_write(response_pointer + w*4, stream_word);
        end
        host_write(32'hF8001000, 32'h6F6B0000);
        await_command(32'h636D0180);
        register_read(32'hF8001024, value);
        if (value != 0) $fatal(1, "input read selected wrong slot offset");
        register_read(32'hF8001028, value);
        if (value != 32'hB0000000) $fatal(1, "input read selected wrong bridge address");
        word_count = operation == 0 ? 16 : 2048;
        register_read(32'hF800102C, value);
        if (value != word_count*4) $fatal(1, "input read selected wrong exact length");
        host_write(32'hF8001000, 32'h62750000);
        for (w = 0; w < word_count; w = w + 1)
            host_write(32'hB0000000 + w*4, swap(payload_word(w)));
        host_write(32'hF8001000, 32'h6F6B0000);
        polls = 0;
        while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
        if (completions != before_completion + 1 || failed || err || restore_io_busy || input_count != word_count)
            $fatal(1, "assigned-slot input did not complete with all payload words");
        if (observed_unique != 64 || observed_bad || debug_status[102:96] != 64)
            $fatal(1, "firmware-returned path trace did not retain all words");
        for (b = 0; b < 40; b = b + 1) begin
            expected = b < expected_path.len() ? expected_path[b] : 0;
            if (observed_path[b*8 +: 8] !== expected)
                $fatal(1, "firmware-returned path trace byte %0d differs", b);
        end
    end
endtask

reg [31:0] recovery_disk [0:2047];
integer recovery_opens, recovery_writes, recovery_reads;
reg recovery_disk_exists;
reg [31:0] recovery_disk_size;
reg recovery_slot_bound;
reg [31:0] recovery_path_words [0:63];
reg [31:0] received_path_words [0:63];
task recovery_open(input [31:0] wanted_flags, input [31:0] wanted_size,
                   input [15:0] result_code);
    integer word_index, byte_index;
    reg [31:0] structure_pointer, response, expected_word, discarded;
    reg path_matches;
    reg [15:0] model_result;
    begin
        await_command(32'h636D0192);
        recovery_opens = recovery_opens + 1;
        register_read(32'hF8001024, structure_pointer);
        if (structure_pointer != 32'h90000000)
            $fatal(1, "recovery open selected wrong struct pointer");
        host_write(32'hF8001000, 32'h62750000);
        host_read(structure_pointer, response);
        for (word_index = 0; word_index < 66; word_index = word_index + 1) begin
            if (SPLIT_FIELDS && word_index >= 64) begin
                // Scalars are separate repeated reads, matching the probe
                // trace. Keep the second response, after priming this field.
                host_read(structure_pointer + 4*word_index, discarded);
                host_read(structure_pointer + 4*word_index, response);
                host_read(structure_pointer + 4*word_index, discarded);
            end else begin
                // Flush the path's last word while returning to commands,
                // before issuing the independently primed scalar reads.
                host_read(SPLIT_FIELDS && word_index == 63 ? 32'hF8001000 :
                          structure_pointer + 4*(word_index+1), response);
            end
            expected_word = 0;
            if (word_index < 64) begin
                received_path_words[word_index] = response;
                for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
                    if (word_index*4+byte_index < expected_path.len())
                        expected_word[31-byte_index*8 -: 8] = expected_path[word_index*4+byte_index];
                end
            end else if (word_index == 64) expected_word = wanted_flags;
            else expected_word = wanted_size;
            if (response !== expected_word)
                $fatal(1, "recovery structure word %0d expected %08x got %08x",
                       word_index, expected_word, response);
        end
        if (SPLIT_FIELDS) host_read(32'hF8001000, discarded);
        // Independent filesystem/slot association model. A successful create
        // binds the actual received path, not a canned expected reply. This
        // represents internally consistent host behavior, not a claim about
        // Pocket's undocumented zero-length durability behavior.
        path_matches = 1;
        for (word_index = 0; word_index < 64; word_index = word_index + 1)
            if (received_path_words[word_index] !== recovery_path_words[word_index]) path_matches = 0;
        if (result_code >= 8) model_result = result_code; // injected unknown result
        else if (wanted_flags == 3 && !recovery_disk_exists) begin
            model_result = 1;
            recovery_disk_exists = 1;
            recovery_slot_bound = 1;
            for (word_index = 0; word_index < 64; word_index = word_index + 1)
                recovery_path_words[word_index] = received_path_words[word_index];
            // Fault 3: the host leaves the new file at size zero, as the
            // Pocket did for a create-only open (12CD, C358).
            recovery_disk_size = RECOVERY_FAULT == 3 ? 32'd0 : wanted_size;
        end else if (recovery_disk_exists && path_matches) begin
            model_result = 0;
            recovery_slot_bound = 1;
        end else model_result = 3;
        if (model_result != result_code)
            $fatal(1, "independent recovery filesystem disagrees with requested result");
        if (model_result < 2) begin
            host_write(32'hF8002020, 32'd23);
            host_write(32'hF8002024, recovery_disk_size);
        end
        host_write(32'hF8001000, 32'h6F6B0000 | model_result);
    end
endtask

task recovery_get_name;
    integer word_index;
    reg [31:0] response_pointer, response_word;
    begin
        await_command(32'h636D0190);
        register_read(32'hF8001024, response_pointer);
        if (response_pointer != 32'hC0000000)
            $fatal(1, "backup Get Filename used wrong response pointer");
        if (!recovery_disk_exists || !recovery_slot_bound)
            $fatal(1, "backup Get Filename has no created slot association");
        host_write(32'hF8001000, 32'h62750000);
        for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
            response_word = recovery_path_words[word_index];
            // Change the final index digit from PRE0000 to PRE0001 only in
            // the returned association, never in the independently bound path.
            if (RECOVERY_FAULT == 1 && word_index == 7) response_word = response_word ^ 32'd1;
            host_write(response_pointer + word_index*4, response_word);
        end
        host_write(32'hF8001000, 32'h6F6B0000);
    end
endtask

task recovery_refused(input [3:0] wanted_error, input [3:0] wanted_stage,
                     input [3:0] wanted_seen, input [15:0] create_result);
    begin
        polls = 0;
        while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
        if (completions != before_completion + 1 || !failed || err != wanted_error ||
            restore_io_busy || debug_status[106:103] != wanted_stage)
            $fatal(1, "recovery association/full-result refusal failed: error=%h stage=%h",
                   err, debug_status[106:103]);
        if (debug_sequence !== {wanted_seen, (RECOVERY_FAULT == 3 ? 32'd0 : 32'hFFFFFFFF),
                                16'd3, create_result, 16'd0, 16'd0})
            $fatal(1, "recovery refusal lost full-width command history: %h", debug_sequence);
        if (recovery_writes || recovery_reads || recovery_opens != 2)
            $fatal(1, "recovery refusal performed forbidden later file I/O");
        tick(16);
        if (command.target_0[31:16] == 16'h636D || r_target_open || r_target_write || r_target_read)
            $fatal(1, "recovery refusal issued a subsequent command");
    end
endtask

task recovery_success;
    integer word_index;
    reg [31:0] transfer_pointer, response;
    begin : recovery_flow
        recovery_opens = 1; // The validated, absent-name probe above.
        recovery_writes = 0;
        recovery_reads = 0;
        recovery_disk_exists = 0;
        recovery_disk_size = 0;
        recovery_slot_bound = 0;
        host_write(32'hF8001000, 32'h6F6B0003);
        recovery_open(32'd3, 32'd8192, RECOVERY_FAULT == 2 ? 16'h0009 : 16'd1);
        if (RECOVERY_FAULT == 2) begin
            recovery_refused(4'd15, 4'd6, 4'b1100, 16'h0009);
            disable recovery_flow;
        end
        recovery_get_name();
        if (RECOVERY_FAULT == 1) begin
            recovery_refused(4'd14, 4'd14, 4'b1110, 16'd1);
            disable recovery_flow;
        end
        if (RECOVERY_FAULT == 3) begin
            recovery_refused(4'd9, 4'd3, 4'b1110, 16'd1);
            disable recovery_flow;
        end
        await_command(32'h636D0184);
        recovery_writes = recovery_writes + 1;
        register_read(32'hF8001024, response);
        if (response != 0) $fatal(1, "recovery write used nonzero file offset");
        register_read(32'hF8001028, transfer_pointer);
        if (transfer_pointer != 32'hA0000000) $fatal(1, "recovery write used wrong buffer");
        register_read(32'hF800102C, response);
        if (response != 8192) $fatal(1, "recovery write used wrong exact length");
        host_write(32'hF8001000, 32'h62750000);
        host_read(transfer_pointer, response);
        for (word_index = 0; word_index < 2048; word_index = word_index + 1) begin
            host_read(transfer_pointer + 4*(word_index+1), response);
            // The recovery payload goes out byte zero high, like the path
            // string and like every word APF delivers; the host writes the
            // same words back on reread.
            if (response !== swap(backup_word(word_index)))
                $fatal(1, "recovery payload word %0d expected %08x got %08x",
                       word_index, backup_word(word_index), response);
            recovery_disk[word_index] = response;
        end
        host_write(32'hF8001000, 32'h6F6B0000);
        recovery_open(32'd0, 32'd0, 16'd0);
        await_command(32'h636D0180);
        recovery_reads = recovery_reads + 1;
        register_read(32'hF8001024, response);
        if (response != 0) $fatal(1, "recovery reread used nonzero file offset");
        register_read(32'hF8001028, transfer_pointer);
        if (transfer_pointer != 32'hB0000000) $fatal(1, "recovery reread used wrong buffer");
        register_read(32'hF800102C, response);
        if (response != 8192) $fatal(1, "recovery reread used wrong exact length");
        input_count = 0;
        host_write(32'hF8001000, 32'h62750000);
        for (word_index = 0; word_index < 2048; word_index = word_index + 1)
            host_write(transfer_pointer + 4*word_index, recovery_disk[word_index]);
        host_write(32'hF8001000, 32'h6F6B0000);
        polls = 0;
        while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
        if (completions != before_completion + 1 || failed || err || restore_io_busy ||
            input_count != 2048 || recovery_opens != 3 || recovery_writes != 1 || recovery_reads != 1)
            $fatal(1, "full recovery command/SPI round trip did not complete");
        if (debug_sequence !== {4'b1110, 32'd8192, 16'd3, 16'd1, 16'd0, 16'd0})
            $fatal(1, "full recovery lost create association and command history");
    end
endtask
initial begin
    // Cyclone registers without explicit initializers power up at zero.
    // Model only that startup here, not a runtime reset or a command response.
    #1;
    spi_ss = 1; // reset the peripheral's asynchronous receive counter
    command.hstate = 0;
    command.tstate = 0;
    command.host_cmd_start = 0;
    command.target_0 = 0;
    command.idt.memory[4] = 21; command.idt.memory[5] = 64;
    command.idt.memory[6] = 22; command.idt.memory[7] = 8192;
    tick(8);
    reset = 0;
    for (endian_mode = 0; endian_mode < 2; endian_mode = endian_mode + 1) begin
        bridge_endian_little = endian_mode;
        tick(8);
        for (operation = 0; operation < 3; operation = operation + 1) begin
            host_read(32'h70000000, ignored_word);
            if (!dump_bridge_rd_hit) $fatal(1, "dumper held-response precondition missing");
            inject_active = INJECT_WORD;
            op = operation;
            before_completion = completions;
            start = 1;
            tick(1);
            start = 0;
            if (operation < 2) begin
                fixed_input();
            end else begin
            polls = 0;
            value = 0;
            while (value != 32'h636D0192 && polls < 20) begin
                register_read(32'hF8001000, value);
                polls = polls + 1;
            end
            if (value != 32'h636D0192)
                $fatal(1, "real command register did not publish open: observed=%h register=%h address=%h",
                       value, command.target_0, bridge_addr);
            register_read(32'hF8001020, value);
            if (value != 21 + operation) $fatal(1, "open command selected wrong slot");
            register_read(32'hF8001024, pointer);
            if (pointer != 32'h90000000) $fatal(1, "open command selected wrong struct pointer");
            host_write(32'hF8001000, 32'h62750000);
            // Chunk priming adds duplicate observed responses, but not bytes
            // to the host's retained structure. Sixteen-word chunks produce
            // 70 observations, as in the 2BDA screen. This is a compatible
            // hypothesis for the count, not a measured firmware read order.
            if (SPLIT_FIELDS) begin
                // A separate bulk path read and scalar field reads recreate
                // the 05AF repeat indices. The actual request order remains
                // a hypothesis: the screenshot records response counts only.
                host_read(pointer, prime_word);
                for (b = 0; b < 4; b = b + 1)
                    stale_path[b] = prime_word[31-b*8 -: 8];
                for (w = 0; w < 64; w = w + 1) begin
                    // Flush the last path word while returning to commands.
                    host_read(w == 63 ? 32'hF8001000 : pointer + 4*(w+1), value);
                    for (b = 0; b < 4; b = b + 1) begin
                        path[w*4+b] = value[31-b*8 -: 8];
                        // Deliberately wrong consumer: keeps the stale prime
                        // and discards the final response, with identical I/O.
                        if (w < 63) stale_path[(w+1)*4+b] = value[31-b*8 -: 8];
                    end
                end
                for (w = 64; w < 66; w = w + 1) begin
                    host_read(pointer + 4*w, ignored_word);
                    host_read(pointer + 4*w, value);
                    for (b = 0; b < 4; b = b + 1) path[w*4+b] = value[b*8 +: 8];
                    host_read(pointer + 4*w, ignored_word);
                end
                host_read(32'hF8001000, ignored_word);
                if ({stale_path[0],stale_path[1],stale_path[2],stale_path[3]} !== prime_word ||
                    {stale_path[0],stale_path[1],stale_path[2],stale_path[3]} === 32'h2F417373)
                    $fatal(1, "stale-prime control did not retain the previous command response");
                for (b = 4; b < 256; b = b + 1)
                    if (stale_path[b] !== path[b-4])
                        $fatal(1, "stale-prime control did not demonstrate a four-byte shift");
            end else for (chunk = 0; chunk < 66; chunk = chunk + CHUNK_WORDS) begin
                host_read(pointer + chunk*4, ignored_word);
                chunk_end = chunk + CHUNK_WORDS;
                if (chunk_end > 66) chunk_end = 66;
                for (w = chunk; w < chunk_end; w = w + 1) begin
                    host_read(pointer + 4*(w+1), value);
                    for (b = 0; b < 4; b = b + 1)
                        path[w*4+b] = w < 64 ? value[31-b*8 -: 8] : value[b*8 +: 8];
                end
            end
            expected_path = operation == 0 ? "/Assets/carttools/common/RESTORE.meta" :
                            operation == 1 ? "/Assets/carttools/common/RESTORE.sav" :
                                             "/Assets/carttools/common/PRE0000.sav";
            // Independently follows the hardware-proven pocket-pcengine
            // Open File path representation: high byte first for strings,
            // native numeric words for flags and size. Save bytes use their
            // separate low-first outbound data-transfer convention.
            path_bad = 0;
            for (b = 0; b < 264; b = b + 1) begin
                expected = b < expected_path.len() ? expected_path[b] : 8'd0;
                if (INJECT_WORD && b == 20) expected = expected ^ 8'd1;
                if (path[b] !== expected && BAD_PATH_ORDER) path_bad = 1;
                else if (path[b] !== expected)
                    $fatal(1, "delivered open structure byte %0d expected %02x got %02x", b, expected, path[b]);
            end
            if (BAD_PATH_ORDER && !path_bad)
                $fatal(1, "opposite-order path unexpectedly passed independent host parser");
            if (INJECT_WORD) begin
                if (!observed_bad || observed_bad_index != 5 ||
                    observed_bad_word != 32'h6C6D6F6E || observed_bad_expected != 32'h6D6D6F6E)
                    $fatal(1, "observer missed actual selected-response corruption");
                inject_active = 0;
                host_read(pointer + 5*4, ignored_word);
                host_read(pointer + 6*4, value);
                if (value != 32'h6D6D6F6E || observed_path[20*8 +: 32] != swap(value))
                    $fatal(1, "clean reread did not replace path word");
                if (!observed_bad || observed_bad_word != 32'h6C6D6F6E || observed_bad_index != 5)
                    $fatal(1, "clean reread erased the first bad response");
            end
            if (!BAD_PATH_ORDER) begin
            if (debug_status[108:107] != operation ||
                debug_status[102:96] != 66 + EXPECTED_REPEATS + INJECT_WORD ||
                debug_status[95:64] != 32'h2F417373)
                $fatal(1, "refusal lost delivered-path evidence: op=%h reads=%h first=%h",
                       debug_status[108:107], debug_status[102:96], debug_status[95:64]);
            if (observed_unique != 66 || observed_repeats != EXPECTED_REPEATS + INJECT_WORD ||
                observed_bad != INJECT_WORD || observed_size != 0 || observed_path_seen != 10'h3FF)
                $fatal(1, "full response trace disagrees with transferred structure");
            for (b = 0; b < 40; b = b + 1)
                if (observed_path[b*8 +: 8] !== (INJECT_WORD && b == 20 ? path[b] ^ 8'd1 : path[b]))
                    $fatal(1, "observed path byte %0d differs from host byte", b);
            if (!SPLIT_FIELDS && CHUNK_WORDS == 16 && observed_repeat_indices != {7'd64,7'd48,7'd32,7'd16})
                $fatal(1, "chunk priming did not retain repeated indices");
            if (SPLIT_FIELDS && observed_repeat_indices != {7'd65,7'd65,7'd64,7'd64})
                $fatal(1, "split path and scalar reads did not reproduce 05AF repeat indices");
            end
            if (RECOVERY_SUCCESS && !BAD_PATH_ORDER) recovery_success();
            else begin
                // Normal refusal is synthetic. BAD_PATH_ORDER instead derives
                // this refusal from the independent high-first host parser.
                host_write(32'hF8001000, 32'h6F6B0004);
                polls = 0;
                while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
                if (completions != before_completion + 1 || !failed || err != 4 || restore_io_busy ||
                    r_target_write || r_target_read || r_target_open)
                    $fatal(1, "real command refusal did not reach file-service result without further I/O");
                if (BAD_PATH_ORDER) begin
                    tick(16);
                    if (command.target_0[31:16] == 16'h636D)
                        $fatal(1, "bad path refusal allowed another recovery command");
                end
            end
            end
            tick(4);
            // End the optional clean reread's pipeline while the service is
            // idle, so its held word is not counted in the next operation.
            host_read(32'hF8001000, ignored_word);
        end
    end
    $display("TB PASS: restore bridge command integration (chunk=%0d SPI=%0d split=%0d success=%0d badpath=%0d recoveryfault=%0d)",
             CHUNK_WORDS, USE_SPI, SPLIT_FIELDS, RECOVERY_SUCCESS, BAD_PATH_ORDER, RECOVERY_FAULT);
    $finish;
end
initial begin #100000000; $fatal(1, "restore bridge watchdog"); end
endmodule

// Vendor RAM replacement only. Match mf_datatable's 256-word depth and
// registered read outputs on both ports. The command RTL is unchanged.
module mf_datatable (
    input wire [7:0] address_a, address_b,
    input wire clock_a, clock_b,
    input wire [31:0] data_a, data_b,
    input wire wren_a, wren_b,
    output reg [31:0] q_a, q_b
);
reg [31:0] memory [0:255];
reg [31:0] read_a, read_b;
always @(posedge clock_a) begin
    if (wren_a) memory[address_a] <= data_a;
    read_a <= wren_a ? data_a : memory[address_a];
    q_a <= read_a;
end
always @(posedge clock_b) begin
    if (wren_b) memory[address_b] <= data_b;
    read_b <= wren_b ? data_b : memory[address_b];
    q_b <= read_b;
end
endmodule
`default_nettype wire
