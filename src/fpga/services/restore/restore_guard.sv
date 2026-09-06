// SPDX-License-Identifier: GPL-3.0-or-later
//
// Latched restore pages with two independent deliberate holds. A complete
// Select hold opens the page. A new A press/release requests preflight; a new
// A hold after preflight authorizes one transaction. Unrelated keys clear
// affirmative progress while retaining the page.
//
// transaction_busy covers the engine, its pending dispatch, and electrical
// probes. Cancellation keeps ownership until all of that work has drained.
// The caller also quarantines ordinary controls until a full key release
// after the overlay closes.

`default_nettype none

module restore_guard #(
    parameter [31:0] DEBOUNCE_CYCLES   = 32'd2013266,
    parameter [31:0] ENTRY_HOLD_CYCLES = 32'd301989888,
    parameter [31:0] HOLD_CYCLES       = 32'd301989888
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       key_select,
    input  wire       key_x,
    input  wire       key_y,
    input  wire       key_a,
    input  wire       key_b,
    input  wire       cancel,
    input  wire       available,
    input  wire       transaction_busy,
    input  wire       preflight_done,
    input  wire       preflight_ok,
    input  wire       operation_done,
    input  wire       operation_failed,
    output wire       preflight_start,
    output wire       write_start,
    output wire       unlocked,
    output wire       active,
    output wire       busy,
    output reg  [3:0] state,
    output reg  [1:0] hold_progress,
    output wire       authorized
);

localparam [3:0] ST_LOCKED       = 4'd0;
localparam [3:0] ST_ENTRY_HOLD   = 4'd1;
localparam [3:0] ST_READY        = 4'd2;
localparam [3:0] ST_PREFLIGHT    = 4'd3;
localparam [3:0] ST_CONFIRM_HOLD = 4'd6;
localparam [3:0] ST_RUN          = 4'd7;
localparam [3:0] ST_DONE         = 4'd8;
localparam [3:0] ST_FAILED       = 4'd9;
localparam [3:0] ST_ABORTING     = 4'd10;

localparam [4:0] KEY_SELECT = 5'b10000;
localparam [4:0] KEY_A      = 5'b00010;
localparam [31:0] ENTRY_LIMIT = ENTRY_HOLD_CYCLES < 1 ? 1 : ENTRY_HOLD_CYCLES;
localparam [31:0] HOLD_LIMIT = HOLD_CYCLES < 1 ? 1 : HOLD_CYCLES;
// Constant thresholds keep division out of the clocked hold/progress path.
localparam [31:0] ENTRY_THIRD = (ENTRY_LIMIT + 2) / 3;
localparam [31:0] HOLD_THIRD = (HOLD_LIMIT + 2) / 3;

wire [4:0] raw_keys = {key_select, key_x, key_y, key_a, key_b};
reg [4:0] stable_keys;
reg [4:0] candidate_keys;
reg [31:0] debounce_count;
reg [31:0] hold_timer;
reg [3:0] entry_return_state;
reg entry_abandoned;
reg release_ready;
reg press_pending;
reg preflight_armed;
reg operation_armed;
reg preflight_pulse;
reg write_pulse;

wire released = raw_keys == 0 && stable_keys == 0;
wire accepted_key = raw_keys == stable_keys;
wire terminal_state = state == ST_LOCKED || state == ST_DONE || state == ST_FAILED;
wire work_state = state == ST_PREFLIGHT || state == ST_CONFIRM_HOLD ||
                  state == ST_RUN || state == ST_ABORTING;

assign active = state != ST_LOCKED;
assign busy = work_state;
assign unlocked = state == ST_READY || state == ST_PREFLIGHT ||
                  state == ST_CONFIRM_HOLD || state == ST_RUN;
assign authorized = state == ST_RUN && !reset && !cancel && !key_b;
assign preflight_start = preflight_pulse && !reset && !cancel && !key_b;
assign write_start = write_pulse && authorized;

// Affirmative actions require a stable whole key vector. A chord can never
// become two independent affirmative actions. Cancellation is immediate.
always @(posedge clk) begin
    if (reset) begin
        stable_keys    <= 0;
        candidate_keys <= 0;
        debounce_count <= 0;
    end else if (raw_keys == stable_keys) begin
        candidate_keys <= raw_keys;
        debounce_count <= 0;
    end else if (DEBOUNCE_CYCLES <= 1) begin
        stable_keys    <= raw_keys;
        candidate_keys <= raw_keys;
        debounce_count <= 0;
    end else if (raw_keys != candidate_keys) begin
        candidate_keys <= raw_keys;
        debounce_count <= 1;
    end else if (debounce_count >= DEBOUNCE_CYCLES - 1) begin
        stable_keys    <= raw_keys;
        debounce_count <= 0;
    end else begin
        debounce_count <= debounce_count + 1'b1;
    end
end

always @(posedge clk) begin
    preflight_pulse <= 0;
    write_pulse <= 0;

    if (reset) begin
        state <= ST_LOCKED;
        hold_progress <= 0;
        hold_timer <= 0;
        entry_return_state <= ST_LOCKED;
        entry_abandoned <= 0;
        release_ready <= 0;
        press_pending <= 0;
        preflight_armed <= 0;
        operation_armed <= 0;
    end else if ((cancel || key_b) && state != ST_ABORTING &&
                 (!terminal_state || cancel || release_ready)) begin
        // Busy cancellation always occupies ABORTING for at least one clock.
        // A held B cannot dismiss the failure result produced by that stop.
        // Aggregate busy also includes ordinary cartridge scans. A cancel
        // outside restore must not claim those scans as a restore transaction.
        state <= state == ST_LOCKED ? ST_LOCKED :
                 work_state || transaction_busy ? ST_ABORTING : ST_LOCKED;
        hold_timer <= 0;
        hold_progress <= 0;
        release_ready <= 0;
        press_pending <= 0;
        entry_abandoned <= 1;
    end else begin
        case (state)
            ST_LOCKED, ST_DONE, ST_FAILED: begin
                hold_timer <= 0;
                hold_progress <= 0;
                press_pending <= 0;
                if (released) begin
                    release_ready <= 1;
                end else if (!available || transaction_busy || raw_keys != KEY_SELECT) begin
                    release_ready <= 0;
                end else if (release_ready && accepted_key && stable_keys == KEY_SELECT) begin
                    state <= ST_ENTRY_HOLD;
                    entry_return_state <= state;
                    entry_abandoned <= 0;
                    release_ready <= 0;
                end
            end

            ST_ENTRY_HOLD: begin
                if (entry_abandoned || !available || transaction_busy ||
                    raw_keys != KEY_SELECT || !accepted_key) begin
                    entry_abandoned <= 1;
                    hold_timer <= 0;
                    hold_progress <= 0;
                    // Retain the overlay while any button from the abandoned
                    // gesture is down. A short retry returns to its result.
                    if (released) begin
                        state <= entry_return_state;
                        release_ready <= 0;
                    end
                end else if (hold_timer >= ENTRY_LIMIT - 1) begin
                    state <= ST_READY;
                    hold_timer <= 0;
                    hold_progress <= 3;
                    release_ready <= 0;
                    press_pending <= 0;
                end else begin
                    hold_timer <= hold_timer + 1'b1;
                    if (hold_timer >= ENTRY_THIRD * 2 - 1) hold_progress <= 2;
                    else if (hold_timer >= ENTRY_THIRD - 1) hold_progress <= 1;
                end
            end

            ST_READY: begin
                // READY is latched. Incompatible inputs or temporarily lost
                // availability clear intent, never expose ordinary controls.
                if (!available || transaction_busy ||
                    (raw_keys != 0 && raw_keys != KEY_A)) begin
                    press_pending <= 0;
                    release_ready <= 0;
                    hold_progress <= 0;
                end else if (released) begin
                    hold_progress <= 0;
                    release_ready <= 1;
                    if (press_pending) begin
                        state <= ST_PREFLIGHT;
                        preflight_pulse <= 1;
                        preflight_armed <= !preflight_done;
                        press_pending <= 0;
                        release_ready <= 0;
                    end
                end else if (release_ready && accepted_key && stable_keys == KEY_A) begin
                    press_pending <= 1;
                    release_ready <= 0;
                end
            end

            ST_PREFLIGHT: begin
                hold_progress <= 0;
                if (!preflight_done) preflight_armed <= 1;
                if (preflight_armed && preflight_done) begin
                    state <= preflight_ok ? ST_CONFIRM_HOLD : ST_FAILED;
                    hold_timer <= 0;
                    hold_progress <= 0;
                    release_ready <= 0;
                    press_pending <= 0;
                end
            end

            ST_CONFIRM_HOLD: begin
                // Completion does not inherit any button held during work.
                // A complete new release is required before the final hold.
                if (raw_keys != 0 && raw_keys != KEY_A) begin
                    hold_timer <= 0;
                    hold_progress <= 0;
                    release_ready <= 0;
                    press_pending <= 0;
                end else if (released) begin
                    hold_timer <= 0;
                    hold_progress <= 0;
                    release_ready <= 1;
                    press_pending <= 0;
                end else if (raw_keys != KEY_A || !accepted_key) begin
                    hold_timer <= 0;
                    hold_progress <= 0;
                    press_pending <= 0;
                end else if (press_pending || release_ready) begin
                    release_ready <= 0;
                    press_pending <= 1;
                    if (hold_timer >= HOLD_LIMIT - 1) begin
                        state <= ST_RUN;
                        write_pulse <= 1;
                        operation_armed <= !operation_done;
                        hold_timer <= 0;
                        hold_progress <= 3;
                        press_pending <= 0;
                    end else begin
                        hold_timer <= hold_timer + 1'b1;
                        if (hold_timer >= HOLD_THIRD * 2 - 1) hold_progress <= 2;
                        else if (hold_timer >= HOLD_THIRD - 1) hold_progress <= 1;
                    end
                end
            end

            ST_RUN: begin
                if (!operation_done) operation_armed <= 1;
                // failed is a result qualifier, never a cleanup acknowledgment.
                if (operation_armed && operation_done) begin
                    state <= operation_failed ? ST_FAILED : ST_DONE;
                    hold_progress <= 0;
                    release_ready <= 0;
                end
            end

            ST_ABORTING: begin
                hold_timer <= 0;
                hold_progress <= 0;
                release_ready <= 0;
                press_pending <= 0;
                // Probes can be canceled before an engine starts, so they
                // have no engine completion pulse. Aggregate ownership is the
                // authoritative proof that both probe and engine have drained.
                if (!transaction_busy)
                    state <= ST_FAILED;
            end

            default: begin
                state <= transaction_busy ? ST_ABORTING : ST_LOCKED;
                hold_progress <= 0;
                release_ready <= 0;
                press_pending <= 0;
            end
        endcase
    end
end

endmodule
`default_nettype wire
