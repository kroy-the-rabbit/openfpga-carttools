// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// apf_file_writer.sv - open a file on the SD card and stream bytes into it
//
// The nonvolatile-writeback path this core inherited is the wrong tool for a
// dump: it fixes the filename, fires only at core exit, needs the whole
// payload addressable at once, and reports nothing. This uses the target
// command path instead, which is the one APF offers for cores that want to
// write a file they name themselves. docs/APF-NOTES.md sections 3 and 9.
//
// Sequence, all of it driven from clk_74a because that is the domain
// core_bridge_cmd lives in:
//
//   [0192] open the file, with a path and a desired size
//   [0184] write one chunk, repeated, each carrying its own slot offset
//   [0188] flush, because buffered data can fail only at flush time
//
// The caller supplies bytes through a chunk handshake rather than a stream:
// this module asks for a bufferful (chunk_req), the producer fills the chunk
// RAM through its own port and answers (chunk_ack). That keeps the cartridge
// side free to run at its own rate in its own clock domain, and it is what
// lets a dump be built out of a reader that knows nothing about APF.
//
// Error handling is deliberate. target_dataslot_err is three bits and it is
// the only failure channel that exists: there is no free space query, and a
// full card, a write-protected card and a filesystem error all collapse into
// the same code. So every command is checked, not just the last one, and the
// chunk index of the first failure is held for the UI. A dump that fails at
// chunk 900 of 1000 must not look like a dump that succeeded.
//
// What is NOT verified here, and must be checked on hardware:
//   - the byte order the bridge presents for the struct and the buffer
//   - whether a length that is not a multiple of four is accepted
//   - whether consecutive writes to one slot really do keep the file open
//

module apf_file_writer #(
    // Data slot this writes into. Must exist in data.json, must not be
    // read-only, and should be deferload.
    parameter [15:0]  SLOT_ID     = 16'd20,

    // Bridge windows. Each must occupy its own top nibble: the decode in
    // core_top matches on bridge_addr[31:28] only.
    parameter [31:0]  BUF_BASE    = 32'h6000_0000,
    parameter [31:0]  STRUCT_BASE = 32'h7000_0000,

    // Bytes per [0184]. A power of two keeps the offset arithmetic a shift.
    parameter integer CHUNK_BYTES = 4096,

    // How long to wait for APF to answer a command before giving up on it.
    // There is no upper bound in the documentation and no way to cancel, so
    // the only alternative to a limit is waiting forever, which is what two
    // hardware sessions did: the screen said DUMPING with the bar full and
    // nothing ever moved again. About 1.8 seconds at 74.25 MHz.
    parameter integer TIMEOUT_CYCLES = 134_217_728,

    // Whether to issue [0188] flush at all. OFF, because APF does not answer
    // it: hardware reported err 6 stalled-at-flush after every write had
    // returned success. It is not merely useless, it is harmful. core_bridge_cmd's
    // target state machine waits in TARG_ST_WAITRESULT_DSO for a result that
    // never arrives, so one stalled flush blocks every target command after
    // it and the next dump cannot even open.
    //
    // The command is documented and this core implemented it because
    // docs/HANDOFF.md said its absence was a defect. Being in the
    // documentation turned out not to mean it is answered.
    //
    // Without it the writes still commit; the first dump that reached the
    // card did so with a flush that had already hung. What is lost is the
    // confirmation that they committed, which was the only reason to want it.
    parameter bit     USE_FLUSH = 1'b0
) (
    input  wire        clk,            // clk_74a
    input  wire        reset,

    // --- caller ---
    input  wire        start,          // pulse, sampled in idle only
    input  wire [31:0] total_bytes,    // file size; also the [0192] resize

    // The producer can no longer produce: the slot lost power or the
    // cartridge was pulled. Level, and sticky once seen, because there is no
    // other way out of waiting for a chunk that will never arrive.
    input  wire        abort,

    // Write into whatever file the slot already has, without opening one.
    // 0x0192 has refused sixty-four combinations of a path APF itself
    // confirmed the format of, so this is the route that does not need it:
    // data.json gives slot 20 a filename, APF associates a real path with it,
    // and 0x0184 writes into that. The name is fixed instead of chosen, which
    // is worse, and a dump that exists is better than one that does not.
    input  wire        skip_open,
    output reg         busy,
    output reg         done,           // one cycle when the whole file is written
    output reg         failed,         // sticky with done: something went wrong
    // True when the failure was the open itself, so nothing was written and
    // the whole attempt can be repeated with different parameters. A failure
    // partway through a file cannot be, because the file already exists and
    // has bytes in it.
    output reg         failed_open,

    // Which command APF never answered, when err is ERR_STALLED. 1 open,
    // 2 write, 3 flush. A hang that reports where it hung is a bug report;
    // one that does not is a support ticket.
    output reg  [1:0]  stall_at,
    output reg  [2:0]  err,            // last target_dataslot_err
    output reg  [15:0] fail_chunk,     // which chunk index failed, for the UI

    // --- chunk producer ---
    // req rises when the module wants chunk number chunk_index filled with
    // chunk_len bytes. The producer writes them through the chunk RAM's other
    // port and pulses ack. req falls on ack.
    output reg         chunk_req,
    output reg  [15:0] chunk_index,
    output reg  [31:0] chunk_len,
    input  wire        chunk_ack,

    // --- core_bridge_cmd ---
    output reg         target_dataslot_write,
    output reg         target_dataslot_openfile,
    output reg         target_dataslot_flush,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    output wire [31:0] target_buffer_param_struct,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err
);

assign target_buffer_param_struct = STRUCT_BASE;

localparam [3:0] ST_IDLE      = 4'd0;
localparam [3:0] ST_OPEN      = 4'd1;
localparam [3:0] ST_OPEN_WAIT = 4'd2;
localparam [3:0] ST_ASK       = 4'd3;
localparam [3:0] ST_ASK_WAIT  = 4'd4;
localparam [3:0] ST_WRITE     = 4'd5;
localparam [3:0] ST_WRITE_WAIT= 4'd6;
localparam [3:0] ST_FLUSH     = 4'd7;
localparam [3:0] ST_FLUSH_WAIT= 4'd8;
localparam [3:0] ST_DONE      = 4'd9;
localparam [3:0] ST_FAIL      = 4'd10;

reg [3:0]  state;
reg [31:0] written;        // bytes handed to APF so far
reg [31:0] remaining;

// target_dataslot_done stays asserted until the next command is issued, so it
// cannot be sampled as a level on entry to a wait state: the previous
// command's done is still there. Wait for it to fall first.
reg        saw_busy;

// An abort is never acted on in the middle of an APF command. Leaving one
// outstanding while this goes idle would desync the next command's done
// handshake, and the command completes on its own in a bounded time anyway.
// So it is latched, and taken at the next point where the choice is ours.
reg        aborting;

// Reloaded on entry to every wait state, counted down while waiting.
reg [31:0] tmo;
wire       expired = (tmo == 32'd0);

// Not a code APF can return; the documented range is 0 to 5. It has to be
// distinguishable, because "the cartridge went away" and "the card is full"
// are the same three bits otherwise.
localparam [2:0] ERR_ABORTED = 3'd7;

// Also outside the documented range. APF returns 0 to 5; 6 is this core
// saying it stopped waiting.
localparam [2:0] ERR_STALLED = 3'd6;

localparam [1:0] AT_OPEN  = 2'd1;
localparam [1:0] AT_WRITE = 2'd2;
localparam [1:0] AT_FLUSH = 2'd3;

wire [31:0] this_len = (remaining > CHUNK_BYTES[31:0]) ? CHUNK_BYTES[31:0]
                                                       : remaining;

always @(posedge clk) begin
    // Strobes are single cycle. core_bridge_cmd edge-detects them.
    target_dataslot_write    <= 1'b0;
    target_dataslot_openfile <= 1'b0;
    target_dataslot_flush    <= 1'b0;
    done                     <= 1'b0;

    if (reset) begin
        state       <= ST_IDLE;
        busy        <= 1'b0;
        failed      <= 1'b0;
        failed_open <= 1'b0;
        err         <= 3'd0;
        fail_chunk  <= 16'd0;
        chunk_req   <= 1'b0;
        chunk_index <= 16'd0;
        chunk_len   <= 32'd0;
        written     <= 32'd0;
        remaining   <= 32'd0;
        saw_busy    <= 1'b0;
        aborting    <= 1'b0;
        stall_at    <= 2'd0;
        tmo         <= 32'd0;
        target_dataslot_id         <= SLOT_ID;
        target_dataslot_slotoffset <= 32'd0;
        target_dataslot_bridgeaddr <= BUF_BASE;
        target_dataslot_length     <= 32'd0;
    end else begin
        if (abort && busy) aborting <= 1'b1;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    aborting <= 1'b0;
                    busy        <= 1'b1;
                    failed      <= 1'b0;
                    failed_open <= 1'b0;
                    stall_at    <= 2'd0;
                    err         <= 3'd0;
                    fail_chunk  <= 16'd0;
                    written     <= 32'd0;
                    remaining   <= total_bytes;
                    chunk_index <= 16'd0;
                    target_dataslot_id <= SLOT_ID;
                    state       <= skip_open ? ST_ASK : ST_OPEN;
                end
            end

            // [0192]. The path and the flags live in the struct RAM, which the
            // caller has already filled; all this carries is the slot id and
            // the pointer, both of which are standing.
            ST_OPEN: begin
                target_dataslot_openfile <= 1'b1;
                saw_busy <= 1'b0;
                tmo      <= TIMEOUT_CYCLES[31:0];
                state    <= ST_OPEN_WAIT;
            end

            ST_OPEN_WAIT: begin
                tmo <= tmo - 32'd1;
                if (expired) begin
                    err         <= ERR_STALLED;
                    stall_at    <= AT_OPEN;
                    failed_open <= 1'b1;
                    state       <= ST_FAIL;
                end else if (!target_dataslot_done) saw_busy <= 1'b1;
                else if (saw_busy) begin
                    err <= target_dataslot_err;
                    // 0 opened, 1 created and opened. 1 is not an error, and
                    // treating it as one would break every first dump.
                    if (aborting) begin
                        err   <= ERR_ABORTED;
                        state <= ST_FAIL;
                    end else if (target_dataslot_err == 3'd0 ||
                                 target_dataslot_err == 3'd1) begin
                        if (remaining == 32'd0)
                            state <= USE_FLUSH ? ST_FLUSH : ST_DONE;
                        else
                            state <= ST_ASK;
                    end else begin
                        failed_open <= 1'b1;
                        state       <= ST_FAIL;
                    end
                end
            end

            // The only two states where nothing is outstanding at APF, and
            // therefore the only two where an abort can be taken at once.
            // Waiting here for a chunk that will never arrive is precisely
            // the hang this exists to prevent.
            ST_ASK: begin
                if (aborting) begin
                    err        <= ERR_ABORTED;
                    fail_chunk <= chunk_index;
                    state      <= ST_FAIL;
                end else begin
                    chunk_len <= this_len;
                    chunk_req <= 1'b1;
                    state     <= ST_ASK_WAIT;
                end
            end

            ST_ASK_WAIT: begin
                if (aborting) begin
                    chunk_req  <= 1'b0;
                    err        <= ERR_ABORTED;
                    fail_chunk <= chunk_index;
                    state      <= ST_FAIL;
                end else if (chunk_ack) begin
                    chunk_req <= 1'b0;
                    state     <= ST_WRITE;
                end
            end

            ST_WRITE: begin
                target_dataslot_slotoffset <= written;
                target_dataslot_bridgeaddr <= BUF_BASE;
                target_dataslot_length     <= chunk_len;
                target_dataslot_write      <= 1'b1;
                saw_busy <= 1'b0;
                tmo      <= TIMEOUT_CYCLES[31:0];
                state    <= ST_WRITE_WAIT;
            end

            ST_WRITE_WAIT: begin
                tmo <= tmo - 32'd1;
                if (expired) begin
                    err        <= ERR_STALLED;
                    stall_at   <= AT_WRITE;
                    fail_chunk <= chunk_index;
                    state      <= ST_FAIL;
                end else if (!target_dataslot_done) saw_busy <= 1'b1;
                else if (saw_busy) begin
                    err <= target_dataslot_err;
                    if (aborting) begin
                        err        <= ERR_ABORTED;
                        fail_chunk <= chunk_index;
                        state      <= ST_FAIL;
                    end else if (target_dataslot_err == 3'd0) begin
                        written   <= written   + chunk_len;
                        remaining <= remaining - chunk_len;
                        if (remaining == chunk_len) begin
                            state <= USE_FLUSH ? ST_FLUSH : ST_DONE;
                        end else begin
                            chunk_index <= chunk_index + 16'd1;
                            state       <= ST_ASK;
                        end
                    end else begin
                        // Checked per chunk, not once at the end. Buffered
                        // data means a card that filled up at chunk 900
                        // reports it at chunk 900, and the UI can say so.
                        fail_chunk <= chunk_index;
                        state      <= ST_FAIL;
                    end
                end
            end

            ST_FLUSH: begin
                target_dataslot_flush <= 1'b1;
                saw_busy <= 1'b0;
                tmo      <= TIMEOUT_CYCLES[31:0];
                state    <= ST_FLUSH_WAIT;
            end

            // A flush that never answers is reported, but the bytes are
            // already at APF: every write returned success. So this is a
            // failure of the commit, not of the dump, and the file may well
            // be on the card. The screen has to be able to say that.
            ST_FLUSH_WAIT: begin
                tmo <= tmo - 32'd1;
                if (expired) begin
                    err      <= ERR_STALLED;
                    stall_at <= AT_FLUSH;
                    state    <= ST_FAIL;
                end else if (!target_dataslot_done) saw_busy <= 1'b1;
                else if (saw_busy) begin
                    err <= target_dataslot_err;
                    if (target_dataslot_err == 3'd0) state <= ST_DONE;
                    else                             state <= ST_FAIL;
                end
            end

            ST_DONE: begin
                done   <= 1'b1;
                failed <= 1'b0;
                busy   <= 1'b0;
                state  <= ST_IDLE;
            end

            ST_FAIL: begin
                done   <= 1'b1;
                failed <= 1'b1;
                busy   <= 1'b0;
                state  <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
