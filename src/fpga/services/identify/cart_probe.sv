`default_nettype none

//
// cart_probe.sv - decide which system is in the slot
//
// Probe order and the reason for it are in docs/HARDWARE-NOTES.md section 5a.
// GB first. Escalate to GBA only when the GB probe found nothing at all.
//
// A GB probe that found something, whatever it found, must never be followed
// by a GBA probe: GBA mode drives pins 22-29 as an address output and a GB
// cartridge drives its data bus there.
//

module cart_probe #(
    // Cycles to hold a mode after cart_pins reports it ready, before the first
    // read. This is reset-recovery time, not pin turnaround: cart_pins only
    // releases pin 30 (/RES on a Game Boy cartridge) when mode_ready asserts,
    // so without this the cartridge is read in the same cycle it leaves reset.
    // On hardware that made the first identification after launch fail while
    // every rescan succeeded, because a rescan follows a cartridge that was
    // awake moments earlier. 5,000,000 is about 50 ms at clk_sys.
    parameter integer WAKE_CYCLES = 5_000_000
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,
    input  wire        cart_powered,      // APF cart_play & cart_power
    output reg         busy,
    output reg         done,

    // cart_pins
    output reg  [1:0]  mode,
    input  wire        mode_ready,

    // GB identifier
    output reg         gb_start,
    input  wire        gb_done,
    input  wire [2:0]  gb_result,

    // GBA identifier
    output reg         gba_start,
    input  wire        gba_done,
    input  wire [2:0]  gba_result,

    output reg  [2:0]  platform,          // see below

    // Which engine produced the verdict in platform. P_UNKNOWN and P_UNSTABLE
    // can arrive from either, so the platform code alone cannot tell a reader
    // which identifier's buffer holds the bytes that were actually read.
    output reg         answered_gba
);

localparam [1:0] MODE_IDLE = 2'b00;
localparam [1:0] MODE_GBA  = 2'b01;
localparam [1:0] MODE_GB   = 2'b10;

// Identifier result codes, shared by both.
localparam [2:0] R_OK        = 3'd0;
localparam [2:0] R_NO_CART   = 3'd1;
localparam [2:0] R_UNSTABLE  = 3'd2;
localparam [2:0] R_NOT_MINE  = 3'd3;
localparam [2:0] R_NO_POWER  = 3'd4;

// Platform codes reach the user as a line of text. Append, never renumber.
localparam [2:0] P_NONE     = 3'd0;
localparam [2:0] P_GBA      = 3'd1;
localparam [2:0] P_GB       = 3'd2;
localparam [2:0] P_UNKNOWN  = 3'd3;
localparam [2:0] P_UNSTABLE = 3'd4;
localparam [2:0] P_NO_POWER = 3'd5;

localparam [2:0] ST_IDLE      = 3'd0;
localparam [2:0] ST_MODE_HOLD = 3'd1;   // one cycle for cart_pins to see it
localparam [2:0] ST_MODE_WAIT = 3'd2;
localparam [2:0] ST_GB_RUN    = 3'd3;
localparam [2:0] ST_GBA_RUN   = 3'd4;
localparam [2:0] ST_WAKE      = 3'd5;
localparam [2:0] ST_PARK      = 3'd6;
localparam [2:0] ST_DONE      = 3'd7;

reg [2:0] state;
reg [27:0] wake;

// mode_ready is stale in the cycle after mode changes, so it is not sampled
// until ST_MODE_WAIT. Sampling it a cycle earlier reads the previous mode's
// answer and starts a probe against pins that have not turned round.
reg next_is_gba;

always @(posedge clk) begin
    done      <= 1'b0;
    gb_start  <= 1'b0;
    gba_start <= 1'b0;

    if (reset) begin
        state        <= ST_IDLE;
        busy         <= 1'b0;
        mode         <= MODE_IDLE;
        platform     <= P_NONE;
        next_is_gba  <= 1'b0;
        answered_gba <= 1'b0;
        wake         <= 28'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                if (start) begin
                    busy <= 1'b1;
                    if (!cart_powered) begin
                        platform     <= P_NO_POWER;
                        answered_gba <= 1'b0;
                        mode         <= MODE_IDLE;
                        state        <= ST_DONE;
                    end else begin
                        mode        <= MODE_GB;
                        next_is_gba <= 1'b0;
                        state       <= ST_MODE_HOLD;
                    end
                end
            end

            ST_MODE_HOLD: state <= ST_MODE_WAIT;

            ST_MODE_WAIT: begin
                if (mode_ready) begin
                    wake  <= WAKE_CYCLES[27:0];
                    state <= ST_WAKE;
                end
            end

            // The pins now carry the requested mode, so /RES is high and the
            // cartridge is out of reset. Give it time to become responsive
            // before the first strobe.
            ST_WAKE: begin
                if (wake != 28'd0) begin
                    wake <= wake - 28'd1;
                end else if (next_is_gba) begin
                    gba_start    <= 1'b1;
                    answered_gba <= 1'b1;
                    state        <= ST_GBA_RUN;
                end else begin
                    gb_start     <= 1'b1;
                    answered_gba <= 1'b0;
                    state        <= ST_GB_RUN;
                end
            end

            ST_GB_RUN: begin
                if (gb_done) begin
                    case (gb_result)
                        R_OK:       begin platform <= P_GB;       state <= ST_PARK; end
                        R_UNSTABLE: begin platform <= P_UNSTABLE; state <= ST_PARK; end
                        // Something answered, consistently, and it is not a
                        // Game Boy header. Do not escalate: a GBA probe
                        // against a Game Boy cartridge is contention.
                        R_NOT_MINE: begin platform <= P_UNKNOWN;  state <= ST_PARK; end
                        R_NO_POWER: begin platform <= P_NO_POWER; state <= ST_PARK; end
                        // Nothing drove the bus. A GBA cartridge reads this
                        // way in GB mode, so this is the one case that goes on.
                        default: begin
                            mode        <= MODE_GBA;
                            next_is_gba <= 1'b1;
                            state       <= ST_MODE_HOLD;
                        end
                    endcase
                end
            end

            ST_GBA_RUN: begin
                if (gba_done) begin
                    case (gba_result)
                        R_OK:       platform <= P_GBA;
                        R_UNSTABLE: platform <= P_UNSTABLE;
                        R_NOT_MINE: platform <= P_UNKNOWN;
                        R_NO_POWER: platform <= P_NO_POWER;
                        default:    platform <= P_NONE;
                    endcase
                    state <= ST_PARK;
                end
            end

            // Leave the bus idle rather than in whichever mode happened to
            // win. Nothing holds a cartridge selected between operations.
            ST_PARK: begin
                mode  <= MODE_IDLE;
                state <= ST_DONE;
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
