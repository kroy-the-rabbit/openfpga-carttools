// Harness compiled by check_restore_bridge.py, with actual core_top muxes.
`default_nettype none
`timescale 1ns/1ps
module tb_restore_bridge #(
    parameter integer CHUNK_WORDS = 66,
    parameter integer USE_SPI = 0,
    parameter integer INJECT_WORD = 0,
    parameter integer SPLIT_FIELDS = 0
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
     (bridge_endian_little ? 32'h01000000 : 32'h00000001) : 32'd0);
wire restore_bridge_rd_hit, restore_io_busy, done, failed;
wire [3:0] err;
wire [108:0] debug_status;
wire [475:0] debug_detail;
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
wire [10:0] input_index;
wire [31:0] input_data;
integer input_count = 0;
function [31:0] payload_word(input integer index);
    payload_word = 32'h873421AD ^ (index * 32'h05130711);
endfunction
always @(posedge clk) if (input_we) begin
    if (input_index != input_count || input_data !== payload_word(input_count))
        $fatal(1, "real bridge input payload arrived in wrong byte order or sequence");
    input_count = input_count + 1;
end
wire target_dataslot_read, target_dataslot_write, target_dataslot_openfile;
wire target_dataslot_getfile, target_dataslot_flush, target_dataslot_done;
wire [2:0] target_dataslot_err;
wire [15:0] target_dataslot_id;
wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
wire [31:0] target_buffer_param_struct, target_buffer_resp_struct;
// Idle dumper values are intentionally different from restore's parameters.
wire d_target_write = 0, d_target_open = 0, d_target_get = 0, d_target_flush = 0;
wire [15:0] d_target_id = 20;
wire [31:0] d_target_offset = 32'hCAFE, d_target_bridge = 32'h60000000;
wire [31:0] d_target_length = 32'h8000, d_target_struct = 32'h70000000;
wire [31:0] d_target_response = 32'h80000000, dump_bridge_rd_data = 32'hBAD0BAD0;
wire dump_bridge_rd_hit = 0;
integer completions = 0;
always @(posedge clk) if (done) completions = completions + 1;
// TOP_MUX

restore_file_io #(.TIMEOUT_CYCLES(1000000)) files (
    .clk(clk), .reset(reset), .start(start), .op(op), .busy(restore_io_busy),
    .done(done), .failed(failed), .err(err), .debug_status(debug_status),
    .debug_detail(debug_detail), .observed_bridge_data(bridge_rd_data),
    .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_endian_little(bridge_endian_little),
    .bridge_rd_data(restore_bridge_rd_data), .bridge_rd_hit(restore_bridge_rd_hit),
    .backup_rd_q(32'h12345678), .datatable_addr(table_address), .datatable_q(table_data),
    .target_dataslot_read(r_target_read), .target_dataslot_write(r_target_write),
    .target_dataslot_openfile(r_target_open), .target_dataslot_id(r_target_id),
    .target_dataslot_getfile(r_target_get), .target_buffer_resp_struct(r_target_response),
    .input_we(input_we), .input_index(input_index), .input_data(input_data),
    .target_dataslot_slotoffset(r_target_offset), .target_dataslot_bridgeaddr(r_target_bridge),
    .target_dataslot_length(r_target_length), .target_buffer_param_struct(r_target_struct),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err)
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
                    stale_path[b] = prime_word[b*8 +: 8];
                for (w = 0; w < 64; w = w + 1) begin
                    // Flush the last path word while returning to commands.
                    host_read(w == 63 ? 32'hF8001000 : pointer + 4*(w+1), value);
                    for (b = 0; b < 4; b = b + 1) begin
                        path[w*4+b] = value[b*8 +: 8];
                        // Deliberately wrong consumer: keeps the stale prime
                        // and discards the final response, with identical I/O.
                        if (w < 63) stale_path[(w+1)*4+b] = value[b*8 +: 8];
                    end
                end
                for (w = 64; w < 66; w = w + 1) begin
                    host_read(pointer + 4*w, ignored_word);
                    host_read(pointer + 4*w, value);
                    for (b = 0; b < 4; b = b + 1) path[w*4+b] = value[b*8 +: 8];
                    host_read(pointer + 4*w, ignored_word);
                end
                host_read(32'hF8001000, ignored_word);
                if ({stale_path[3],stale_path[2],stale_path[1],stale_path[0]} !== prime_word ||
                    {stale_path[3],stale_path[2],stale_path[1],stale_path[0]} === 32'h7373412F)
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
                    for (b = 0; b < 4; b = b + 1) path[w*4+b] = value[b*8 +: 8];
                end
            end
            expected_path = operation == 0 ? "/Assets/carttools/common/RESTORE.meta" :
                            operation == 1 ? "/Assets/carttools/common/RESTORE.sav" :
                                             "/Assets/carttools/common/PRE0000.sav";
            for (b = 0; b < 264; b = b + 1) begin
                expected = b < expected_path.len() ? expected_path[b] : 8'd0;
                if (INJECT_WORD && b == 20) expected = expected ^ 8'd1;
                if (path[b] !== expected)
                    $fatal(1, "delivered open structure byte %0d expected %02x got %02x", b, expected, path[b]);
            end
            if (INJECT_WORD) begin
                if (!observed_bad || observed_bad_index != 5 ||
                    observed_bad_word != 32'h6E6F6D6C || observed_bad_expected != 32'h6E6F6D6D)
                    $fatal(1, "observer missed actual selected-response corruption");
                inject_active = 0;
                host_read(pointer + 5*4, ignored_word);
                host_read(pointer + 6*4, value);
                if (value != 32'h6E6F6D6D || observed_path[20*8 +: 32] != value)
                    $fatal(1, "clean reread did not replace path word");
                if (!observed_bad || observed_bad_word != 32'h6E6F6D6C || observed_bad_index != 5)
                    $fatal(1, "clean reread erased the first bad response");
            end
            // This is an injected firmware refusal, not a reproduced parser.
            host_write(32'hF8001000, 32'h6F6B0004);
            polls = 0;
            while (completions == before_completion && polls < 20) begin tick(1); polls = polls + 1; end
            if (completions != before_completion + 1 || !failed || err != 4 || restore_io_busy)
                $fatal(1, "real command refusal did not reach file-service result");
            if (debug_status[108:107] != operation ||
                debug_status[102:96] != 66 + EXPECTED_REPEATS + INJECT_WORD ||
                debug_status[95:64] != 32'h7373412F)
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
            tick(4);
            // End the optional clean reread's pipeline while the service is
            // idle, so its held word is not counted in the next operation.
            host_read(32'hF8001000, ignored_word);
        end
    end
    $display("TB PASS: restore bridge command integration (chunk=%0d SPI=%0d split=%0d)",
             CHUNK_WORDS, USE_SPI, SPLIT_FIELDS);
    $finish;
end
initial begin #20000000; $fatal(1, "restore bridge watchdog"); end
endmodule

// Vendor RAM replacement only. The command RTL itself is unchanged.
module mf_datatable (
    input wire [9:0] address_a, address_b,
    input wire clock_a, clock_b,
    input wire [31:0] data_a, data_b,
    input wire wren_a, wren_b,
    output reg [31:0] q_a, q_b
);
reg [31:0] memory [0:1023];
always @(posedge clock_a) begin
    if (wren_a) memory[address_a] <= data_a;
    q_a <= memory[address_a];
end
always @(posedge clock_b) begin
    if (wren_b) memory[address_b] <= data_b;
    q_b <= memory[address_b];
end
endmodule
`default_nettype wire
