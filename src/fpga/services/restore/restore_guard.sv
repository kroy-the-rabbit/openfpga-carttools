// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deliberate, one-use UI authorization for a separately guarded restore engine.
// Inputs are synchronized button levels. Affirmative steps require a stable
// single button and a complete release; raw conflicting buttons cancel them.
// RUN authorization is revoked immediately by cancel/B. The caller then stops
// safely and acknowledges completion before ABORTING releases ownership.

`default_nettype none

module restore_guard #(
    parameter [31:0] DEBOUNCE_CYCLES = 32'd2013266,
    parameter [31:0] UNLOCK_CYCLES   = 32'd1006632960,
    parameter [31:0] CONFIRM_CYCLES  = 32'd3019898880,
    parameter [31:0] HOLD_CYCLES     = 32'd301989888
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
    output reg  [2:0] unlock_count,
    output wire       authorized
);

localparam [3:0] ST_LOCKED       = 4'd0;
localparam [3:0] ST_UNLOCK       = 4'd1;
localparam [3:0] ST_READY        = 4'd2;
localparam [3:0] ST_PREFLIGHT    = 4'd3;
localparam [3:0] ST_CONFIRM_Y    = 4'd4;
localparam [3:0] ST_CONFIRM_X    = 4'd5;
localparam [3:0] ST_CONFIRM_HOLD = 4'd6;
localparam [3:0] ST_RUN          = 4'd7;
localparam [3:0] ST_DONE         = 4'd8;
localparam [3:0] ST_FAILED       = 4'd9;
localparam [3:0] ST_ABORTING     = 4'd10;

localparam [4:0] KEY_SELECT = 5'b10000;
localparam [4:0] KEY_X      = 5'b01000;
localparam [4:0] KEY_Y      = 5'b00100;
localparam [4:0] KEY_A      = 5'b00010;

wire [4:0] raw_keys = {key_select, key_x, key_y, key_a, key_b};
reg  [4:0] stable_keys;
reg  [4:0] candidate_keys;
reg [31:0] debounce_count;
reg [31:0] unlock_timer;
reg [31:0] confirm_timer;
reg [31:0] hold_timer;
reg        release_ready;
reg        press_pending;
reg        preflight_armed;
reg        operation_armed;
reg        preflight_pulse;
reg        write_pulse;

wire released = (raw_keys == 5'b0) && (stable_keys == 5'b0);
wire accepted_key = (raw_keys == stable_keys);
wire terminal_state = state == ST_LOCKED || state == ST_DONE || state == ST_FAILED;
wire confirm_state = state == ST_READY || state == ST_CONFIRM_Y ||
                     state == ST_CONFIRM_X || state == ST_CONFIRM_HOLD;
wire [4:0] expected_key = (state == ST_CONFIRM_Y) ? KEY_Y : KEY_X;

assign active = !terminal_state;
assign busy = state == ST_PREFLIGHT || state == ST_RUN || state == ST_ABORTING;
assign unlocked = state == ST_READY || state == ST_PREFLIGHT ||
                  state == ST_CONFIRM_Y || state == ST_CONFIRM_X ||
                  state == ST_CONFIRM_HOLD || state == ST_RUN;
assign authorized = state == ST_RUN && !reset && !cancel && !key_b;
assign preflight_start = preflight_pulse && !reset && !cancel && !key_b;
assign write_start = write_pulse && authorized;

// Debounce the entire key vector, so a chord cannot be accepted as two
// independent affirmative presses. Cancellation itself is not delayed.
always @(posedge clk) begin
    if (reset) begin
        stable_keys    <= 5'b0;
        candidate_keys <= 5'b0;
        debounce_count <= 32'd0;
    end else if (raw_keys == stable_keys) begin
        candidate_keys <= raw_keys;
        debounce_count <= 32'd0;
    end else if (DEBOUNCE_CYCLES <= 32'd1) begin
        stable_keys    <= raw_keys;
        candidate_keys <= raw_keys;
        debounce_count <= 32'd0;
    end else if (raw_keys != candidate_keys) begin
        candidate_keys <= raw_keys;
        debounce_count <= 32'd1;
    end else if (debounce_count >= DEBOUNCE_CYCLES - 32'd1) begin
        stable_keys    <= raw_keys;
        debounce_count <= 32'd0;
    end else begin
        debounce_count <= debounce_count + 32'd1;
    end
end

always @(posedge clk) begin
    preflight_pulse <= 1'b0;
    write_pulse     <= 1'b0;

    if (reset) begin
        state            <= ST_LOCKED;
        unlock_count     <= 3'd0;
        unlock_timer     <= 32'd0;
        confirm_timer    <= 32'd0;
        hold_timer       <= 32'd0;
        release_ready    <= 1'b0;
        press_pending    <= 1'b0;
        preflight_armed  <= 1'b0;
        operation_armed  <= 1'b0;
    end else if (cancel || key_b) begin
        unlock_count  <= 3'd0;
        unlock_timer  <= 32'd0;
        confirm_timer <= 32'd0;
        hold_timer    <= 32'd0;
        release_ready <= 1'b0;
        press_pending <= 1'b0;
        if (state == ST_RUN || state == ST_ABORTING) begin
            if (!operation_done && !operation_failed)
                operation_armed <= 1'b1;
            if (operation_armed && (operation_done || operation_failed))
                state <= ST_FAILED;
            else
                state <= ST_ABORTING;
        end else begin
            state <= ST_LOCKED;
        end
    end else if (confirm_state && confirm_timer >= CONFIRM_CYCLES - 32'd1) begin
        state         <= ST_LOCKED;
        unlock_count  <= 3'd0;
        release_ready <= 1'b0;
        press_pending <= 1'b0;
        hold_timer    <= 32'd0;
    end else begin
        if (confirm_state)
            confirm_timer <= confirm_timer + 32'd1;

        case (state)
            ST_LOCKED, ST_DONE, ST_FAILED: begin
                unlock_count  <= 3'd0;
                unlock_timer  <= 32'd0;
                confirm_timer <= 32'd0;
                hold_timer    <= 32'd0;
                press_pending <= 1'b0;
                if (!available || (raw_keys != 5'b0 && raw_keys != KEY_SELECT))
                    release_ready <= 1'b0;
                else if (released)
                    release_ready <= 1'b1;
                else if (release_ready && accepted_key && stable_keys == KEY_SELECT) begin
                    state         <= ST_UNLOCK;
                    press_pending <= 1'b1;
                    release_ready <= 1'b0;
                end
            end

            ST_UNLOCK: begin
                unlock_timer <= unlock_timer + 32'd1;
                if (!available || unlock_timer >= UNLOCK_CYCLES - 32'd1 ||
                    (raw_keys != 5'b0 && raw_keys != KEY_SELECT)) begin
                    state         <= ST_LOCKED;
                    unlock_count  <= 3'd0;
                    release_ready <= 1'b0;
                    press_pending <= 1'b0;
                end else if (released) begin
                    release_ready <= 1'b1;
                    if (press_pending) begin
                        press_pending <= 1'b0;
                        unlock_count  <= unlock_count + 3'd1;
                        if (unlock_count == 3'd4) begin
                            state         <= ST_READY;
                            confirm_timer <= 32'd0;
                            release_ready <= 1'b0;
                        end
                    end
                end else if (release_ready && accepted_key && stable_keys == KEY_SELECT) begin
                    press_pending <= 1'b1;
                    release_ready <= 1'b0;
                end
            end

            ST_READY, ST_CONFIRM_Y, ST_CONFIRM_X: begin
                if ((state == ST_READY && !available) ||
                    (raw_keys != 5'b0 && raw_keys != expected_key)) begin
                    state         <= ST_LOCKED;
                    unlock_count  <= 3'd0;
                    release_ready <= 1'b0;
                    press_pending <= 1'b0;
                end else if (released) begin
                    release_ready <= 1'b1;
                    if (press_pending) begin
                        press_pending <= 1'b0;
                        release_ready <= 1'b0;
                        if (state == ST_READY) begin
                            state            <= ST_PREFLIGHT;
                            preflight_pulse  <= 1'b1;
                            preflight_armed  <= !preflight_done;
                            confirm_timer    <= 32'd0;
                        end else if (state == ST_CONFIRM_Y) begin
                            state <= ST_CONFIRM_X;
                        end else begin
                            state      <= ST_CONFIRM_HOLD;
                            hold_timer <= 32'd0;
                        end
                    end
                end else if (release_ready && accepted_key && stable_keys == expected_key) begin
                    press_pending <= 1'b1;
                    release_ready <= 1'b0;
                end
            end

            ST_PREFLIGHT: begin
                // Ignore completion held over from an earlier transaction.
                if (!preflight_done)
                    preflight_armed <= 1'b1;
                if (preflight_armed && preflight_done) begin
                    state         <= preflight_ok ? ST_CONFIRM_Y : ST_FAILED;
                    confirm_timer <= 32'd0;
                    release_ready <= 1'b0;
                    press_pending <= 1'b0;
                    if (!preflight_ok)
                        unlock_count <= 3'd0;
                end
            end

            ST_CONFIRM_HOLD: begin
                if (raw_keys != 5'b0 && raw_keys != KEY_A) begin
                    state         <= ST_LOCKED;
                    unlock_count  <= 3'd0;
                    hold_timer    <= 32'd0;
                    release_ready <= 1'b0;
                    press_pending <= 1'b0;
                end else if (released) begin
                    release_ready <= 1'b1;
                    press_pending <= 1'b0;
                    hold_timer    <= 32'd0;
                end else if (raw_keys != KEY_A || !accepted_key) begin
                    // Even a brief release restarts the entire hold period.
                    hold_timer    <= 32'd0;
                    press_pending <= 1'b0;
                end else if (press_pending || release_ready) begin
                    release_ready <= 1'b0;
                    press_pending <= 1'b1;
                    if (hold_timer >= HOLD_CYCLES - 32'd1) begin
                        state           <= ST_RUN;
                        write_pulse     <= 1'b1;
                        operation_armed <= !operation_done && !operation_failed;
                        press_pending   <= 1'b0;
                        hold_timer      <= 32'd0;
                    end else begin
                        hold_timer <= hold_timer + 32'd1;
                    end
                end
            end

            ST_RUN, ST_ABORTING: begin
                if (!operation_done && !operation_failed)
                    operation_armed <= 1'b1;
                if (operation_armed && (operation_done || operation_failed)) begin
                    state <= operation_failed || state == ST_ABORTING ? ST_FAILED : ST_DONE;
                    unlock_count  <= 3'd0;
                    release_ready <= 1'b0;
                end
            end

            default: begin
                state         <= ST_LOCKED;
                unlock_count  <= 3'd0;
                release_ready <= 1'b0;
                press_pending <= 1'b0;
            end
        endcase
    end
end

endmodule

`default_nettype wire
