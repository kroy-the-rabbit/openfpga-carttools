// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// cart_dump_gb.sv - read a whole Game Boy or Game Boy Color ROM
//
// Bank 0 is read straight out of 0x0000-0x3FFF. Every other bank is selected
// through the mapper and read out of 0x4000-0x7FFF. The size comes from
// header byte 0x0148, so nothing here guesses: banks = 2 << rom_size_code.
//
// Mapper writes are the only writes this core performs on a cartridge, and
// they are writes to ROM space, which is legal and is the whole mechanism by
// which a GB cartridge is banked. gb_cart_bus permits them deliberately;
// docs/STATUS.md records why that is the opposite of the GBA rule.
//
// Which registers get written, by cartridge type at 0x0147:
//
//   MBC1  0x01-0x03  5-bit bank at 0x2000, 2-bit upper at 0x4000, mode 0
//   MBC2  0x05-0x06  4-bit bank at 0x2100
//   MBC3  0x0F-0x13  7-bit bank at 0x2000
//   MBC5  0x19-0x1E  8-bit bank at 0x2000, bit 8 at 0x3000
//   none  0x00       32 KB, no banking, bank 1 is simply the upper half
//
// KNOWN LIMITATION, and it is a real one for MBC1 cartridges larger than
// 512 KB: MBC1 forces the low 5 bits of the bank register to 1 when they are
// written as 0, so banks 0x20, 0x40 and 0x60 cannot be selected at all. A dump
// of such a cartridge gets banks 0x21, 0x41 and 0x61 in their place. This is
// the mapper's behaviour, not a defect here, and it is why real dumps of large
// MBC1 titles are known to contain those duplicates. Nothing in this module
// can work around it; a note belongs in the sidecar so the hash mismatch is
// explainable rather than mysterious.
//
// Every byte is read once. There is no retry and no verification pass: a dump
// that needs to be trusted must be verified by reading it back, which is a
// separate operation.
//

module cart_dump_gb (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,          // pulse
    input  wire [7:0]  cart_type,      // header 0x0147
    input  wire [7:0]  rom_size_code,  // header 0x0148

    output reg         busy,
    output reg         done,
    output wire [31:0] total_bytes,

    // gb_cart_bus. The handshake rule is that req must be dropped before done
    // arrives or a second transaction is issued; see docs/STATUS.md.
    output reg         bus_req,
    output reg         bus_wr,
    output reg  [15:0] bus_addr,
    output reg  [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,

    // Byte stream out. Held until taken.
    output reg  [7:0]  out_data,
    output reg         out_valid,
    input  wire        out_ready
);

// 0x0148: 0 is 32 KB and every step doubles. Two banks of 16 KB at 0x00.
wire [8:0] bank_count = 9'd2 << rom_size_code[3:0];
assign total_bytes = {bank_count, 14'd0};   // banks * 16384

localparam [7:0] T_ROM_ONLY = 8'h00;

wire is_mbc1 = (cart_type >= 8'h01) && (cart_type <= 8'h03);
wire is_mbc2 = (cart_type >= 8'h05) && (cart_type <= 8'h06);
wire is_mbc3 = (cart_type >= 8'h0F) && (cart_type <= 8'h13);
wire is_mbc5 = (cart_type >= 8'h19) && (cart_type <= 8'h1E);

localparam [3:0] ST_IDLE     = 4'd0;
localparam [3:0] ST_BANK_LO  = 4'd1;
localparam [3:0] ST_BANK_LO_W= 4'd2;
localparam [3:0] ST_BANK_HI  = 4'd3;
localparam [3:0] ST_BANK_HI_W= 4'd4;
localparam [3:0] ST_READ     = 4'd5;
localparam [3:0] ST_READ_W   = 4'd6;
localparam [3:0] ST_EMIT     = 4'd7;
localparam [3:0] ST_NEXT     = 4'd8;
localparam [3:0] ST_DONE     = 4'd9;

reg [3:0]  state;
reg [8:0]  bank;        // bank being read
reg [13:0] offset;      // byte within the bank

// Bank 0 lives at 0x0000, every other bank is windowed at 0x4000.
wire [15:0] read_addr = (bank == 9'd0) ? {2'b00, offset}
                                       : {2'b01, offset};

always @(posedge clk) begin
    done    <= 1'b0;
    bus_req <= 1'b0;

    if (reset) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        bank      <= 9'd0;
        offset    <= 14'd0;
        out_valid <= 1'b0;
        out_data  <= 8'd0;
        bus_wr    <= 1'b0;
        bus_addr  <= 16'd0;
        bus_wdata <= 8'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                busy      <= 1'b0;
                out_valid <= 1'b0;
                if (start) begin
                    busy   <= 1'b1;
                    bank   <= 9'd0;
                    offset <= 14'd0;
                    state  <= ST_READ;
                end
            end

            // Select the bank. Bank 0 needs no write at all, and on a cart
            // with no mapper there is nothing to write to.
            ST_BANK_LO: begin
                if (bank == 9'd0 || cart_type == T_ROM_ONLY) begin
                    state <= ST_READ;
                end else begin
                    bus_wr    <= 1'b1;
                    bus_req   <= 1'b1;
                    if (is_mbc2) begin
                        // MBC2 decodes bit 8 of the address to mean "bank",
                        // so the register is at 0x2100, not 0x2000.
                        bus_addr  <= 16'h2100;
                        bus_wdata <= {4'd0, bank[3:0]};
                    end else if (is_mbc5) begin
                        bus_addr  <= 16'h2000;
                        bus_wdata <= bank[7:0];
                    end else if (is_mbc1) begin
                        bus_addr  <= 16'h2000;
                        bus_wdata <= {3'd0, bank[4:0]};
                    end else begin  // MBC3 and anything else with a bank reg
                        bus_addr  <= 16'h2000;
                        bus_wdata <= {1'b0, bank[6:0]};
                    end
                    state <= ST_BANK_LO_W;
                end
            end

            ST_BANK_LO_W: if (bus_done) state <= ST_BANK_HI;

            // The high bits, where the mapper has them somewhere else.
            ST_BANK_HI: begin
                if (is_mbc5 && bank[8]) begin
                    bus_wr    <= 1'b1;
                    bus_req   <= 1'b1;
                    bus_addr  <= 16'h3000;
                    bus_wdata <= 8'h01;
                    state     <= ST_BANK_HI_W;
                end else if (is_mbc1) begin
                    // Upper two bits, and mode 0 so they extend the ROM bank
                    // rather than selecting a RAM bank.
                    bus_wr    <= 1'b1;
                    bus_req   <= 1'b1;
                    bus_addr  <= 16'h4000;
                    bus_wdata <= {6'd0, bank[6:5]};
                    state     <= ST_BANK_HI_W;
                end else begin
                    state <= ST_READ;
                end
            end

            ST_BANK_HI_W: if (bus_done) state <= ST_READ;

            ST_READ: begin
                bus_wr   <= 1'b0;
                bus_req  <= 1'b1;
                bus_addr <= read_addr;
                state    <= ST_READ_W;
            end

            ST_READ_W: begin
                if (bus_done) begin
                    out_data  <= bus_rdata;
                    out_valid <= 1'b1;
                    state     <= ST_EMIT;
                end
            end

            ST_EMIT: begin
                if (out_ready) begin
                    out_valid <= 1'b0;
                    state     <= ST_NEXT;
                end
            end

            ST_NEXT: begin
                if (offset == 14'h3FFF) begin
                    offset <= 14'd0;
                    if (bank + 9'd1 == bank_count) begin
                        state <= ST_DONE;
                    end else begin
                        bank  <= bank + 9'd1;
                        state <= ST_BANK_LO;
                    end
                end else begin
                    offset <= offset + 14'd1;
                    state  <= ST_READ;
                end
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
