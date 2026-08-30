// SOURCES: src/fpga/services/dump/cart_dump_gb.sv
//
// tb_cart_dump_gb.sv - reading a whole ROM, bank by bank
//
// The bus is stubbed and the mapper is modelled here, because what needs
// proving is the dump's own behaviour: that it reads every byte exactly once,
// in order, that bank 0 comes from 0x0000 and every other bank from 0x4000,
// and that the right mapper register is written before each bank.
//
// The ROM content is a function of the linear address, so a bank-switching
// mistake cannot pass. Reading bank 3 while the mapper still points at bank 2
// yields bytes that belong to a different address and the check fails on the
// first one.
//
`default_nettype none
`timescale 1ns/1ps

module tb_cart_dump_gb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg start = 1'b0;
reg [7:0] cart_type = 8'h19;
reg [7:0] rom_size_code = 8'd1;

wire        busy, done;
wire [31:0] total_bytes;
wire        bus_req, bus_wr;
wire [15:0] bus_addr;
wire [7:0]  bus_wdata;
reg  [7:0]  bus_rdata = 8'd0;
reg         bus_done = 1'b0;
wire [7:0]  out_data;
wire        out_valid;
reg         out_ready = 1'b1;

cart_dump_gb dut (
    .clk (clk), .reset (reset),
    .start (start), .cart_type (cart_type), .rom_size_code (rom_size_code),
    .busy (busy), .done (done), .total_bytes (total_bytes),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_wdata (bus_wdata), .bus_rdata (bus_rdata), .bus_done (bus_done),
    .out_data (out_data), .out_valid (out_valid), .out_ready (out_ready)
);

integer errors = 0;

// --- the cartridge -----------------------------------------------------------
// Content is derived from the linear address so every byte identifies where it
// came from.
function [7:0] content(input [23:0] lin);
    content = lin[7:0] ^ lin[15:8] ^ {4'd0, lin[19:16]};
endfunction

reg [8:0] cur_bank = 9'd1;   // what the mapper currently points at
reg [1:0] mbc1_hi  = 2'd0;
reg       mbc5_hi  = 1'b0;

integer n_writes = 0;
integer w_addr [0:63];
integer w_data [0:63];

// Effective bank for a read at addr, as the cartridge would decode it.
function [8:0] eff_bank(input [15:0] a);
    begin
        if (a < 16'h4000) eff_bank = 9'd0;
        else              eff_bank = cur_bank;
    end
endfunction

// Stubbed bus: a transaction takes a few cycles, then done for one cycle.
always @(posedge clk) begin
    bus_done <= 1'b0;
    if (bus_req) begin
        repeat (3) @(posedge clk);
        if (bus_wr) begin
            if (n_writes < 64) begin
                w_addr[n_writes] = bus_addr;
                w_data[n_writes] = bus_wdata;
            end
            n_writes = n_writes + 1;
            // Model the mappers we claim to drive.
            if (bus_addr == 16'h2000) begin
                if (cart_type >= 8'h19 && cart_type <= 8'h1E)
                    cur_bank <= {mbc5_hi, bus_wdata};
                else if (cart_type >= 8'h01 && cart_type <= 8'h03)
                    cur_bank <= {2'd0, mbc1_hi, bus_wdata[4:0]};
                else
                    cur_bank <= {2'd0, bus_wdata[6:0]};
            end else if (bus_addr == 16'h2100) begin
                cur_bank <= {5'd0, bus_wdata[3:0]};
            end else if (bus_addr == 16'h3000) begin
                mbc5_hi <= bus_wdata[0];
                cur_bank <= {bus_wdata[0], cur_bank[7:0]};
            end else if (bus_addr == 16'h4000) begin
                mbc1_hi <= bus_wdata[1:0];
                cur_bank <= {2'd0, bus_wdata[1:0], cur_bank[4:0]};
            end
        end else begin
            bus_rdata <= content({eff_bank(bus_addr), bus_addr[13:0]} & 24'hFFFFFF);
        end
        bus_done <= 1'b1;
        @(posedge clk);
    end
end

// --- collect the stream ------------------------------------------------------
integer got = 0;
reg [23:0] expect_lin;

always @(posedge clk) begin
    if (out_valid && out_ready) begin
        expect_lin = got;
        if (out_data !== content(expect_lin)) begin
            if (errors < 5)
                $display("ERROR: byte %0d = %02h, expected %02h",
                         got, out_data, content(expect_lin));
            errors = errors + 1;
        end
        got = got + 1;
    end
end

task run_dump(input [7:0] ctype, input [7:0] szcode);
begin
    @(negedge clk);
    cart_type     = ctype;
    rom_size_code = szcode;
    cur_bank      = 9'd1;
    mbc1_hi       = 2'd0;
    mbc5_hi       = 1'b0;
    n_writes      = 0;
    got           = 0;
    errors        = errors;   // keep running total
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk);
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // --- MBC5, 64 KB, four banks. Every byte checked. ---
    run_dump(8'h19, 8'd1);
    if (total_bytes !== 32'd65536) begin
        $display("ERROR: total_bytes %0d for size code 1, expected 65536",
                 total_bytes);
        errors = errors + 1;
    end
    if (got !== 65536) begin
        $display("ERROR: emitted %0d bytes, expected 65536", got);
        errors = errors + 1;
    end
    // Three bank selections, for banks 1, 2 and 3. Bank 0 needs none.
    if (n_writes !== 3) begin
        $display("ERROR: %0d mapper writes for a 4 bank MBC5, expected 3",
                 n_writes);
        errors = errors + 1;
    end
    if (w_addr[0] !== 16'h2000 || w_data[0] !== 1) begin
        $display("ERROR: first MBC5 bank write was %04h=%02h, expected 2000=01",
                 w_addr[0][15:0], w_data[0][7:0]);
        errors = errors + 1;
    end

    // --- no mapper at all, 32 KB. Nothing may be written to the cartridge. ---
    run_dump(8'h00, 8'd0);
    if (total_bytes !== 32'd32768) begin
        $display("ERROR: total_bytes %0d for a ROM-only cart, expected 32768",
                 total_bytes);
        errors = errors + 1;
    end
    if (got !== 32768) begin
        $display("ERROR: emitted %0d bytes for ROM-only, expected 32768", got);
        errors = errors + 1;
    end
    if (n_writes !== 0) begin
        $display("ERROR: %0d writes to a cartridge with no mapper, expected 0",
                 n_writes);
        errors = errors + 1;
    end

    // --- MBC3, 128 KB. Checks the 7-bit register path. ---
    run_dump(8'h13, 8'd2);
    if (got !== 131072) begin
        $display("ERROR: emitted %0d bytes for MBC3 128K, expected 131072", got);
        errors = errors + 1;
    end
    if (n_writes !== 7) begin
        $display("ERROR: %0d mapper writes for 8 banks of MBC3, expected 7",
                 n_writes);
        errors = errors + 1;
    end

    // --- MBC1, 128 KB. Both registers are written for every bank. ---
    run_dump(8'h01, 8'd2);
    if (got !== 131072) begin
        $display("ERROR: emitted %0d bytes for MBC1 128K, expected 131072", got);
        errors = errors + 1;
    end
    // Seven banks, each costing a low write and an upper write.
    if (n_writes !== 14) begin
        $display("ERROR: %0d mapper writes for 8 banks of MBC1, expected 14",
                 n_writes);
        errors = errors + 1;
    end
    if (w_addr[1] !== 16'h4000) begin
        $display("ERROR: MBC1 second write went to %04h, expected 4000",
                 w_addr[1][15:0]);
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("tb_cart_dump_gb: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_cart_dump_gb");
    $finish;
end

initial begin
    #400000000;
    $display("ERROR: tb_cart_dump_gb watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
