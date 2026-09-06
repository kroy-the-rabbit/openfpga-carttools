// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

// The initial restore writer supports one physical save organization:
// MBC1 + RAM + battery (03), with one 8 KiB RAM bank (02). Identification,
// immutable source staging, the recovery backup, and confirmation belong to
// the caller. authorized must represent all of those checks, and remain high
// throughout the operation. No title or particular save content is assumed.
//
// Requests remain revocable until gb_cart_bus accepts them. An accepted byte
// finishes before cancellation closes the RAM gate and restores MBC1 mode 0.
// reset during a powered operation follows that same cleanup path. The caller
// must keep gb_cart_bus out of reset and hold GB mode until bus_busy falls;
// resetting that bus during /WR low cannot preserve its data hold interval.
// A real power loss releases ownership and reports failure without attempting
// cleanup writes to an unpowered cartridge.
//
// done means the writer terminated. failed distinguishes completion of all
// bytes from refusal or cancellation. The caller must independently read back
// the save before reporting a successful restore to the user.
module cart_restore_gb (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire        abort,
    input  wire        cart_powered,
    input  wire [7:0]  cart_type,
    input  wire [7:0]  ram_size_code,
    input  wire        authorized,

    output wire        supported,
    output reg         busy,
    output reg         done,
    output reg         failed,

    // The source must stay immutable for the operation. Offset is presented
    // for a complete clock before data is captured, permitting synchronous RAM.
    output reg  [12:0] source_offset,
    input  wire [7:0]  source_data,

    output wire        bus_req,
    output reg         bus_wr,
    output reg  [15:0] bus_addr,
    output reg  [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

assign supported = (cart_type == 8'h03) && (ram_size_code == 8'h02);

localparam [3:0] ST_DISABLE_INITIAL = 4'd0;
localparam [3:0] ST_MODE_INITIAL    = 4'd1;
localparam [3:0] ST_BANK_INITIAL    = 4'd2;
localparam [3:0] ST_ENABLE          = 4'd3;
localparam [3:0] ST_SOURCE_WAIT     = 4'd4;
localparam [3:0] ST_SOURCE_CAPTURE  = 4'd5;
localparam [3:0] ST_WRITE           = 4'd6;
localparam [3:0] ST_ACCEPT          = 4'd7;
localparam [3:0] ST_WAIT            = 4'd8;
localparam [3:0] ST_DISABLE_FINAL   = 4'd9;
localparam [3:0] ST_MODE_FINAL      = 4'd10;
localparam [3:0] ST_DONE            = 4'd11;

reg [3:0] state;
reg [3:0] after_transfer;
reg [7:0] source_byte;
reg       pending;
reg       cleanup;
reg       data_transfer;
reg       cancelled;
reg       all_written;

wire cancel_now = abort || reset || !authorized || !supported;
wire cancel_run = cancelled || cancel_now;
wire bus_available = !bus_busy && !bus_done;

// Mapper cleanup is required after cancellation and does not authorize a
// further save write. A queued data request loses permission immediately.
assign bus_req = busy && cart_powered && pending && bus_available &&
                 (cleanup || !cancel_run);

// Every address and payload is registered before req can rise and held until
// bus completion. None of the source RAM signals feed cartridge pins directly.
task queue_write(
    input [15:0] address,
    input [7:0] payload,
    input [3:0] continuation,
    input is_data
);
    begin
        bus_wr         <= 1'b1;
        bus_addr       <= address;
        bus_wdata      <= payload;
        after_transfer <= continuation;
        data_transfer  <= is_data;
        pending        <= 1'b1;
        state          <= ST_ACCEPT;
    end
endtask

always @(posedge clk) begin
    done <= 1'b0;

    // This ordering also initializes normally on the first reset clock, when
    // busy has not yet been assigned. A powered run always drains and cleans
    // up, even when reset is held high for more than one clock.
    if (busy && cart_powered) begin
        if (cancel_now) begin
            cancelled <= 1'b1;
            failed    <= 1'b1;
        end

        if (cancel_run && !cleanup &&
            (state != ST_ACCEPT) && (state != ST_WAIT)) begin
            pending <= 1'b0;
            cleanup <= 1'b1;
            state   <= ST_DISABLE_FINAL;
        end else begin
            case (state)
                ST_DISABLE_INITIAL: begin
                    if (bus_available)
                        queue_write(16'h0000, 8'h00, ST_MODE_INITIAL, 1'b0);
                end
                ST_MODE_INITIAL: begin
                    if (bus_available)
                        queue_write(16'h6000, 8'h00, ST_BANK_INITIAL, 1'b0);
                end
                ST_BANK_INITIAL: begin
                    if (bus_available)
                        queue_write(16'h4000, 8'h00, ST_ENABLE, 1'b0);
                end
                ST_ENABLE: begin
                    if (bus_available)
                        queue_write(16'h0000, 8'h0A, ST_SOURCE_WAIT, 1'b0);
                end
                ST_SOURCE_WAIT: state <= ST_SOURCE_CAPTURE;
                ST_SOURCE_CAPTURE: begin
                    source_byte <= source_data;
                    state       <= ST_WRITE;
                end
                ST_WRITE: begin
                    if (bus_available)
                        queue_write({3'b101, source_offset}, source_byte,
                                    (source_offset == 13'd8191) ?
                                        ST_DISABLE_FINAL : ST_SOURCE_WAIT,
                                    1'b1);
                end
                ST_ACCEPT: begin
                    if (bus_req) begin
                        pending <= 1'b0;
                        state   <= ST_WAIT;
                    end else if (cancel_run && !cleanup) begin
                        pending <= 1'b0;
                        cleanup <= 1'b1;
                        state   <= ST_DISABLE_FINAL;
                    end
                end
                ST_WAIT: begin
                    if (bus_done) begin
                        if (data_transfer) begin
                            if (source_offset == 13'd8191)
                                all_written <= 1'b1;
                            else
                                source_offset <= source_offset + 13'd1;
                        end
                        if (cancel_run && !cleanup) begin
                            cleanup <= 1'b1;
                            state   <= ST_DISABLE_FINAL;
                        end else begin
                            state <= after_transfer;
                            if (after_transfer == ST_DISABLE_FINAL)
                                cleanup <= 1'b1;
                        end
                    end
                end
                ST_DISABLE_FINAL: begin
                    cleanup <= 1'b1;
                    if (bus_available)
                        queue_write(16'h0000, 8'h00, ST_MODE_FINAL, 1'b0);
                end
                ST_MODE_FINAL: begin
                    if (bus_available)
                        queue_write(16'h6000, 8'h00, ST_DONE, 1'b0);
                end
                ST_DONE: begin
                    pending <= 1'b0;
                    bus_wr  <= 1'b0;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    failed  <= cancel_run || !all_written;
                end
                default: begin
                    pending   <= 1'b0;
                    cancelled <= 1'b1;
                    failed    <= 1'b1;
                    cleanup   <= 1'b1;
                    state     <= ST_DISABLE_FINAL;
                end
            endcase
        end
    end else if (reset) begin
        busy           <= 1'b0;
        done           <= 1'b0;
        failed         <= 1'b0;
        source_offset  <= 13'd0;
        source_byte    <= 8'd0;
        bus_wr         <= 1'b0;
        bus_addr       <= 16'd0;
        bus_wdata      <= 8'd0;
        state          <= ST_DISABLE_INITIAL;
        after_transfer <= ST_DONE;
        pending        <= 1'b0;
        cleanup        <= 1'b0;
        data_transfer  <= 1'b0;
        cancelled      <= 1'b0;
        all_written    <= 1'b0;
    end else if (busy) begin
        // Power was lost. The pin owner must release the cartridge immediately.
        pending   <= 1'b0;
        busy      <= 1'b0;
        done      <= 1'b1;
        failed    <= 1'b1;
        cancelled <= 1'b1;
    end else if (start) begin
        failed <= 1'b0;
        if (supported && cart_powered && authorized && !abort && bus_available) begin
            busy          <= 1'b1;
            source_offset <= 13'd0;
            cancelled     <= 1'b0;
            all_written   <= 1'b0;
            pending       <= 1'b0;
            cleanup       <= 1'b0;
            data_transfer <= 1'b0;
            state         <= ST_DISABLE_INITIAL;
        end else begin
            done   <= 1'b1;
            failed <= 1'b1;
        end
    end
end

// bus_rdata is intentionally unused: readback verification is a separate pass.
endmodule

`default_nettype wire
