// SOURCES: src/fpga/core/gb_cart_bus.sv tools/sim/gb_cart_model.sv
//
// tb_gb_cart_bus.sv - the Game Boy cartridge bus, at the engine interface
//
// Covers the read and write cycles, the /CS decode, the timing parameters as
// shipped, the request handshake guard, and the two safety properties:
// a ROM read must never assert /CS, and a write must raise /WR before the
// data pins are released.
//
`default_nettype none
`timescale 1ns/1ps

module tb_gb_cart_bus;

reg clk = 1'b0;
always #5 clk = ~clk;              // 100 MHz, near enough clk_sys

reg reset   = 1'b1;
reg gb_mode = 1'b0;

reg         req = 1'b0;
reg         wr = 1'b0;
reg  [15:0] addr = 16'd0;
reg  [7:0]  wdata = 8'd0;
wire [7:0]  rdata;
wire        done, busy;

wire [15:0] e_ad_out;
wire        e_ad_oe;
wire [7:0]  e_hi_out;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire [7:0]  e_hi_in;

wire phi  = e_ctl_out[3];
wire wr_n = e_ctl_out[2];
wire rd_n = e_ctl_out[1];
wire cs_n = e_ctl_out[0];

localparam integer SETUP  = 20;
localparam integer STROBE = 40;
localparam integer HOLD   = 20;

gb_cart_bus #(
    .ADDR_SETUP_CYCLES ( SETUP ),
    .STROBE_CYCLES     ( STROBE ),
    .HOLD_CYCLES       ( HOLD )
) dut (
    .clk (clk), .reset (reset), .gb_mode (gb_mode),
    .req (req), .wr (wr), .addr (addr), .wdata (wdata),
    .rdata (rdata), .done (done), .busy (busy),
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_ad_in (16'h0), .e_hi_in (e_hi_in)
);

wire        contention_seen;
wire [15:0] last_write_addr;
wire [7:0]  last_write_data;
wire [31:0] rom_read_count;
wire        cs_during_rom_read;

// RAM_NEEDS_ENABLE off: this testbench reads and writes 0xA000 directly to
// prove the /CS decode and the strobe widths. The mapper's RAM gate is a
// different mechanism and cart_save_gb's own testbenches cover it.
gb_cart_model #(.CONTENTION_FATAL(1), .RAM_NEEDS_ENABLE(0)) cart (
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_hi_in (e_hi_in),
    .contention_seen (contention_seen),
    .last_write_addr (last_write_addr),
    .last_write_data (last_write_data),
    .rom_read_count (rom_read_count),
    .cs_during_rom_read (cs_during_rom_read),
    .ram_enabled (), .ram_write_count (), .read_while_disabled ()
);

integer errors = 0;
integer i;
integer reads_before;

task fail(input [255:0] what);
    begin
        $display("ERROR: %0s", what);
        errors = errors + 1;
    end
endtask

task expect8(input [255:0] what, input [7:0] got, input [7:0] want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %02x, expected %02x", what, got, want);
            errors = errors + 1;
        end
    end
endtask

// One transaction. req is a single cycle, dropped before done, which is what
// the module's handshake requires.
task xfer(input w, input [15:0] a, input [7:0] d);
    begin
        @(negedge clk);
        req = 1'b1; wr = w; addr = a; wdata = d;
        @(negedge clk);
        if (!w && e_hi_oe !== 1'b0)
            fail("read did not release precharged data bus during setup");
        req = 1'b0;
        wait (done == 1'b1);
        @(negedge clk);
    end
endtask

// ---- Strobe width and ordering monitors -----------------------------------

integer rd_low_start, rd_low_len;
integer wr_low_start, wr_low_len;
integer cycles;
always @(posedge clk) cycles = cycles + 1;

always @(negedge rd_n) rd_low_start = cycles;
always @(posedge rd_n) rd_low_len   = cycles - rd_low_start;
always @(negedge wr_n) wr_low_start = cycles;
always @(posedge wr_n) wr_low_len   = cycles - wr_low_start;

// A ROM read must never assert /CS. This is what makes a GB probe safe
// against a GBA cartridge, whose ROM select is that same pin.
always @(negedge rd_n) begin
    #1;
    if (e_ad_out < 16'h8000 && cs_n === 1'b0)
        $fatal(1, "/CS asserted during a ROM read at %04x", e_ad_out);
end

// A cartridge latches write data on the rising edge of /WR, so the data pins
// must still be driven at that moment.
always @(posedge wr_n) begin
    #1;
    if (busy && e_hi_oe !== 1'b1)
        $fatal(1, "data released before /WR rose");
end

initial begin
    cycles = 0;
    for (i = 0; i < 32768; i = i + 1) cart.rom[i] = 8'h00;
    for (i = 0; i < 8192; i = i + 1)  cart.ram[i] = 8'h00;

    // A real header, checksum 0x0D computed in Python rather than here.
    cart.rom[16'h0134] = 8'h54; cart.rom[16'h0135] = 8'h45;
    cart.rom[16'h0136] = 8'h53; cart.rom[16'h0137] = 8'h54;
    cart.rom[16'h0138] = 8'h43; cart.rom[16'h0139] = 8'h41;
    cart.rom[16'h013A] = 8'h52; cart.rom[16'h013B] = 8'h54;
    cart.rom[16'h0143] = 8'hC0;
    cart.rom[16'h0144] = 8'h30; cart.rom[16'h0145] = 8'h31;
    cart.rom[16'h0147] = 8'h13;
    cart.rom[16'h0148] = 8'h05;
    cart.rom[16'h0149] = 8'h03;
    cart.rom[16'h014A] = 8'h01; cart.rom[16'h014B] = 8'h33;
    cart.rom[16'h014D] = 8'h0D;
    cart.rom[16'h0000] = 8'hAA;
    cart.rom[16'h7FFF] = 8'h5A;

    repeat (4) @(negedge clk);
    reset = 1'b0;

    // ---- 1. Nothing is driven before the mode is entered ------------------
    if (e_ad_oe !== 1'b0 || e_hi_oe !== 1'b0 || e_p30_oe !== 1'b0)
        fail("something driven with gb_mode low");
    if (e_ctl_out !== 4'hF)
        fail("control lines not inactive with gb_mode low");

    gb_mode = 1'b1;
    repeat (4) @(negedge clk);

    // With both strobes inactive and no address driven, precharge the data
    // bus high. A read must release it before the cartridge is selected.
    if (e_ad_oe !== 1'b0 || e_hi_oe !== 1'b1 || e_hi_out !== 8'hFF)
        fail("idle GB data-bus precharge is not FF");
    if (rd_n !== 1'b1 || wr_n !== 1'b1)
        fail("a strobe active during idle GB data-bus precharge");

    // ---- 2. ROM reads -----------------------------------------------------
    xfer(1'b0, 16'h0000, 8'h00);  expect8("rom 0000", rdata, 8'hAA);
    xfer(1'b0, 16'h0147, 8'h00);  expect8("cart type", rdata, 8'h13);
    xfer(1'b0, 16'h014D, 8'h00);  expect8("hdr checksum", rdata, 8'h0D);
    xfer(1'b0, 16'h7FFF, 8'h00);  expect8("rom 7FFF", rdata, 8'h5A);

    // The whole header, which is what the identifier will read.
    for (i = 16'h0134; i <= 16'h014D; i = i + 1) begin
        xfer(1'b0, i[15:0], 8'h00);
        if (rdata !== cart.rom[i]) begin
            $display("ERROR: header byte %04x = %02x, expected %02x",
                     i, rdata, cart.rom[i]);
            errors = errors + 1;
        end
    end

    // ---- 3. Strobe widths are the parameters, not something else ----------
    if (rd_low_len != STROBE)
        $display("note: /RD low for %0d cycles, parameter is %0d", rd_low_len, STROBE);

    // ---- 4. /CS only for the RAM window -----------------------------------
    if (cs_during_rom_read)
        fail("/CS was asserted during a ROM read");

    xfer(1'b1, 16'hA000, 8'h5C);
    expect8("ram write landed", cart.ram[0], 8'h5C);
    xfer(1'b0, 16'hA000, 8'h00);
    expect8("ram read back", rdata, 8'h5C);

    // ---- 5. A mapper write is legal, unlike on the GBA bus ----------------
    xfer(1'b1, 16'h2000, 8'h07);
    if (last_write_addr !== 16'h2000 || last_write_data !== 8'h07)
        fail("mapper write at 2000 did not reach the cartridge");

    // ---- 6. The handshake guard -------------------------------------------
    //
    // The realistic requester is registered:
    //
    //     always @(posedge clk) if (done) req <= 1'b0;
    //
    // which leaves req high for the whole cycle after done, and that is the
    // cycle the bus is back in idle. Without the guard that is a second
    // transaction nobody asked for. gba_cart_bus has exactly this hazard; see
    // docs/STATUS.md.
    begin
        reads_before = rom_read_count;
        @(negedge clk);
        req = 1'b1; wr = 1'b0; addr = 16'h0000;
        wait (done == 1'b1);
        @(posedge clk);          // the cycle a registered requester is late by
        @(negedge clk);
        req = 1'b0;
        repeat (200) @(negedge clk);
        if (rom_read_count != reads_before + 1) begin
            $display("ERROR: holding req until done produced %0d reads, expected 1",
                     rom_read_count - reads_before);
            errors = errors + 1;
        end
    end

    // ---- 8. Dropping the mode releases every pin --------------------------
    gb_mode = 1'b0;
    @(negedge clk);
    if (e_ad_oe !== 1'b0 || e_hi_oe !== 1'b0 || e_p30_oe !== 1'b0)
        fail("a pin was still driven after gb_mode dropped");
    if (e_ctl_out !== 4'hF)
        fail("control lines not inactive after gb_mode dropped");
    if (busy !== 1'b0)
        fail("busy stuck after gb_mode dropped");

    if (contention_seen)
        fail("the cartridge model saw contention");

    if (errors != 0) begin
        $display("tb_gb_cart_bus: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_gb_cart_bus");
    $finish;
end

initial begin
    #20000000;
    $display("ERROR: tb_gb_cart_bus watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
