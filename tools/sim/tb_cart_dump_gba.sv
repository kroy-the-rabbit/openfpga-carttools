// SOURCES: src/fpga/services/dump/cart_dump_gba.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv tools/sim/gba_cart_model.sv
//
// tb_cart_dump_gba.sv - reading a whole GBA ROM, four bytes at a time
//
// This one runs against the real bus and the real cartridge model rather than
// a stub, because two of the three things worth proving live in that
// interaction and a stub would agree with the module by construction:
//
//   Byte order. The cartridge model answers with a halfword built from the
//   address it latched, so the byte a given address holds is known. The
//   content function is deliberately asymmetric - the four bytes of every
//   word differ from each other - so emitting a word big-endian, or swapping
//   the two halfwords, cannot pass. There is a check before the first run
//   that the four bytes of word 0 really are distinct, so the test cannot
//   quietly lose its teeth if that function is ever changed.
//
//   That the accesses are 32-bit. The model counts CS1# address phases and
//   RD# pulses independently of what the module believes it asked for. Four
//   bytes must cost one address phase and two RD# pulses. Sixteen-bit reads
//   would cost two address phases for the same bytes and the count fails.
//
// The third is back pressure, which is the module's own: a consumer that
// stalls indefinitely, including across the boundary where the module has to
// go back to the bus for the next word, must lose no byte and see none twice.
// The stall after every fourth byte is 120 cycles, comfortably longer than
// the ~55 a 32-bit read takes at the shipped timings, so out_ready is low for
// the whole of the next read and still low when its first byte appears.
//
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1ns/1ps

module tb_cart_dump_gba;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg cart_mode = 1'b0;
reg clr = 1'b0;

reg         start = 1'b0;
reg  [31:0] size_bytes = 32'd0;

wire        rd_busy, rd_done;
wire [31:0] total_bytes;
wire        bus_req, bus_wr;
wire [27:0] bus_addr;
wire [1:0]  bus_acc;
wire [31:0] bus_wdata, bus_rdata;
wire        bus_done, bus_busy;
wire [7:0]  out_data;
wire        out_valid;

integer errors = 0;

// --- the consumer's back pressure -------------------------------------------
// bp_mode 0 takes every byte the cycle it appears. bp_mode 1 stalls for a
// pseudo-random few cycles after most bytes and for 120 after every fourth,
// which is the byte after which the module must go back to the bus.
reg        bp_mode = 1'b0;
reg [7:0]  stall_ctr = 8'd0;
reg [15:0] lfsr = 16'hACE1;
wire       out_ready = bp_mode ? (stall_ctr == 8'd0) : 1'b1;

cart_dump_gba dut (
    .clk (clk), .reset (reset),
    .start (start), .size_bytes (size_bytes),
    .busy (rd_busy), .done (rd_done), .total_bytes (total_bytes),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_acc (bus_acc), .bus_wdata (bus_wdata), .bus_rdata (bus_rdata),
    .bus_done (bus_done), .bus_busy (bus_busy),
    .out_data (out_data), .out_valid (out_valid), .out_ready (out_ready)
);

// --- bus, pins and cartridge -------------------------------------------------

wire [15:0] e_ad_out, e_ad_in;
wire        e_ad_oe;
wire [7:0]  e_hi_out, e_hi_in;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire        mode_ready;

tri  [7:0] bank2, bank3, bank1;
wire       bank2_dir, bank3_dir, bank1_dir;
tri  [7:4] bank0;
wire       bank0_dir;
tri        pin30;
wire       pin30_dir, pin30_pwroff;
tri        pin31;
wire       pin31_dir;

wire [23:0] rom_addr;
wire [15:0] save_addr;
wire [31:0] cs1_latch_count, cs2_latch_count;
wire [31:0] rom_rd_count, save_rd_count;
wire [31:0] wr_pulse_count, rom_wr_count, save_wr_count;
wire [23:0] last_cs1_latch_addr;

gba_cart_bus bus (
    .clk (clk), .reset (reset), .cart_mode (cart_mode),
    .req (bus_req), .wr (bus_wr), .addr (bus_addr), .acc (bus_acc),
    .wdata (bus_wdata), .rdata (bus_rdata),
    .done (bus_done), .busy (bus_busy),
    .e_ad_out (e_ad_out), .e_ad_oe (e_ad_oe),
    .e_hi_out (e_hi_out), .e_hi_oe (e_hi_oe),
    .e_ctl_out (e_ctl_out),
    .e_p30_out (e_p30_out), .e_p30_oe (e_p30_oe),
    .e_ad_in (e_ad_in), .e_hi_in (e_hi_in)
);

cart_pins pins (
    .clk (clk), .reset (reset), .mode (cart_mode ? 2'b01 : 2'b00),
    .mode_ready (mode_ready),
    .gba_ad_out (e_ad_out), .gba_ad_oe (e_ad_oe),
    .gba_hi_out (e_hi_out), .gba_hi_oe (e_hi_oe),
    .gba_ctl_out (e_ctl_out),
    .gba_p30_out (e_p30_out), .gba_p30_oe (e_p30_oe),
    .gba_ad_in (e_ad_in), .gba_hi_in (e_hi_in),
    .cart_tran_bank2 (bank2), .cart_tran_bank2_dir (bank2_dir),
    .cart_tran_bank3 (bank3), .cart_tran_bank3_dir (bank3_dir),
    .cart_tran_bank1 (bank1), .cart_tran_bank1_dir (bank1_dir),
    .cart_tran_bank0 (bank0), .cart_tran_bank0_dir (bank0_dir),
    .cart_tran_pin30 (pin30), .cart_tran_pin30_dir (pin30_dir),
    .cart_pin30_pwroff_reset (pin30_pwroff),
    .cart_tran_pin31 (pin31), .cart_tran_pin31_dir (pin31_dir)
);

// The cartridge's contents, as a function of the byte address. Nibble-swapping
// the low byte makes every byte of a word differ from its neighbours, so no
// transposition inside a 32-bit read survives the comparison.
function [7:0] content(input [27:0] a);
begin
    content = ({a[3:0], a[7:4]} ^ a[15:8]) ^ 8'hC3;
end
endfunction

// A halfword is little-endian: the even byte address is the low byte.
function [15:0] rom_word(input [23:0] w);
begin
    rom_word = {content({w, 1'b1}), content({w, 1'b0})};
end
endfunction

gba_cart_model cart (
    .cart_mode (cart_mode), .clr (clr),
    .bank3 (bank3), .bank3_dir (bank3_dir),
    .bank2 (bank2), .bank2_dir (bank2_dir),
    .bank1 (bank1), .bank1_dir (bank1_dir),
    .bank0 (bank0), .pin30 (pin30),
    .rom_addr (rom_addr), .rom_rdata (rom_word(rom_addr)),
    .save_addr (save_addr), .save_rdata (8'h00),
    .cs1_latch_count (cs1_latch_count), .cs2_latch_count (cs2_latch_count),
    .rom_rd_count (rom_rd_count), .save_rd_count (save_rd_count),
    .wr_pulse_count (wr_pulse_count),
    .rom_wr_count (rom_wr_count), .save_wr_count (save_wr_count),
    .last_cs1_latch_addr (last_cs1_latch_addr),
    .last_cs2_latch_addr (),
    .last_rom_wr_addr (), .last_rom_wr_data (),
    .last_save_wr_addr (), .last_save_wr_data (),
    .contention_seen (), .both_cs_seen ()
);

// --- the module may never write ---------------------------------------------
// Checked at the module's own port as well as at the connector, because the
// bus refusing to pulse WR# in ROM space would hide a wr that should never
// have been asserted in the first place.
// Sampled on the request rather than every cycle: what matters is what the
// bus latches, and a per-cycle check buries a real failure under thousands of
// identical lines.
always @(posedge clk) begin
    if (!reset && bus_req) begin
        if (bus_wr !== 1'b0) begin
            $display("ERROR: bus_wr asserted with a request at %0t", $time);
            errors = errors + 1;
        end
        if (bus_acc === 2'b00 || bus_acc === 2'b01) begin
            $display("ERROR: acc %b is an 8 or 16 bit access, not 32", bus_acc);
            errors = errors + 1;
        end
    end
end

// --- request addresses -------------------------------------------------------
integer n_reqs = 0;
reg [27:0] req_addr [0:3];
always @(posedge clk) begin
    if (bus_req) begin
        if (n_reqs < 4) req_addr[n_reqs] = bus_addr;
        n_reqs = n_reqs + 1;
    end
end

// --- the stream, and the stalls ---------------------------------------------
integer got = 0;
reg [7:0] first_bytes [0:7];

always @(posedge clk) begin
    lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    if (stall_ctr != 8'd0) stall_ctr <= stall_ctr - 8'd1;

    if (!reset && out_valid && out_ready) begin
        if (out_data !== content(got)) begin
            if (errors < 5)
                $display("ERROR: byte %0d = %02h, expected %02h",
                         got, out_data, content(got));
            errors = errors + 1;
        end
        if (got < 8) first_bytes[got] = out_data;
        got = got + 1;
        // Stall hard on the word boundary, briefly elsewhere.
        stall_ctr <= ((got & 3) == 0) ? 8'd120 : {5'd0, lfsr[2:0]};
    end
end

// A stalled byte must not move or vanish.
reg       was_stalled = 1'b0;
reg [7:0] stalled_data = 8'd0;
always @(posedge clk) begin
    if (was_stalled) begin
        if (out_valid !== 1'b1) begin
            $display("ERROR: out_valid dropped while the consumer was stalled at %0t",
                     $time);
            errors = errors + 1;
        end
        if (out_data !== stalled_data) begin
            $display("ERROR: out_data changed under a stall, %02h became %02h",
                     stalled_data, out_data);
            errors = errors + 1;
        end
    end
    was_stalled  <= !reset && out_valid && !out_ready;
    stalled_data <= out_data;
end

// --- driving a dump ----------------------------------------------------------

task run_dump(input [31:0] n, input bp);
begin
    @(negedge clk);
    size_bytes = n;
    bp_mode    = bp;
    got        = 0;
    n_reqs     = 0;
    clr        = 1'b1;
    @(negedge clk);
    clr = 1'b0;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (rd_done == 1'b1);
    @(negedge clk);
end
endtask

task chk_counts(input [31:0] n, input [31:0] want_reads);
begin
    if (got !== n) begin
        $display("ERROR: emitted %0d bytes for a %0d byte dump", got, n);
        errors = errors + 1;
    end
    if (total_bytes !== n) begin
        $display("ERROR: total_bytes %0d for a %0d byte dump", total_bytes, n);
        errors = errors + 1;
    end
    if (n_reqs !== want_reads) begin
        $display("ERROR: made %0d bus requests, expected %0d",
                 n_reqs, want_reads);
        errors = errors + 1;
    end
    if (cs1_latch_count !== want_reads) begin
        $display("ERROR: %0d CS1 address phases for %0d words",
                 cs1_latch_count, want_reads);
        errors = errors + 1;
    end
    if (rom_rd_count !== want_reads * 2) begin
        $display("ERROR: %0d RD pulses for %0d words, expected two each",
                 rom_rd_count, want_reads);
        errors = errors + 1;
    end
    if (wr_pulse_count !== 32'd0 || cs2_latch_count !== 32'd0) begin
        $display("ERROR: the dump touched the cartridge: %0d WR pulses, %0d CS2 phases",
                 wr_pulse_count, cs2_latch_count);
        errors = errors + 1;
    end
    if (rd_busy !== 1'b0) begin
        $display("ERROR: still busy after done");
        errors = errors + 1;
    end
end
endtask

initial begin
    // The comparison has teeth only if the four bytes of a word differ.
    if (content(28'd0) === content(28'd1) || content(28'd0) === content(28'd2) ||
        content(28'd0) === content(28'd3) || content(28'd1) === content(28'd2) ||
        content(28'd1) === content(28'd3) || content(28'd2) === content(28'd3)) begin
        $display("ERROR: the model content function is not asymmetric within a word");
        errors = errors + 1;
    end

    repeat (2) @(negedge clk);
    reset     = 1'b0;
    cart_mode = 1'b1;
    // cart_pins passes a mode change through idle before driving anything.
    wait (mode_ready);
    repeat (4) @(negedge clk);

    // --- 1 KiB, taken as fast as it is produced ---------------------------
    run_dump(32'd1024, 1'b0);
    chk_counts(32'd1024, 32'd256);
    if (req_addr[0] !== 28'd0 || req_addr[1] !== 28'd4 || req_addr[2] !== 28'd8) begin
        $display("ERROR: read addresses began %0d %0d %0d, expected 0 4 8",
                 req_addr[0], req_addr[1], req_addr[2]);
        errors = errors + 1;
    end
    // Halfword 511 is the last one a 1 KiB image contains; the address phase
    // for the last word latches halfword 510 and the cart supplies 511 itself.
    if (last_cs1_latch_addr !== 24'd510) begin
        $display("ERROR: last address phase latched halfword %0d, expected 510",
                 last_cs1_latch_addr);
        errors = errors + 1;
    end

    // Byte order, stated as halfwords rather than left implicit in the loop.
    if ({first_bytes[1], first_bytes[0]} !== rom_word(24'd0)) begin
        $display("ERROR: first halfword emitted as %02h %02h, expected %04h low byte first",
                 first_bytes[0], first_bytes[1], rom_word(24'd0));
        errors = errors + 1;
    end
    if ({first_bytes[3], first_bytes[2]} !== rom_word(24'd1)) begin
        $display("ERROR: second halfword emitted as %02h %02h, expected %04h low byte first",
                 first_bytes[2], first_bytes[3], rom_word(24'd1));
        errors = errors + 1;
    end
    if ({first_bytes[5], first_bytes[4]} !== rom_word(24'd2)) begin
        $display("ERROR: third halfword emitted as %02h %02h, expected %04h low byte first",
                 first_bytes[4], first_bytes[5], rom_word(24'd2));
        errors = errors + 1;
    end

    // --- 512 bytes, against a consumer that stalls ------------------------
    run_dump(32'd512, 1'b1);
    chk_counts(32'd512, 32'd128);

    // --- a size that is not a multiple of four ----------------------------
    // The last word is read whole and only its first byte is emitted. Sizes
    // like this cannot come from the probe, which only ever returns powers of
    // two, but the byte count downstream has to be exact whatever it is told.
    run_dump(32'd13, 1'b0);
    chk_counts(32'd13, 32'd4);

    // --- and one with the consumer stalling through the ragged end --------
    run_dump(32'd7, 1'b1);
    chk_counts(32'd7, 32'd2);

    // --- nothing at all ---------------------------------------------------
    // An empty slot can produce a zero size. Finishing without touching the
    // connector is the right answer; hanging or reading one word anyway is
    // not.
    run_dump(32'd0, 1'b0);
    chk_counts(32'd0, 32'd0);

    // Nothing above may leave a pin driven.
    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0) begin
        $display("ERROR: a bank was still driven after the last dump");
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("tb_cart_dump_gba: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_cart_dump_gba");
    $finish;
end

initial begin
    #20_000_000;
    $display("tb_cart_dump_gba watchdog expired at %0t, got %0d bytes", $time, got);
    $fatal(1);
end

endmodule

`default_nettype wire
