`default_nettype none

//
// gb_cart_bus.sv - Game Boy and Game Boy Color cartridge bus
//
// Pin meanings are in docs/HARDWARE-NOTES.md section 5, verified against
// budude2's GBC core. Probe order and why GB is probed first is section 5a.
//
//   pins 6-21   A0-A15, always driven by this side
//   pins 22-29  D0-D7, bidirectional
//   pin 5       /CS, SRAM select only. NOT a ROM select
//   pin 4       /RD
//   pin 3       /WR
//   pin 2       PHI, 1.048576 MHz
//   pin 30      /RESET, held high while running
//
// /CS is derived from the address here rather than taken from the caller.
// 0xA000-0xBFFF asserts it; nothing else does.
//
// Writes to 0x0000-0x7FFF are mapper register writes and are legal. This is
// the opposite of the GBA bus, where a write below the save window is
// suppressed. A GB cartridge cannot be banked without them.
//
// Timing is conservative: one transaction is about 800 ns, close to a real
// Game Boy machine cycle at 1.048576 MHz. The parameters are counts of
// clk_sys cycles at 9.934 ns.
//

module gb_cart_bus #(
    parameter integer ADDR_SETUP_CYCLES = 20,   // address stable before a strobe
    parameter integer STROBE_CYCLES     = 40,   // /RD or /WR low
    parameter integer HOLD_CYCLES       = 20,   // after the strobe rises
    parameter integer PHI_HALF_CYCLES   = 48    // clk_sys 100.663296 MHz / 96
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        gb_mode,       // low releases everything

    input  wire        req,           // sampled in idle only
    input  wire        wr,
    input  wire [15:0] addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,
    output reg         done,
    output wire        busy,

    // Engine interface to cart_pins. This module names no pin.
    output wire [15:0] e_ad_out,
    output wire        e_ad_oe,
    output wire [7:0]  e_hi_out,
    output wire        e_hi_oe,
    output wire [3:0]  e_ctl_out,     // {PHI, WR_n, RD_n, CS_n}
    output wire        e_p30_out,
    output wire        e_p30_oe,
    input  wire [15:0] e_ad_in,
    input  wire [7:0]  e_hi_in
);

localparam [2:0] ST_IDLE   = 3'd0;
localparam [2:0] ST_SETUP  = 3'd1;
localparam [2:0] ST_STROBE = 3'd2;
localparam [2:0] ST_HOLD   = 3'd3;
localparam [2:0] ST_DONE   = 3'd4;

localparam [7:0] SETUP_COUNT  = ADDR_SETUP_CYCLES % 256;
localparam [7:0] STROBE_COUNT = STROBE_CYCLES     % 256;
localparam [7:0] HOLD_COUNT   = HOLD_CYCLES       % 256;

reg [2:0]  state;
reg [7:0]  wait_count;
reg [15:0] latched_addr;
reg [7:0]  latched_wdata;
reg        latched_wr;

reg        rd_n;
reg        wr_n;
reg        addr_drive;
reg        data_drive;

// One cycle of deafness after done, so a requester that waits for done before
// dropping req cannot be given a second transaction. gba_cart_bus has that
// hazard; see docs/STATUS.md.
reg        refuse;

// 0xA000-0xBFFF, the cartridge RAM window.
wire cs_active = (latched_addr[15:13] == 3'b101);

// High for the whole of a transaction, and the reason it matters is not
// arbitration.
//
// e_ctl_out and e_hi_oe are both gated by gb_mode combinationally, so the
// instant the mode goes away /WR rises and the data pins release together.
// That is the edge a cartridge latches a mapper register on, and releasing
// the data on it is how a write gets corrupted. The strobe cannot defend
// itself: cart_pins owns the pins and honours the mode immediately.
//
// So whoever changes the mode must wait for this to fall first. dump_engine
// does, including on an abort, where the reader is reset but the transaction
// it left in flight still finishes on its own, because req is only sampled
// in ST_IDLE.
assign busy = state != ST_IDLE;

// ---- PHI ------------------------------------------------------------------
// clk_sys is 100.663296 MHz, which is exactly 96 x 1048576, so a divide by 96
// gives the Game Boy cartridge clock with no error.

reg [7:0] phi_count;
reg       phi;

always @(posedge clk) begin
    if (reset || !gb_mode) begin
        phi_count <= 8'd0;
        phi       <= 1'b0;
    end else if (phi_count == PHI_HALF_CYCLES[7:0] - 8'd1) begin
        phi_count <= 8'd0;
        phi       <= ~phi;
    end else begin
        phi_count <= phi_count + 8'd1;
    end
end

// ---- Pins -----------------------------------------------------------------

assign e_ad_out  = latched_addr;
assign e_ad_oe   = gb_mode & addr_drive;

assign e_hi_out  = latched_wdata;
assign e_hi_oe   = gb_mode & data_drive;

assign e_ctl_out = gb_mode ? {phi, wr_n, rd_n, ~(cs_active & busy)} : 4'hF;

// /RESET high is the cartridge running. Driven only in GB mode; released
// otherwise so the idle state in cart_pins applies.
assign e_p30_out = 1'b1;
assign e_p30_oe  = gb_mode;

// ---- Sequencer ------------------------------------------------------------

always @(posedge clk) begin
    done <= 1'b0;

    if (reset || !gb_mode) begin
        state         <= ST_IDLE;
        wait_count    <= 8'd0;
        latched_addr  <= 16'd0;
        latched_wdata <= 8'd0;
        latched_wr    <= 1'b0;
        rdata         <= 8'd0;
        rd_n          <= 1'b1;
        wr_n          <= 1'b1;
        addr_drive    <= 1'b0;
        data_drive    <= 1'b0;
        refuse        <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                rd_n       <= 1'b1;
                wr_n       <= 1'b1;
                addr_drive <= 1'b0;
                data_drive <= 1'b0;
                refuse     <= 1'b0;
                if (req && !refuse) begin
                    latched_addr  <= addr;
                    latched_wdata <= wdata;
                    latched_wr    <= wr;
                    addr_drive    <= 1'b1;
                    // Write data goes out with the address, so it is stable
                    // for the whole of the strobe.
                    data_drive    <= wr;
                    wait_count    <= SETUP_COUNT;
                    state         <= ST_SETUP;
                end
            end

            ST_SETUP: begin
                if (wait_count == 8'd0) begin
                    if (latched_wr) wr_n <= 1'b0;
                    else            rd_n <= 1'b0;
                    wait_count <= STROBE_COUNT;
                    state      <= ST_STROBE;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_STROBE: begin
                // Sample one cycle before the strobe rises, while the
                // cartridge is still driving.
                if (wait_count == 8'd1 && !latched_wr)
                    rdata <= e_hi_in;

                if (wait_count == 8'd0) begin
                    rd_n       <= 1'b1;
                    wr_n       <= 1'b1;
                    wait_count <= HOLD_COUNT;
                    state      <= ST_HOLD;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_HOLD: begin
                // Address and write data are held for the whole of this
                // state, so /WR has already risen before either is released.
                // A cartridge latches on the rising edge of /WR.
                if (wait_count == 8'd0) begin
                    addr_drive <= 1'b0;
                    data_drive <= 1'b0;
                    state      <= ST_DONE;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_DONE: begin
                done   <= 1'b1;
                refuse <= 1'b1;
                state  <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
