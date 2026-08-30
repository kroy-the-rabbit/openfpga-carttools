// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_path_gen.sv - build the open_dataslot_file_t that names the dump
//
// Target command 0x0192 does not take a filename. It takes a pointer into
// core memory and reads a 264-byte struct out of it over the bridge:
//
//   0x000  256  full path and file, null terminated, under Assets or Saves
//   0x100    4  flags, bit 0 create if absent, bit 1 resize or truncate
//   0x104    4  desired size, used by the resize
//
// So this module is the struct: it owns the RAM APF reads, fills it from the
// cartridge title, and reports when it is safe to issue the command. See
// docs/APF-NOTES.md section 3.
//
// WHERE THE PATH IS ROOTED IS NOT KNOWN, so all eight candidates are here and
// dump_engine tries them until one is accepted.
//
// The documentation says "full path and file ... in the Assets or Saves
// folder" and that is the whole of it. Two hardware sessions returned 4,
// malformed path, for paths that looked right, under both byte orders, with
// APF demonstrably reading the whole struct each time. So the format is
// wrong rather than the delivery, and which format is right is not derivable
// from anything available here.
//
//   0  /Assets/carttools/common/NAME   absolute, the literal reading
//   1  Assets/carttools/common/NAME    the same without a leading slash
//   2  NAME                            bare, if the slot's folder is the root
//   3  /Saves/carttools/common/NAME    if a written file belongs in Saves
//   4  common/NAME                     relative to the platform's Assets dir
//   5  carttools/common/NAME           relative to Assets itself
//   6  /carttools/common/NAME          the same with a leading slash
//   7  Saves/carttools/common/NAME     Saves without the leading slash
//
// An open costs one target command, so trying all of them costs less than a
// millisecond and no human attention. Guessing one at a time costs a Quartus
// run and a card swap each, which is how two sessions went.
//
// Names are derived, not chosen, so two dumps of the same cartridge overwrite
// rather than accumulate. That is deliberate: there is no directory listing
// command, so uniquifying would mean probing names one round trip at a time,
// and a dump that silently became POKEMON_3.gb is worse than one that
// replaced POKEMON.gb. The resize flag is set so a shorter dump does not
// leave the tail of a longer one behind it.
//
// THE FLAGS AND SIZE WORDS ARE NOT PLAIN NUMBERS, and believing they were
// cost three hardware sessions.
//
// The struct is 264 bytes that the host copies out of the bridge in one go.
// Its two 32-bit fields are little endian within that byte array, exactly
// like the path is a byte array, so they get the same treatment: whichever
// end of a bridge word byte 0 goes in, the low byte of flags goes in the same
// end. Storing them plain is only correct for one of the two byte orders.
//
// It was stored plain on the reasoning that a plain number reads back
// correctly because that is how the datatable reports slot sizes. The
// datatable is written by APF and read back by APF, so that round trip proves
// nothing about how the host interprets it, and 0x0190's reply says
// otherwise: it puts the first byte of a string in the most significant byte
// of a word, and a memcpy'd little endian struct byte-reverses its u32 fields
// relative to that.
//
// Which is why every one of the sixteen path and byte order combinations was
// refused. None of them varied this. APF read flags as 0x03000000 every time:
// create clear, resize clear, and two reserved bits set.
//

module dump_path_gen #(
    parameter integer WORDS = 128
) (
    input  wire         clk,               // clk_sys
    input  wire         reset,

    input  wire         start,             // pulse
    input  wire         selftest,          // name the ramp file, not a cart
    input  wire [2:0]   path_style,        // which root, see above
    // Whether the two 32-bit fields are little or big endian inside the byte
    // array. Independent of byte_order and not derivable from anything seen
    // so far, so dump_engine searches it too.
    input  wire         field_order,
    // Create alone rather than create and resize. Resizing a file that does
    // not exist yet may be what APF objects to; the documentation does not
    // say, and every other reading of it has been wrong once.
    input  wire         create_only,
    input  wire [119:0] title,             // GB header 0x0134, 15 bytes
    // Which system the image is for, which decides the extension. A dump is
    // useless to the tools that read it if it is not named after its system:
    // a 16 MB GBA image called .gb is mis-identified by everything that looks
    // at it, and the size is not a reliable substitute because a 1 MB GB
    // cartridge and a 1 MB GBA cartridge are both real.
    //   0  Game Boy          .gb
    //   1  Game Boy Color    .gbc    0x0143 is 0x80 or 0xC0
    //   2  Game Boy Advance  .gba
    // The self test overrides all three with .bin; it is not a cartridge.
    input  wire [1:0]   cart_kind,
    input  wire [31:0]  total_bytes,
    input  wire         byte_order,        // 0 first byte in [31:24], 1 in [7:0]

    output reg          busy,
    output reg          done,              // one cycle, struct is readable

    // The name alone, without the root, so the screen can say what it wrote.
    // The root is the part nobody wants to read and the part that changes as
    // the search runs; the name is the part that identifies the file.
    output wire [127:0] out_name,
    output wire [4:0]   out_name_len,
    output wire [31:0]  out_ext,
    output wire [2:0]   out_ext_len,

    // Bridge read port, clk_74a.
    input  wire         rd_clk,
    input  wire [6:0]   rd_addr,
    output reg  [31:0]  rd_q
);

// All four padded to the same width, first character in the most significant
// byte, so one register can hold whichever was chosen.
localparam integer PRE_MAX = 25;

localparam [PRE_MAX*8-1:0] PRE_0 = {"/Assets/carttools/common/"};
localparam [PRE_MAX*8-1:0] PRE_1 = {"Assets/carttools/common/",   8'd0};
localparam [PRE_MAX*8-1:0] PRE_2 = {200'd0};
localparam [PRE_MAX*8-1:0] PRE_3 = {"/Saves/carttools/common/",   8'd0};
localparam [PRE_MAX*8-1:0] PRE_4 = {"common/",                  144'd0};
localparam [PRE_MAX*8-1:0] PRE_5 = {"carttools/common/",         64'd0};
localparam [PRE_MAX*8-1:0] PRE_6 = {"/carttools/common/",        56'd0};
localparam [PRE_MAX*8-1:0] PRE_7 = {"Saves/carttools/common/",   16'd0};

localparam [127:0] NAME_SELFTEST = {"SELFTEST", 64'd0};
localparam [127:0] NAME_FALLBACK = {"UNTITLED", 64'd0};

localparam [31:0] EXT_GB  = ".gb ";
localparam [31:0] EXT_GBC = ".gbc";
localparam [31:0] EXT_GBA = ".gba";
localparam [31:0] EXT_BIN = ".bin";
localparam [31:0] EXT_SAV = ".sav";

localparam [1:0] KIND_GB  = 2'd0;
localparam [1:0] KIND_GBC = 2'd1;
localparam [1:0] KIND_GBA = 2'd2;
// A save, from either platform. The extension names what the file holds, not
// which machine it came out of: TETRIS.gb and TETRIS.sav side by side say
// more than two files distinguished by a suffix nobody reads.
localparam [1:0] KIND_SAV = 2'd3;

// Create if absent, and resize to the size below.
localparam [31:0] OPEN_FLAGS      = 32'h0000_0003;   // create and resize
localparam [31:0] OPEN_FLAGS_CRE  = 32'h0000_0001;   // create only

localparam integer PATH_BYTES = 256;
localparam integer W_FLAGS    = 64;      // 0x100 >> 2
localparam integer W_SIZE     = 65;      // 0x104 >> 2

assign out_name     = name_reg;
assign out_name_len = name_len;
assign out_ext      = ext_reg;
assign out_ext_len  = ext_len;

// ---- the struct RAM -------------------------------------------------------

reg [31:0] mem [0:WORDS-1];

integer i;
initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
end

reg [1:0]  lane;
reg [31:0] pack;
reg [6:0]  wa;

reg        pk_en;      // a path byte is being emitted this cycle
reg [7:0]  pk_data;

wire [31:0] next_pack =
    byte_order_l ?
        ((lane == 2'd0) ? {pack[31:8],  pk_data}               :
         (lane == 2'd1) ? {pack[31:16], pk_data, pack[7:0]}    :
         (lane == 2'd2) ? {pack[31:24], pk_data, pack[15:0]}   :
                          {pk_data,     pack[23:0]})
      : ((lane == 2'd0) ? {pk_data,     pack[23:0]}            :
         (lane == 2'd1) ? {pack[31:24], pk_data, pack[15:0]}   :
         (lane == 2'd2) ? {pack[31:16], pk_data, pack[7:0]}    :
                          {pack[31:8],  pk_data});

reg        ww_en;      // a whole word is being written this cycle
reg [6:0]  ww_addr;
reg [31:0] ww_data;

reg        mem_we;
reg [6:0]  mem_wa;
reg [31:0] mem_wd;

always @(*) begin
    mem_we = 1'b0;
    mem_wa = wa;
    mem_wd = next_pack;
    if (ww_en) begin
        mem_we = 1'b1;
        mem_wa = ww_addr;
        mem_wd = ww_data;
    end else if (pk_en && lane == 2'd3) begin
        mem_we = 1'b1;
    end
end

always @(posedge clk) begin
    if (mem_we) mem[mem_wa] <= mem_wd;
end

always @(posedge rd_clk) begin
    rd_q <= mem[rd_addr];
end

// ---- name construction ----------------------------------------------------

// A 32-bit field of the struct, laid out the way its four bytes would be if
// they had gone through the packer above: little endian within the byte
// array, and the byte array's first byte at whichever end byte_order says.
function [31:0] as_bytes(input [31:0] v);
    reg [31:0] le;
    begin
        // The field's four bytes in array order. field_order 0 is little
        // endian, which is what a memcpy'd struct on a little endian host
        // gives; 1 is big endian.
        le = field_order_l ? {v[7:0], v[15:8], v[23:16], v[31:24]} : v;

        // Then those four bytes are laid into the word the same way any four
        // array bytes are: byte 0 of the array at whichever end byte_order
        // says, which for byte_order 0 is the top.
        as_bytes = byte_order_l ? le
                                : {le[7:0], le[15:8], le[23:16], le[31:24]};
    end
endfunction

function [7:0] sanitize(input [7:0] c);
    begin
        if (c >= "A" && c <= "Z")      sanitize = c;
        else if (c >= "0" && c <= "9") sanitize = c;
        else if (c >= "a" && c <= "z") sanitize = c - 8'd32;
        else                           sanitize = "_";
    end
endfunction

// What counts as padding on a GB title. 0x00 and 0x20 are the two the
// cartridges use; 0xFF is what an unreadable cartridge returns, and trimming
// it means a failed read does not produce a filename of fifteen underscores.
function is_blank(input [7:0] c);
    begin
        is_blank = (c == 8'h00) || (c == 8'h20) || (c == 8'hFF);
    end
endfunction

reg [PRE_MAX*8-1:0] pre_reg;
reg [4:0]           pre_len;

reg [127:0] name_reg;    // 16 bytes, first character in the most significant
reg [4:0]   name_len;
reg [31:0]  ext_reg;
reg [2:0]   ext_len;
reg [31:0]  size_l;
reg         byte_order_l;
reg         field_order_l;
reg         create_l;
reg [119:0] title_l;

reg [3:0]   scan_i;
reg [4:0]   trim_len;

reg [8:0]   pos;         // 0..255, byte within the path field

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_SCAN = 3'd1;
localparam [2:0] ST_FIX  = 3'd2;
localparam [2:0] ST_EMIT = 3'd3;
localparam [2:0] ST_FLAG = 3'd4;
localparam [2:0] ST_SIZE = 3'd5;
localparam [2:0] ST_DONE = 3'd6;

reg [2:0] state;

// Which source supplies the character at pos.
wire [8:0] pre_end   = {4'd0, pre_len};
wire [8:0] name_end  = pre_end + {4'd0, name_len};
wire [8:0] ext_end   = name_end + {6'd0, ext_len};

// Offsets are taken at full width and only then narrowed. Slicing pos itself
// wraps at 32 and puts the sixteenth character of a long title back at the
// start of the name.
wire [8:0] pre_i9    = pos;
wire [7:0] pre_char  = pre_reg[8*(PRE_MAX-1-pre_i9[4:0]) +: 8];
wire [8:0] name_i9   = pos - pre_end;
wire [3:0] name_i    = name_i9[3:0];
wire [7:0] name_char = name_reg[8*(15 - name_i) +: 8];
wire [8:0] ext_i9    = pos - name_end;
wire [7:0] ext_char  = ext_reg[8*(3 - ext_i9[1:0]) +: 8];

always @(posedge clk) begin
    done  <= 1'b0;
    pk_en <= 1'b0;
    ww_en <= 1'b0;

    if (reset) begin
        state        <= ST_IDLE;
        busy         <= 1'b0;
        lane         <= 2'd0;
        pack         <= 32'd0;
        wa           <= 7'd0;
        name_reg     <= 128'd0;
        name_len     <= 5'd0;
        ext_reg      <= 32'd0;
        ext_len      <= 3'd0;
        byte_order_l  <= 1'b0;
        field_order_l <= 1'b0;
        create_l      <= 1'b0;
        size_l       <= 32'd0;
        pre_reg      <= PRE_0;
        pre_len      <= 5'd25;
    end else begin
        // The packer advances whenever a path byte was emitted.
        if (pk_en) begin
            lane <= lane + 2'd1;
            pack <= next_pack;
            if (lane == 2'd3) begin
                wa   <= wa + 7'd1;
                pack <= 32'd0;
            end
        end

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy         <= 1'b1;
                    byte_order_l  <= byte_order;
                    field_order_l <= field_order;
                    create_l      <= create_only;
                    size_l       <= total_bytes;
                    title_l      <= title;
                    case (path_style)
                        3'd0: begin pre_reg <= PRE_0; pre_len <= 5'd25; end
                        3'd1: begin pre_reg <= PRE_1; pre_len <= 5'd24; end
                        3'd2: begin pre_reg <= PRE_2; pre_len <= 5'd0;  end
                        3'd3: begin pre_reg <= PRE_3; pre_len <= 5'd24; end
                        3'd4: begin pre_reg <= PRE_4; pre_len <= 5'd7;  end
                        3'd5: begin pre_reg <= PRE_5; pre_len <= 5'd17; end
                        3'd6: begin pre_reg <= PRE_6; pre_len <= 5'd18; end
                        3'd7: begin pre_reg <= PRE_7; pre_len <= 5'd23; end
                    endcase
                    lane         <= 2'd0;
                    pack         <= 32'd0;
                    wa           <= 7'd0;
                    pos          <= 9'd0;
                    if (selftest) begin
                        name_reg <= NAME_SELFTEST;
                        name_len <= 5'd8;
                        ext_reg  <= EXT_BIN;
                        ext_len  <= 3'd4;
                        state    <= ST_EMIT;
                    end else begin
                        name_reg <= 128'd0;
                        ext_reg  <= (cart_kind == KIND_SAV) ? EXT_SAV :
                                    (cart_kind == KIND_GBA) ? EXT_GBA :
                                    (cart_kind == KIND_GBC) ? EXT_GBC : EXT_GB;
                        ext_len  <= (cart_kind == KIND_GB)  ? 3'd3 : 3'd4;
                        scan_i   <= 4'd0;
                        trim_len <= 5'd0;
                        state    <= ST_SCAN;
                    end
                end
            end

            // One title byte per cycle: sanitise it into the name, and
            // remember the position after the last one that was not padding.
            ST_SCAN: begin
                name_reg[8*(15 - {1'b0, scan_i}) +: 8]
                    <= sanitize(title_l[8*(14 - scan_i) +: 8]);
                if (!is_blank(title_l[8*(14 - scan_i) +: 8]))
                    trim_len <= {1'b0, scan_i} + 5'd1;
                if (scan_i == 4'd14) state <= ST_FIX;
                else                 scan_i <= scan_i + 4'd1;
            end

            // A cartridge whose title read as all padding would otherwise
            // produce /Assets/carttools/common/.gb, a hidden file with no
            // name. Give it one.
            ST_FIX: begin
                if (trim_len == 5'd0) begin
                    name_reg <= NAME_FALLBACK;
                    name_len <= 5'd8;
                end else begin
                    name_len <= trim_len;
                end
                state <= ST_EMIT;
            end

            ST_EMIT: begin
                pk_en <= 1'b1;
                if (pos < pre_end)        pk_data <= pre_char;
                else if (pos < name_end)  pk_data <= name_char;
                else if (pos < ext_end)   pk_data <= ext_char;
                else                      pk_data <= 8'h00;

                if (pos == PATH_BYTES[8:0] - 9'd1) state <= ST_FLAG;
                else                               pos   <= pos + 9'd1;
            end

            // Written a cycle after the last path byte, so the packer has
            // committed word 63 and wa has moved past it.
            ST_FLAG: begin
                ww_en   <= 1'b1;
                ww_addr <= W_FLAGS[6:0];
                ww_data <= as_bytes(create_l ? OPEN_FLAGS_CRE : OPEN_FLAGS);
                state   <= ST_SIZE;
            end

            ST_SIZE: begin
                ww_en   <= 1'b1;
                ww_addr <= W_SIZE[6:0];
                ww_data <= as_bytes(size_l);
                state   <= ST_DONE;
            end

            ST_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
