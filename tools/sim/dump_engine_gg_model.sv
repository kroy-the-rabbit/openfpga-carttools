// SOURCES: src/fpga/services/dump/dump_engine.sv src/fpga/services/dump/dump_buffer.sv src/fpga/services/dump/dump_path_gen.sv src/fpga/services/dump/dump_chunk_src.sv src/fpga/services/dump/dump_checksum.sv src/fpga/services/dump/apf_file_writer.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_dump_gba.sv src/fpga/services/dump/cart_dump_gg.sv src/fpga/services/dump/cart_save_gb.sv src/fpga/services/dump/cart_save_gba.sv src/fpga/services/dump/cart_save_gba_eeprom.sv src/fpga/services/dump/gba_eeprom_io.sv src/fpga/services/dump/dump_crc32.sv src/fpga/apf/common.v
// Complete GG captures, real reader and dual-clock buffer/bridge, a Sega slot-2
// bus model and an APF filesystem that refuses modification of occupied names.
`default_nettype none
`timescale 1ns/1ps
// Independent complete-image scenarios share the same actual engine, Sega
// model, APF bridge/filesystem model, and assertions. Separate top-level
// benches let the runner overlap these expensive simulations.
// CASE 0: 256KiB plus cancellation/session loss/refusals.
// CASE 1: 512KiB, opposite bridge byte order, occupied smaller capture.
// CASE 2: reread mismatch, APF result failures, partial capture, full recovery.
// CASE 3: short APF serialization regression, split scalar reads, both bridge
// endian modes, and native settings that must not change the GG contract.
module dump_engine_gg_model #(parameter integer CASE = 0);
reg clk_sys = 0, clk_74a = 0;
always #5 clk_sys = ~clk_sys;
always #6.734 clk_74a = ~clk_74a;
reg reset = 1, start = 0, cancel = 0, powered = 1, save_mode = 0;
reg adapter_present = 1;
reg [31:0] size = 32'h40000;
reg native_byte_order = 1;
reg [2:0] native_path_style = 0;
wire busy, done, failed, sum_checked, pair_checked;
wire [2:0] err;
wire [1:0] want_mode;
wire [31:0] total_bytes, crc, verify_crc;
wire verify_checked, verify_ok, no_open;
wire [127:0] out_name;
wire [31:0] out_ext;
wire [4:0] out_name_len;
wire [2:0] out_ext_len;
wire out_name_valid;
wire gb_req, gba_req, gg_req, gg_wr;
wire [15:0] gg_addr;
wire [7:0] gg_wdata;
reg [7:0] gg_rdata = 0;
reg gg_done = 0, gg_busy = 0;
reg [31:0] bridge_addr = 0;
reg bridge_rd = 0, bridge_endian_little = 1;
wire [31:0] bridge_data;
wire bridge_hit;
wire t_open, t_write, t_flush;
wire [15:0] t_id;
wire [31:0] t_offset, t_length, t_bridgeaddr, t_struct;
reg t_done = 1;
reg [15:0] t_result = 0;

dump_engine #(.WAKE_CYCLES(8)) dut (
    .clk_sys(clk_sys), .reset_sys(reset), .start(start), .cancel(cancel),
    .selftest(1'b0), .save_mode(save_mode), .byte_order(native_byte_order),
    .path_style(native_path_style),
    .title("NOT_A_GG_TITLE "), .cart_kind(3'd4), .cart_type(8'h03),
    .rom_size_code(8'd0), .ram_size_code(8'd2), .rom_source(2'd2),
    .gba_size_bytes(32'd0), .gg_size_bytes(size), .gba_save_size_bytes(32'd0),
    .gg_connected(powered && adapter_present),
    .gba_save_is_eeprom(1'b0), .gba_save_addr_bits(4'd0), .cart_mode(1'b0),
    .gg_verify_checked(verify_checked), .gg_verify_ok(verify_ok),
    .gg_verify_crc32(verify_crc), .busy(busy), .done(done), .failed(failed),
    .err(err), .total_bytes(total_bytes), .crc32(crc), .sum_checked(sum_checked),
    .pair_checked(pair_checked), .want_mode(want_mode), .mode_ready(1'b1),
    .cart_powered(powered), .out_name(out_name), .out_name_len(out_name_len),
    .out_ext(out_ext), .out_ext_len(out_ext_len), .out_name_valid(out_name_valid),
    .no_open(no_open), .bus_req(gb_req), .bus_rdata(8'd0), .bus_done(1'b0),
    .bus_busy(1'b0), .gba_req(gba_req), .gba_rdata(32'd0), .gba_done(1'b0),
    .gba_busy(1'b0), .gg_req(gg_req), .gg_wr(gg_wr), .gg_addr(gg_addr),
    .gg_wdata(gg_wdata), .gg_rdata(gg_rdata), .gg_done(gg_done), .gg_busy(gg_busy),
    .clk_74a(clk_74a), .reset_74a(reset), .bridge_addr(bridge_addr),
    .bridge_rd(bridge_rd), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
    .bridge_endian_little(bridge_endian_little), .bridge_rd_data(bridge_data),
    .bridge_rd_hit(bridge_hit), .probe_start(1'b0), .probe_slot(16'd0),
    .target_dataslot_write(t_write), .target_dataslot_openfile(t_open),
    .target_dataslot_flush(t_flush), .target_dataslot_id(t_id),
    .target_dataslot_slotoffset(t_offset), .target_dataslot_bridgeaddr(t_bridgeaddr),
    .target_dataslot_length(t_length), .target_buffer_param_struct(t_struct),
    .target_dataslot_done(t_done), .target_dataslot_err(t_result[2:0]),
    .target_dataslot_result(t_result)
);

// The test ROM encodes bank and byte address. Slot 0/1 are deliberately not
// modelled as switchable; all ROM reads must use slot 2, including bank zero.
function [7:0] content(input integer linear);
    content = (linear ^ (linear >> 8) ^ ((linear >> 14) * 8'hB7)) & 255;
endfunction
function [31:0] crc_byte(input [31:0] old, input [7:0] data);
    reg [31:0] c;
    integer bitno;
    begin
        c = old ^ data;
        for (bitno = 0; bitno < 8; bitno = bitno + 1)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
        crc_byte = c;
    end
endfunction
function [31:0] expected_crc(input integer bytes);
    integer i;
    reg [31:0] c;
    begin
        c = 32'hFFFFFFFF;
        for (i = 0; i < bytes; i = i + 1) c = crc_byte(c, content(i));
        expected_crc = ~c;
    end
endfunction
integer bus_wait = 0, bank = 0, reads = 0, mapper_writes = 0, passes = 0;
integer test_stage = 0;
integer linear;
reg latched_wr = 0;
reg [15:0] latched_addr = 0;
reg [7:0] latched_data = 0;
reg corrupt_second = 0;
reg [1:0] old_mode = 0;
always @(posedge clk_sys) begin
    gg_done <= 0;
    old_mode <= want_mode;
    if (!reset && (gb_req || gba_req)) $fatal(1, "GG started a native reader");
    if (!reset && (sum_checked || pair_checked)) $fatal(1, "GG inherited GB verification");
    if (!reset && no_open) $fatal(1, "GG used unnamed-slot fallback");
    if (!reset && old_mode == 2'b11 && want_mode != 2'b11 && gg_busy && powered && adapter_present)
        $fatal(1, "GG mode released while transaction held write data");
    if (reset || !powered || !adapter_present) begin
        gg_busy <= 0;
        bus_wait <= 0;
    end else if (gg_req && !gg_busy) begin
        if (want_mode != 2'b11) $fatal(1, "GG request without connector ownership");
        gg_busy <= 1;
        latched_wr <= gg_wr;
        latched_addr <= gg_addr;
        latched_data <= gg_wdata;
        bus_wait <= 2 + gg_addr[2:0];
    end else if (gg_busy) begin
        if (bus_wait != 0) bus_wait <= bus_wait - 1;
        else begin
            if (latched_wr) begin
                mapper_writes = mapper_writes + 1;
                case (latched_addr)
                    16'hFFFC: begin
                        if (latched_data != 0) $fatal(1, "EEPROM enabled");
                        passes = passes + 1;
                    end
                    16'hFFFD: if (latched_data != 0) $fatal(1, "unexpected slot 0 write");
                    16'hFFFE: if (latched_data != 1) $fatal(1, "unexpected slot 1 write");
                    16'hFFFF: bank = latched_data;
                    default: $fatal(1, "save/EEPROM data write during ROM capture");
                endcase
            end else begin
                if (latched_addr[15:14] != 2'b10)
                    $fatal(1, "ROM reader used a fixed slot");
                linear = bank * 16384 + latched_addr[13:0];
                if (linear >= size) $fatal(1, "reader exceeded selected ROM length");
                gg_rdata <= content(linear) ^
                    ((corrupt_second && passes == 2 && linear == 16401) ? 8'h04 : 8'h00);
                reads = reads + 1;
                if ((reads & 65535) == 0) begin
                    $display("GG engine case %0d stage %0d: reads=%0d pass=%0d file_bytes=%0d at %0t",
                             CASE, test_stage, reads, passes, file_bytes, $time);
                    $fflush();
                end
            end
            gg_done <= 1;
            gg_busy <= 0;
        end
    end
end

// Reproduce the APF bridge's standing response, read pulse, and one-word
// transaction lag. A direct hierarchical buffer read would miss CDC/order bugs.
task bridge_xfer(input [31:0] addr, output reg [31:0] data, input check);
begin
    @(negedge clk_74a); bridge_addr = addr;
    repeat (4) @(negedge clk_74a);
    data = bridge_data;
    if (check && !bridge_hit) $fatal(1, "bridge window did not answer");
    @(negedge clk_74a); bridge_rd = 1;
    @(negedge clk_74a); bridge_rd = 0;
    @(negedge clk_74a);
end
endtask
function [31:0] native_word(input [31:0] data);
    native_word = bridge_endian_little ? {data[7:0],data[15:8],data[23:16],data[31:24]} : data;
endfunction
function integer hexval(input [7:0] ch);
begin
    if (ch >= "0" && ch <= "9") hexval = ch - "0";
    else if (ch >= "A" && ch <= "F") hexval = ch - "A" + 10;
    else begin hexval = 0; $fatal(1, "invalid filename index digit"); end
end
endfunction
localparam [199:0] PREFIX = "/Assets/carttools/common/";
reg [7:0] path [0:255];
reg [7:0] file_data [0:524287];
reg occupied [0:15];
integer lengths [0:15];
integer opens = 0, creates = 0, writes = 0, file_bytes = 0, active_file = -1;
integer name_index, flags, declared_size, j, wordno, lane;
integer override_probe = -1, override_create = -1, fail_write_at = -1;
reg [31:0] raw, host, discarded;
integer last_reads = 0, last_writes = 0, last_opens = 0, last_mapper_writes = 0;
integer stalled_cycles = 0;
// Normal cartridge beats take fewer than twenty clocks and even a complete
// APF chunk transfer takes fewer than 20,000. A quiet 100,000 clocks while
// busy is a stuck handshake, not a long full-image pass. Preserve state in
// the failure so a deadlock is distinguishable from host runtime limits.
always @(posedge clk_sys) begin
    if (!busy || reset || reads != last_reads || writes != last_writes ||
        opens != last_opens || mapper_writes != last_mapper_writes) stalled_cycles = 0;
    else stalled_cycles = stalled_cycles + 1;
    last_reads = reads;
    last_writes = writes;
    last_opens = opens;
    last_mapper_writes = mapper_writes;
    if (stalled_cycles == 100000) begin
        $display("GG engine stalled: case=%0d stage=%0d ss=%0d reader=%0d writer=%0d reads=%0d writes=%0d opens=%0d file_bytes=%0d gg_busy=%b gg_req=%b gg_done=%b",
                 CASE, test_stage, dut.ss, dut.reader_gg.state, dut.writer.state,
                 reads, writes, opens, file_bytes, gg_busy, gg_req, gg_done);
        $fflush();
        $fatal(1, "GG engine made no cartridge or file progress for 100000 clocks");
    end
end
initial begin
    forever begin
        @(posedge clk_74a);
        if (t_flush) $fatal(1, "GG issued disabled APF flush");
        if (t_open) begin
            t_done = 0;
            opens = opens + 1;
            bridge_xfer(t_struct, raw, 0);
            for (wordno = 0; wordno < 66; wordno = wordno + 1) begin
                if (CASE == 3 && wordno >= 64) begin
                    // Hardware reads these as separate numeric words, not
                    // as four little-endian bytes copied from the path.
                    bridge_xfer(t_struct + wordno*4, discarded, 0);
                    bridge_xfer(t_struct + wordno*4, raw, 1);
                    bridge_xfer(t_struct + wordno*4, discarded, 1);
                end else begin
                    // Flush the final path response before independently
                    // priming the scalar fields, as the restore host does.
                    bridge_xfer(CASE == 3 && wordno == 63 ? 32'hF8001000 :
                                t_struct + (wordno+1)*4, raw, 1);
                end
                host = native_word(raw);
                if (wordno == 0 && host !== 32'h2F417373)
                    $fatal(1, "APF path first word must be /Ass in SPI order: got %08h", host);
                if (wordno < 64) begin
                    // Independent firmware byte-buffer interpretation,
                    // matching the hardware-tested restore command path.
                    for (lane = 0; lane < 4; lane = lane + 1)
                        path[wordno*4+lane] = host[31-lane*8 -: 8];
                end else if (wordno == 64) flags = host;
                else declared_size = host;
            end
            for (j = 0; j < 25; j = j + 1)
                if (path[j] !== PREFIX[199-j*8 -: 8]) $fatal(1, "wrong GG directory");
            if ({path[25],path[26],path[31],path[32],path[33],path[34]} !== {"GG.gg",8'd0})
                $fatal(1, "wrong GG filename/extension/terminator");
            for (j = 35; j < 256; j = j + 1)
                if (path[j] !== 0) $fatal(1, "GG path padding was not zero");
            name_index = hexval(path[27])*4096 + hexval(path[28])*256 + hexval(path[29])*16 + hexval(path[30]);
            if (name_index >= 16) $fatal(1, "allocator skipped available names");
            if (flags == 0) begin
                if (declared_size != 0) $fatal(1, "existence probe supplied a resize");
                t_result = override_probe >= 0 ? override_probe : occupied[name_index] ? 0 : 3;
            end else if (flags == 3) begin
                if (override_create >= 0) t_result = override_create;
                else begin
                    if (occupied[name_index]) $fatal(1, "allocator resized an existing capture");
                    if (declared_size !== size) $fatal(1, "wrong GG declared file length");
                    occupied[name_index] = 1;
                    active_file = name_index;
                    lengths[name_index] = declared_size;
                    creates = creates + 1;
                    t_result = 1;
                end
            end else $fatal(1, "unexpected GG open flags");
            t_done = 1;
        end else if (t_write) begin
            t_done = 0;
            if (active_file < 2 || t_id != 20) $fatal(1, "write did not own a new GG file");
            if (t_offset !== file_bytes || t_length != 4096) $fatal(1, "wrong GG chunk placement");
            repeat (17) @(negedge clk_74a); // consumer stalls must preserve stream
            if (writes == fail_write_at) t_result = 5;
            else begin
                bridge_xfer(t_bridgeaddr, raw, 0);
                for (wordno = 0; wordno < t_length/4; wordno = wordno + 1) begin
                    bridge_xfer(t_bridgeaddr + (wordno+1)*4, raw, 1);
                    host = native_word(raw);
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        // The 772B recovery preflight measured this same
                        // high-byte-first convention for outgoing payloads.
                        if (host[31-lane*8 -: 8] !== content(file_bytes))
                            $fatal(1, "APF payload byte %0d differs from ROM: word %08h", file_bytes, host);
                        file_data[file_bytes] = host[31-lane*8 -: 8];
                        file_bytes = file_bytes + 1;
                    end
                end
                t_result = 0;
            end
            writes = writes + 1;
            t_done = 1;
        end
    end
end

task prepare;
begin
    repeat (8) @(negedge clk_sys);
    reads = 0; mapper_writes = 0; passes = 0;
    opens = 0; creates = 0; writes = 0; file_bytes = 0; active_file = -1;
    override_probe = -1; override_create = -1; fail_write_at = -1;
    cancel = 0; corrupt_second = 0;
    test_stage = test_stage + 1;
end
endtask
task launch;
begin
    $display("GG engine case %0d stage %0d start: size=%0d corrupt=%b probe_result=%0d create_result=%0d fail_write=%0d save=%b at %0t",
             CASE, test_stage, size, corrupt_second, override_probe, override_create,
             fail_write_at, save_mode, $time);
    $fflush();
    @(negedge clk_sys); start = 1;
    @(negedge clk_sys); start = 0;
    if (!save_mode && total_bytes !== size)
        $fatal(1, "GG start retained the previous capture's selected length");
end
endtask
task finish;
begin
    wait(done);
    @(negedge clk_sys);
    if (want_mode != 0 || gg_busy) $fatal(1, "completion did not drain connector");
    if (lengths[0] != 7 || lengths[1] != 13) $fatal(1, "protected files changed");
    $display("GG engine case %0d stage %0d done: failed=%b err=%0d reads=%0d file_bytes=%0d file=%0d checked=%b agrees=%b at %0t",
             CASE, test_stage, failed, err, reads, file_bytes, active_file,
             verify_checked, verify_ok, $time);
    $fflush();
end
endtask
task check_capture(input integer expected_name);
begin
    if (failed || !verify_checked || !verify_ok || crc !== expected_crc(size) || verify_crc !== crc)
        $fatal(1, "GG complete capture verification failed");
    if (active_file != expected_name || file_bytes != size || creates != 1 || reads != size*2)
        $fatal(1, "wrong allocated file or number of emitted/read bytes");
    if (mapper_writes != 8 + 2*(size/16384)) $fatal(1, "wrong number of mapper operations");
    if (!out_name_valid || out_name_len != 6 || out_ext !== ".gg " || out_ext_len != 3)
        $fatal(1, "wrong displayed GG output name");
end
endtask

initial begin
    for (j = 0; j < 16; j = j + 1) begin occupied[j] = 0; lengths[j] = 0; end
    occupied[0] = 1; lengths[0] = 7;
    occupied[1] = 1; lengths[1] = 13;
    // Prior captures in the other independent benches are existing-file
    // fixtures here. The APF model forbids resizing any occupied name.
    if (CASE == 1 || CASE == 2) begin
        occupied[2] = 1; lengths[2] = 32'h40000;
    end
    if (CASE == 2) begin
        occupied[3] = 1; lengths[3] = 32'h80000;
    end
    repeat (8) @(negedge clk_sys);
    reset = 0;
    if (CASE == 3) begin
        // Keep each capture deliberately short: one complete chunk reaches
        // the modeled card, then a host error ends the transfer. This gives
        // fast negative controls without replacing any full-image coverage.
        prepare;
        fail_write_at = 1;
        launch; finish;
        if (!failed || err != 5 || opens != 4 || creates != 1 || writes != 2 ||
            file_bytes != 4096 || active_file != 2 || !occupied[2])
            $fatal(1, "short APF capture did not preserve its first chunk");
        if ({file_data[0], file_data[1], file_data[2], file_data[3]} !== 32'h00010203)
            $fatal(1, "short APF capture omitted the non-palindromic word");

        prepare;
        bridge_endian_little = 0;
        native_byte_order = 0;
        native_path_style = 7;
        fail_write_at = 1;
        launch; finish;
        if (!failed || err != 5 || opens != 5 || creates != 1 || writes != 2 ||
            file_bytes != 4096 || active_file != 3 || !occupied[2] || !occupied[3])
            $fatal(1, "GG APF contract depended on native settings or bridge byte order");
        $display("TB PASS: tb_dump_engine_gg_apf");
        $finish;
    end else if (CASE == 0) begin
        prepare; launch; finish; check_capture(2);
    end else if (CASE == 1) begin
        prepare;
        size = 32'h80000;
        bridge_endian_little = 0;
        launch; finish; check_capture(3);
        if (lengths[2] != 32'h40000) $fatal(1, "second dump resized first dump");
        $display("TB PASS: tb_dump_engine_gg_512");
        $finish;
    end else if (CASE != 2) $fatal(1, "unsupported GG integration scenario");

    if (CASE == 2) begin
    bridge_endian_little = 0;
    prepare;
    size = 32'h40000;
    corrupt_second = 1;
    launch; finish;
    if (!failed || !verify_checked || verify_ok || crc !== expected_crc(size) ||
        file_bytes != size || active_file != 4 || reads != size*2)
        $fatal(1, "second-pass mismatch lost or rewrote the first capture");

    prepare;
    override_probe = 16'h000B;
    launch; finish;
    if (!failed || opens != 1 || creates != 0 || writes != 0)
        $fatal(1, "aliased missing-file result authorized creation");

    prepare;
    override_create = 16'h0009;
    launch; finish;
    if (!failed || creates != 0 || writes != 0)
        $fatal(1, "aliased created-file result authorized writes");

    prepare;
    fail_write_at = 1;
    launch; finish;
    if (!failed || writes != 2 || file_bytes != 4096 || active_file != 5 || !occupied[5])
        $fatal(1, "partial GG file was retried or discarded");

    prepare;
    launch; finish; check_capture(6);
    if (!occupied[4] || !occupied[5]) $fatal(1, "failed captures were not preserved");
    $display("TB PASS: tb_dump_engine_gg_recovery");
    $finish;
    end

    prepare;
    // Retain the same-engine length transition even though complete256/512
    // captures now run independently. Cancellation needs no extra image pass.
    size = 32'h80000;
    launch;
    wait(gg_busy && gg_wr);
    @(negedge clk_sys); cancel = 1;
    finish;
    if (!failed || writes != 0 || reads != 0) $fatal(1, "mapper cancellation did not drain");
    cancel = 0;

    prepare;
    size = 32'h40000;
    launch;
    wait(reads > 200 && gg_busy);
    @(negedge clk_sys); powered = 0;
    finish;
    if (!failed || err != 7 || gg_busy) $fatal(1, "power loss stranded GG capture");
    powered = 1;

    // Revocation of the physical adapter session resets the bus, so no
    // completion reply can be expected for either accepted or pending work.
    prepare;
    launch;
    wait(gg_busy && gg_wr);
    @(negedge clk_sys); adapter_present = 0;
    finish;
    if (!failed || err != 7 || writes != 0) $fatal(1, "disconnect during mapper write hung");
    adapter_present = 1;

    prepare;
    launch;
    wait(gg_req && !gg_wr);
    @(negedge clk_sys); adapter_present = 0;
    finish;
    if (!failed || err != 7 || writes != 0) $fatal(1, "disconnect during pending read hung");
    adapter_present = 1;

    prepare;
    size = 32'h20000;
    launch; finish;
    if (!failed || opens != 0 || gg_busy || mapper_writes != 0)
        $fatal(1, "unsupported GG length reached cartridge or file");

    prepare;
    size = 32'h40000; save_mode = 1;
    launch; finish;
    if (!failed || opens != 0 || mapper_writes != 0) $fatal(1, "GG save mode reached a reader");

    $display("TB PASS: tb_dump_engine_gg");
    $finish;
end
initial begin
    #1500000000;
    $fatal(1, "GG dump integration watchdog");
end
endmodule
`default_nettype wire
