// SPDX-License-Identifier: GPL-3.0-or-later
//
// Restore overlay. The complete display snapshot and each whole row are
// registered before the column byte mux, matching the existing UI pipeline.
// A previous operation's phase/CRC/backup fields are hidden during unlock.
// A check build can never claim that cartridge data was restored.

`default_nettype none

module ui_restore_screen (
    input  wire        clk,
    input  wire        reset,
    input  wire        active,
    input  wire [3:0]  guard_state,
    input  wire [1:0]  hold_progress,
    input  wire [5:0]  phase,
    input  wire [4:0]  error,
    input  wire [3:0]  io_error,
    input  wire [108:0] io_debug,
    input  wire [475:0] io_detail,
    input  wire [31:0] rom_crc,
    input  wire [31:0] save_crc,
    input  wire [15:0] backup_index,
    input  wire        write_enabled,
    output reg  [9:0]  tb_addr,
    output reg  [7:0]  tb_char,
    output reg  [1:0]  tb_attr,
    output reg         tb_we
);

localparam integer COLS = 30;
localparam integer ROWS = 20;
localparam integer LW = COLS * 8;
localparam [LW-1:0] BLANK = "                              ";
`include "build_stamp.vh"

function [7:0] hex_digit(input [3:0] value);
    hex_digit = value < 4'd10 ? 8'h30 + {4'b0, value} :
                               8'h41 + {4'b0, value} - 8'd10;
endfunction

function [63:0] hex_word(input [31:0] value);
    hex_word = {hex_digit(value[31:28]), hex_digit(value[27:24]),
                hex_digit(value[23:20]), hex_digit(value[19:16]),
                hex_digit(value[15:12]), hex_digit(value[11:8]),
                hex_digit(value[7:4]), hex_digit(value[3:0])};
endfunction

function [15:0] hex_count(input [6:0] value);
    hex_count = {hex_digit({1'b0, value[6:4]}), hex_digit(value[3:0])};
endfunction
function [15:0] hex_index(input [6:0] value);
    hex_index = value == 7'h7F ? "--" : hex_count(value);
endfunction

// Forty observed bytes cover all three fixed paths and their terminators.
// Missing words and non-ASCII bytes are visible, not silently blanked.
function [199:0] path_text(input [319:0] bytes, input [9:0] seen,
                           input integer first, input integer count);
    integer i, offset;
    reg [7:0] ch;
    begin
        path_text = "                         ";
        for (i = 0; i < 25; i = i + 1) begin
            offset = first + i;
            if (i < count && offset < 40) begin
                ch = bytes[offset*8 +: 8];
                path_text[199-i*8 -: 8] = !seen[offset/4] ? "?" :
                    ch == 0 ? "~" : ch >= 8'h20 && ch <= 8'h7E ? ch : "?";
            end
        end
    end
endfunction

function [LW-1:0] io_stage_line(input [3:0] stage);
    case (stage)
        1: io_stage_line = "SD STAGE: OPEN INPUT          ";
        2: io_stage_line = "SD STAGE: CHECK SLOT ID       ";
        3: io_stage_line = "SD STAGE: CHECK FILE SIZE     ";
        4: io_stage_line = "SD STAGE: READ INPUT          ";
        5: io_stage_line = "SD STAGE: PROBE BACKUP NAME   ";
        6: io_stage_line = "SD STAGE: CREATE BACKUP       ";
        7: io_stage_line = "SD STAGE: SIZE NEW BACKUP     ";
        8: io_stage_line = "SD STAGE: WRITE BACKUP        ";
        9: io_stage_line = "SD STAGE: REOPEN BACKUP       ";
        10: io_stage_line = "SD STAGE: READ BACKUP         ";
        11: io_stage_line = "SD STAGE: GET INPUT PATH      ";
        12: io_stage_line = "SD STAGE: CHECK INPUT PATH    ";
        default: io_stage_line = "SD STAGE: NOT STARTED         ";
    endcase
endfunction

function [LW-1:0] status_line(input [3:0] guard, input [5:0] current_phase,
                              input [4:0] current_error, input writes);
    begin
        case (guard)
            4'd1: status_line = "HOLD SELECT TO ENTER RESTORE  ";
            4'd2: status_line = "RESTORE READY                 ";
            4'd3: status_line = "PREFLIGHT IN PROGRESS         ";
            4'd6: status_line = "PREFLIGHT CHECKS PASSED       ";
            4'd7: status_line = writes ? "RESTORE IN PROGRESS           " :
                                         "FINAL CHECKS IN PROGRESS      ";
            4'd8: status_line = current_phase != 6'd18 || current_error != 5'd0 ?
                                         "RESULT NOT VERIFIED           " :
                               writes ? "RESTORE VERIFIED              " :
                                         "CHECK COMPLETE                ";
            4'd9: status_line = "RESTORE STOPPED               ";
            4'd10: status_line = "STOPPING SAFELY               ";
            default: status_line = "RESTORE LOCKED                ";
        endcase
    end
endfunction

function [LW-1:0] action_line(input [3:0] guard, input [5:0] current_phase,
                              input [4:0] current_error, input writes);
    begin
        case (guard)
            4'd1: action_line = "KEEP SELECT HELD FOR 3 SECONDS";
            4'd2: action_line = "A: CHECK CART AND BACKUP      ";
            4'd3: action_line = "READS AND SD BACKUP ONLY      ";
            4'd6: action_line = "HOLD A FOR 3 SECONDS          ";
            4'd7: action_line = "KEEP CARTRIDGE AND POWER ON   ";
            4'd8: action_line = current_phase != 6'd18 || current_error != 5'd0 ?
                                         "NO SUCCESS REPORTED           " :
                               writes ? "TWO READBACK CHECKS PASSED    " :
                                         "WRITES DISABLED               ";
            4'd9: action_line = "NO SUCCESS REPORTED           ";
            4'd10: action_line = "WAIT FOR CARTRIDGE CLEANUP    ";
            default: action_line = "HOLD SELECT FOR RESTORE       ";
        endcase
    end
endfunction

// Progress is measured in thirds of the required hold. Only the two hold
// states display it, so a retained completed hold cannot look like the next
// action has already been confirmed.
function [LW-1:0] progress_line(input [1:0] progress);
    begin
        case (progress)
            2'd0: progress_line = "HOLD PROGRESS [---] 0/3       ";
            2'd1: progress_line = "HOLD PROGRESS [#--] 1/3       ";
            2'd2: progress_line = "HOLD PROGRESS [##-] 2/3       ";
            2'd3: progress_line = "HOLD PROGRESS [###] 3/3       ";
        endcase
    end
endfunction

function [LW-1:0] phase_line(input [5:0] current_phase);
    begin
        case (current_phase)
            6'd1: phase_line = "READING IDENTITY METADATA     ";
            6'd2: phase_line = "VALIDATING IDENTITY METADATA  ";
            6'd3: phase_line = "LOADING RESTORE SAVE          ";
            6'd4: phase_line = "CHECKING INPUT SAVE CRC       ";
            6'd5: phase_line = "WAITING FOR STABLE CARTRIDGE  ";
            6'd6: phase_line = "SETTING KNOWN MAPPER STATE    ";
            6'd7: phase_line = "CHECKING FULL ROM IDENTITY    ";
            6'd8: phase_line = "READING ORIGINAL SAVE         ";
            6'd9: phase_line = "COMPARING SECOND SAVE READ    ";
            6'd10: phase_line = "WRITING AND REREADING BACKUP  ";
            6'd11: phase_line = "COMPARING SD RECOVERY BYTES   ";
            6'd12: phase_line = "RECOVERY FILE VERIFIED        ";
            6'd13: phase_line = "RECHECKING FULL ROM IDENTITY  ";
            6'd14: phase_line = "RECHECKING ORIGINAL SAVE      ";
            6'd15: phase_line = "PROGRAMMING CARTRIDGE RAM     ";
            6'd16: phase_line = "VERIFYING RESTORED SAVE 1/2   ";
            6'd17: phase_line = "VERIFYING RESTORED SAVE 2/2   ";
            6'd18: phase_line = "CHECKS FINISHED               ";
            6'd19: phase_line = "CHECK DID NOT COMPLETE        ";
            6'd20: phase_line = "WAITING FOR SAFE STOP         ";
            6'd21: phase_line = "DISABLING RAM AND CLEANUP     ";
            6'd22: phase_line = "FINAL CART SAFETY SCAN        ";
            default: phase_line = "STARTING PREFLIGHT            ";
        endcase
    end
endfunction

function [LW-1:0] error_line(input [4:0] current_error);
    begin
        case (current_error)
            5'd1: error_line = "INVALID RESTORE METADATA      ";
            5'd2: error_line = "UNSUPPORTED CARTRIDGE         ";
            5'd3: error_line = "INPUT SAVE CRC MISMATCH       ";
            5'd4: error_line = "ROM IDENTITY MISMATCH         ";
            5'd5: error_line = "ORIGINAL SAVE READS DIFFER    ";
            5'd6: error_line = "SD FILE OPERATION FAILED      ";
            5'd7: error_line = "SD RECOVERY BYTES DIFFER      ";
            5'd8: error_line = "CARTRIDGE CHANGED             ";
            5'd9: error_line = "RESTORED SAVE READS DIFFER    ";
            5'd10: error_line = "CANCELED OR POWER LOST        ";
            5'd11: error_line = "OPERATION TIMED OUT           ";
            5'd12: error_line = "CARTRIDGE WRITER FAILED       ";
            default: error_line = "CHECK DID NOT COMPLETE        ";
        endcase
    end
endfunction

wire [687:0] snapshot = {active, guard_state, hold_progress, phase, error, io_error, io_debug, io_detail, rom_crc,
                       save_crc, backup_index, write_enabled};
reg [687:0] shown;
reg dirty;
reg was_active;
wire shown_active;
wire [3:0] shown_guard;
wire [1:0] shown_progress;
wire [5:0] shown_phase;
wire [4:0] shown_error;
wire [3:0] shown_io_error;
wire [1:0] shown_io_op;
wire [3:0] shown_io_stage;
wire [6:0] shown_io_reads;
wire [31:0] shown_io_first, shown_io_tail, shown_io_flags;
wire [319:0] shown_path;
wire [9:0] shown_path_seen;
wire [6:0] shown_unique, shown_repeats;
wire [27:0] shown_repeat_indices;
wire shown_bad;
wire [6:0] shown_bad_index;
wire [31:0] shown_bad_word, shown_bad_expected, shown_size;
wire [31:0] shown_rom;
wire [31:0] shown_save;
wire [15:0] shown_backup;
wire shown_writes;
assign {shown_active, shown_guard, shown_progress, shown_phase, shown_error, shown_io_error,
        shown_io_op, shown_io_stage, shown_io_reads, shown_io_first, shown_io_tail, shown_io_flags,
        shown_path, shown_path_seen, shown_unique, shown_repeats, shown_repeat_indices,
        shown_bad, shown_bad_index, shown_bad_word, shown_bad_expected, shown_size, shown_rom,
        shown_save, shown_backup, shown_writes} = shown;

wire sd_failure = shown_guard == 4'd9 && shown_error == 5'd6;

wire checks_passed = shown_error == 5'd0 &&
                     ((shown_guard == 4'd6 || shown_guard == 4'd7) ||
                      (shown_guard == 4'd8 && shown_phase == 6'd18));
wire [LW-1:0] rom_line = {"ROM CRC  ",
    hex_digit(shown_rom[31:28]), hex_digit(shown_rom[27:24]),
    hex_digit(shown_rom[23:20]), hex_digit(shown_rom[19:16]),
    hex_digit(shown_rom[15:12]), hex_digit(shown_rom[11:8]),
    hex_digit(shown_rom[7:4]), hex_digit(shown_rom[3:0]), "             "};
wire [LW-1:0] save_line = {"SAVE CRC ",
    hex_digit(shown_save[31:28]), hex_digit(shown_save[27:24]),
    hex_digit(shown_save[23:20]), hex_digit(shown_save[19:16]),
    hex_digit(shown_save[15:12]), hex_digit(shown_save[11:8]),
    hex_digit(shown_save[7:4]), hex_digit(shown_save[3:0]), "             "};
wire [LW-1:0] recovery_line = {"RECOVERY ID ",
    hex_digit(shown_backup[15:12]), hex_digit(shown_backup[11:8]),
    hex_digit(shown_backup[7:4]), hex_digit(shown_backup[3:0]),
    "              "};
wire [LW-1:0] io_error_line = {"SD ERROR: ", hex_digit(shown_io_error),
                              "                   "};

reg painting;
reg [4:0] row_c;
reg [4:0] col_c;
reg [9:0] addr_c;
reg [4:0] col_r;
reg [9:0] addr_r;
reg [LW-1:0] line_r;
reg [1:0] attr_r;
reg paint_r;
reg [LW-1:0] line_next;

always @* begin
    line_next = BLANK;
    case (row_c)
        5'd0: line_next = "CARTRIDGE SAVE RESTORE        ";
        5'd1: line_next = {"BUILD ", hex_digit(BUILD_STAMP[15:12]), hex_digit(BUILD_STAMP[11:8]),
                           hex_digit(BUILD_STAMP[7:4]), hex_digit(BUILD_STAMP[3:0]),
                           "                    "};
        5'd2: line_next = sd_failure && shown_io_op == 0 ? "FILE: RESTORE.meta            " :
                         sd_failure && shown_io_op == 2 ?
                         {"FILE: PRE", hex_digit(shown_backup[15:12]), hex_digit(shown_backup[11:8]),
                          hex_digit(shown_backup[7:4]), hex_digit(shown_backup[3:0]), ".sav             "} :
                         "FILE: RESTORE.sav             ";
        5'd3: line_next = sd_failure ? {"PATH ", path_text(shown_path, shown_path_seen, 0, 25)} :
                                     "FIRST TARGET: MBC1 8K         ";
        5'd4: line_next = sd_failure ? {"NAME ", path_text(shown_path, shown_path_seen, 25, 15)} :
                                     "LINK'S AWAKENING (NON-DX)     ";
        5'd5: line_next = shown_writes ? "CARTRIDGE WRITES ENABLED      " :
                                         "CORE WRITES DISABLED          ";
        5'd7: line_next = status_line(shown_guard, shown_phase, shown_error, shown_writes);
        5'd8: line_next = action_line(shown_guard, shown_phase, shown_error, shown_writes);
        5'd9: line_next = shown_guard == 4'd1 || shown_guard == 4'd6 ?
                         progress_line(shown_progress) : BLANK;
        5'd10: begin
            if (shown_guard == 4'd3)
                line_next = shown_phase >= 6'd1 && shown_phase <= 6'd11 ?
                            phase_line(shown_phase) : "STARTING PREFLIGHT            ";
            else if (shown_guard == 4'd9)
                line_next = error_line(shown_error);
            else if (shown_guard == 4'd10)
                line_next = phase_line(6'd20);
            else if (checks_passed)
                line_next = phase_line(shown_phase);
        end
        5'd11: line_next = shown_guard == 4'd9 && shown_error == 5'd6 ?
                          io_error_line : BLANK;
        5'd12: line_next = sd_failure ? io_stage_line(shown_io_stage) :
                          checks_passed ? rom_line : BLANK;
        5'd13: line_next = sd_failure ? {shown_io_op < 2 ? "RX    " : "READS ", hex_count(shown_io_reads),
                                         " UNIQUE ", hex_count(shown_unique),
                                         " RPT ", hex_count(shown_repeats), "     "} :
                          checks_passed ? save_line : BLANK;
        5'd14: line_next = sd_failure ? {"REPEAT ", hex_index(shown_repeat_indices[6:0]), " ",
                                        hex_index(shown_repeat_indices[13:7]), " ",
                                        hex_index(shown_repeat_indices[20:14]), " ",
                                        hex_index(shown_repeat_indices[27:21]), "            "} :
                          checks_passed ? recovery_line : BLANK;
        5'd15: line_next = sd_failure ? {"FLAGS ", hex_word(shown_io_flags),
                                         " SIZE ", hex_word(shown_size), "  "} :
                          checks_passed ? "RECOVERY FILE VERIFIED        " : BLANK;
        5'd16: line_next = sd_failure ? (shown_bad ? {"BAD ", hex_index(shown_bad_index),
                                      " GOT ", hex_word(shown_bad_word), "           "} :
                                      "NO OBSERVED WORD MISMATCH     ") : BLANK;
        5'd17: line_next = sd_failure ? (shown_bad ? {"EXP ", hex_word(shown_bad_expected),
                                                    "                  "} :
                                      "PATH: ~ NUL  ? UNREAD/NONASCII") :
                          shown_guard >= 4'd2 ?
                              "RESTORE PAGE STAYS OPEN       " : BLANK;
        5'd18: line_next = shown_guard == 4'd3 || shown_guard == 4'd6 ||
                          shown_guard == 4'd7 || shown_guard == 4'd10 ?
                              "B: REQUEST SAFE STOP          " :
                          shown_guard == 4'd8 || shown_guard == 4'd9 ?
                              "B: CLOSE  HOLD SELECT: RETRY  " :
                          shown_guard == 4'd1 ?
                              "B: CANCEL HOLD                " :
                              "B: CLOSE RESTORE PAGE         ";
        5'd19: line_next = shown_writes ?
                              "SAVE DATA WILL BE OVERWRITTEN " :
                              "CHECK BUILD: NO SAVE WRITES   ";
        default: line_next = BLANK;
    endcase
end

always @(posedge clk) begin
    if (reset) begin
        shown      <= 688'b0;
        dirty      <= 1'b1;
        was_active <= 1'b0;
        painting   <= 1'b0;
        row_c      <= 5'd0;
        col_c      <= 5'd0;
        addr_c     <= 10'd0;
        col_r      <= 5'd0;
        addr_r     <= 10'd0;
        line_r     <= BLANK;
        attr_r     <= 2'd0;
        paint_r    <= 1'b0;
        tb_addr    <= 10'd0;
        tb_char    <= 8'h20;
        tb_attr    <= 2'd0;
        tb_we      <= 1'b0;
    end else begin
        // Register the change comparator separately from the painter control.
        dirty      <= snapshot != shown;
        was_active <= active;
        tb_we      <= 1'b0;
        paint_r    <= painting && active;
        line_r     <= line_next;
        attr_r     <= row_c == 5'd0 || row_c == 5'd5 ? 2'd1 : 2'd0;
        col_r      <= col_c;
        addr_r     <= addr_c;

        if (!active) begin
            painting <= 1'b0;
            paint_r  <= 1'b0;
        end else if (!was_active || dirty) begin
            shown    <= snapshot;
            painting <= 1'b1;
            row_c    <= 5'd0;
            col_c    <= 5'd0;
            addr_c   <= 10'd0;
            paint_r  <= 1'b0;
        end else begin
            if (painting) begin
                if (addr_c == COLS * ROWS - 1) begin
                    painting <= 1'b0;
                end else begin
                    addr_c <= addr_c + 10'd1;
                    if (col_c == COLS - 1) begin
                        col_c <= 5'd0;
                        row_c <= row_c + 5'd1;
                    end else begin
                        col_c <= col_c + 5'd1;
                    end
                end
            end
            if (paint_r) begin
                tb_addr <= addr_r;
                tb_char <= line_r[(COLS - 1 - col_r) * 8 +: 8];
                tb_attr <= attr_r;
                tb_we   <= 1'b1;
            end
        end
    end
end

endmodule

`default_nettype wire
