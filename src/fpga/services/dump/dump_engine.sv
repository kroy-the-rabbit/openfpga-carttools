// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_engine.sv - everything a dump needs, on both sides of the clock wall
//
// A dump straddles two clock domains and that is the whole reason this module
// exists rather than the pieces being wired up in core_top: the crossings are
// the part most likely to be wrong, and they can only be tested if they are
// inside something a testbench can instantiate.
//
//   clk_sys   cart_dump_gb or cart_dump_gba reads the cartridge, dump_chunk_src
//             throttles it into dump_buffer, dump_path_gen builds the open
//             struct
//
// WHICH READER
// ------------
// platform_gba picks, and it is latched at start with everything else. The two
// readers present the same byte stream, so the choice reaches exactly three
// places: which start pulse is issued, where total_bytes comes from, and which
// bus SS_END watches. Nothing downstream of src_data knows there are two.
//
// The size is the real difference. A GB header says how many banks exist at
// 0x0148; a GBA header says nothing at all about its own size, so the number
// arrives from gba_size_probe, measured on the bus before the dump started.
// That is also why a GBA dump has no image checksum: see sum_checked.
//   clk_74a   apf_file_writer issues the target commands, and APF reads the
//             buffer and the struct back out through the bridge
//
// Three things cross. The chunk handshake is four phase and level based, so
// no pulse has to survive a synchroniser. The start and finish events are
// toggles, edge detected on the far side, for the same reason. The payload
// crosses inside dump_buffer's RAM, which is written from one clock and read
// from the other and never at the same address at the same time, because the
// handshake serialises them.
//
// WHY THE WAKE DELAY IS HERE TOO
// ------------------------------
// cart_probe parks the pins at idle when it finishes, and cart_pins drives
// pin 30 low at idle, which is /RES on a Game Boy cartridge. So between an
// identification and a dump the cartridge is held in reset, and a dump that
// starts reading the moment the mode turns round reads a cartridge that has
// not woken up. That is the fault that cost a hardware session during
// bring-up, recorded in docs/STATUS.md, and it applies here for exactly the
// same reason. The reader does not start until the mode is ready and the
// wake counter has expired.
//
// WHAT THIS CANNOT VERIFY
// -----------------------
// Byte order. See dump_buffer.sv. Everything here is correct for either
// answer, and byte_order picks between them at runtime.
//

module dump_engine #(
    parameter [15:0]  SLOT_ID     = 16'd20,
    parameter [31:0]  BUF_BASE    = 32'h6000_0000,
    parameter [31:0]  STRUCT_BASE = 32'h7000_0000,
    // Where APF writes the response to 0x0190 Get filename. A window the
    // bridge writes to rather than reads from, and the only place in this
    // design where APF says something in its own words.
    parameter [31:0]  RESP_BASE   = 32'h8000_0000,
    parameter integer CHUNK_BYTES = 4096,
    parameter integer BUF_WORDS   = 1024,
    parameter integer BUF_AW      = 10,
    // ~2 s at 100.663296 MHz, the value cart_probe needed on hardware.
    parameter integer WAKE_CYCLES = 201_326_592,
    // Length of the byte order self test. A round 256 so the ramp wraps
    // exactly once and every value appears; testbenches override it to reach
    // the short trailing chunk a cartridge size never produces.
    parameter integer SELFTEST_BYTES = 256
) (
    // ---- cartridge domain ----
    input  wire        clk_sys,
    input  wire        reset_sys,

    input  wire        start,             // pulse
    input  wire        selftest,          // write the ramp, touch no cartridge
    // Read the cartridge's battery-backed RAM instead of its ROM. GB and GBC
    // only; there is no GBA save path yet. Latched at start with everything
    // else, so a scan mid-dump cannot change what is being read.
    input  wire        save_mode,
    input  wire        byte_order,        // latched at start
    input  wire [2:0]  path_style,        // where the search starts
    input  wire [119:0] title,            // GB header 0x0134
    // Which system, for the file extension. Latched at start with everything
    // else, so a scan mid-dump cannot rename the file being written.
    input  wire [1:0]  cart_kind,
    input  wire [7:0]  cart_type,         // 0x0147
    input  wire [7:0]  rom_size_code,     // 0x0148
    // 0x0149. Not latched into the engine: cart_save_gb latches it itself,
    // and save_supported has to be live so a caller can gate a button on it.
    input  wire [7:0]  ram_size_code,

    // Which reader runs, latched at start with everything else. A GBA
    // cartridge has no ROM size field anywhere in it, so the size arrives from
    // gba_size_probe instead of from a header byte, and it must be stable for
    // the whole dump for the same reason rom_size_code must: the loop bound is
    // read live.
    input  wire        platform_gba,
    input  wire [31:0] gba_size_bytes,
    // How many bytes of GBA save to read, decided by core_top from
    // gba_save_scan's result. Zero when the type was refused or not found, and
    // cart_save_gba treats that as finish without touching the connector.
    // Latched at start for the same reason gba_size_bytes is.
    input  wire [31:0] gba_save_size_bytes,

    // EEPROM is a different reader, not a different size. It is serial, it
    // lives in its own space rather than the save window, and it is addressed
    // by writing the block number in a bit at a time. Both come from
    // gba_eeprom_probe, because nothing in a cartridge says which width the
    // chip has. Latched at start with everything else.
    input  wire        gba_save_is_eeprom,
    input  wire [3:0]  gba_save_addr_bits,

    // The connector's actual state, for the EEPROM reader's abandon guard.
    // The other readers do not need it: they are held in reset by an abort,
    // and an abort is what a mode loss produces. The EEPROM reader waits on a
    // chip through a bus that stops answering, so it checks for itself.
    input  wire        cart_mode,

    output reg         busy,
    output reg         done,              // one cycle
    output reg         failed,
    output reg  [2:0]  err,
    output reg  [15:0] fail_chunk,
    output wire [15:0] chunks_done,
    output wire [15:0] chunks_total,

    // How far along, as 0 to 255, so the screen can draw a bar without a
    // divide. A divider in a per-cell path is what failed this design's
    // timing once already; see ui_screen.sv.
    output reg  [7:0]  progress,

    output wire [31:0] total_bytes,

    // Evidence, not features. target_dataslot_err is three bits and it cannot
    // say whether APF disliked the path or never came looking for it, so
    // these say what APF actually did on the bus. All three are counted in
    // clk_74a and crossed for display; they are stable by the time anyone
    // reads them, because the dump has finished by then.
    output wire [15:0] dbg_reads,         // every bridge read the core saw
    output wire [15:0] dbg_struct_reads,  // those that landed in the struct window
    output wire [31:0] dbg_last_addr,     // last read outside the F8 register page

    // What the core actually handed APF for the first word of the path.
    // Every path form and both byte orders were refused identically, which is
    // what a window returning nothing looks like as well as what a wrong path
    // looks like. The read counters prove APF addressed this window; they say
    // nothing about what it received. This does.
    //
    // For "/Ass" at byte order 1 on a little endian host the answer is
    // 2F417373. Zero means the window is broken and no path would ever have
    // worked. Anything else names the fault.
    output wire [31:0] dbg_first_word,
    // The two struct fields as the core actually delivered them, from the
    // first attempt of the search rather than the last. The last is whatever
    // the counter wrapped to and tells you nothing.
    output wire [31:0] dbg_flags_word,
    output wire [31:0] dbg_size_word,

    // 0x0190 Get filename, against slot 0. If APF hands back a path it built
    // itself, the format question is answered by the only party that knows.
    input  wire        probe_start,       // pulse
    input  wire [15:0] probe_slot,        // which slot to ask about
    output reg  [2:0]  probe_err,
    // 128 bytes of the response, which is enough to hold any root plus the
    // name. Shown as text, not hex: the point of asking APF is to read the
    // answer, and four rows of hex digits photographed off a handheld are not
    // readable with any confidence.
    output wire [1023:0] resp_words,

    // The mirror of it: the first 128 bytes this core handed APF when it read
    // the struct, in the same layout, so one screen compares what was sent
    // with what was received instead of comparing a screen with an intention.
    output wire [1023:0] sent_words,

    // Which combination the open was finally accepted with, and how many were
    // tried. This is the answer to the question two hardware sessions could
    // not settle, so it is displayed rather than merely acted on.
    output reg  [2:0]  used_style,
    output reg         used_order,
    output reg  [7:0]  tries,
    // The dump got its bytes onto the card, but into the slot's own file
    // rather than one it named. Reported separately because it is a different
    // outcome, not a lesser success.
    output reg         no_open,
    // Which command APF never answered. 1 open, 2 write, 3 flush.
    output reg  [1:0]  stall_at,

    // The image's identity, computed while it streamed past. Unlike the
    // checksum below this judges nothing on its own - there is no reference to
    // compare it against inside the cartridge - but it is the only thing a GBA
    // dump can be checked with at all, against a second dump or against a
    // published one. Both platforms get it.
    output wire [31:0] crc32,

    // The cartridge's own verdict on the image, computed while it streamed
    // past. sum_checked is false for the self test, which has no header, and
    // for GBA, which has no checksum over its own contents: the header
    // complement at 0xBD covers 0xA0..0xBC and nothing else, and
    // cart_identify_gba has already checked it. Claiming a verified image on a
    // platform that cannot supply one would be worse than saying nothing.
    output wire        sum_checked,
    // Whether crc32 describes a cartridge image. False for the self test,
    // whose bytes never reach the accumulator, so the register still holds
    // the previous dump's value and showing it would label a stale number.
    output wire        crc_checked,
    output wire        sum_ok,
    output wire [15:0] sum_computed,
    output wire [15:0] sum_stored,

    // Whether this cartridge's save can be read at all, live off the header
    // rather than latched, so the button can be gated on it before a press.
    output wire        save_supported,
    // What the last save read found. A save carries no checksum, no logo and
    // no length - every check that makes a ROM dump trustworthy is missing -
    // so these three facts are all there is, and the screen shows them rather
    // than turning them into a verdict.
    output wire        save_responded,   // the RAM answered, by the probe
    output wire        save_blank_ff,    // every byte 0xFF
    output wire        save_blank_00,    // every byte 0x00
    output wire [31:0] save_first,       // the first four bytes read

    // The file's name, for display: out_name_len characters of out_name then
    // out_ext_len of out_ext.
    output wire [127:0] out_name,
    output wire [4:0]   out_name_len,
    output wire [31:0]  out_ext,
    output wire [2:0]   out_ext_len,

    // cart_pins must be held in the right mode for the whole dump, and
    // cart_probe must not be allowed to move it. Two bits rather than one
    // because there are now two modes to hold: 2'b10 GB, 2'b01 GBA, 2'b00
    // release, which is cart_pins' own encoding so core_top passes it through
    // rather than translating it.
    output reg  [1:0]  want_mode,
    input  wire        mode_ready,

    // cart_play & cart_power, in this domain. Losing it mid dump is the one
    // failure the bus cannot report: gb_cart_bus drops its transaction
    // without asserting done, so the reader waits forever and every stage
    // above it waits on the reader. Watched here, and turned into a failure
    // with its own error code, because the alternative is a core that has to
    // be exited to recover.
    input  wire        cart_powered,

    // gb_cart_bus master port
    output wire        bus_req,
    output wire        bus_wr,
    output wire [15:0] bus_addr,
    output wire [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,
    // High for the whole of a bus transaction. The mode must not change while
    // it is high; see gb_cart_bus.sv.
    input  wire        bus_busy,

    // gba_cart_bus master port. A separate port rather than a widened one:
    // the two engines are different modules on different pins with different
    // access widths, only one of them is enabled at a time by cart_pins, and
    // muxing them here would put a mode decision inside a data path that has
    // no business making one.
    output wire        gba_req,
    output wire        gba_wr,
    output wire [27:0] gba_addr,
    output wire [1:0]  gba_acc,
    output wire [31:0] gba_wdata,
    input  wire [31:0] gba_rdata,
    input  wire        gba_done,
    input  wire        gba_busy,

    // ---- bridge domain ----
    input  wire        clk_74a,
    input  wire        reset_74a,

    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_endian_little,
    output wire [31:0] bridge_rd_data,
    output wire        bridge_rd_hit,

    output wire        target_dataslot_write,
    output wire        target_dataslot_openfile,
    output reg         target_dataslot_getfile,
    output wire        target_dataslot_flush,
    output wire [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output wire [31:0] target_dataslot_bridgeaddr,
    output wire [31:0] target_dataslot_length,
    output wire [31:0] target_buffer_param_struct,
    output wire [31:0] target_buffer_resp_struct,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err
);

// ============================================================
// clk_sys: sequencing
// ============================================================

reg         sel_l;          // selftest, latched
reg         save_l;         // save_mode, latched
reg         bo_l;           // byte_order, latched
// The combination being tried. combo[4] is the struct field byte order,
// combo[3] is the array byte order inverted so that counting up walks the
// measured answer first, and combo[2:0] is the path root. Starting from the
// operator's setting means the diagnostics page still chooses where the
// search begins; it just no longer has to finish it.
reg [5:0]   combo;
wire        try_create_only = combo[5];
wire        try_field = combo[4];
wire        try_order = ~combo[3];
wire [2:0]  try_style = combo[2:0];

// Latched on the first success and used as the starting point afterwards, so
// only the first dump of a session pays for the search.
// Forgotten the moment the operator changes either knob. A remembered
// combination that overrode an explicit setting would make the diagnostics
// page lie, and there is one case where overriding would be actively wrong: a
// bare filename reversed is still a creatable filename, so the search can
// succeed on a byte order that garbles the name, and the only way out of that
// is for the operator's correction to win.
reg         known;
reg [5:0]   known_combo;

wire [5:0]  user_combo = {2'b0, ~byte_order, path_style};
reg  [5:0]  user_last;

// Tested combinationally rather than by clearing known a cycle later, because
// a knob turned in the same cycle the dump starts would otherwise be a cycle
// too late and the dump would silently use the remembered combination.
wire        known_valid = known && (user_combo == user_last);
reg  [7:0]  type_l;
reg  [7:0]  size_l;

wire [31:0] rom_bytes;      // from cart_dump_gb, combinational off size_l
reg         gba_l;          // which reader this dump is using, latched
reg [1:0]   kind_l;         // which system, for the extension, latched
reg  [31:0] gsize_l;        // the probed size, latched
reg  [31:0] gssize_l;       // the GBA save size, latched
reg         eeprom_l;       // this save is EEPROM, latched
reg  [3:0]  eebits_l;       // its address width, latched

// Three sources, one number, and everything downstream - the chunk count, the
// progress bar, the length in the APF open struct - reads only this one.
assign total_bytes = sel_l            ? SELFTEST_BYTES :
                     (gba_l & save_l) ? (eeprom_l ? gee_bytes : gsv_bytes) :
                     save_l           ? save_bytes :
                     gba_l            ? gsize_l : rom_bytes;

// Chunks the file will take. Every GB ROM size is a multiple of the chunk so
// the round-up only ever matters for the self-test, but a progress display
// that says 8 of 8 while 128 writes are still to come is worse than none.
localparam integer CHUNK_SHIFT = $clog2(CHUNK_BYTES);

wire [31:0] tb_whole = total_bytes >> CHUNK_SHIFT;
wire        tb_part  = (total_bytes & (CHUNK_BYTES - 1)) != 0;
assign chunks_total  = tb_whole[15:0] + (tb_part ? 16'd1 : 16'd0);

// Progress without dividing. chunks_total is rounded up to a power of two by
// taking the position of its highest set bit, and chunks_done is shifted to
// suit. That is approximate for any total that is not a power of two, which
// for a Game Boy ROM is never: every size is a power of two multiple of the
// chunk. The self test is the only case that rounds, and it has two chunks.
// REGISTERED, and it has to be. As a combinational chain this was the
// critical path and it failed timing at -1.050 ns: two bits of size_l reach
// progress[7] through the shift, the round-up add, a sixteen way priority
// encoder, a barrel shifter and a compare, and the low bits get in because
// tb_part tests them, so a +1 can move the highest set bit and change the
// shift distance. 10.461 ns of data delay against a 9.931 ns period.
//
// Breaking the chain here costs one cycle of latency on a number that only
// changes when a dump starts, and the dump it describes then runs for
// seconds. total_bytes is latched from inputs latched at start, so this
// settles long before the first chunk completes and there is nothing to race.
reg [4:0] total_log2;
integer   b;
reg [4:0] log2_comb;
always @(*) begin
    log2_comb = 5'd0;
    for (b = 0; b < 16; b = b + 1)
        if (chunks_total[b]) log2_comb = b[4:0];
end

always @(posedge clk_sys) begin
    if (reset_sys) total_log2 <= 5'd0;
    else           total_log2 <= log2_comb;
end

wire [31:0] scaled = (total_log2 <= 5'd8)
    ? ({16'd0, chunks_done} << (5'd8 - total_log2))
    : ({16'd0, chunks_done} >> (total_log2 - 5'd8));

always @(posedge clk_sys) begin
    if (reset_sys)                 progress <= 8'd0;
    else if (arm)                  progress <= 8'd0;
    else if (scaled > 32'd255)     progress <= 8'd255;
    else                           progress <= scaled[7:0];
end

// Eight roots, two array byte orders, two struct field byte orders. Every one
// is a single open and nothing more, so all thirty-two are done in well under
// a millisecond, which is still less time than one person spends reading one
// error code.
// And a sixth bit for the open flags themselves. 3 is create-and-resize,
// which is what a new file wants; 1 is create alone, in case resizing a file
// that does not exist yet is what APF objects to. Picking 3 was a reading of
// the documentation, not a measurement, and every other reading of that
// documentation has been wrong once.
localparam integer COMBO_COUNT = 64;

localparam [3:0] SS_IDLE  = 4'd0;
localparam [3:0] SS_MODE  = 4'd1;
localparam [3:0] SS_WAKE  = 4'd2;
localparam [3:0] SS_PATH  = 4'd3;
localparam [3:0] SS_HOLD  = 4'd4;
localparam [3:0] SS_GO    = 4'd5;
localparam [3:0] SS_RUN   = 4'd6;
localparam [3:0] SS_END   = 4'd7;

reg [3:0]  ss;
reg [31:0] wake;
reg [4:0]  hold;
reg        abort_l;

// Matches apf_file_writer's ERR_ABORTED. Outside the documented 0 to 5 that
// APF returns, so a dump that stopped because the cartridge went away is
// never confused with a full card.
localparam [2:0] ERR_ABORTED = 3'd7;

// A self test touches no cartridge, so slot power is irrelevant to it.
wire abort_now = busy && !sel_l && !cart_powered;

always @(posedge clk_sys) begin
    if (reset_sys)         abort_l <= 1'b0;
    else if (ss == SS_IDLE) abort_l <= 1'b0;
    else if (abort_now)     abort_l <= 1'b1;
end
reg        go_toggle;
reg        skip_open;
reg [15:0] end_wait;
reg        rd_start;        // pulse to cart_dump_gb
reg        arm;             // pulse to dump_chunk_src
reg        path_start;

wire       path_busy, path_done;

// Finish, crossed back from the bridge domain.
wire       fin_pulse;
wire       w_failed;
wire       w_failed_open;
wire [1:0] w_stall_at;
wire [2:0] w_err;
wire [15:0] w_fail_chunk;

always @(posedge clk_sys) begin
    done       <= 1'b0;
    rd_start   <= 1'b0;
    arm        <= 1'b0;
    path_start <= 1'b0;

    if (reset_sys) begin
        ss         <= SS_IDLE;
        busy       <= 1'b0;
        failed     <= 1'b0;
        err        <= 3'd0;
        fail_chunk <= 16'd0;
        want_mode  <= 2'b00;
        gba_l      <= 1'b0;
        kind_l     <= 2'd0;
        gsize_l    <= 32'd0;
        gssize_l   <= 32'd0;
        eeprom_l   <= 1'b0;
        eebits_l   <= 4'd14;
        go_toggle  <= 1'b0;
        hold       <= 5'd0;
        wake       <= 32'd0;
        sel_l      <= 1'b0;
        save_l     <= 1'b0;
        bo_l       <= 1'b1;
        combo      <= 6'd0;
        known      <= 1'b0;
        known_combo<= 6'd0;
        used_style <= 3'd0;
        used_order <= 1'b1;
        no_open    <= 1'b0;
        skip_open  <= 1'b0;
        stall_at   <= 2'd0;
        end_wait   <= 16'd0;
        tries      <= 8'd0;
        user_last  <= 6'd0;
        type_l     <= 8'd0;
        size_l     <= 8'd0;
    end else begin
        user_last <= user_combo;
        if (user_combo != user_last) known <= 1'b0;

        case (ss)
            SS_IDLE: begin
                busy      <= 1'b0;
                want_mode <= 2'b00;
                if (start) begin
                    busy       <= 1'b1;
                    failed     <= 1'b0;
                    err        <= 3'd0;
                    fail_chunk <= 16'd0;
                    no_open    <= 1'b0;
                    skip_open  <= 1'b0;
                    stall_at   <= 2'd0;
                    sel_l      <= selftest;
                    save_l     <= save_mode;
                    tries      <= 8'd0;
                    combo      <= known_valid ? known_combo : user_combo;
                    bo_l       <= known_valid ? ~known_combo[3] : byte_order;
                    type_l     <= cart_type;
                    size_l     <= rom_size_code;
                    gba_l      <= platform_gba;
                    kind_l     <= cart_kind;
                    gsize_l    <= gba_size_bytes;
                    gssize_l   <= gba_save_size_bytes;
                    eeprom_l   <= gba_save_is_eeprom;
                    eebits_l   <= gba_save_addr_bits;
                    arm        <= 1'b1;
                    if (selftest) begin
                        ss <= SS_PATH;
                    end else begin
                        want_mode <= platform_gba ? 2'b01 : 2'b10;
                        ss        <= SS_MODE;
                    end
                end
            end

            SS_MODE: begin
                if (abort_l) begin
                    failed <= 1'b1;
                    err    <= ERR_ABORTED;
                    begin end_wait <= 16'hFFFF; ss <= SS_END; end
                end else if (mode_ready) begin
                    wake <= WAKE_CYCLES[31:0];
                    ss   <= SS_WAKE;
                end
            end

            SS_WAKE: begin
                if (abort_l) begin
                    failed <= 1'b1;
                    err    <= ERR_ABORTED;
                    begin end_wait <= 16'hFFFF; ss <= SS_END; end
                end else if (wake != 32'd0) wake <= wake - 32'd1;
                else begin
                    rd_start <= 1'b1;
                    ss       <= SS_PATH;
                end
            end

            SS_PATH: begin
                bo_l       <= try_order;
                path_start <= 1'b1;
                tries      <= tries + 8'd1;
                ss         <= SS_HOLD;
            end

            // The path RAM has to be complete before APF is told to read it,
            // and total_bytes has to have been stable for longer than the
            // start toggle takes to cross. Both are covered by waiting here.
            SS_HOLD: begin
                if (path_done) hold <= 5'd31;
                else if (hold != 5'd0) hold <= hold - 5'd1;
                if (hold == 5'd1) ss <= SS_GO;
            end

            SS_GO: begin
                go_toggle <= ~go_toggle;
                ss        <= SS_RUN;
            end

            // An open that APF refused costs nothing and wrote nothing, so
            // the whole attempt is repeated with the next combination. Only
            // the open is retried this way: a failure partway through a file
            // has already created it and already written bytes, and repeating
            // that would be a different and worse thing than giving up.
            //
            // An abort is never retried either. The cartridge is gone.
            SS_RUN: begin
                if (fin_pulse) begin
                    // A stall is not retried. Each one costs the full
                    // timeout, and sixty-four of those is a minute of a
                    // screen saying nothing.
                    if (w_failed && w_failed_open && !abort_l &&
                        w_err != 3'd6 && tries != COMBO_COUNT) begin
                        combo <= combo + 6'd1;
                        ss    <= SS_PATH;
                    // Every open refused. Try writing into the file the slot
                    // already has, which needs no open at all.
                    // A stall does not stop the fallback, only the search:
                    // if APF will not answer an open it may still answer a
                    // write into the file the slot already has.
                    end else if (w_failed && w_failed_open && !abort_l &&
                                 !skip_open) begin
                        skip_open <= 1'b1;
                        no_open   <= 1'b1;
                        ss        <= SS_PATH;
                    end else begin
                        failed     <= w_failed;
                        err        <= w_err;
                        fail_chunk <= w_fail_chunk;
                        stall_at   <= w_stall_at;
                        // Only meaningful when something was accepted. On
                        // exhaustion combo has wrapped and pointing at
                        // whatever it landed on would read as a result.
                        if (!w_failed) begin
                            used_style <= try_style;
                            used_order <= try_order;
                        end
                        if (!w_failed) begin
                            known       <= 1'b1;
                            known_combo <= combo;
                        end
                        begin end_wait <= 16'hFFFF; ss <= SS_END; end
                    end
                end
            end

            // Dropping want_mode changes the connector mode, and cart_pins
            // honours that immediately: /WR rises and the data pins release
            // on the same edge, which is the edge a cartridge latches a
            // mapper register on. So the mode is held until the bus is idle.
            //
            // This matters most on an abort, where the reader is reset
            // mid-transaction. The transaction still completes, because
            // gb_cart_bus only samples req in ST_IDLE, so waiting is bounded
            // by one transaction and not by anything the reader does.
            //
            // The counter is a backstop for a bus that never goes idle. It
            // is long enough that no real transaction reaches it.
            //
            // On GBA the same hold is a smaller risk and is kept anyway. A
            // ROM-space write cannot pulse WR# at all there - gba_cart_bus
            // gates it behind eeprom, save or gpio space, which
            // tb_gba_cart_write_protect covers in 62 cases - so the worst a
            // truncated GBA transaction does is abandon a read. It costs one
            // comparison and a mux to keep, and the reason it is that cheap is
            // the reason not to make the behaviour depend on the platform:
            // one path, tested once, correct for both.
            SS_END: begin
                // The save reader gets held here as well as the bus. On an
                // abort the bus can be idle for the moment between two
                // transactions, and dropping the connector mode in that gap
                // would truncate the disable write that has not been issued
                // yet - gb_cart_bus gates e_ctl_out on gb_mode
                // combinationally, so the strobe would simply stop. The one
                // write that must never be truncated is the one that shuts
                // the cartridge's write gate.
                if ((!dump_bus_busy && !(save_l && sv_busy)) ||
                    end_wait == 16'd0) begin
                    want_mode <= 2'b00;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    ss      <= SS_IDLE;
                end else begin
                    end_wait <= end_wait - 16'd1;
                end
            end

            default: ss <= SS_IDLE;
        endcase
    end
end

// ============================================================
// clk_sys: the reader, the throttle and the buffer's write side
// ============================================================

wire [7:0] src_data;
wire       src_valid;
wire       src_ready;
wire       rd_busy, rd_done;
wire [7:0] gb_data, gba_data, gsv_data, gee_data;
wire       gb_valid, gba_valid, gsv_valid, gee_valid;
wire       gb_busy, gb_done, gba_rd_busy, gba_rd_done;
wire       gsv_busy, gsv_done;
wire [31:0] gsv_bytes;
wire        gsv_responded, gsv_blank_ff, gsv_blank_00;
wire [31:0] gsv_first;

// The GBA bus has two masters now for the same reason the GB bus does: a ROM
// reader and a save reader.
wire        gdmp_req, gdmp_wr;
wire [27:0] gdmp_addr;
wire [1:0]  gdmp_acc;
wire [31:0] gdmp_wdata;
wire        gee_busy, gee_done;
wire [31:0] gee_bytes;
wire        gee_responded, gee_blank_ff, gee_blank_00;
wire [31:0] gee_first;
wire        gee_req, gee_wr;
wire [27:0] gee_addr;
wire [1:0]  gee_acc;
wire [31:0] gee_wdata;

wire        gsv_req, gsv_wr;
wire [27:0] gsv_addr;
wire [1:0]  gsv_acc;
wire [31:0] gsv_wdata;

// The GB bus has two masters now: the ROM reader and the save reader.
wire        grom_req, grom_wr;
wire [15:0] grom_addr;
wire [7:0]  grom_wdata;
wire        sv_req, sv_wr;
wire [15:0] sv_addr;
wire [7:0]  sv_wdata;
wire [7:0]  sv_data;
wire        sv_valid, sv_busy, sv_done;
wire        sv_responded, sv_blank_ff, sv_blank_00;
wire [31:0] sv_first;
wire [31:0] save_bytes;

// One reader runs per dump and the other is left in idle, which is why the
// start pulse is gated rather than the bus ports muxed: an idle reader issues
// nothing, so the two masters can be wired straight out to their own buses.
// Starting both would be worse than untidy - the engine whose connector mode
// is not selected would wait forever for a done that its bus, disabled by
// cart_pins, is never going to raise.
// Four operations, four readers, one running at a time.
wire rd_start_gb     = rd_start & ~gba_l & ~save_l;
wire rd_start_gba    = rd_start &  gba_l & ~save_l;
wire rd_start_sv     = rd_start & ~gba_l &  save_l;
wire rd_start_gba_sv = rd_start &  gba_l &  save_l & ~eeprom_l;
wire rd_start_gba_ee = rd_start &  gba_l &  save_l &  eeprom_l;

// Held in reset by an abort rather than given an abort input of its own: it
// is stalled waiting for a bus_done that is not coming, and a reset is the
// only thing that reaches that state. Both readers are the same in this.
cart_dump_gb reader (
    .clk           ( clk_sys ),
    .reset         ( reset_sys | abort_l ),
    .start         ( rd_start_gb ),
    .cart_type     ( type_l ),
    .rom_size_code ( size_l ),
    .busy          ( gb_busy ),
    .done          ( gb_done ),
    .total_bytes   ( rom_bytes ),
    .bus_req       ( grom_req ),
    .bus_wr        ( grom_wr ),
    .bus_addr      ( grom_addr ),
    .bus_wdata     ( grom_wdata ),
    .bus_rdata     ( bus_rdata ),
    .bus_done      ( bus_done ),
    .out_data      ( gb_data ),
    .out_valid     ( gb_valid ),
    .out_ready     ( src_ready )
);

// The save reader. Same bus as the ROM reader and the same byte stream out,
// and the one difference that matters: it is NOT held in reset by an abort.
//
// Every other reader here can be reset where it stands, because the worst it
// abandons is a read. This one has opened the cartridge's write gate, and a
// reset would leave it open - the cartridge would come out of the slot with
// its RAM writable, which is worse than any file that failed to be written.
// So the abort is an input it acts on, and it leaves by way of the disable.
cart_save_gb reader_save (
    .clk           ( clk_sys ),
    .reset         ( reset_sys ),
    .start         ( rd_start_sv ),
    .abort         ( abort_l ),
    .cart_type     ( cart_type ),
    .ram_size_code ( ram_size_code ),
    .supported     ( save_supported ),
    .busy          ( sv_busy ),
    .done          ( sv_done ),
    .total_bytes   ( save_bytes ),
    .responded     ( sv_responded ),
    .blank_ff      ( sv_blank_ff ),
    .blank_00      ( sv_blank_00 ),
    .first_word    ( sv_first ),
    .bus_req       ( sv_req ),
    .bus_wr        ( sv_wr ),
    .bus_addr      ( sv_addr ),
    .bus_wdata     ( sv_wdata ),
    .bus_rdata     ( bus_rdata ),
    .bus_done      ( bus_done ),
    .out_data      ( sv_data ),
    .out_valid     ( sv_valid ),
    .out_ready     ( src_ready )
);

// Two masters on one bus, and only one of them is ever started, so this is a
// mux rather than an arbiter. An unstarted reader sits in idle and asserts
// nothing, but wiring both to the same net would still be a multiple driver.
assign bus_req   = save_l ? sv_req   : grom_req;
assign bus_wr    = save_l ? sv_wr    : grom_wr;
assign bus_addr  = save_l ? sv_addr  : grom_addr;
assign bus_wdata = save_l ? sv_wdata : grom_wdata;

// The GBA reader. No mapper, no bank registers, no writes: an address counter
// and 32-bit reads. The size it is given came off the bus rather than out of a
// header, which is the whole difference between the two platforms here.
cart_dump_gba reader_gba (
    .clk         ( clk_sys ),
    .reset       ( reset_sys | abort_l ),
    .start       ( rd_start_gba ),
    .size_bytes  ( gsize_l ),
    .busy        ( gba_rd_busy ),
    .done        ( gba_rd_done ),
    .total_bytes (  ),
    .bus_req     ( gdmp_req ),
    .bus_wr      ( gdmp_wr ),
    .bus_addr    ( gdmp_addr ),
    .bus_acc     ( gdmp_acc ),
    .bus_wdata   ( gdmp_wdata ),
    .bus_rdata   ( gba_rdata ),
    .bus_done    ( gba_done ),
    .bus_busy    ( gba_busy ),
    .out_data    ( gba_data ),
    .out_valid   ( gba_valid ),
    .out_ready   ( src_ready )
);

// The GBA save reader. Unlike cart_save_gb it opens no gate, so there is
// nothing it has to close on the way out and it can be held in reset by an
// abort exactly as the two ROM readers are. That is the whole difference, and
// it is why this instance carries no abort input.
cart_save_gba reader_gba_save (
    .clk         ( clk_sys ),
    .reset       ( reset_sys | abort_l ),
    .start       ( rd_start_gba_sv ),
    .size_bytes  ( gssize_l ),
    .busy        ( gsv_busy ),
    .done        ( gsv_done ),
    .total_bytes ( gsv_bytes ),
    .responded   ( gsv_responded ),
    .blank_ff    ( gsv_blank_ff ),
    .blank_00    ( gsv_blank_00 ),
    .first_word  ( gsv_first ),
    .bus_req     ( gsv_req ),
    .bus_wr      ( gsv_wr ),
    .bus_addr    ( gsv_addr ),
    .bus_acc     ( gsv_acc ),
    .bus_wdata   ( gsv_wdata ),
    .bus_rdata   ( gba_rdata ),
    .bus_done    ( gba_done ),
    .bus_busy    ( gba_busy ),
    .out_data    ( gsv_data ),
    .out_valid   ( gsv_valid ),
    .out_ready   ( src_ready )
);

// The EEPROM save reader. It writes to the cartridge and the other two do
// not, which is the protocol rather than a relaxation: the block number is
// clocked in a bit at a time and there is no other way to ask for one.
// gba_eeprom_io underneath it cannot express a write command.
cart_save_gba_eeprom reader_gba_eeprom (
    .clk         ( clk_sys ),
    .reset       ( reset_sys | abort_l ),
    .cart_mode   ( cart_mode ),
    .start       ( rd_start_gba_ee ),
    .size_bytes  ( gssize_l ),
    .addr_bits   ( eebits_l ),
    .busy        ( gee_busy ),
    .done        ( gee_done ),
    .total_bytes ( gee_bytes ),
    .responded   ( gee_responded ),
    .blank_ff    ( gee_blank_ff ),
    .blank_00    ( gee_blank_00 ),
    .first_word  ( gee_first ),
    .bus_req     ( gee_req ),
    .bus_wr      ( gee_wr ),
    .bus_addr    ( gee_addr ),
    .bus_acc     ( gee_acc ),
    .bus_wdata   ( gee_wdata ),
    .bus_rdata   ( gba_rdata ),
    .bus_done    ( gba_done ),
    .bus_busy    ( gba_busy ),
    .out_data    ( gee_data ),
    .out_valid   ( gee_valid ),
    .out_ready   ( src_ready )
);

// Three masters on the GBA bus, one of them ever started, so this is a mux
// rather than an arbiter, the same as the GB side above.
wire gba_ee_l = save_l & eeprom_l;
assign gba_req   = gba_ee_l ? gee_req   : save_l ? gsv_req   : gdmp_req;
assign gba_wr    = gba_ee_l ? gee_wr    : save_l ? gsv_wr    : gdmp_wr;
assign gba_addr  = gba_ee_l ? gee_addr  : save_l ? gsv_addr  : gdmp_addr;
assign gba_acc   = gba_ee_l ? gee_acc   : save_l ? gsv_acc   : gdmp_acc;
assign gba_wdata = gba_ee_l ? gee_wdata : save_l ? gsv_wdata : gdmp_wdata;

// The stream below here has never cared which platform it came from, and
// still does not: one byte, one valid, one ready.
wire gba_sv_l = gba_l & save_l;
wire gba_ee    = gba_sv_l &  eeprom_l;
wire gba_ram   = gba_sv_l & ~eeprom_l;
assign src_data  = gba_ee ? gee_data : gba_ram ? gsv_data : gba_l ? gba_data    : save_l ? sv_data  : gb_data;
assign src_valid = gba_ee ? gee_valid: gba_ram ? gsv_valid: gba_l ? gba_valid   : save_l ? sv_valid : gb_valid;
assign rd_busy   = gba_ee ? gee_busy : gba_ram ? gsv_busy : gba_l ? gba_rd_busy : save_l ? sv_busy  : gb_busy;
assign rd_done   = gba_ee ? gee_done : gba_ram ? gsv_done : gba_l ? gba_rd_done : save_l ? sv_done  : gb_done;

// The evidence follows whichever reader ran, for the same reason the stream
// does. These were wired straight from the GB reader once, and the screen
// reported SAVE RAM DID NOT ANSWER over a Golden Sun Flash backup that had
// worked, because cart_save_gb had never run and was still holding its idle
// values.
assign save_responded = gba_ee ? gee_responded : gba_sv_l ? gsv_responded : sv_responded;
assign save_blank_ff  = gba_ee ? gee_blank_ff  : gba_sv_l ? gsv_blank_ff  : sv_blank_ff;
assign save_blank_00  = gba_ee ? gee_blank_00  : gba_sv_l ? gsv_blank_00  : sv_blank_00;
assign save_first     = gba_ee ? gee_first     : gba_sv_l ? gsv_first     : sv_first;

// Which bus SS_END has to see go idle before it drops the mode.
wire dump_bus_busy = gba_l ? gba_busy : bus_busy;

// Chunk request, crossed from the bridge domain. req is a level held until
// ack, so three flops are all it needs.
wire        w_chunk_req;
wire [31:0] w_chunk_len;
wire        chunk_req_sys;
wire        chunk_ack_sys;
wire        chunk_ack_74a;

synch_3 s_req (.i (w_chunk_req),   .o (chunk_req_sys), .clk (clk_sys));
synch_3 s_ack (.i (chunk_ack_sys), .o (chunk_ack_74a), .clk (clk_74a));

// chunk_len is stable for the whole time req is high, and req is what gates
// its use, so it crosses as data qualified by a synchronised control signal
// rather than on its own.
reg [31:0] chunk_len_m, chunk_len_sys;
always @(posedge clk_sys) begin
    chunk_len_m   <= w_chunk_len;
    chunk_len_sys <= chunk_len_m;
end

wire       buf_rst, buf_we, buf_flush;
wire [7:0] buf_data;

// Every byte the reader produces passes here on its way to the buffer, so
// the check costs an adder and nothing in the data path.
wire byte_taken = src_valid & src_ready;

dump_checksum sumcalc (
    .clk    ( clk_sys ),
    .reset  ( reset_sys ),
    .start  ( rd_start ),
    .data   ( src_data ),
    .valid  ( byte_taken ),
    .sum    ( sum_computed ),
    .stored ( sum_stored ),
    .count  (  )
);

// Every byte again, this time for an identity rather than a verdict. The same
// accumulator serves both platforms: dump_crc32 knows nothing about headers.
//
// On GB this is a second opinion next to the cartridge's own checksum. On GBA
// it is the only opinion there is, and it is not a verdict - a CRC32 with
// nothing to compare against says only that two dumps agree, or that this one
// matches a published image. docs/GBA-DUMP-PLAN.md is explicit that this does
// not replace what dump_checksum does; it is what exists where dump_checksum
// has nothing to read.
dump_crc32 crccalc (
    .clk   ( clk_sys ),
    .reset ( reset_sys ),
    .start ( rd_start ),
    .data  ( src_data ),
    .valid ( byte_taken ),
    .crc   ( crc32 ),
    .count (  )
);

// A dump that was retried after a refused open re-reads nothing: the reader
// runs once. So the comparison is only meaningful once the image is complete,
// which is what busy going low means.
//
// And it is only meaningful at all on a platform that carries a checksum over
// its own contents. GBA does not: the complement at 0xBD covers the header
// and stops at 0xBC, so there is nothing here to compare a whole image
// against, and sum_computed against sum_stored would be two numbers about
// nothing. Reported as unchecked, which is the truth, rather than as a pass.
assign sum_checked = !sel_l && !gba_l && !save_l;

// Unlike sum_checked this is true on both platforms: a CRC32 needs nothing
// from the cartridge to be meaningful. It is false only for the self test,
// and for the reason above - dump_crc32's start is rd_start, which the self
// test path never reaches, so without this the screen would caption the last
// cartridge dump's CRC with the ramp's name.
assign crc_checked = !sel_l;
assign sum_ok      = (sum_computed == sum_stored);

dump_chunk_src #(.AW (BUF_AW)) chunk_src (
    .clk         ( clk_sys ),
    .reset       ( reset_sys ),
    .arm         ( arm ),
    .selftest    ( sel_l ),
    .abort       ( abort_l ),
    .req         ( chunk_req_sys ),
    .req_len     ( chunk_len_sys ),
    .ack         ( chunk_ack_sys ),
    .src_data    ( src_data ),
    .src_valid   ( src_valid ),
    .src_ready   ( src_ready ),
    .buf_rst     ( buf_rst ),
    .buf_we      ( buf_we ),
    .buf_data    ( buf_data ),
    .buf_flush   ( buf_flush ),
    .chunks_done ( chunks_done )
);

// ============================================================
// The two RAMs the bridge reads
// ============================================================

reg  [BUF_AW-1:0] buf_rd_addr;
wire [31:0]       buf_rd_q;

dump_buffer #(.WORDS (BUF_WORDS), .AW (BUF_AW)) chunk_buf (
    .wr_clk     ( clk_sys ),
    .wr_rst     ( buf_rst ),
    .wr_en      ( buf_we ),
    .wr_data    ( buf_data ),
    .wr_flush   ( buf_flush ),
    .byte_order ( bo_l ),
    .rd_clk     ( clk_74a ),
    .rd_addr    ( buf_rd_addr ),
    .rd_q       ( buf_rd_q )
);

reg  [6:0]  str_rd_addr;
wire [31:0] str_rd_q;

// What the file is called, for the screen. A dump that says COMPLETE without
// naming the file it wrote leaves the user hunting the card for it.
dump_path_gen path_gen (
    .clk         ( clk_sys ),
    .reset       ( reset_sys ),
    .start       ( path_start ),
    .selftest    ( sel_l ),
    .path_style  ( try_style ),
    .field_order ( try_field ),
    .create_only ( try_create_only ),
    .title       ( title ),
    .cart_kind   ( kind_l ),
    .total_bytes ( total_bytes ),
    .byte_order  ( bo_l ),
    .busy        ( path_busy ),
    .done        ( path_done ),
    .out_name    ( out_name ),
    .out_name_len( out_name_len ),
    .out_ext     ( out_ext ),
    .out_ext_len ( out_ext_len ),
    .rd_clk      ( clk_74a ),
    .rd_addr     ( str_rd_addr ),
    .rd_q        ( str_rd_q )
);

// ============================================================
// clk_74a: the bridge read window
//
// TWO THINGS, AND GETTING EITHER ONE WRONG LOOKS LIKE THE OTHER.
//
// The address free runs. io_bridge_peripheral.v holds it from the SPI address
// phase and never tells the core when it settled, so a window that waits for
// bridge_rd starts its lookup after the read has already been sampled.
//
// The data is latched on bridge_rd, which puts it one transaction behind.
// That is not a mistake, it is the protocol: core_bridge_cmd.v does exactly
// this with the datatable, free running b_datatable_addr and latching
// b_datatable_q on bridge_rd, and APF has been driven against that shape
// since before this core existed. The value the host receives for a
// transaction is the one the core presented during the previous one.
//
// This half was removed in "bridge_rd is not a request", which free ran the
// output as well as the address on the reasoning that the peripheral samples
// before it pulses. It does, and the host accounts for it. Removing the lag
// made every read arrive one word early: the first dump that reached the card
// contained source word k+1 at word k, and APF read the open struct's path as
// "ets/carttools/..." rather than "/Assets/...", which is a malformed path,
// which is result 4, sixty-four times over.
// ============================================================

reg sel_str_1, sel_str_2;

wire endian_little_74a;
synch_3 s_endian (.i (bridge_endian_little), .o (endian_little_74a), .clk (clk_74a));

wire       win_hit_now = (bridge_addr[31:28] == BUF_BASE[31:28]) ||
                         (bridge_addr[31:28] == STRUCT_BASE[31:28]);
wire [31:0] win_now    = sel_str_2 ? str_rd_q : buf_rd_q;

reg [31:0] win_hold;
reg        hit_hold;

always @(posedge clk_74a) begin
    if (reset_74a) begin
        buf_rd_addr <= {BUF_AW{1'b0}};
        str_rd_addr <= 7'd0;
        sel_str_1   <= 1'b0;
        sel_str_2   <= 1'b0;
        win_hold    <= 32'd0;
        hit_hold    <= 1'b0;
    end else begin
        // Free running, so the answer is standing well before it is wanted.
        buf_rd_addr <= bridge_addr[BUF_AW+1:2];
        str_rd_addr <= bridge_addr[8:2];
        sel_str_1   <= (bridge_addr[31:28] == STRUCT_BASE[31:28]);
        sel_str_2   <= sel_str_1;

        // Held from one transaction to the next, which is the protocol.
        if (bridge_rd) begin
            win_hold <= win_now;
            hit_hold <= win_hit_now;
        end
    end
end

wire [31:0] win_nat = win_hold;

// The same conditional swap core_bridge_cmd applies to its own registers.
assign bridge_rd_data = endian_little_74a
    ? {win_nat[7:0], win_nat[15:8], win_nat[23:16], win_nat[31:24]}
    : win_nat;

// Also held, because it selects between two sources that are both a
// transaction behind.
assign bridge_rd_hit = hit_hold;

// Counted on bridge_rd rather than on the free running decode, because
// bridge_rd is one pulse per transaction while the decode is valid every
// cycle. The address is still held when the pulse arrives, so it can be
// recorded alongside. A struct count of zero after a failed open says APF
// never came looking here, and dbg_last_addr says where it went instead.
reg [15:0] rd_count, str_count;
reg [31:0] last_addr;
reg [31:0] first_word;
reg [31:0] flags_word;
reg [31:0] size_word;

// Everything captured from the struct is captured for one attempt only, the
// first. A search that runs thirty-two opens otherwise leaves the last one's
// values on screen, and the last one is whichever the counter wrapped to.
reg  cap_en;
reg  arm_1, arm_2, arm_3;
always @(posedge clk_74a) begin
    arm_1 <= arm_toggle;
    arm_2 <= arm_1;
    arm_3 <= arm_2;
end
wire arm_74a = arm_3 ^ arm_2;

always @(posedge clk_74a) begin
    if (reset_74a)     cap_en <= 1'b0;
    else if (arm_74a)  cap_en <= 1'b1;
    // APF reads the size field last, so that is where one attempt ends.
    else if (bridge_rd && bridge_addr == STRUCT_BASE + 32'h104)
                       cap_en <= 1'b0;
end

// Captured on bridge_rd, which is safe even though the peripheral samples
// before it: the address is still held and bridge_rd_data still carries the
// value that was sampled.
always @(posedge clk_74a) begin
    if (reset_74a) begin
        rd_count   <= 16'd0;
        str_count  <= 16'd0;
        last_addr  <= 32'd0;
        first_word <= 32'd0;
        flags_word <= 32'd0;
        size_word  <= 32'd0;
    end else if (bridge_rd) begin
        if (cap_en) begin
            if (bridge_addr == STRUCT_BASE)              first_word <= bridge_rd_data;
            if (bridge_addr == STRUCT_BASE + 32'h100)    flags_word <= bridge_rd_data;
            if (bridge_addr == STRUCT_BASE + 32'h104)    size_word  <= bridge_rd_data;
        end
        // Captured un-swapped, so it means the same thing as a captured
        // write and the two can be read side by side.
        if (cap_en && bridge_addr[31:28] == STRUCT_BASE[31:28] &&
            bridge_addr[27:7] == 21'd0)
            sent_w[bridge_addr[6:2]] <= rd_nat;
        rd_count <= rd_count + 16'd1;
        if (bridge_addr[31:28] == STRUCT_BASE[31:28])
            str_count <= str_count + 16'd1;
        // 0xF8xxxxxx is core_bridge_cmd's register page and APF polls it
        // constantly, so recording it would bury everything else.
        if (bridge_addr[31:24] != 8'hF8)
            last_addr <= bridge_addr;
    end
end

synch_3 #(.WIDTH(16)) s_rdc   (.i (rd_count),  .o (dbg_reads),        .clk (clk_sys));
synch_3 #(.WIDTH(16)) s_strc  (.i (str_count), .o (dbg_struct_reads), .clk (clk_sys));
synch_3 #(.WIDTH(32)) s_lasta (.i (last_addr), .o (dbg_last_addr),    .clk (clk_sys));
synch_3 #(.WIDTH(32)) s_first (.i (first_word),.o (dbg_first_word),   .clk (clk_sys));
synch_3 #(.WIDTH(32)) s_flags (.i (flags_word),.o (dbg_flags_word),   .clk (clk_sys));
synch_3 #(.WIDTH(32)) s_size  (.i (size_word), .o (dbg_size_word),    .clk (clk_sys));

// ============================================================
// clk_74a: 0x0190 Get filename
//
// The only command here that makes APF write rather than read, and therefore
// the only way to see a path in APF's own format instead of guessing at one.
// Eight words of the response are kept, which is 32 characters, enough to
// show the root.
// ============================================================

assign target_buffer_resp_struct = RESP_BASE;

// The same conditional swap the read side applies, so a captured word means
// the same thing as one presented.
wire [31:0] wr_nat = endian_little_74a
    ? {bridge_wr_data[7:0], bridge_wr_data[15:8],
       bridge_wr_data[23:16], bridge_wr_data[31:24]}
    : bridge_wr_data;

reg [31:0] resp_w [0:31];
reg [31:0] sent_w [0:31];
integer    r;
initial for (r = 0; r < 32; r = r + 1) begin
    resp_w[r] = 32'd0;
    sent_w[r] = 32'd0;
end

// bridge_rd_data with the peripheral's conditional swap undone, which is
// exactly what wr_nat is for the other direction.
wire [31:0] rd_nat = endian_little_74a
    ? {bridge_rd_data[7:0], bridge_rd_data[15:8],
       bridge_rd_data[23:16], bridge_rd_data[31:24]}
    : bridge_rd_data;

always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:28] == RESP_BASE[31:28] &&
        bridge_addr[27:7] == 21'd0)
        resp_w[bridge_addr[6:2]] <= wr_nat;
end

genvar gi;
generate
    for (gi = 0; gi < 32; gi = gi + 1) begin : g_resp
        assign resp_words[32*gi +: 32] = resp_w[gi];
        assign sent_words[32*gi +: 32] = sent_w[gi];
    end
endgenerate

// One command at a time, and never while a dump owns the target path.
localparam [1:0] PS_IDLE = 2'd0;
localparam [1:0] PS_GO   = 2'd1;
localparam [1:0] PS_WAIT = 2'd2;

reg [1:0] ps;
reg       ps_busy;
reg       ps_saw;

wire probe_start_74a;
reg  pst_1, pst_2, pst_3;
always @(posedge clk_74a) begin
    pst_1 <= probe_toggle;
    pst_2 <= pst_1;
    pst_3 <= pst_2;
end
assign probe_start_74a = pst_3 ^ pst_2;

always @(posedge clk_74a) begin
    target_dataslot_getfile <= 1'b0;
    if (reset_74a) begin
        ps        <= PS_IDLE;
        ps_busy   <= 1'b0;
        probe_err <= 3'd0;
    end else begin
        case (ps)
            PS_IDLE: begin
                ps_busy <= 1'b0;
                if (probe_start_74a && !w_busy) begin
                    ps_busy <= 1'b1;
                    ps      <= PS_GO;
                end
            end
            PS_GO: begin
                target_dataslot_getfile <= 1'b1;
                ps_saw <= 1'b0;
                ps     <= PS_WAIT;
            end
            PS_WAIT: begin
                if (!target_dataslot_done) ps_saw <= 1'b1;
                else if (ps_saw) begin
                    probe_err <= target_dataslot_err;
                    ps        <= PS_IDLE;
                end
            end
            default: ps <= PS_IDLE;
        endcase
    end
end

// Slot 0 answers with the path of the file the user browsed to, which is how
// the format was established. Slot 20 answers with the path APF associates
// with the output slot itself, which is the more useful question and the one
//0x0192 has been refusing to answer for three sessions.
reg [15:0] ps_slot;
always @(posedge clk_74a) if (ps == PS_IDLE) ps_slot <= probe_slot;

assign target_dataslot_id = ps_busy ? ps_slot : w_slot_id;

// ============================================================
// clk_74a: the writer
// ============================================================

wire go_74a;
reg  go_s1, go_s2, go_s3;

always @(posedge clk_74a) begin
    if (reset_74a) begin
        go_s1 <= 1'b0; go_s2 <= 1'b0; go_s3 <= 1'b0;
    end else begin
        go_s1 <= go_toggle;
        go_s2 <= go_s1;
        go_s3 <= go_s2;
    end
end
assign go_74a = go_s3 ^ go_s2;

reg [31:0] total_74a;
always @(posedge clk_74a) total_74a <= total_bytes;

// A level, and sticky on the far side until the sequencer clears it, so it
// does not have to be caught in any particular cycle.
wire abort_74a;
synch_3 s_abort (.i (abort_l), .o (abort_74a), .clk (clk_74a));

wire skip_open_74a;
synch_3 s_skip (.i (skip_open), .o (skip_open_74a), .clk (clk_74a));

wire w_busy, w_done;
wire [15:0] w_slot_id;

// probe_start is a clk_sys pulse; a toggle survives the crossing.
reg arm_toggle;
always @(posedge clk_sys) begin
    if (reset_sys) arm_toggle <= 1'b0;
    else if (arm)  arm_toggle <= ~arm_toggle;
end

reg probe_toggle;
always @(posedge clk_sys) begin
    if (reset_sys)        probe_toggle <= 1'b0;
    else if (probe_start) probe_toggle <= ~probe_toggle;
end

apf_file_writer #(
    .SLOT_ID     ( SLOT_ID ),
    .BUF_BASE    ( BUF_BASE ),
    .STRUCT_BASE ( STRUCT_BASE ),
    .CHUNK_BYTES ( CHUNK_BYTES )
) writer (
    .clk         ( clk_74a ),
    .reset       ( reset_74a ),
    .start       ( go_74a ),
    .total_bytes ( total_74a ),
    .abort       ( abort_74a ),
    .skip_open   ( skip_open_74a ),
    .busy        ( w_busy ),
    .done        ( w_done ),
    .failed      ( w_failed ),
    .failed_open ( w_failed_open ),
    .stall_at    ( w_stall_at ),
    .err         ( w_err ),
    .fail_chunk  ( w_fail_chunk ),
    .chunk_req   ( w_chunk_req ),
    .chunk_index (  ),
    .chunk_len   ( w_chunk_len ),
    .chunk_ack   ( chunk_ack_74a ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    .target_dataslot_flush      ( target_dataslot_flush ),
    .target_dataslot_id         ( w_slot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err )
);

// Finish, crossed back. The result registers are written on the same edge
// the toggle flips and the toggle takes three clk_sys cycles to arrive, so
// they are stable long before they are sampled.
reg  fin_toggle;
always @(posedge clk_74a) begin
    if (reset_74a)   fin_toggle <= 1'b0;
    else if (w_done) fin_toggle <= ~fin_toggle;
end

reg fin_s1, fin_s2, fin_s3;
always @(posedge clk_sys) begin
    if (reset_sys) begin
        fin_s1 <= 1'b0; fin_s2 <= 1'b0; fin_s3 <= 1'b0;
    end else begin
        fin_s1 <= fin_toggle;
        fin_s2 <= fin_s1;
        fin_s3 <= fin_s2;
    end
end
assign fin_pulse = fin_s3 ^ fin_s2;

endmodule

`default_nettype wire
