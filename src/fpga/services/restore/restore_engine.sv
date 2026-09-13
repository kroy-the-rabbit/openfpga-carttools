// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// Restore transaction for two save geometries: MBC1 + 8 KiB RAM (type 03,
// RAM code 02, DMG) and MBC3 + battery RAM with four 8 KiB banks (type 10 or
// 13, RAM code 03, DMG or CGB flag 80). save_bytes follows the RAM code.
// Identity comes from the prepared metadata, never a title or a built-in CRC.
// The default build exercises every preflight check with save writes disabled.
// SD completion events cross clocks outside this module. Buffer ownership is
// transferred only by those events; the host cannot edit the staged save while
// the cartridge writer owns it.
module restore_engine #(
    parameter bit WRITE_ENABLED = 1'b0,
    parameter integer WAKE_CYCLES = 201326592,
    parameter integer TIMEOUT_CYCLES = 2013265920
) (
    // reset is cold FPGA reset. A user/OS reset must assert cancel instead;
    // the connector and bus clock must remain alive until cleanup completes.
    input wire clk, reset, clk_io,
    input wire preflight_start, commit_start, cancel,
    output reg reprobe_start,
    input wire reprobe_done, reprobe_ok,
    input wire cart_powered, mode_ready, target_ok,
    input wire [7:0] cart_type, ram_size_code, rom_size_code, cgb_flag,
    input wire [7:0] header_checksum, sw_version,
    output wire busy,
    output wire [1:0] want_mode,
    output reg preflight_done, preflight_ok, done, failed,
    output reg [5:0] phase,
    output reg [4:0] error,
    output reg [31:0] rom_crc, save_crc,
    output reg [14:0] mismatch_offset,
    // Save length of the latched geometry, stable from preflight_start until
    // the next one. The file service sizes every transfer from it.
    output reg [15:0] save_bytes,
    // The live header describes a supported geometry. The guard opens the
    // page on it; preflight_start applies the same test before latching.
    output wire geometry_ok,

    // A request and its reply are synchronous to clk. op 0 loads metadata,
    // op 1 loads the save, op 2 writes and reads the recovery backup.
    output reg io_start,
    output reg [1:0] io_op,
    input wire io_done, io_failed,
    // Incoming words from the file service, synchronous to clk_io. Byte zero
    // is bits 7:0. The service checks the full transfer and exact file length.
    input wire input_we,
    input wire [1:0] input_kind,
    input wire [12:0] input_index,
    input wire [31:0] input_data,
    input wire [12:0] backup_addr,
    output reg [31:0] backup_data,

    output wire bus_req, bus_wr,
    output wire [15:0] bus_addr,
    output wire [7:0] bus_wdata,
    input wire [7:0] bus_rdata,
    input wire bus_done, bus_busy
);

localparam [5:0] IDLE=0, META=1, META_CHECK=2, LOAD=3, SAVE_CRC=4,
    WAKE=5, NORMALIZE=6, ROM=7, CAPTURE=8, COMPARE=9, BACKUP=10,
    BACKUP_CHECK=11, READY=12, FINAL_ROM=13, FINAL_SAVE=14, PROGRAM=15,
    VERIFY1=16, VERIFY2=17, COMPLETE=18, FAIL=19, STOP=20, CLEAN=21, FINAL_PROBE=22;
assign busy = phase != IDLE && phase != COMPLETE && phase != FAIL;
reg mode_owned;
assign want_mode = mode_owned ? 2'b10 : 2'b00;

reg [31:0] meta [0:15];
reg [31:0] staged [0:8191];
reg [31:0] readback [0:8191];
reg [7:0] original0 [0:8191];
reg [7:0] original1 [0:8191];
reg [7:0] original2 [0:8191];
reg [7:0] original3 [0:8191];
reg [2:0] load_meta_sync, load_save_sync, load_backup_sync;
always @(posedge clk_io) begin
    if (reset) begin
        load_meta_sync <= 0;
        load_save_sync <= 0;
        load_backup_sync <= 0;
    end else begin
        load_meta_sync <= {load_meta_sync[1:0], phase == META};
        load_save_sync <= {load_save_sync[1:0], phase == LOAD};
        load_backup_sync <= {load_backup_sync[1:0], phase == BACKUP};
    end
end
always @(posedge clk_io) begin
    if (input_we) begin
        case (input_kind)
            2'd0: if (load_meta_sync[2] && input_index < 16)
                      meta[input_index[3:0]] <= input_data;
            2'd1: if (load_save_sync[2]) staged[input_index] <= input_data;
            2'd2: if (load_backup_sync[2]) readback[input_index] <= input_data;
            default: ;
        endcase
    end
    backup_data <= {original3[backup_addr], original2[backup_addr],
                    original1[backup_addr], original0[backup_addr]};
end

reg [31:0] offset;
wire [14:0] writer_offset;
wire writer_busy, writer_done, writer_failed;
wire [14:0] mem_offset = phase == PROGRAM ? writer_offset : offset[14:0];
reg [31:0] stage_q, original_q, readback_q, meta_q;
always @(posedge clk) begin
    stage_q <= staged[mem_offset[14:2]];
    original_q <= {original3[mem_offset[14:2]], original2[mem_offset[14:2]],
                   original1[mem_offset[14:2]], original0[mem_offset[14:2]]};
    readback_q <= readback[mem_offset[14:2]];
    meta_q <= meta[offset[5:2]];
end
wire [7:0] stage_byte = stage_q >> (8 * mem_offset[1:0]);
wire [7:0] original_byte = original_q >> (8 * mem_offset[1:0]);
wire [7:0] readback_byte = readback_q >> (8 * mem_offset[1:0]);
wire [7:0] meta_byte = meta_q >> (8 * offset[1:0]);

function [31:0] crc_byte(input [31:0] prior, input [7:0] data);
    reg [31:0] c;
    integer n;
    begin
        c = prior ^ {24'd0, data};
        for (n=0; n<8; n=n+1) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
        crc_byte = c;
    end
endfunction
reg [31:0] crc, expected_save_crc, expected_rom_crc, expected_rom_bytes;
reg [127:0] expected_title;
reg [31:0] geometry, identity;
reg [7:0] type_l, ram_l, rom_l;
reg [31:0] timer;
reg [1:0] memory_wait;
reg [2:0] step;
reg inflight, aborting, committing, mismatch, io_pending;
reg [5:0] after_normalize;
reg [31:0] reader_count;
wire [3:0] title_index = reader_count[3:0] - 4'h4;

reg rom_start, save_start, writer_start;
wire rom_busy, rom_done, rom_valid;
wire [7:0] rom_data;
wire rom_req, rom_wr;
wire [15:0] rom_addr;
wire [7:0] rom_wdata;
wire save_busy, save_done, save_valid, save_responded;
wire [7:0] save_data;
wire save_req, save_wr;
wire [15:0] save_addr;
wire [7:0] save_wdata;
wire writer_req, writer_wr;
wire [15:0] writer_addr;
wire [7:0] writer_wdata;
reg ctl_req, ctl_wr;
reg [15:0] ctl_addr;
reg [7:0] ctl_data;

wire stopping = aborting || cancel || !cart_powered;
wire geometry_mbc1_8k = cart_type == 8'h03 && ram_size_code == 8'h02 &&
                        cgb_flag == 8'h00 && rom_size_code <= 8'd4;
wire geometry_mbc3_32k = (cart_type == 8'h10 || cart_type == 8'h13) &&
                         ram_size_code == 8'h03 &&
                         (cgb_flag == 8'h00 || cgb_flag == 8'h80) && rom_size_code <= 8'd6;
assign geometry_ok = geometry_mbc1_8k || geometry_mbc3_32k;
cart_dump_gb rom_reader (
    .clk(clk), .reset(reset || stopping), .start(rom_start),
    .cart_type(type_l), .rom_size_code(rom_l), .busy(rom_busy), .done(rom_done),
    .total_bytes(), .bus_req(rom_req), .bus_wr(rom_wr), .bus_addr(rom_addr),
    .bus_wdata(rom_wdata), .bus_rdata(bus_rdata), .bus_done(bus_done),
    .out_data(rom_data), .out_valid(rom_valid), .out_ready(1'b1)
);
cart_save_gb save_reader (
    .clk(clk), .reset(reset || !cart_powered), .start(save_start),
    .abort(stopping), .cart_type(type_l), .ram_size_code(ram_l),
    .supported(), .busy(save_busy), .done(save_done), .total_bytes(),
    .responded(save_responded), .blank_ff(), .blank_00(), .first_word(),
    .bus_req(save_req), .bus_wr(save_wr), .bus_addr(save_addr),
    .bus_wdata(save_wdata), .bus_rdata(bus_rdata), .bus_done(bus_done),
    .out_data(save_data), .out_valid(save_valid), .out_ready(1'b1)
);
wire permit_program = WRITE_ENABLED && phase == PROGRAM && committing &&
                      preflight_ok && !failed && timer != 0 && !stopping;
cart_restore_gb writer (
    .clk(clk), .reset(reset), .start(writer_start), .abort(stopping),
    .cart_powered(cart_powered), .cart_type(type_l), .ram_size_code(ram_l),
    .authorized(permit_program), .supported(), .busy(writer_busy),
    .done(writer_done), .failed(writer_failed), .source_offset(writer_offset),
    .source_data(stage_byte), .bus_req(writer_req), .bus_wr(writer_wr),
    .bus_addr(writer_addr), .bus_wdata(writer_wdata), .bus_rdata(bus_rdata),
    .bus_done(bus_done), .bus_busy(bus_busy)
);

wire use_rom = phase == ROM || phase == FINAL_ROM;
// An abort must leave the reader/writer in charge until their RAM-disable
// cleanup has drained. phase remains unchanged during that interval.
wire use_save = phase == CAPTURE || phase == COMPARE || phase == FINAL_SAVE ||
                phase == VERIFY1 || phase == VERIFY2;
assign bus_req = !mode_owned ? 1'b0 : phase == PROGRAM ? writer_req :
                 use_save ? save_req : use_rom ? rom_req : ctl_req;
assign bus_wr = phase == PROGRAM ? writer_wr : use_save ? save_wr :
                use_rom ? rom_wr : ctl_wr;
assign bus_addr = phase == PROGRAM ? writer_addr : use_save ? save_addr :
                  use_rom ? rom_addr : ctl_addr;
assign bus_wdata = phase == PROGRAM ? writer_wdata : use_save ? save_wdata :
                   use_rom ? rom_wdata : ctl_data;

// Original data is written only by the first cartridge pass.
always @(posedge clk) begin
    if (!reset && phase == CAPTURE && save_valid && !stopping) begin
        case (offset[1:0])
            0: original0[offset[14:2]] <= save_data;
            1: original1[offset[14:2]] <= save_data;
            2: original2[offset[14:2]] <= save_data;
            3: original3[offset[14:2]] <= save_data;
        endcase
    end
end

task fail_with(input [4:0] reason);
    begin
        failed <= 1'b1;
        error <= reason;
        aborting <= 1'b1;
        preflight_ok <= 1'b0;
    end
endtask
task begin_rom(input bit final_pass);
    begin
        phase <= final_pass ? FINAL_ROM : ROM;
        rom_start <= 1'b1;
        reader_count <= 0;
        crc <= 32'hFFFFFFFF;
        mismatch <= 0;
    end
endtask
task begin_save(input [5:0] next_phase);
    begin
        phase <= next_phase;
        save_start <= 1'b1;
        reader_count <= 0;
        offset <= 0;
        mismatch <= 1'b0;
    end
endtask

always @(posedge clk) begin
    io_start <= 1'b0;
    reprobe_start <= 1'b0;
    rom_start <= 1'b0;
    save_start <= 1'b0;
    writer_start <= 1'b0;
    ctl_req <= 1'b0;
    preflight_done <= 1'b0;
    done <= 1'b0;
    if (reset) begin
        phase <= IDLE;
        mode_owned <= 1'b0;
        preflight_ok <= 1'b0;
        failed <= 1'b0;
        error <= 0;
        rom_crc <= 0;
        save_crc <= 0;
        mismatch_offset <= 0;
        save_bytes <= 16'd8192;
        offset <= 0;
        crc <= 32'hFFFFFFFF;
        expected_save_crc <= 0;
        expected_rom_crc <= 0;
        expected_rom_bytes <= 0;
        expected_title <= 0;
        geometry <= 0;
        identity <= 0;
        type_l <= 0;
        ram_l <= 0;
        rom_l <= 0;
        timer <= 0;
        memory_wait <= 0;
        step <= 0;
        inflight <= 1'b0;
        aborting <= 1'b0;
        committing <= 1'b0;
        mismatch <= 1'b0;
        io_pending <= 1'b0;
        after_normalize <= ROM;
        reader_count <= 0;
        io_op <= 0;
        ctl_wr <= 0;
        ctl_addr <= 0;
        ctl_data <= 0;
    end else begin
        if (busy && phase != READY) begin
            if (timer != 0) timer <= timer - 1'b1;
            else if (!aborting) fail_with(5'd11);
        end
        if (io_done) io_pending <= 1'b0;
        if (busy && (cancel || !cart_powered) && !aborting) fail_with(5'd10);

        if (aborting) begin
            // Commands cannot be canceled in APF. Wait for completion, or its
            // poisoned timeout result, before releasing the target interface.
            if (!save_busy && !writer_busy && !bus_busy && !io_pending) begin
                if (cart_powered && mode_owned && phase != CLEAN) begin
                    phase <= CLEAN;
                    step <= 0;
                    inflight <= 0;
                end else if (!cart_powered || !mode_owned) begin
                    mode_owned <= 0;
                    phase <= FAIL;
                    preflight_done <= !committing;
                    done <= committing;
                    aborting <= 0;
                end
            end
        end

        // Stop scheduling work as soon as a cancellation or failure is seen.
        // CLEAN is allowed to run because it only disables RAM/restores mode.
        if ((!aborting && !cancel && (cart_powered || !busy) &&
             (!busy || phase == READY || timer != 0)) || phase == CLEAN)
        case (phase)
            IDLE, COMPLETE, FAIL: if (preflight_start) begin
                failed <= 0;
                error <= 0;
                preflight_ok <= 0;
                committing <= 0;
                aborting <= 0;
                rom_crc <= 0;
                save_crc <= 0;
                mismatch_offset <= 0;
                timer <= TIMEOUT_CYCLES;
                if (!target_ok || !cart_powered || !(geometry_mbc1_8k || geometry_mbc3_32k)) begin
                    phase <= META;
                    fail_with(5'd2);
                end else begin
                    type_l <= cart_type;
                    ram_l <= ram_size_code;
                    rom_l <= rom_size_code;
                    save_bytes <= geometry_mbc3_32k ? 16'd32768 : 16'd8192;
                    geometry <= {cgb_flag,rom_size_code,ram_size_code,cart_type};
                    identity <= {16'd0,sw_version,header_checksum};
                    io_op <= 0;
                    io_start <= 1;
                    io_pending <= 1;
                    phase <= META;
                end
            end
            META: if (io_done) begin
                if (io_failed) fail_with(5'd6);
                else begin
                    phase <= META_CHECK;
                    offset <= 0;
                    memory_wait <= 0;
                    crc <= 32'hFFFFFFFF;
                end
            end
            META_CHECK: begin
                if (memory_wait != 2) memory_wait <= memory_wait + 1'b1;
                else begin
                    memory_wait <= 0;
                    if (offset < 60) begin
                        crc <= crc_byte(crc,meta_byte);
                        offset <= offset + 1'b1;
                    end else if (meta[0] != 32'h53525443 || meta[1] != 1 ||
                        meta[2] != {16'd0, save_bytes} || meta[4] != (32'd32768 << rom_l) ||
                        meta[6] != geometry || meta[7] != identity ||
                        meta[12] != 0 || meta[13] != 0 || meta[14] != 0 ||
                        meta[15] != ~crc) fail_with(5'd1);
                    else begin
                        expected_save_crc <= meta[3];
                        expected_rom_bytes <= meta[4];
                        expected_rom_crc <= meta[5];
                        expected_title <= {meta[11],meta[10],meta[9],meta[8]};
                        io_start <= 1;
                        io_op <= 1;
                        io_pending <= 1;
                        phase <= LOAD;
                    end
                end
            end
            LOAD: if (io_done) begin
                if (io_failed) fail_with(5'd6);
                else begin
                    phase <= SAVE_CRC;
                    offset <= 0;
                    memory_wait <= 0;
                    crc <= 32'hFFFFFFFF;
                end
            end
            SAVE_CRC: begin
                // Compare the registered final CRC on a separate cycle. The
                // BRAM -> byte mux -> CRC -> equality -> error/timer path
                // otherwise exceeds clk_sys setup timing in the fitted core.
                if (offset == {16'd0, save_bytes}) begin
                    if (save_crc != expected_save_crc) fail_with(5'd3);
                    else begin
                        phase <= WAKE;
                        mode_owned <= 1;
                        timer <= WAKE_CYCLES;
                        after_normalize <= ROM;
                    end
                end else if (memory_wait != 2) memory_wait <= memory_wait + 1'b1;
                else begin
                    memory_wait <= 0;
                    crc <= crc_byte(crc,stage_byte);
                    offset <= offset + 1'b1;
                    if (offset == {16'd0, save_bytes} - 1)
                        save_crc <= ~crc_byte(crc,stage_byte);
                end
            end
            WAKE: begin
                if (!mode_ready) timer <= WAKE_CYCLES;
                else if (timer == 1) begin
                    timer <= TIMEOUT_CYCLES;
                    phase <= NORMALIZE;
                    step <= 0;
                    inflight <= 0;
                end
            end
            NORMALIZE, CLEAN: begin
                if (!inflight && !bus_busy && cart_powered) begin
                    ctl_wr <= 1;
                    ctl_addr <= step == 0 ? 16'h0000 : step == 1 ? 16'h6000 : 16'h4000;
                    ctl_data <= 0;
                    ctl_req <= 1;
                    inflight <= 1;
                end else if (inflight && bus_done) begin
                    inflight <= 0;
                    step <= step + 1'b1;
                    if (step == 2) begin
                        if (phase == CLEAN) begin
                            // bus_done arrives after the full hold interval.
                            mode_owned <= 0;
                            phase <= FAIL;
                            preflight_done <= !committing;
                            done <= committing;
                            aborting <= 0;
                        end else begin_rom(after_normalize == FINAL_ROM);
                    end
                end
            end
            ROM, FINAL_ROM: begin
                if (rom_valid) begin
                    crc <= crc_byte(crc,rom_data);
                    reader_count <= reader_count + 1'b1;
                    if (reader_count >= 32'h134 && reader_count < 32'h144 &&
                        rom_data != expected_title[title_index*8 +: 8])
                        mismatch <= 1;
                end
                if (rom_done) begin
                    rom_crc <= ~crc;
                    if (reader_count != expected_rom_bytes || ~crc != expected_rom_crc || mismatch)
                        fail_with(phase == FINAL_ROM ? 5'd8 : 5'd4);
                    else begin_save(phase == FINAL_ROM ? FINAL_SAVE : CAPTURE);
                end
            end
            CAPTURE, COMPARE, FINAL_SAVE, VERIFY1, VERIFY2: begin
                if (save_valid) begin
                    if (phase != CAPTURE && save_data !=
                        ((phase == VERIFY1 || phase == VERIFY2) ? stage_byte : original_byte)) begin
                        if (!mismatch) mismatch_offset <= offset[14:0];
                        mismatch <= 1;
                    end
                    offset <= offset + 1'b1;
                    reader_count <= reader_count + 1'b1;
                end
                if (save_done) begin
                    if (reader_count != {16'd0, save_bytes} || !save_responded || mismatch)
                        fail_with(phase == VERIFY1 || phase == VERIFY2 ? 5'd9 :
                                  phase == FINAL_SAVE ? 5'd8 : 5'd5);
                    else if (phase == CAPTURE) begin_save(COMPARE);
                    else if (phase == COMPARE) begin
                        phase <= BACKUP;
                        io_start <= 1;
                        io_op <= 2;
                        io_pending <= 1;
                    end else if (phase == FINAL_SAVE) begin
                        if (WRITE_ENABLED) begin
                            phase <= PROGRAM;
                            writer_start <= 1;
                        end else begin
                            phase <= COMPLETE;
                            mode_owned <= 0;
                            done <= 1;
                        end
                    end else if (phase == VERIFY1) begin_save(VERIFY2);
                    else begin
                        phase <= COMPLETE;
                        mode_owned <= 0;
                        done <= 1;
                    end
                end
            end
            BACKUP: if (io_done) begin
                if (io_failed) fail_with(5'd6);
                else begin
                    phase <= BACKUP_CHECK;
                    offset <= 0;
                    memory_wait <= 0;
                end
            end
            BACKUP_CHECK: begin
                if (memory_wait != 2) memory_wait <= memory_wait + 1'b1;
                else begin
                    memory_wait <= 0;
                    if (readback_byte != original_byte) begin
                        mismatch_offset <= offset[14:0];
                        fail_with(5'd7);
                    end else if (offset == {16'd0, save_bytes} - 1) begin
                        phase <= READY;
                        preflight_ok <= 1;
                        preflight_done <= 1;
                    end else offset <= offset + 1'b1;
                end
            end
            READY: if (commit_start && preflight_ok) begin
                committing <= 1;
                timer <= TIMEOUT_CYCLES;
                phase <= FINAL_PROBE;
                mode_owned <= 0;
                reprobe_start <= 1;
            end
            FINAL_PROBE: if (reprobe_done) begin
                if (!reprobe_ok || {cgb_flag,rom_size_code,ram_size_code,cart_type} != geometry ||
                    {16'd0,sw_version,header_checksum} != identity) fail_with(5'd8);
                else begin
                    phase <= WAKE;
                    mode_owned <= 1;
                    timer <= WAKE_CYCLES;
                    after_normalize <= FINAL_ROM;
                end
            end
            PROGRAM: if (writer_done) begin
                if (writer_failed) fail_with(5'd12);
                else begin_save(VERIFY1);
            end
            default: ;
        endcase
    end
end
endmodule
`default_nettype wire
