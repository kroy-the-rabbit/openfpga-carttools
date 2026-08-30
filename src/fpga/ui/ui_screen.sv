//
// ui_screen.sv - paint the identification result into the text buffer
//
// Phase 3's screen, and nothing more. There is no menu yet because there is
// nothing to choose between: the core identifies whatever is in the slot and
// says what it found.
//
//   CARTRIDGE TOOLS
//
//   GBA CARTRIDGE
//
//   Title  TESTCART
//   Code   AMTE
//   Maker  01
//   Ver    00
//
//   header ok  checksum ok
//
// How it paints
// -------------
// A full repaint of all 600 cells, triggered whenever the inputs change. That
// is 600 writes at 100 MHz, six microseconds, against a renderer that repaints
// the screen every 382 us. Repainting everything rather than tracking which
// cells changed costs nothing here and removes a whole class of bug where the
// screen keeps a line from a previous cartridge.
//
// The layout is a set of 30-character constants, one per row, with the
// variable fields overlaid at fixed columns. Keeping the static text as whole
// lines means the screen can be read in the source in the same shape it has
// on the display.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module ui_screen #(
    parameter COLS = 30,
    parameter ROWS = 20
) (
    input  wire        clk,
    input  wire        reset,

    // Result snapshot from cart_identify_gba. Stable while `valid` is high.
    input  wire        valid,           // an identification has completed
    input  wire [2:0]  platform,        // cart_probe result, see below
    input  wire [95:0] title,
    input  wire [31:0] game_code,
    input  wire [15:0] maker_code,
    input  wire [7:0]  sw_version,
    input  wire        fixed_ok,
    input  wire        checksum_ok,
    input  wire        reserved_ok,

    // How big the GBA cartridge is, already reduced to a code by core_top.
    // A code and not the number, for two reasons that are the same reason:
    // the repaint trigger compares four bits instead of thirty-four, and the
    // screen picks a whole prepared row instead of formatting a number in the
    // per-column path. That path has failed setup three times.
    //
    //   0     nothing to say
    //   1..6  1, 2, 4, 8, 16, 32 MB, measured
    //   7     32 MB, but by exhaustion rather than by observation
    //   8     something is in the slot and it could not be sized
    //   9     the slot answered with one value everywhere
    input  wire [3:0]   gba_size_code,

    // The dumped image's CRC32. Not a verdict - there is nothing here to
    // compare it against - but it is what a second dump, or a published
    // image, is compared with, and on GBA it is the only such thing that
    // exists.
    input  wire [31:0]  crc32,

    // Game Boy fields, used when platform is P_GB.
    input  wire [119:0] gb_title,
    input  wire [7:0]   gb_cart_type,
    input  wire [7:0]   gb_rom_size,
    input  wire [7:0]   gb_ram_size,
    input  wire         gb_checksum_ok,
    input  wire        scanning,        // an identification is in progress


    // Increments once per completed identification. It is in the repaint
    // Increments once per completed probe. Every header field on both
    // platforms changes only when it does, so it is the whole repaint
    // trigger for them. A caller that changes a field without incrementing
    // it will not see the screen update.
    input  wire [3:0]   id_seq,

    // Dumping. dump_state is held after a dump finishes rather than being
    // derived from a busy flag, so the result of the last one stays readable
    // instead of vanishing the moment the engine goes idle.
    input  wire [1:0]   dump_state,      // 0 idle, 1 running, 2 ok, 3 failed
    input  wire         dump_ready,      // X would do something right now
    input  wire [2:0]   dump_err,        // target_dataslot_err of the failure
    input  wire [15:0]  dump_fail_chunk,
    input  wire         no_open,         // written into the slot's own file
    input  wire [1:0]   stall_at,        // 1 open, 2 write, 3 flush

    // The cartridge's own checksum against the image just read. This is the
    // only thing on this screen that judges a dump rather than reporting on
    // it.
    // A save has no checksum, no logo and no length of its own - every check
    // that makes a ROM dump trustworthy is missing - so these facts are shown
    // as facts rather than folded into a verdict.
    input  wire         save_shown,      // the last dump was a save
    input  wire         save_ready,      // Y would do something right now
    // This cartridge has save RAM and this core cannot read it. Distinct from
    // "no save": a cartridge with nothing to back up needs no explanation,
    // and one with a save that Y silently will not touch does. The first
    // cartridge the save path ever met was refused with no word on screen.
    input  wire         save_refused,
    input  wire         save_responded,  // the RAM answered the presence probe
    input  wire         save_blank_ff,
    input  wire         save_blank_00,
    input  wire [31:0]  save_first,      // first four bytes read

    input  wire         sum_checked,
    input  wire         sum_ok,
    input  wire [15:0]  sum_computed,
    input  wire [15:0]  sum_stored,
    input  wire [7:0]   dump_progress,   // 0 to 255, for the bar
    input  wire [127:0] out_name,        // the file's name, without the root
    input  wire [4:0]   out_name_len,
    input  wire [31:0]  out_ext,
    input  wire [2:0]   out_ext_len,


    // Text buffer write port
    output reg  [9:0]  tb_addr,
    output reg  [7:0]  tb_char,
    output reg  [1:0]  tb_attr,
    output reg         tb_we
);

// cart_probe platform codes. These reach the user as text; append, never
// renumber.
localparam [2:0] P_NONE     = 3'd0;
localparam [2:0] P_GBA      = 3'd1;
localparam [2:0] P_GB       = 3'd2;
localparam [2:0] P_UNKNOWN  = 3'd3;
localparam [2:0] P_UNSTABLE = 3'd4;
localparam [2:0] P_NO_POWER = 3'd5;

// Which bitstream is actually running, as four hex characters in the title
// row. Two hardware sessions were spent flashing builds that looked identical
// on screen, with no way to tell whether the card had taken the new one.
`include "build_stamp.vh"

localparam integer CELLS = COLS * ROWS;
localparam integer LW    = 8 * COLS;      // one row of text, as bits

// ---- Static rows ----------------------------------------------------------
//                                       111111111122222222223
//                             0123456789012345678901234567890
localparam [LW-1:0] ROW_TITLE = "CARTRIDGE TOOLS               ";
localparam [LW-1:0] ROW_BLANK = "                              ";

localparam [LW-1:0] MSG_GBA      = "GBA CARTRIDGE                 ";
localparam [LW-1:0] MSG_GB       = "GB / GBC CARTRIDGE            ";
localparam [LW-1:0] MSG_NO_CART  = "NO CARTRIDGE DETECTED         ";
localparam [LW-1:0] MSG_UNSTABLE = "UNSTABLE READ, RESEAT CART    ";
localparam [LW-1:0] MSG_NOT_GBA  = "UNRECOGNISED CARTRIDGE        ";
localparam [LW-1:0] MSG_NO_POWER = "SELECT PLAY CARTRIDGE         ";
localparam [LW-1:0] MSG_SCANNING = "READING HEADER...             ";
localparam [LW-1:0] MSG_READY    = "READY                         ";

// Sizes and mappers as words, not as the header codes. "ROM 05" is the number
// in the cartridge; "1 MB" is what it means, and nobody carries the table in
// their head.
localparam [LW-1:0] ROW_SIZES = "ROM              RAM          ";

localparam [LW-1:0] ROW_GBA_CODE = "Code           Maker          ";   // AMTE at 5, 01 at 21

// The GBA size shares the version row, and it shares it as a whole prepared
// line rather than as a field overlaid at a column. There is no field mux, no
// comparison against col, nothing new between the column counter and the
// character: the row is chosen at the row counter, one stage earlier, and
// registered. ui_screen has failed setup three times on the per-column path
// and this is the shape that does not touch it.
//
// The version digits are still overlaid at columns 8 and 9 by the field path,
// which is why every line below leaves those columns blank.
//
// "32 MB max" is not the same claim as "32 MB". 32 MB is the largest the bus
// can address - rom_word_addr is latched_addr[24:1] - so a probe that reaches
// it has run out of candidates rather than found an end, and the screen must
// not present a guess and a measurement in the same words.
localparam [LW-1:0] ROW_GBA_VER  = "Version                       ";   // 00 at 8
localparam [LW-1:0] ROW_SZ_1     = "Version        ROM 1 MB       ";
localparam [LW-1:0] ROW_SZ_2     = "Version        ROM 2 MB       ";
localparam [LW-1:0] ROW_SZ_4     = "Version        ROM 4 MB       ";
localparam [LW-1:0] ROW_SZ_8     = "Version        ROM 8 MB       ";
localparam [LW-1:0] ROW_SZ_16    = "Version        ROM 16 MB      ";
localparam [LW-1:0] ROW_SZ_32    = "Version        ROM 32 MB      ";
localparam [LW-1:0] ROW_SZ_CEIL  = "Version        ROM 32 MB max  ";
localparam [LW-1:0] ROW_SZ_NONE  = "Version        size not found ";
localparam [LW-1:0] ROW_SZ_FLAT  = "Version        blank cartridge";
localparam [LW-1:0] ROW_GB_FLAGS = "checksum                      ";   // verdict at 9
localparam [LW-1:0] ROW_BLANKR   = "                              ";

// The flags row, with the two verdicts overlaid at columns 7 and 20.
localparam [LW-1:0] ROW_FLAGS_BASE = "header     checksum           ";
localparam [LW-1:0] ROW_FLAGS_GB   = "           checksum           ";

// Two help rows, not one. X does nothing at all unless a Game Boy cartridge
// has been identified, and a button that is silently inert is worse than one
// that is visibly absent.
localparam [LW-1:0] ROW_HELP_DUMP  = "A scan  X dump                ";
localparam [LW-1:0] ROW_HELP_SAVE  = "A scan  X dump  Y save        ";
localparam [LW-1:0] ROW_HELP_PLAIN = "A scan                        ";

// The dump status line. Values are overlaid at fixed columns:
//
//   DUMPING 0042 OF 0200
//   0       8    13 16
//
//   DUMP FAILED  err 5  chunk 0042
//   0            13  17   20    26
localparam [LW-1:0] ROW_DUMPING   = "DUMPING                       ";
localparam [LW-1:0] ROW_BAR       = "[                ]            ";
localparam [LW-1:0] ROW_DUMP_OK   = "DUMP COMPLETE                 ";
// Same bytes on the card, but under the slot's own name rather than one
// chosen from the cartridge title. A different outcome, not a lesser one.
localparam [LW-1:0] ROW_DUMP_SLOT = "DUMPED TO SLOT FILE           ";

// Row 13, once a dump has finished. The good case is one word, because a
// dump that verified needs no explanation. The bad case shows both numbers,
// because the difference between them is the only clue to the fault.
localparam [LW-1:0] ROW_ISUM_OK  = "image checksum ok             ";
localparam [LW-1:0] ROW_ISUM_BAD = "image sum      want           ";
localparam [LW-1:0] ROW_DUMP_FAIL = "DUMP FAILED  err              ";

// target_dataslot_err in words. The code is still shown, because it is what
// the documentation is written in, but on its own it tells a user nothing.
localparam [LW-1:0] ERR_2 = "slot 20 not declared          ";
localparam [LW-1:0] ERR_3 = "file not found                ";
localparam [LW-1:0] ERR_4 = "APF rejected every path       ";
localparam [LW-1:0] ERR_5 = "card full or write locked     ";
localparam [LW-1:0] ERR_7 = "cartridge removed             ";
localparam [LW-1:0] ERR_X = "unexpected result             ";
// APF never answered. Which command it was matters: a stalled flush means
// every write already succeeded and the bytes may well be on the card.
localparam [LW-1:0] ERR_6_OPEN  = "APF never answered the open   ";
localparam [LW-1:0] ERR_6_WRITE = "APF never answered a write    ";
localparam [LW-1:0] ERR_6_FLUSH = "written, but never flushed    ";

// Columns the variable fields start at.
localparam integer FIELD_COL = 7;


// A save backup's own report, on the row a ROM dump uses for its checksum
// verdict. Which line is chosen says what happened, in this order of
// precedence: whether the RAM answered at all comes first, because a save
// that was never read is not a blank save.
//
// A dead battery and a dead enable look the same from outside - both give
// 0xFF - so the screen says both facts and does not pick between them. That
// is why "did not answer" is shouted and "blank" is not: the first means the
// file is probably worthless, the second may be a perfectly good backup of a
// cartridge whose battery went flat years ago.
localparam [LW-1:0] ROW_SAVE_OK   = "save RAM answered             ";
localparam [LW-1:0] ROW_SAVE_DEAD = "SAVE RAM DID NOT ANSWER       ";
localparam [LW-1:0] ROW_SAVE_FF   = "save is blank, every byte FF  ";
localparam [LW-1:0] ROW_SAVE_00   = "save is blank, every byte 00  ";
localparam [LW-1:0] ROW_NO_SAVE   = "save RAM here is not supported";

// Rows.
// The cartridge occupies rows 4 to 7 and the dump rows 10 to 12, so the two
// never move about relative to each other as a dump runs.
localparam integer R_TITLE  = 0;
localparam integer R_MSG    = 2;
localparam integer R_NAME   = 4;
localparam integer R_TYPE   = 5;
localparam integer R_SIZE   = 6;
localparam integer R_FLAGS  = 7;
localparam integer R_DUMP   = 10;
localparam integer R_BAR    = 11;
localparam integer R_FILE   = 12;
localparam integer R_VERIFY = 13;
localparam integer R_CRC    = 14;
localparam integer R_FIRST  = 15;
localparam integer R_HELP   = 18;

// A nibble as a hex character. Up here rather than beside its first user
// because the CRC32 row below is built out of eight of them, and that row is
// assembled before the character mux rather than inside it.
function [7:0] hex_digit(input [3:0] v);
    hex_digit = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
endfunction

// ---- Repaint trigger ------------------------------------------------------
//
// Any change to what would be displayed starts a repaint. Comparing the whole
// snapshot rather than watching for a done pulse means the screen is also
// correct after a reset or a change of cart_mode, neither of which produces
// one.

// Everything that can change what is on screen. Comparing the whole thing
// rather than watching for a done pulse means the screen is also correct
// after a reset or a change of slot power, neither of which produces one.
//
// Every header field, on both platforms, changes only when a probe completes
// and id_seq counts those, so none of them are compared here. A 320 bit
// comparator made this the critical path of the core; 39 bits does not.
//
// The dump fields are here for the reason the identification fields are not:
// they change without a probe completing, so id_seq does not cover them.
// Only the low eight bits of the stored checksum and four of the progress
// byte are compared, which is enough because the low bits always move when
// the value does, and comparing all of them would put another twenty bits in
// a path that has already failed timing once.
// save_ready is here for the reason dump_ready is: it changes the help row
// with no dump running. save_shown is here because it changes which verdict
// row 13 carries. The rest of the save fields are not, for the reason crc32
// is not: they are latched at the start of a save and read at the end of it,
// so they cannot move without dump_state moving with them.
wire [38:0] snapshot = {valid, scanning, platform, id_seq,
                        save_ready, save_shown, save_refused,
                        // The probed size, as a code. Four bits, and they are
                        // needed: the size arrives after the probe that
                        // id_seq counts, so id_seq has already moved by the
                        // time there is a size to show.
                        gba_size_code,
                        dump_state, dump_ready, no_open, stall_at,
                        sum_checked, sum_ok, sum_computed[7:0],
                        // Four bits, because the bar has sixteen cells and
                        // changes only when they do.
                        dump_progress[7:4], dump_err};

reg [38:0] shown;
reg         painting;

// ---- Where the painter is -------------------------------------------------
//
// Row, column and linear address are kept as three counters that advance
// together, rather than one counter with the other two derived from it.
//
// That is a timing decision made the expensive way. The first version stored
// only the cell number and wrote `row = cell / COLS`, which Quartus turned
// into an lpm_divide: an 11.4 ns path from the counter through a divider and
// the character mux, against a 9.93 ns clock, and the build failed setup by
// 2.3 ns. Division by 30 in a per-cycle path is not free just because 30 is a
// constant. Three counters and one comparison cost a handful of ALMs and
// nothing in depth.

// Two stages, and the split is a timing decision made the expensive way for
// the second time. The character mux runs from the column counter through a
// twenty-way mux of whole rows and then a thirty-way byte select, and once
// the dump bar, the filename field and the mapper and size lookups were added
// on top of that it missed setup by 0.694 ns.
//
// So the counters advance in one cycle and the character is chosen in the
// next, from a row that has already been selected and registered. That takes
// the twenty-way mux out of the column path entirely. The painter is 601
// cycles instead of 600, against a renderer that repaints every 382 us.
reg [4:0] row_c;    // counters
reg [4:0] col_c;
reg [9:0] addr_c;

reg [4:0] row;      // registered, and what every character decision reads
reg [4:0] col;
reg [9:0] addr_r;
reg       paint_r;

// ---- Character selection --------------------------------------------------

// The message row depends on where the identification got to, which is three
// states rather than two: nothing tried yet, trying, and a result.
//
// Written as a function behind a continuous assignment rather than an
// always @(*) block. The difference is not style: with no cartridge in the
// slot none of these three inputs ever changes, so an always @(*) never fires
// and the line holds X in simulation while hardware would have settled it.
// That is a simulation and synthesis mismatch on the exact case a user is
// most likely to hit first, a cold boot with an empty slot.
function [LW-1:0] msg_of(input scan, input val, input [2:0] res);
    begin
        if (scan)       msg_of = MSG_SCANNING;
        else if (!val)  msg_of = MSG_READY;
        else case (res)
            P_GBA:      msg_of = MSG_GBA;
            P_GB:       msg_of = MSG_GB;
            P_NONE:     msg_of = MSG_NO_CART;
            P_UNSTABLE: msg_of = MSG_UNSTABLE;
            P_UNKNOWN:  msg_of = MSG_NOT_GBA;
            P_NO_POWER: msg_of = MSG_NO_POWER;
            // Every result code has a line. A code with no line would put the
            // user in front of a blank screen after a failure, which is the
            // moment they most need to be told something.
            default:         msg_of = MSG_NOT_GBA;
        endcase
    end
endfunction

wire [LW-1:0] msg_line = msg_of(scanning, valid, platform);

wire settled     = valid && !scanning;
wire details_gba = settled && (platform == P_GBA);
wire details_gb  = settled && (platform == P_GB);
wire details     = details_gba || details_gb;

// Same reasoning as msg_of: a function behind a continuous assignment, so it
// is defined before anything changes rather than after.
function [LW-1:0] dump_line_of(input [1:0] st, input nop);
    begin
        case (st)
            2'd1:    dump_line_of = ROW_DUMPING;
            2'd2:    dump_line_of = nop ? ROW_DUMP_SLOT : ROW_DUMP_OK;
            2'd3:    dump_line_of = ROW_DUMP_FAIL;
            default: dump_line_of = ROW_BLANK;
        endcase
    end
endfunction

wire [LW-1:0] dump_line = dump_line_of(dump_state, no_open);

// The GBA version row, with the probed size in it. One of ten prepared lines,
// picked here in the row path, so the column path is untouched. Written as a
// function behind a continuous assignment for the same reason msg_of is: with
// nothing in the slot none of its inputs ever changes, and an always @(*)
// would never fire.
function [LW-1:0] gba_ver_line(input [3:0] code);
    begin
        case (code)
            4'd1:    gba_ver_line = ROW_SZ_1;
            4'd2:    gba_ver_line = ROW_SZ_2;
            4'd3:    gba_ver_line = ROW_SZ_4;
            4'd4:    gba_ver_line = ROW_SZ_8;
            4'd5:    gba_ver_line = ROW_SZ_16;
            4'd6:    gba_ver_line = ROW_SZ_32;
            4'd7:    gba_ver_line = ROW_SZ_CEIL;
            4'd8:    gba_ver_line = ROW_SZ_NONE;
            4'd9:    gba_ver_line = ROW_SZ_FLAT;
            // Including code 0: the size probe has not run or had nothing to
            // say, and a version row with no size on it is the honest answer.
            default: gba_ver_line = ROW_GBA_VER;
        endcase
    end
endfunction

wire [LW-1:0] gba_ver_row = gba_ver_line(gba_size_code);

// Row 14, after a dump that completed. Eight hex digits assembled into a
// whole row here, one stage before the column mux, so the CRC costs the
// per-column path nothing at all - which is the only reason it is on screen
// at this point in the design's life rather than waiting for a screen that
// could carry it properly.
//
// Shown only for a dump that finished. A CRC over a partial image is a number
// that looks exactly like a good one and means nothing.
wire [LW-1:0] ROW_CRC = {"crc32  ",
                         hex_digit(crc32[31:28]), hex_digit(crc32[27:24]),
                         hex_digit(crc32[23:20]), hex_digit(crc32[19:16]),
                         hex_digit(crc32[15:12]), hex_digit(crc32[11:8]),
                         hex_digit(crc32[7:4]),   hex_digit(crc32[3:0]),
                         "               "};

// Row 15 after a save, the raw evidence. Four bytes as eight hex digits,
// assembled here rather than in the column path for the same reason the CRC
// row is: the col -> tb_char mux has failed setup three times and nothing new
// goes in it.
wire [LW-1:0] ROW_FIRST = {"first  ",
                           hex_digit(save_first[31:28]), hex_digit(save_first[27:24]),
                           hex_digit(save_first[23:20]), hex_digit(save_first[19:16]),
                           hex_digit(save_first[15:12]), hex_digit(save_first[11:8]),
                           hex_digit(save_first[7:4]),   hex_digit(save_first[3:0]),
                           "               "};

// Which of the save lines, if any. Only after a save that finished: a verdict
// about a partial read is worth less than no verdict.
wire [LW-1:0] save_line =
    !(save_shown && dump_state == 2'd2) ? ROW_BLANKR :
    !save_responded                     ? ROW_SAVE_DEAD :
    save_blank_ff                       ? ROW_SAVE_FF :
    save_blank_00                       ? ROW_SAVE_00 :
                                          ROW_SAVE_OK;

wire [LW-1:0] first_line = (save_shown && dump_state == 2'd2) ? ROW_FIRST :
                           save_refused                       ? ROW_NO_SAVE
                                                              : ROW_BLANKR;

function [LW-1:0] line_of(input [4:0] r, input det, input gb,
                          input [LW-1:0] msg, input [LW-1:0] dmp,
                          input [LW-1:0] fil, input [LW-1:0] vsum,
                          input [LW-1:0] ver, input [LW-1:0] crcl,
                          input [LW-1:0] fst,
                          input rdy, input svrdy, input [1:0] dst);
    begin
        case (r)
            R_TITLE: line_of = ROW_TITLE;
            R_MSG:   line_of = msg;
            // The title is its own line with no label. A row that reads
            // "Title  ZELDA" spends seven characters saying something the
            // reader already knows from the fact that it is a cartridge.
            R_NAME:  line_of = ROW_BLANKR;
            R_TYPE:  line_of = det ? (gb ? ROW_BLANKR : ROW_GBA_CODE) : ROW_BLANKR;
            R_SIZE:  line_of = det ? (gb ? ROW_SIZES  : ver)          : ROW_BLANKR;
            R_FLAGS: line_of = det ? (gb ? ROW_GB_FLAGS : ROW_FLAGS_BASE)
                                   : ROW_BLANKR;
            R_DUMP:  line_of = dmp;
            R_BAR:   line_of = (dst == 2'd0) ? ROW_BLANKR : ROW_BAR;
            R_FILE:  line_of = fil;
            R_VERIFY: line_of = vsum;
            R_CRC:   line_of = crcl;
            R_FIRST: line_of = fst;
            // Three help lines, because a button that is silently inert is
            // worse than one that is visibly absent. X appears once a
            // cartridge has been identified; Y only when that cartridge has
            // a save this core can read, which is a stricter condition and
            // false for most of them.
            R_HELP:  line_of = svrdy ? ROW_HELP_SAVE :
                               rdy   ? ROW_HELP_DUMP : ROW_HELP_PLAIN;
            default: line_of = ROW_BLANKR;
        endcase
    end
endfunction

// Row 12 is the filename while a dump runs or after it succeeds, and the
// reason in words when it fails. A failure that says only "err 4" makes the
// reader go and find the table.
function [LW-1:0] err_line_of(input [2:0] e, input [1:0] at);
    begin
        case (e)
            3'd6:    err_line_of = (at == 2'd1) ? ERR_6_OPEN  :
                                   (at == 2'd2) ? ERR_6_WRITE : ERR_6_FLUSH;
            3'd2:    err_line_of = ERR_2;
            3'd3:    err_line_of = ERR_3;
            3'd4:    err_line_of = ERR_4;
            3'd5:    err_line_of = ERR_5;
            3'd7:    err_line_of = ERR_7;
            default: err_line_of = ERR_X;
        endcase
    end
endfunction

wire [LW-1:0] file_line = (dump_state == 2'd3) ? err_line_of(dump_err, stall_at)
                                               : ROW_BLANKR;

// Only once a dump has finished, and only when there was a header to check
// against: the self test has none and must not claim one.
wire sum_shown = (dump_state == 2'd2) && sum_checked;

wire [LW-1:0] sum_line = !sum_shown ? ROW_BLANKR
                       : sum_ok     ? ROW_ISUM_OK
                                    : ROW_ISUM_BAD;

// Gated the same way the checksum row is, and for a sharper reason: the
// checksum row would merely be blank for a self test, while this one would
// show the previous cartridge dump's number under the self test's name.
wire [LW-1:0] crc_line = (dump_state == 2'd2) ? ROW_CRC
                                                             : ROW_BLANKR;

// Row 13 carries whichever verdict applies. A ROM dump has the cartridge's
// own checksum; a save has nothing of the kind and gets the report from its
// presence probe instead. They are never both meaningful, and sum_checked is
// already false for a save, so the row would otherwise sit blank.
wire [LW-1:0] verify_line = save_shown ? save_line : sum_line;

wire [LW-1:0] static_next = line_of(row_c, details, details_gb, msg_line,
                                    dump_line, file_line, verify_line,
                                    gba_ver_row, crc_line, first_line,
                                    dump_ready, save_ready, dump_state);
reg  [LW-1:0] static_line;

// Left to right: a 30-character constant has its first character in the most
// significant byte, so column c is byte (COLS - 1 - c).
wire [7:0] static_char = static_line[8*(COLS-1-col) +: 8];

// ---- The header codes, as words -------------------------------------------
//
// Behind functions and continuous assignments rather than always blocks, for
// the reason given above msg_of: with no cartridge in the slot the inputs
// never change, and an always @(*) would never fire.

function [7*8-1:0] rom_size_text(input [7:0] code);
    begin
        case (code)
            8'd0: rom_size_text = "32 KB  ";
            8'd1: rom_size_text = "64 KB  ";
            8'd2: rom_size_text = "128 KB ";
            8'd3: rom_size_text = "256 KB ";
            8'd4: rom_size_text = "512 KB ";
            8'd5: rom_size_text = "1 MB   ";
            8'd6: rom_size_text = "2 MB   ";
            8'd7: rom_size_text = "4 MB   ";
            8'd8: rom_size_text = "8 MB   ";
            default: rom_size_text = "?      ";
        endcase
    end
endfunction

function [7*8-1:0] ram_size_text(input [7:0] code);
    begin
        case (code)
            8'd0: ram_size_text = "none   ";
            8'd1: ram_size_text = "2 KB   ";
            8'd2: ram_size_text = "8 KB   ";
            8'd3: ram_size_text = "32 KB  ";
            8'd4: ram_size_text = "128 KB ";
            8'd5: ram_size_text = "64 KB  ";
            default: ram_size_text = "?      ";
        endcase
    end
endfunction

// A cartridge whose type byte is not one of these is still dumped: the reader
// falls back to a plain bank register at 0x2000, which is what MBC3 and MBC5
// both use. What it cannot do is name it, so it says so.
function [25*8-1:0] mapper_text(input [7:0] code);
    begin
        case (code)
            8'h00: mapper_text = "ROM only                 ";
            8'h01: mapper_text = "MBC1                     ";
            8'h02: mapper_text = "MBC1 + RAM               ";
            8'h03: mapper_text = "MBC1 + RAM + battery     ";
            8'h05: mapper_text = "MBC2                     ";
            8'h06: mapper_text = "MBC2 + battery           ";
            8'h08: mapper_text = "ROM + RAM                ";
            8'h09: mapper_text = "ROM + RAM + battery      ";
            8'h0F: mapper_text = "MBC3 + RTC + battery     ";
            8'h10: mapper_text = "MBC3 + RTC + RAM + batt  ";
            8'h11: mapper_text = "MBC3                     ";
            8'h12: mapper_text = "MBC3 + RAM               ";
            8'h13: mapper_text = "MBC3 + RAM + battery     ";
            8'h19: mapper_text = "MBC5                     ";
            8'h1A: mapper_text = "MBC5 + RAM               ";
            8'h1B: mapper_text = "MBC5 + RAM + battery     ";
            8'h1C: mapper_text = "MBC5 + rumble            ";
            8'h1D: mapper_text = "MBC5 + rumble + RAM      ";
            8'h1E: mapper_text = "MBC5 + rumble + RAM + bat";
            default: mapper_text = "unrecognised type        ";
        endcase
    end
endfunction

wire [7*8-1:0]  rom_txt = rom_size_text(gb_rom_size);
wire [7*8-1:0]  ram_txt = ram_size_text(gb_ram_size);
wire [25*8-1:0] map_txt = mapper_text(gb_cart_type);


// Variable fields. Each is a run of characters starting at FIELD_COL.
// Same reasoning as msg_of: behind a continuous assignment, not an
// always @(*), so it is defined before the first paint rather than after the
// first input change.
reg [7:0] field_char_r;
reg       field_hit_r;
always @(row or col or details or details_gb or title or game_code or
         maker_code or sw_version or gb_title or gb_cart_type or
         rom_txt or ram_txt or map_txt or dump_state or
         out_name or out_name_len or out_ext or out_ext_len) begin
    field_char_r = 8'h20;
    field_hit_r  = 1'b0;

    // Which bitstream this is, in every state including a cold boot with an
    // empty slot, because that is when you most want to know whether the card
    // took the flash.
    if (row == R_TITLE && col >= 5'd26) begin
        field_hit_r  = 1'b1;
        field_char_r = hex_digit(BUILD_STAMP[4*(5'd29 - col) +: 4]);
    end else if (row == R_FILE && dump_state != 2'd0 && dump_state != 2'd3) begin
        // The name of the file being written, or that was written. A dump
        // that says COMPLETE without naming the file leaves the reader
        // hunting the card for it.
        if (col < {1'b0, out_name_len}) begin
            field_hit_r  = 1'b1;
            field_char_r = out_name[8*(5'd15 - col) +: 8];
        end else if (col < {1'b0, out_name_len} + {3'd0, out_ext_len}) begin
            field_hit_r  = 1'b1;
            field_char_r = out_ext[8*(2'd3 - (col - {1'b0, out_name_len})) +: 8];
        end
    end else if (details) begin
        case (row)
            R_NAME: begin
                if (details_gb && col < 5'd15) begin
                    field_hit_r  = 1'b1;
                    field_char_r = gb_title[8*(14 - col) +: 8];
                end else if (!details_gb && col < 5'd12) begin
                    field_hit_r  = 1'b1;
                    field_char_r = title[8*(11 - col) +: 8];
                end
            end

            R_TYPE: begin
                if (details_gb) begin
                    // The mapper in words, with the header byte kept at the
                    // right hand end for anyone cross referencing a datasheet.
                    if (col < 5'd25) begin
                        field_hit_r  = 1'b1;
                        field_char_r = map_txt[8*(24 - col) +: 8];
                    end else if (col == 5'd28) begin
                        field_hit_r  = 1'b1;
                        field_char_r = hex_digit(gb_cart_type[7:4]);
                    end else if (col == 5'd29) begin
                        field_hit_r  = 1'b1;
                        field_char_r = hex_digit(gb_cart_type[3:0]);
                    end
                end else begin
                    if (col >= 5'd5 && col < 5'd9) begin
                        field_hit_r  = 1'b1;
                        field_char_r = game_code[8*(3 - (col - 5'd5)) +: 8];
                    end else if (col >= 5'd21 && col < 5'd23) begin
                        field_hit_r  = 1'b1;
                        field_char_r = maker_code[8*(1 - (col - 5'd21)) +: 8];
                    end
                end
            end

            R_SIZE: begin
                if (details_gb) begin
                    if (col >= 5'd5 && col < 5'd12) begin
                        field_hit_r  = 1'b1;
                        field_char_r = rom_txt[8*(6 - (col - 5'd5)) +: 8];
                    end else if (col >= 5'd22 && col < 5'd29) begin
                        field_hit_r  = 1'b1;
                        field_char_r = ram_txt[8*(6 - (col - 5'd22)) +: 8];
                    end
                end else begin
                    if (col == 5'd8) begin
                        field_hit_r  = 1'b1;
                        field_char_r = hex_digit(sw_version[7:4]);
                    end else if (col == 5'd9) begin
                        field_hit_r  = 1'b1;
                        field_char_r = hex_digit(sw_version[3:0]);
                    end
                end
            end

            default: ;
        endcase
    end
end

wire [7:0] field_char = field_char_r;
wire       field_hit  = field_hit_r;

// The flags row carries two independent verdicts, so it is a pair of overlays
// on ROW_FLAGS_BASE rather than one field.
//
//   cols 7..8    "ok" or "--"  for the fixed byte at 0xB2
//   cols 20..21  "ok" or "--"  for the header complement check
wire flags_ok = details_gb ? gb_checksum_ok : checksum_ok;

// GB puts one verdict at column 9; GBA keeps two, the fixed byte and the
// checksum, at the columns its own label row leaves free.
wire flag_hit = details && (row == R_FLAGS) &&
                (details_gb ? (col == 5'd9 || col == 5'd10)
                            : (col == 5'd7  || col == 5'd8 ||
                               col == 5'd20 || col == 5'd21));

wire [7:0] flag_char =
    (col == 5'd7)  ? (fixed_ok ? "o" : "-") :
    (col == 5'd8)  ? (fixed_ok ? "k" : "-") :
    (col == 5'd9)  ? (flags_ok ? "o" : "-") :
    (col == 5'd10) ? (flags_ok ? "k" : "-") :
    (col == 5'd20) ? (flags_ok ? "o" : "-") :
                     (flags_ok ? "k" : "-");

// ---- The dump line's overlaid values ---------------------------------------
//
// Counts are hexadecimal. A decimal one would need a divide, and this module
// has already failed timing once for putting a divider in a per-cell path.

wire dump_run = (dump_state == 2'd1);
wire dump_ok  = (dump_state == 2'd2);
wire dump_bad = (dump_state == 2'd3);

// A bar, not a hex chunk count. "DUMPING 0042 OF 0200" asks the reader to do
// hexadecimal arithmetic to find out whether anything is happening.
//
// dump_engine supplies progress as 0 to 255 precisely so that this is a
// comparison per cell rather than a divide: `col / total` in a per-cell path
// is what failed this design's timing once already.
localparam integer BAR_L = 1;    // first cell column
localparam integer BAR_W = 16;

wire [3:0] bar_fill = dump_progress[7:4];
wire [4:0] bar_i    = col - BAR_L[4:0];

wire bar_hit = (row == R_BAR) && (dump_state != 2'd0) &&
               (col >= BAR_L[4:0]) && (col < BAR_L[4:0] + BAR_W[4:0]);

// Full on success regardless of where the counter got to: the last chunk
// completing and the file being flushed are not the same moment.
wire [7:0] bar_char = (dump_ok || bar_i < {1'b0, bar_fill}) ? "#" : "-";

// The error code still appears, because the documentation is written in code
// numbers, but next to the sentence rather than instead of it.
wire dump_hit = (row == R_DUMP) && dump_bad && (col == 5'd17);

// The two sums side by side, when they disagree.
wire sum_hit = sum_shown && !sum_ok && (row == R_VERIFY) &&
               ((col >= 5'd10 && col <= 5'd13) ||
                (col >= 5'd20 && col <= 5'd23));

wire [3:0] sum_nib =
    (col == 5'd10) ? sum_computed[15:12] :
    (col == 5'd11) ? sum_computed[11:8]  :
    (col == 5'd12) ? sum_computed[7:4]   :
    (col == 5'd13) ? sum_computed[3:0]   :
    (col == 5'd20) ? sum_stored[15:12]   :
    (col == 5'd21) ? sum_stored[11:8]    :
    (col == 5'd22) ? sum_stored[7:4]     :
                     sum_stored[3:0];

wire [7:0] dump_char = hex_digit({1'b0, dump_err});


// ---- The painter ----------------------------------------------------------

always @(posedge clk) begin
    if (reset) begin
        // Paint once out of reset, so a cold boot with an empty slot shows
        // the screen rather than the buffer's power-on contents. Nothing else
        // would trigger it: with no cartridge, no input ever changes.
        painting <= 1'b1;
        row_c    <= 5'd0;
        col_c    <= 5'd0;
        addr_c   <= 10'd0;
        paint_r  <= 1'b0;
        shown    <= {39{1'b1}};   // deliberately not a reachable snapshot
        tb_we    <= 1'b0;
    end else begin
        tb_we <= 1'b0;

        // Stage one: where the painter is, and which row's text that means.
        paint_r     <= painting;
        row         <= row_c;
        col         <= col_c;
        addr_r      <= addr_c;
        static_line <= static_next;

        if (!painting) begin
            if (snapshot != shown) begin
                shown    <= snapshot;
                painting <= 1'b1;
                row_c    <= 5'd0;
                col_c    <= 5'd0;
                addr_c   <= 10'd0;
            end
        end else begin
            if (addr_c == CELLS - 1) begin
                painting <= 1'b0;
                row_c    <= 5'd0;
                col_c    <= 5'd0;
                addr_c   <= 10'd0;
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

        // Stage two: the character itself, chosen from an already selected
        // row. Everything below reads the registered row and column.
        if (paint_r) begin
            tb_addr <= addr_r;
            tb_attr <= (row == R_TITLE) ? 2'd1 : 2'd0;

            if (sum_hit)
                tb_char <= hex_digit(sum_nib);
            else if (bar_hit)
                tb_char <= bar_char;
            else if (dump_hit)
                tb_char <= dump_char;
            else if (flag_hit)
                tb_char <= flag_char;
            else if (field_hit)
                tb_char <= field_char;
            else
                tb_char <= static_char;

            tb_we <= 1'b1;
        end
    end
end

endmodule

`default_nettype wire
