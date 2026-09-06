// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

// Single-file restore staging and recovery-file I/O, entirely in clk_74a.
// The caller owns the shared target-command bus until done. A timeout poisons
// this service until hard reset, because APF commands cannot be cancelled and
// a late completion must never be consumed by a subsequent transaction.
//
// Internal and outbound memory words have byte zero in bits 7:0, matching
// the measured dump output. Incoming APF byte arrays have byte zero in bits
// 31:24 after the bridge's conditional endian swap is undone. The directions
// are asymmetric; do not infer the output layout from a captured input word.
// Reads use the established free-running address / bridge_rd-held response
// shape. See dump_engine's bridge window and docs/APF-NOTES.md.
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
    output reg [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output reg [31:0] target_dataslot_bridgeaddr,
    output reg [31:0] target_dataslot_length,
    output wire [31:0] target_buffer_param_struct,
    input wire target_dataslot_done,
    input wire [2:0] target_dataslot_err
);

localparam [4:0] ST_IDLE = 0, ST_OPEN = 1, ST_OPEN_WAIT = 2,
    ST_ID_WAIT = 3, ST_ID_CHECK = 4, ST_SIZE_WAIT = 5, ST_SIZE_CHECK = 6,
    ST_READ = 7, ST_READ_WAIT = 8, ST_PROBE = 9, ST_PROBE_WAIT = 10,
    ST_CREATE = 11, ST_CREATE_WAIT = 12, ST_WRITE = 13, ST_WRITE_WAIT = 14,
    ST_FINISH = 15, ST_RESIZE = 16, ST_RESIZE_WAIT = 17;
localparam [3:0] ERR_TIMEOUT = 8, ERR_TABLE = 9, ERR_TRANSFER = 10,
    ERR_NAMES_FULL = 11, ERR_OPERATION = 12, ERR_CREATE_RACE = 13;

reg [4:0] state;
reg [1:0] operation;
reg [31:0] expected_bytes;
reg [9:0] table_base;
reg [1:0] open_flags;
reg created_owned;
reg check_before_write;
reg saw_busy;
reg [31:0] timeout;
reg [11:0] received_words;
reg receive_bad;

assign target_dataslot_slotoffset = 32'd0;
assign target_buffer_param_struct = STRUCT_BASE;

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

function automatic [31:0] struct_word(input [6:0] index);
    reg [8:0] offset;
    begin
        offset = {index, 2'b00};
        if (index < 64)
            struct_word = {path_byte(offset + 9'd3), path_byte(offset + 9'd2),
                           path_byte(offset + 9'd1), path_byte(offset)};
        else if (index == 64)
            struct_word = {30'd0, open_flags};
        else if (index == 65)
            // Byte-array little-endian 8192, used for the new backup only.
            struct_word = open_flags != 0 ? 32'd8192 : 32'd0;
        else struct_word = 0;
    end
endfunction

reg [6:0] struct_addr;
reg [31:0] struct_q;
reg select_struct_1, select_struct_2;
reg [31:0] read_hold;
reg hit_hold;
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
    end else begin
        backup_rd_addr <= bridge_addr[12:2];
        struct_addr <= bridge_addr[8:2];
        struct_q <= struct_word(struct_addr);
        select_struct_1 <= struct_hit;
        select_struct_2 <= select_struct_1;
        if (bridge_rd) begin
            read_hold <= select_struct_2 ? struct_q : backup_rd_q;
            hit_hold <= struct_hit || backup_hit;
        end
    end
end

assign bridge_rd_data = endian_3 ? swap_bytes(read_hold) : read_hold;
assign bridge_rd_hit = hit_hold;

wire receive_write = bridge_wr && bridge_addr[31:28] == BUF_BASE[31:28]
                     && state == ST_READ_WAIT;
wire receive_in_order = bridge_addr[27:13] == 0 && bridge_addr[1:0] == 0
                        && {1'b0, bridge_addr[12:2]} == received_words
                        && received_words < expected_bytes[13:2];
wire [31:0] receive_native = endian_3 ? swap_bytes(bridge_wr_data) : bridge_wr_data;
wire [11:0] received_after = received_words + (receive_write && receive_in_order ? 12'd1 : 12'd0);

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
    done <= 0;
    input_we <= 0;
    if (reset) begin
        state <= ST_IDLE;
        operation <= 0;
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
        saw_busy <= 0;
        timeout <= 0;
        received_words <= 0;
        receive_bad <= 0;
        input_index <= 0;
        input_data <= 0;
        input_kind <= 0;
        datatable_addr <= 0;
        target_dataslot_id <= 0;
        target_dataslot_bridgeaddr <= BUF_BASE;
        target_dataslot_length <= 0;
    end else begin
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
                input_kind <= op;
                open_flags <= 0;
                created_owned <= 0;
                check_before_write <= 0;
                expected_bytes <= op == 0 ? 32'd64 : 32'd8192;
                target_dataslot_id <= op == 0 ? META_SLOT : op == 1 ? SAVE_SLOT : BACKUP_SLOT;
                table_base <= op == 0 ? META_TABLE : op == 1 ? SAVE_TABLE : BACKUP_TABLE;
                if (poisoned) fail_command(ERR_TIMEOUT);
                else if (op == 3) fail_command(ERR_OPERATION);
                else state <= op == 2 ? ST_PROBE : ST_OPEN;
            end
            ST_OPEN: begin
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
                    if (target_dataslot_err != 0) fail_command({1'b0, target_dataslot_err});
                    else begin
                        datatable_addr <= table_base;
                        state <= ST_ID_WAIT;
                    end
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_ID_WAIT: state <= ST_ID_CHECK;
            ST_ID_CHECK: begin
                if (datatable_q != {16'd0, target_dataslot_id}) fail_command(ERR_TABLE);
                else begin
                    datatable_addr <= table_base + 10'd1;
                    state <= ST_SIZE_WAIT;
                end
            end
            ST_SIZE_WAIT: state <= ST_SIZE_CHECK;
            ST_SIZE_CHECK: begin
                if (datatable_q != expected_bytes) fail_command(ERR_TABLE);
                else state <= check_before_write ? ST_WRITE : ST_READ;
            end
            ST_READ: begin
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
                    if (target_dataslot_err != 0) fail_command({1'b0, target_dataslot_err});
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
                open_flags <= 0;
                target_dataslot_openfile <= 1;
                begin_wait();
                state <= ST_PROBE_WAIT;
            end
            ST_PROBE_WAIT: begin
                timeout <= timeout - 1;
                if (!target_dataslot_done) saw_busy <= 1;
                if (saw_busy && target_dataslot_done) begin
                    if (target_dataslot_err == 3) state <= ST_CREATE;
                    else if (target_dataslot_err == 0) begin
                        if (backup_index == 16'hFFFF) fail_command(ERR_NAMES_FULL);
                        else begin
                            backup_index <= backup_index + 16'd1;
                            state <= ST_PROBE;
                        end
                    end else fail_command({1'b0, target_dataslot_err});
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_CREATE: begin
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
                    if (target_dataslot_err == 1) begin
                        created_owned <= 1;
                        state <= ST_RESIZE;
                    end
                    else if (target_dataslot_err == 0) fail_command(ERR_CREATE_RACE);
                    else fail_command({1'b0, target_dataslot_err});
                end else if (timeout == 0) begin
                    poisoned <= 1;
                    fail_command(ERR_TIMEOUT);
                end
            end
            ST_RESIZE: begin
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
                    if (target_dataslot_err != 0) fail_command({1'b0, target_dataslot_err});
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
                    if (target_dataslot_err != 0) fail_command({1'b0, target_dataslot_err});
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
