`default_nettype none

//
// cart_identify_gb.sv - read and validate a Game Boy cartridge header
//
// Reads 0x0134 to 0x014D, 26 bytes, twice.
//
//   0x0134-0x0142  title, 15 bytes. On CGB cartridges the last four are a
//                  manufacturer code, which is not separated here
//   0x0143         CGB flag. 0x80 enhanced, 0xC0 CGB only
//   0x0144-0x0145  new licensee
//   0x0146         SGB flag
//   0x0147         cartridge type, which is the mapper and its features
//   0x0148         ROM size, 32 KiB << n
//   0x0149         RAM size code
//   0x014A         destination
//   0x014B         old licensee
//   0x014C         version
//   0x014D         header checksum
//
// The checksum covers 0x0134 to 0x014C:
//
//   x = 0; for each byte: x = x - byte - 1
//
// The Nintendo logo at 0x0104-0x0133 is not checked, for the same reason the
// GBA logo is not: it needs 48 bytes of known-good data compiled in, and
// getting them wrong rejects good cartridges invisibly.
//
// Judgements are the same three as the GBA reader: present, stable, valid.
// Kept apart in the result because they fail for different reasons.
//

module cart_identify_gb (
    input  wire        clk,
    input  wire        reset,
    input  wire        gb_mode,        // the bus is in GB mode and settled

    input  wire        start,
    output reg         busy,
    output reg         done,

    // Bus master port, matching gb_cart_bus.
    output reg         cart_req,
    output wire        cart_wr,
    output reg  [15:0] cart_addr,
    output wire [7:0]  cart_wdata,
    input  wire [7:0]  cart_rdata,
    input  wire        cart_done,
    input  wire        cart_busy,

    output reg  [2:0]  result,
    output reg  [119:0] title,         // 0x134..0x142, first byte in the high bits
    output reg  [7:0]  cgb_flag,
    output reg  [7:0]  cart_type,
    output reg  [7:0]  rom_size_code,
    output reg  [7:0]  ram_size_code,
    output reg  [7:0]  sw_version,
    output reg         checksum_ok,

    output wire [207:0] raw_bytes,     // all 26, byte i at [8*i +: 8]
    output reg  [7:0]   checksum_read,
    output wire [7:0]   checksum_calc
);

localparam [2:0] RESULT_GB       = 3'd0;
localparam [2:0] RESULT_NO_CART  = 3'd1;
localparam [2:0] RESULT_UNSTABLE = 3'd2;
localparam [2:0] RESULT_NOT_GB   = 3'd3;
localparam [2:0] RESULT_NO_POWER = 3'd4;

localparam [15:0] HEADER_BASE = 16'h0134;
localparam integer BYTES = 26;

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_REQ   = 3'd1;
localparam [2:0] ST_WAIT  = 3'd2;
localparam [2:0] ST_NEXT  = 3'd3;
localparam [2:0] ST_JUDGE = 3'd4;
localparam [2:0] ST_DONE  = 3'd5;

reg [2:0] state;
reg [4:0] idx;            // 0..25
reg       pass;

reg [7:0] hdr [0:BYTES-1];

assign cart_wr    = 1'b0;
assign cart_wdata = 8'd0;

genvar gi;
generate
    for (gi = 0; gi < BYTES; gi = gi + 1) begin : g_raw
        assign raw_bytes[8*gi +: 8] = hdr[gi];
    end
endgenerate

// Accumulated as the bytes arrive. A 25 term adder chain evaluated every
// cycle became the critical path when the GBA reader did it that way.
reg       all_zero;
reg       all_ones;
reg       same;
reg [7:0] sum;

assign checksum_calc = sum;

wire hdr_check_ok = (hdr[25] == sum);

always @(posedge clk) begin
    done <= 1'b0;

    if (reset) begin
        state         <= ST_IDLE;
        busy          <= 1'b0;
        cart_req      <= 1'b0;
        cart_addr     <= 16'd0;
        idx           <= 5'd0;
        pass          <= 1'b0;
        result        <= RESULT_NO_CART;
        title         <= 120'd0;
        cgb_flag      <= 8'd0;
        cart_type     <= 8'd0;
        rom_size_code <= 8'd0;
        ram_size_code <= 8'd0;
        sw_version    <= 8'd0;
        checksum_ok   <= 1'b0;
        checksum_read <= 8'd0;
        all_zero      <= 1'b1;
        all_ones      <= 1'b1;
        same          <= 1'b1;
        sum           <= 8'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                cart_req <= 1'b0;
                if (start) begin
                    if (!gb_mode) begin
                        result <= RESULT_NO_POWER;
                        busy   <= 1'b1;
                        state  <= ST_DONE;
                    end else begin
                        busy     <= 1'b1;
                        idx      <= 5'd0;
                        pass     <= 1'b0;
                        all_zero <= 1'b1;
                        all_ones <= 1'b1;
                        same     <= 1'b1;
                        sum      <= 8'd0;
                        state    <= ST_REQ;
                    end
                end
            end

            ST_REQ: begin
                cart_addr <= HEADER_BASE + {11'd0, idx};
                if (!cart_busy) begin
                    cart_req <= 1'b1;
                    state    <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                cart_req <= 1'b0;
                if (cart_done) begin
                    if (pass) begin
                        if (cart_rdata != hdr[idx]) same <= 1'b0;
                    end else begin
                        hdr[idx] <= cart_rdata;
                        if (cart_rdata != 8'h00) all_zero <= 1'b0;
                        if (cart_rdata != 8'hFF) all_ones <= 1'b0;
                        // 0x0134..0x014C, which is index 0 to 24.
                        if (idx < 5'd25)
                            sum <= sum - cart_rdata - 8'd1;
                    end
                    state <= ST_NEXT;
                end
            end

            ST_NEXT: begin
                if (idx == BYTES - 1) begin
                    idx <= 5'd0;
                    if (pass) begin
                        state <= ST_JUDGE;
                    end else begin
                        pass  <= 1'b1;
                        state <= ST_REQ;
                    end
                end else begin
                    idx   <= idx + 5'd1;
                    state <= ST_REQ;
                end
            end

            ST_JUDGE: begin
                title <= {hdr[0],  hdr[1],  hdr[2],  hdr[3],  hdr[4],
                          hdr[5],  hdr[6],  hdr[7],  hdr[8],  hdr[9],
                          hdr[10], hdr[11], hdr[12], hdr[13], hdr[14]};
                cgb_flag      <= hdr[15];
                cart_type     <= hdr[19];
                rom_size_code <= hdr[20];
                ram_size_code <= hdr[21];
                sw_version    <= hdr[24];
                checksum_read <= hdr[25];
                checksum_ok   <= hdr_check_ok;

                if (all_zero || all_ones)
                    result <= RESULT_NO_CART;
                else if (!same)
                    result <= RESULT_UNSTABLE;
                else if (hdr_check_ok)
                    result <= RESULT_GB;
                else
                    result <= RESULT_NOT_GB;

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
