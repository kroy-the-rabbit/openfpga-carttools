`default_nettype none

module gba_cart_bus #(
    parameter integer ADDR_HOLD_CYCLES = 2,
    parameter integer ADDR_LATCH_CYCLES = 4,
    parameter integer READ_TURNAROUND_CYCLES = 4,
    parameter integer READ_SETUP_CYCLES = 14,
    parameter integer WRITE_SETUP_CYCLES = 12,
    parameter integer WRITE_HOLD_CYCLES = 8
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        cart_mode,

    input  wire        req,
    input  wire        wr,
    input  wire [27:0] addr,
    input  wire [1:0]  acc,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         done,
    output wire        busy,

    // High while a write beat is electrically live: data is on the bus and
    // WR# is about to fall, is low, or has just risen and the data is still
    // being held. A mode teardown that lands in this window cuts the beat,
    // so whoever sequences cart_mode has to wait for this to clear. See the
    // comment on ST_WRITE_ABORT below for the case that cannot be waited on.
    output wire        write_active,

    // Engine interface to cart_pins.sv, which owns the connector pins.
    output wire [15:0] e_ad_out,
    output wire        e_ad_oe,
    output wire [7:0]  e_hi_out,
    output wire        e_hi_oe,
    output wire [3:0]  e_ctl_out,
    output wire        e_p30_out,
    output wire        e_p30_oe,
    input  wire [15:0] e_ad_in,
    input  wire [7:0]  e_hi_in
);

localparam [1:0] ACCESS_8BIT  = 2'b00;
localparam [1:0] ACCESS_16BIT = 2'b01;

localparam [3:0] ST_IDLE       = 4'd0;
localparam [3:0] ST_ADDR_SETUP = 4'd1;
localparam [3:0] ST_ADDR_LATCH = 4'd2;
localparam [3:0] ST_READ_TURN  = 4'd3;
localparam [3:0] ST_READ_SETUP = 4'd4;
localparam [3:0] ST_WRITE      = 4'd5;
localparam [3:0] ST_WRITE_HOLD = 4'd6;
localparam [3:0] ST_DONE       = 4'd7;
localparam [3:0] ST_READ_SEQ   = 4'd8;
localparam [3:0] ST_WRITE_SETUP = 4'd9;
localparam [3:0] ST_WRITE_ABORT = 4'd10;

localparam [7:0] ADDR_HOLD_COUNT   = ADDR_HOLD_CYCLES % 256;
localparam [7:0] ADDR_LATCH_COUNT  = ADDR_LATCH_CYCLES % 256;
localparam [7:0] READ_TURN_COUNT   = READ_TURNAROUND_CYCLES % 256;
localparam [7:0] READ_SETUP_COUNT  = READ_SETUP_CYCLES % 256;
localparam [7:0] WRITE_SETUP_COUNT = WRITE_SETUP_CYCLES % 256;
localparam [7:0] WRITE_HOLD_COUNT  = WRITE_HOLD_CYCLES % 256;

reg [3:0]  state;
reg [7:0]  wait_count;
reg        latched_wr;
reg [27:0] latched_addr;
reg [1:0]  latched_acc;
reg [31:0] latched_wdata;
reg [1:0]  beat;
reg [15:0] first_word;

reg        ad_drive;
reg [15:0] ad_out;
wire [15:0] ad_in = e_ad_in;

reg [7:0]  a_hi_out;
reg        rd_n;
reg        wr_n;
reg        cs1_n;
reg        cs2_n;
reg        eeprom_selected;
reg        eeprom_last_wr;
reg        phi_clk;
reg [2:0]  phi_div;

wire eeprom_space = latched_addr[27:24] == 4'hD;
wire req_eeprom_space = addr[27:24] == 4'hD;
wire eeprom_dir_change = eeprom_selected && req_eeprom_space && (wr != eeprom_last_wr);
wire save_space = latched_addr[27:24] == 4'hE || latched_addr[27:24] == 4'hF;
wire gpio_space = latched_addr[27:24] == 4'h8 &&
                  latched_addr[23:0] >= 24'h0000C4 &&
                  latched_addr[23:0] <= 24'h0000C8;
wire cart_write_enable = latched_wr && (eeprom_space || save_space || gpio_space);
wire wr_n_pin = (state == ST_WRITE && cart_write_enable) ? wr_n : 1'b1;

// ST_WRITE is the only state where releasing the bus can corrupt a
// cartridge, because it is the only one where WR# is low. ST_WRITE_SETUP has
// not pulsed yet and ST_WRITE_HOLD has already raised WR#, so a release in
// either of those is a write that did not happen rather than a wrong one.
wire in_write_pulse = state == ST_WRITE;

assign write_active = latched_wr &&
                      (state == ST_WRITE_SETUP || state == ST_WRITE ||
                       state == ST_WRITE_HOLD  || state == ST_WRITE_ABORT);
wire need_second_beat = latched_acc != ACCESS_8BIT && latched_acc != ACCESS_16BIT;
wire transaction_active = state != ST_IDLE && state != ST_DONE;
wire a_hi_drive = cart_mode && transaction_active && (!save_space || latched_wr);
wire [7:0] save_data_in = e_hi_in;
wire [7:0] a_hi_pin_out = save_space ? latched_wdata[7:0] : a_hi_out;
assign busy = state != ST_IDLE;

wire [15:0] write_word =
    (latched_acc == ACCESS_8BIT)  ? {latched_wdata[7:0], latched_wdata[7:0]} :
    (latched_acc == ACCESS_16BIT) ? latched_wdata[15:0] :
                                    (beat == 2'd0 ? latched_wdata[15:0] : latched_wdata[31:16]);

wire [23:0] rom_word_addr = latched_addr[24:1] + {23'd0, beat[0]};
wire [15:0] addr_word = save_space ? latched_addr[15:0] : rom_word_addr[15:0];
wire [7:0]  addr_high = rom_word_addr[23:16];
wire        rom_page_end = rom_word_addr[15:0] == 16'hFFFF;

assign e_ad_out = ad_out;
assign e_ad_oe  = cart_mode && ad_drive;

assign e_hi_out = a_hi_pin_out;
assign e_hi_oe  = a_hi_drive;

assign e_ctl_out = cart_mode ? {1'b0, wr_n_pin, rd_n, cs1_n} : 4'hf;

assign e_p30_out = cs2_n;
assign e_p30_oe  = cart_mode;

always @(posedge clk) begin
    if (reset || !cart_mode) begin
        phi_div <= 3'd0;
        phi_clk <= 1'b0;
    end else if (phi_div == 3'd2) begin
        phi_div <= 3'd0;
        phi_clk <= ~phi_clk;
    end else begin
        phi_div <= phi_div + 3'd1;
    end
end

// A reset landing inside WR# low is sequenced rather than taken immediately:
// WR# rises on the way into ST_WRITE_ABORT, because wr_n_pin is gated on
// ST_WRITE, and the data stays on the bus for the usual hold before it is
// released. A cartridge latches on the WR# rising edge, so releasing both at
// once hands it whatever the floating bus settles to, at an address this
// module has already selected.
//
// A cart_mode drop is NOT sequenced, and deliberately. cart_mode is
// cart_play & cart_power: when it falls the slot is losing power, and driving
// pins into an unpowered cartridge is worse than a truncated write. The pin
// gates below are combinational on cart_mode for that reason. What can be
// avoided is an internally chosen mode change landing here, which is what
// write_active is for.
wire abort_write_pulse = reset && cart_mode && in_write_pulse;

always @(posedge clk) begin
    done <= 1'b0;

    if (abort_write_pulse) begin
        wait_count <= WRITE_HOLD_COUNT;
        state <= ST_WRITE_ABORT;
    end else if ((reset && state != ST_WRITE_ABORT) || !cart_mode) begin
        state <= ST_IDLE;
        wait_count <= 8'd0;
        latched_wr <= 1'b0;
        latched_addr <= 28'd0;
        latched_acc <= 2'd0;
        latched_wdata <= 32'd0;
        beat <= 2'd0;
        first_word <= 16'd0;
        rdata <= 32'd0;
        ad_drive <= 1'b0;
        ad_out <= 16'hFFFF;
        a_hi_out <= 8'hFF;
        rd_n <= 1'b1;
        wr_n <= 1'b1;
        cs1_n <= 1'b1;
        cs2_n <= 1'b1;
        eeprom_selected <= 1'b0;
        eeprom_last_wr <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                ad_drive <= 1'b0;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                cs1_n <= eeprom_selected ? 1'b0 : 1'b1;
                cs2_n <= 1'b1;
                if (req) begin
                    if (eeprom_selected && (!req_eeprom_space || eeprom_dir_change)) begin
                        eeprom_selected <= 1'b0;
                        cs1_n <= 1'b1;
                    end
                    latched_wr <= wr;
                    latched_addr <= addr;
                    latched_acc <= acc;
                    latched_wdata <= wdata;
                    beat <= 2'd0;
                    wait_count <= ADDR_HOLD_COUNT;
                    state <= ST_ADDR_SETUP;
                end
            end

            ST_ADDR_SETUP: begin
                ad_drive <= 1'b1;
                ad_out <= addr_word;
                a_hi_out <= addr_high;
                cs1_n <= eeprom_space ? 1'b0 : 1'b1;
                cs2_n <= 1'b1;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    wait_count <= ADDR_LATCH_COUNT;
                    state <= ST_ADDR_LATCH;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_ADDR_LATCH: begin
                ad_drive <= 1'b1;
                ad_out <= addr_word;
                a_hi_out <= addr_high;
                cs1_n <= save_space;
                cs2_n <= !save_space;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    if (latched_wr) begin
                        ad_out <= save_space ? addr_word : write_word;
                        wait_count <= WRITE_SETUP_COUNT;
                        state <= ST_WRITE_SETUP;
                    end else begin
                        wait_count <= READ_TURN_COUNT;
                        state <= ST_READ_TURN;
                    end
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_READ_TURN: begin
                // Retail carts latch the multiplexed ROM address during the
                // CS-low/RD-high phase. Keep AD driven until RD asserts, then
                // release it for ROM data.
                ad_drive <= 1'b1;
                ad_out <= addr_word;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    wait_count <= READ_SETUP_COUNT;
                    state <= ST_READ_SETUP;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_READ_SETUP: begin
                ad_drive <= save_space;
                ad_out <= addr_word;
                rd_n <= 1'b0;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    rd_n <= 1'b1;
                    if (save_space) begin
                        rdata <= {save_data_in, save_data_in, save_data_in, save_data_in};
                        state <= ST_DONE;
                    end else if (beat == 2'd0) begin
                        first_word <= ad_in;
                        if (need_second_beat) begin
                            beat <= 2'd1;
                            if (rom_page_end) begin
                                wait_count <= ADDR_HOLD_COUNT;
                                state <= ST_ADDR_SETUP;
                            end else begin
                                wait_count <= READ_TURN_COUNT;
                                state <= ST_READ_SEQ;
                            end
                        end else begin
                            rdata <= {16'd0, ad_in};
                            state <= ST_DONE;
                        end
                    end else begin
                        rdata <= {16'd0, ad_in};
                        if (latched_acc != ACCESS_8BIT && latched_acc != ACCESS_16BIT) begin
                            rdata <= {ad_in, first_word};
                        end
                        state <= ST_DONE;
                    end
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_READ_SEQ: begin
                // Sequential ROM halfword: keep CS low and let the cart
                // advance internally, matching the GBA burst path.
                ad_drive <= 1'b0;
                cs1_n <= 1'b0;
                cs2_n <= 1'b1;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    wait_count <= READ_SETUP_COUNT;
                    state <= ST_READ_SETUP;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_WRITE_SETUP: begin
                // Put write data on AD before WR# falls. EEPROM samples a
                // serial bit on AD0, so data and WR# must not change together.
                ad_drive <= 1'b1;
                ad_out <= save_space ? addr_word : write_word;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                wait_count <= WRITE_SETUP_COUNT;
                state <= ST_WRITE;
            end

            ST_WRITE: begin
                ad_drive <= 1'b1;
                ad_out <= save_space ? addr_word : write_word;
                rd_n <= 1'b1;
                wr_n <= 1'b0;
                if (wait_count == 8'd0) begin
                    wr_n <= 1'b1;
                    wait_count <= WRITE_HOLD_COUNT;
                    state <= ST_WRITE_HOLD;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_WRITE_HOLD: begin
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    if (need_second_beat && beat == 2'd0) begin
                        beat <= 2'd1;
                        wait_count <= ADDR_HOLD_COUNT;
                        state <= ST_ADDR_SETUP;
                    end else begin
                        state <= ST_DONE;
                    end
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            // WR# is already high here: the pin is gated on ST_WRITE. All
            // this state does is keep the data where it was for the hold, so
            // the cartridge sees a normal rising edge with valid data, then
            // let it go.
            ST_WRITE_ABORT: begin
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                if (wait_count == 8'd0) begin
                    ad_drive <= 1'b0;
                    ad_out <= 16'hFFFF;
                    cs1_n <= 1'b1;
                    cs2_n <= 1'b1;
                    eeprom_selected <= 1'b0;
                    state <= ST_IDLE;
                end else begin
                    wait_count <= wait_count - 8'd1;
                end
            end

            ST_DONE: begin
                ad_drive <= 1'b0;
                rd_n <= 1'b1;
                wr_n <= 1'b1;
                cs1_n <= eeprom_space ? 1'b0 : 1'b1;
                cs2_n <= 1'b1;
                if (eeprom_space) begin
                    eeprom_selected <= 1'b1;
                    eeprom_last_wr <= latched_wr;
                end
                done <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
