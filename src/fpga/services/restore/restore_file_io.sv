// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

// Single-file restore staging and recovery-file I/O, entirely in clk_74a.
// The caller owns the shared target-command bus until done. A timeout poisons
// this service until hard reset, because APF commands cannot be cancelled and
// a late completion must never be consumed by a subsequent transaction.
//
// Internal save words and outbound file payloads have byte zero in bits 7:0,
// matching the measured dump output. Open File path strings instead put byte
// zero in bits 31:24, as the hardware-tested PC Engine command path does.
// Flags and size are native numeric words, not byte-swapped strings. Incoming
// APF byte arrays also arrive high-byte-first after undoing bridge endianness.
// Do not infer command-structure packing from file-payload packing.
// Reads use the established free-running address / bridge_rd-held response
// shape. See dump_engine's bridge window and docs/APF-NOTES.md.
// Fixed read-only input slots are verified through Get Filename, slot ID,
// and exact size, then read directly. Only recovery files use Open File.
module restore_file_io #(
    parameter [15:0] META_SLOT = 16'd21,
    parameter [15:0] SAVE_SLOT = 16'd22,
    parameter [15:0] BACKUP_SLOT = 16'd23,
    parameter [9:0] META_TABLE = 10'd4,
    parameter [9:0] SAVE_TABLE = 10'd6,
    parameter [9:0] BACKUP_TABLE = 10'd8,
    parameter [31:0] BUF_BASE = 32'hB000_0000,
    parameter [31:0] STRUCT_BASE = 32'h9000_0000,
    parameter [31:0] BACKUP_BASE = 32'hA000_0000,
    parameter [31:0] NAME_BASE = 32'hC000_0000,
    parameter integer TIMEOUT_CYCLES = 134_217_728
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [1:0] op,       // 0 metadata, 1 save, 2 recovery write and reread
    output reg busy,
    output reg done,
    output reg failed,
    output reg [3:0] err,
    output reg poisoned,
    output reg [15:0] backup_index,
    // Retained evidence: operation, last stage, path word count, first word,
    // filename-tail word, and flags. Input trace is received Get Filename
    // data; recovery trace observes transmitted Open File responses.
    output wire [108:0] debug_status,
    output wire [475:0] debug_detail,
    // Seen mask P/C/N/R, creation table size, full probe/create/name/resize results.
    output reg [99:0] debug_sequence,
    // Tap the selected top-level bridge response, not merely our own output.
    input wire [31:0] observed_bridge_data,

    input wire [31:0] bridge_addr,
    input wire bridge_rd,
    input wire bridge_wr,
    input wire [31:0] bridge_wr_data,
    input wire bridge_endian_little,
    output wire [31:0] bridge_rd_data,
    output wire bridge_rd_hit,

    output reg [10:0] backup_rd_addr,
    input wire [31:0] backup_rd_q,
    output reg input_we,
    output reg [10:0] input_index,
    output reg [31:0] input_data,
    output reg [1:0] input_kind,

    output reg [9:0] datatable_addr,
    input wire [31:0] datatable_q,

    output reg target_dataslot_read,
    output reg target_dataslot_write,
    output reg target_dataslot_openfile,
    output reg target_dataslot_getfile,
    output reg [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output reg [31:0] target_dataslot_bridgeaddr,
    output reg [31:0] target_dataslot_length,
    output wire [31:0] target_buffer_param_struct,
    output wire [31:0] target_buffer_resp_struct,
    input wire target_dataslot_done,
    input wire [2:0] target_dataslot_err, // legacy summary, never used for authorization
    input wire [15:0] target_dataslot_result
);

localparam [4:0] ST_IDLE = 0, ST_OPEN = 1, ST_OPEN_WAIT = 2,
    ST_ID_WAIT = 3, ST_ID_CHECK = 4, ST_SIZE_WAIT = 5, ST_SIZE_CHECK = 6,
    ST_READ = 7, ST_READ_WAIT = 8, ST_PROBE = 9, ST_PROBE_WAIT = 10,
    ST_CREATE = 11, ST_CREATE_WAIT = 12, ST_WRITE = 13, ST_WRITE_WAIT = 14,
    ST_FINISH = 15, ST_RESIZE = 16, ST_RESIZE_WAIT = 17,
    ST_NAME = 18, ST_NAME_WAIT = 19, ST_NAME_CHECK = 20,
    ST_ID_SETTLE = 21, ST_SIZE_SETTLE = 22;
localparam [3:0] ERR_TIMEOUT = 8, ERR_TABLE = 9, ERR_TRANSFER = 10,
    ERR_NAMES_FULL = 11, ERR_OPERATION = 12, ERR_CREATE_RACE = 13,
    ERR_INPUT_PATH = 14, ERR_RESULT = 15;

reg [4:0] state;
reg [1:0] operation;
reg [31:0] expected_bytes;
reg [9:0] table_base;
reg [1:0] open_flags;
reg created_owned;
reg check_before_write;
reg checking_created;
reg trace_name;
reg saw_busy;
reg [31:0] timeout;
reg [11:0] received_words;
reg receive_bad;
reg [6:0] name_words;
reg name_transfer_bad, name_path_bad;
reg [3:0] debug_stage;
reg [6:0] debug_reads;
reg [31:0] debug_first, debug_tail, debug_flags;
reg [319:0] debug_path;
reg [65:0] debug_seen;
reg [6:0] debug_unique, debug_repeats;
reg [27:0] debug_repeat_indices;
reg debug_bad;
reg [6:0] debug_bad_index;
reg [31:0] debug_bad_word, debug_bad_expected, debug_size;
assign debug_status = {operation, debug_stage, debug_reads,
                       debug_first, debug_tail, debug_flags};
assign debug_detail = {debug_path, debug_seen[9:0], debug_unique, debug_repeats,
                       debug_repeat_indices, debug_bad, debug_bad_index,
                       debug_bad_word, debug_bad_expected, debug_size};

assign target_dataslot_slotoffset = 32'd0;
assign target_buffer_param_struct = STRUCT_BASE;
assign target_buffer_resp_struct = NAME_BASE;

function automatic [31:0] swap_bytes(input [31:0] value);
    swap_bytes = {value[7:0], value[15:8], value[23:16], value[31:24]};
endfunction

// Like dump_engine, synchronize the bridge endian flag before applying it.
reg endian_1, endian_2, endian_3;
always @(posedge clk) begin
    if (reset) begin
        endian_1 <= 0;
        endian_2 <= 0;
        endian_3 <= 0;
    end else begin
        endian_1 <= bridge_endian_little;
        endian_2 <= endian_1;
        endian_3 <= endian_2;
    end
end

localparam [199:0] PREFIX = "/Assets/carttools/common/";
localparam [95:0] META_NAME = "RESTORE.meta";
localparam [87:0] SAVE_NAME = "RESTORE.sav";

function automatic [7:0] hex_digit(input [3:0] digit);
    hex_digit = digit < 10 ? 8'h30 + {4'd0, digit} : 8'h41 + {4'd0, digit} - 8'd10;
endfunction

function automatic [7:0] path_byte(input [8:0] offset);
    reg [8:0] name_offset;
    begin
        path_byte = 0;
        name_offset = offset - 9'd25;
        if (offset < 25) path_byte = PREFIX[199 - offset*8 -: 8];
        else if (operation == 0 && name_offset < 12)
            path_byte = META_NAME[95 - name_offset*8 -: 8];
        else if (operation == 1 && name_offset < 11)
            path_byte = SAVE_NAME[87 - name_offset*8 -: 8];
        else if (operation == 2) begin
            case (name_offset)
                0: path_byte = "P";
                1: path_byte = "R";
                2: path_byte = "E";
                3: path_byte = hex_digit(backup_index[15:12]);
                4: path_byte = hex_digit(backup_index[11:8]);
                5: path_byte = hex_digit(backup_index[7:4]);
                6: path_byte = hex_digit(backup_index[3:0]);
                7: path_byte = ".";
                8: path_byte = "s";
                9: path_byte = "a";
                10: path_byte = "v";
                default: path_byte = 0;
            endcase
        end
    end
endfunction

// Canonical character order for input validation and the UI: byte zero low.
function automatic [31:0] path_word(input [6:0] index);
    reg [8:0] offset;
    begin
        offset = {index, 2'b00};
        path_word = {path_byte(offset + 9'd3), path_byte(offset + 9'd2),
                     path_byte(offset + 9'd1), path_byte(offset)};
    end
endfunction

function automatic [31:0] struct_word(input [6:0] index);
    begin
        if (index < 64)
            struct_word = swap_bytes(path_word(index));
        else if (index == 64)
            struct_word = {30'd0, open_flags};
        else if (index == 65)
            // Numeric field, independent of the preceding string's packing.
            struct_word = open_flags[1] ? 32'd8192 : 32'd0;
        else struct_word = 0;
    end
endfunction

reg [6:0] struct_addr;
reg [31:0] struct_q;
reg select_struct_1, select_struct_2;
reg [31:0] read_hold;
reg hit_hold;
reg [6:0] reply_word_index;
wire struct_hit = bridge_addr[31:28] == STRUCT_BASE[31:28]
                  && bridge_addr[27:9] == 0 && bridge_addr[8:0] < 264
                  && bridge_addr[1:0] == 0;
wire backup_hit = bridge_addr[31:28] == BACKUP_BASE[31:28]
                  && bridge_addr[27:13] == 0 && bridge_addr[1:0] == 0;

always @(posedge clk) begin
    if (reset) begin
        backup_rd_addr <= 0;
        struct_addr <= 0;
        struct_q <= 0;
        select_struct_1 <= 0;
        select_struct_2 <= 0;
        read_hold <= 0;
        hit_hold <= 0;
        reply_word_index <= 0;
    end else begin
        backup_rd_addr <= bridge_addr[12:2];
        struct_addr <= bridge_addr[8:2];
        struct_q <= struct_word(struct_addr);
        select_struct_1 <= struct_hit;
        select_struct_2 <= select_struct_1;
        if (bridge_rd) begin
            read_hold <= select_struct_2 ? struct_q : backup_rd_q;
            hit_hold <= struct_hit || backup_hit;
            reply_word_index <= bridge_addr[8:2];
        end
    end
end

assign bridge_rd_data = endian_3 ? swap_bytes(read_hold) : read_hold;
assign bridge_rd_hit = hit_hold;

// Like the working dumper, observe the response held BEFORE bridge_rd.
// That is the word the peripheral just sampled, not the new request's word.
// Track its address independently, including across command/window changes.
reg reply_is_struct;
wire [31:0] observed_native = endian_3 ? swap_bytes(observed_bridge_data) : observed_bridge_data;
wire [31:0] expected_reply = struct_word(reply_word_index);
// Get-filename returns a NUL-terminated path, not a save payload. Validate
// every byte through its required terminator; padding beyond it is not part
// of the filename and need not be zero. Accept only contiguous aligned words
// within the documented 256-byte response window.
wire name_write = bridge_wr && bridge_addr[31:28] == NAME_BASE[31:28]
                  && state == ST_NAME_WAIT;
wire name_in_order = bridge_addr[27:8] == 0 && bridge_addr[1:0] == 0
                    && {1'b0, bridge_addr[7:2]} == name_words && name_words < 64;
wire [6:0] name_word_index = {1'b0, bridge_addr[7:2]};
wire [31:0] name_native = swap_bytes(receive_native);
wire [31:0] name_expected = path_word(name_word_index);
wire [31:0] name_mask = name_word_index < 9 ? 32'hFFFFFFFF :
                        name_word_index == 9 ? (operation == 0 ? 32'h0000FFFF : 32'h000000FF) :
                        32'd0;
wire name_mismatch = (name_native & name_mask) != (name_expected & name_mask);
wire trace_event = trace_name ? name_write : busy && bridge_rd && reply_is_struct;
wire [6:0] trace_index = trace_name ? name_word_index : reply_word_index;
wire [31:0] trace_native = trace_name ? name_native : observed_native;
wire [31:0] trace_path = trace_name ? trace_native : swap_bytes(trace_native);
wire [31:0] trace_expected = trace_name ? name_expected : expected_reply;
wire trace_mismatch = trace_name ? name_mismatch : observed_native != expected_reply;
wire [31:0] table_expected = state == ST_ID_CHECK ? {16'd0, target_dataslot_id} : expected_bytes;
wire table_mismatch = (state == ST_ID_CHECK || (state == ST_SIZE_CHECK && !checking_created))
                      && datatable_q != table_expected;
integer trace_word;
always @(posedge clk) begin
    if (reset) begin
        trace_name <= 0;
        reply_is_struct <= 0;
        debug_reads <= 0;
        debug_first <= 0;
        debug_tail <= 0;
        debug_flags <= 0;
        debug_path <= 0;
        debug_seen <= 0;
        debug_unique <= 0;
        debug_repeats <= 0;
        debug_repeat_indices <= {4{7'h7F}};
        debug_bad <= 0;
        debug_bad_index <= 0;
        debug_bad_word <= 0;
        debug_bad_expected <= 0;
        debug_size <= 0;
    end else begin
        if (bridge_rd) reply_is_struct <= struct_hit;
        if ((state == ST_IDLE && start) || target_dataslot_openfile || target_dataslot_getfile) begin
            trace_name <= target_dataslot_getfile || (state == ST_IDLE && start && op < 2);
            debug_reads <= 0;
            debug_first <= 0;
            debug_tail <= 0;
            debug_flags <= 0;
            debug_path <= 0;
            debug_seen <= 0;
            debug_unique <= 0;
            debug_repeats <= 0;
            debug_repeat_indices <= {4{7'h7F}};
            debug_bad <= 0;
            debug_bad_index <= 0;
            debug_bad_word <= 0;
            debug_bad_expected <= 0;
            debug_size <= 0;
        end else if (table_mismatch) begin
            // Keep all diagnostic registers in this single clocked owner.
            debug_bad <= 1;
            debug_bad_index <= datatable_addr[6:0];
            debug_bad_word <= datatable_q;
            debug_bad_expected <= table_expected;
        end else if (trace_event) begin
            if (debug_reads != 127) debug_reads <= debug_reads + 1'b1;
            if (trace_index == 0) debug_first <= trace_native;
            if (trace_index == 8) debug_tail <= trace_native;
            if (trace_index == 64) debug_flags <= trace_native;
            if (trace_index == 65) debug_size <= trace_native;
            for (trace_word = 0; trace_word < 10; trace_word = trace_word + 1)
                if (trace_index == trace_word)
                    debug_path[trace_word*32 +: 32] <= trace_path;
            if (!debug_seen[trace_index]) begin
                debug_seen[trace_index] <= 1;
                debug_unique <= debug_unique + 1'b1;
            end else begin
                if (debug_repeats != 127) debug_repeats <= debug_repeats + 1'b1;
                if (debug_repeats < 4)
                    debug_repeat_indices[debug_repeats*7 +: 7] <= trace_index;
            end
            // Compare every observation, including discarded priming reads.
            // Keep the first mismatch even if a later reread looks correct.
            if (!debug_bad && trace_mismatch) begin
                debug_bad <= 1;
                debug_bad_index <= trace_index;
                debug_bad_word <= trace_native;
                debug_bad_expected <= trace_expected;
            end
        end
    end
end

wire receive_write = bridge_wr && bridge_addr[31:28] == BUF_BASE[31:28]
                     && state == ST_READ_WAIT;
wire receive_in_order = bridge_addr[27:13] == 0 && bridge_addr[1:0] == 0
                        && {1'b0, bridge_addr[12:2]} == received_words
                        && received_words < expected_bytes[13:2];
wire [31:0] receive_native = endian_3 ? swap_bytes(bridge_wr_data) : bridge_wr_data;
wire [11:0] received_after = received_words + (receive_write && receive_in_order ? 12'd1 : 12'd0);
// Preserve known firmware errors, but never alias an unsupported 16-bit result
// onto success or newly-created ownership through the legacy three-bit summary.
wire [3:0] command_error = target_dataslot_result <= 16'd5 ?
                           target_dataslot_result[3:0] : ERR_RESULT;

task automatic fail_command(input [3:0] code);
    begin
        failed <= 1;
        err <= code;
        state <= ST_FINISH;
    end
endtask

task automatic begin_wait;
    begin
        saw_busy <= 0;
        timeout <= TIMEOUT_CYCLES;
    end
endtask

always @(posedge clk) begin
    target_dataslot_read <= 0;
    target_dataslot_write <= 0;
    target_dataslot_openfile <= 0;
    target_dataslot_getfile <= 0;
    done <= 0;
    input_we <= 0;
    if (reset) begin
        state <= ST_IDLE;
        operation <= 0;
        debug_stage <= 0;
        busy <= 0;
        failed <= 0;
        err <= 0;
        poisoned <= 0;
        backup_index <= 0;
        expected_bytes <= 0;
        table_base <= 0;
        open_flags <= 0;
        created_owned <= 0;
        check_before_write <= 0;
        checking_created <= 0;
        debug_sequence <= {4'd0, 32'hFFFFFFFF, 64'd0};
        saw_busy <= 0;
        timeout <= 0;
        received_words <= 0;
        receive_bad <= 0;
        name_words <= 0;
        name_transfer_bad <= 0;
        name_path_bad <= 0;
        input_index <= 0;
        input_data <= 0;
        input_kind <= 0;
        datatable_addr <= 0;
        target_dataslot_id <= 0;
        target_dataslot_bridgeaddr <= BUF_BASE;
        target_dataslot_length <= 0;
    end else begin
        if (name_write) begin
            if (!name_in_order) name_transfer_bad <= 1;
            else begin
                name_words <= name_words + 1'b1;
                if (name_mismatch) name_path_bad <= 1;
            end
        end
        if (receive_write) begin
            if (!receive_in_order) receive_bad <= 1;
            else begin
                received_words <= received_words + 12'd1;
                if (!receive_bad) begin
                    input_we <= 1;
                    input_index <= bridge_addr[12:2];
                    input_data <= swap_bytes(receive_native);
                end
            end
        end
        case (state)
            ST_IDLE: if (start) begin
                busy <= 1;
                failed <= 0;
                err <= 0;
                operation <= op;
                debug_stage <= 0;
                input_kind <= op;
                open_flags <= 0;
                created_owned <= 0;
                check_before_write <= 0;
                checking_created <= 0;
                debug_sequence <= {4'd0, 32'hFFFFFFFF, 64'd0};
                expected_bytes <= op == 0 ? 32'd64 : 32'd8192;
                target_dataslot_id <= op == 0 ? META_SLOT : op == 1 ? SAVE_SLOT : BACKUP_SLOT;
                table_base <= op == 0 ? META_TABLE : op == 1 ? SAVE_TABLE : BACKUP_TABLE;
                if (poisoned) fail_command(ERR_TIMEOUT);
                else if (op == 3) fail_command(ERR_OPERATION);
                else state <= op == 2 ? ST_PROBE : ST_NAME;
            end
            ST_NAME: begin
                // Fixed inputs already belong to their slots. For recovery,
                // query the actual association after create and before resize.
                debug_stage <= operation == 2 ? 4'd13 : 4'd11;
                target_dataslot_getfile <= 1;
                name_words <= 0;
                name_transfer_bad <= 0;
                name_path_bad <= 0;
                begin_wait();
                state <= ST_NAME_WAIT;
            end
            ST_NAME_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    if (operation == 2) begin
                        debug_sequence[97] <= 1;
                        debug_sequence[31:16] <= target_dataslot_result;
                    end
                    if (target_dataslot_result != 0) fail_command(command_error);
                    else state <= ST_NAME_CHECK;
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_NAME_CHECK: begin
                // Separate cycle includes a final write coincident with done.
                debug_stage <= operation == 2 ? 4'd14 : 4'd12;
                if (name_transfer_bad || name_words < 10) fail_command(ERR_TRANSFER);
                else if (name_path_bad) fail_command(ERR_INPUT_PATH);
                else begin
                    datatable_addr <= table_base;
                    state <= ST_ID_WAIT;
                end
            end
            ST_OPEN: begin
                debug_stage <= 9; // reopen the newly written recovery file
                open_flags <= 0;
                check_before_write <= 0;
                target_dataslot_openfile <= 1;
                begin_wait();
                state <= ST_OPEN_WAIT;
            end
            ST_OPEN_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    if (target_dataslot_result != 0) fail_command(command_error);
                    else begin
                        datatable_addr <= table_base;
                        state <= ST_ID_WAIT;
                    end
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_ID_WAIT: begin
                debug_stage <= 2;
                // mf_datatable registers both the RAM read and its output.
                // The new address is captured on this edge, reaches q on
                // the next, and may only be compared on the following edge.
                state <= ST_ID_SETTLE;
            end
            ST_ID_SETTLE: begin
                state <= ST_ID_CHECK;
            end
            ST_ID_CHECK: begin
                if (datatable_q != {16'd0, target_dataslot_id}) fail_command(ERR_TABLE);
                else begin
                    datatable_addr <= table_base + 10'd1;
                    state <= ST_SIZE_WAIT;
                end
            end
            ST_SIZE_WAIT: begin
                debug_stage <= 3;
                state <= ST_SIZE_SETTLE;
            end
            ST_SIZE_SETTLE: begin
                state <= ST_SIZE_CHECK;
            end
            ST_SIZE_CHECK: begin
                if (checking_created) begin
                    // The contract does not promise zero size for create-only.
                    // Retain what firmware reported; exact 8192-byte checks still
                    // guard both payload write and reread after the resize.
                    debug_sequence[95:64] <= datatable_q;
                    checking_created <= 0;
                    state <= ST_RESIZE;
                end else if (datatable_q != expected_bytes) fail_command(ERR_TABLE);
                else state <= check_before_write ? ST_WRITE : ST_READ;
            end
            ST_READ: begin
                debug_stage <= operation == 2 ? 4'd10 : 4'd4;
                target_dataslot_bridgeaddr <= BUF_BASE;
                target_dataslot_length <= expected_bytes;
                target_dataslot_read <= 1;
                received_words <= 0;
                receive_bad <= 0;
                begin_wait();
                state <= ST_READ_WAIT;
            end
            ST_READ_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    if (target_dataslot_result != 0) fail_command(command_error);
                    else if (receive_bad || (receive_write && !receive_in_order)
                             || received_after != expected_bytes[13:2])
                        fail_command(ERR_TRANSFER);
                    else state <= ST_FINISH;
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_PROBE: begin
                debug_stage <= 5;
                open_flags <= 0;
                target_dataslot_openfile <= 1;
                begin_wait();
                state <= ST_PROBE_WAIT;
            end
            ST_PROBE_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    debug_sequence[99] <= 1;
                    debug_sequence[63:48] <= target_dataslot_result;
                    if (target_dataslot_result == 3) state <= ST_CREATE;
                    else if (target_dataslot_result == 0) begin
                        if (backup_index == 16'hFFFF) fail_command(ERR_NAMES_FULL);
                        else begin
                            backup_index <= backup_index + 16'd1;
                            state <= ST_PROBE;
                        end
                    end else fail_command(command_error);
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_CREATE: begin
                debug_stage <= 6;
                open_flags <= 1;
                target_dataslot_openfile <= 1;
                begin_wait();
                state <= ST_CREATE_WAIT;
            end
            ST_CREATE_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    // Result 0 means somebody created it after our probe.
                    // It is now an existing backup, and cannot be written.
                    debug_sequence[98] <= 1;
                    debug_sequence[47:32] <= target_dataslot_result;
                    if (target_dataslot_result == 1) begin
                        created_owned <= 1;
                        checking_created <= 1;
                        state <= ST_NAME;
                    end
                    else if (target_dataslot_result == 0) fail_command(ERR_CREATE_RACE);
                    else fail_command(command_error);
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_RESIZE: begin
                debug_stage <= 7;
                // Only the exact name just proven newly created may be
                // preallocated. Never combine create+resize: result 0 from
                // that combined command would already have truncated an
                // existing file before the controller could reject it.
                if (!created_owned) fail_command(ERR_CREATE_RACE);
                else begin
                    open_flags <= 2;
                    target_dataslot_openfile <= 1;
                    begin_wait();
                    state <= ST_RESIZE_WAIT;
                end
            end
            ST_RESIZE_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    debug_sequence[96] <= 1;
                    debug_sequence[15:0] <= target_dataslot_result;
                    if (target_dataslot_result != 0) fail_command(command_error);
                    else begin
                        check_before_write <= 1;
                        datatable_addr <= table_base;
                        state <= ST_ID_WAIT;
                    end
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_WRITE: begin
                debug_stage <= 8;
                if (!created_owned) fail_command(ERR_CREATE_RACE);
                else begin
                    target_dataslot_bridgeaddr <= BACKUP_BASE;
                    target_dataslot_length <= 32'd8192;
                    target_dataslot_write <= 1;
                    begin_wait();
                    state <= ST_WRITE_WAIT;
                end
            end
            ST_WRITE_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    if (target_dataslot_result != 0) fail_command(command_error);
                    // No flush: current Pocket firmware never answers it.
                    // Reopen the exact recovery filename and verify its size
                    // before returning every byte for caller comparison.
                    else state <= ST_OPEN;
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_FINISH: begin
                created_owned <= 0;
                busy <= 0;
                done <= 1;
                state <= ST_IDLE;
            end
            default: fail_command(ERR_OPERATION);
        endcase
    end
end

endmodule
`default_nettype wire
