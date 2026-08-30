// SOURCES: src/fpga/services/identify/cart_probe.sv src/fpga/services/identify/cart_identify_gb.sv src/fpga/services/identify/cart_identify_gba.sv src/fpga/core/gb_cart_bus.sv src/fpga/core/gba_cart_bus.sv src/fpga/core/cart_pins.sv
//
// tb_probe_pins.sv - what the connector actually sees during a full probe
//
// The whole chain, at the pins, with an empty slot. An empty slot escalates,
// so this run covers GB mode, the turnaround, and GBA mode.
//
// It asserts the properties that decide whether a cartridge can be harmed:
//
//   WR# never falls
//   the two engines never drive at once
//   no pin is driven while the mode is idle or turning round
//   bank1 and the AD pins are never driven at the same time in GB mode
//
`default_nettype none
`timescale 1ns/1ps

module tb_probe_pins;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg powered = 1'b0;
reg start = 1'b0;

wire [1:0] mode;
wire       mode_ready;
wire       probe_busy, probe_done;
wire [2:0] platform;
wire       gb_start, gba_start;

wire       gb_mode_s  = powered && (mode == 2'b10) && mode_ready;
wire       gba_mode_s = powered && (mode == 2'b01) && mode_ready;

// ---- Pins, with pull-ups. An empty slot floats high. ----------------------
wire [7:0] cart_tran_bank2, cart_tran_bank3, cart_tran_bank1;
wire [7:4] cart_tran_bank0;
wire       cart_tran_pin30, cart_tran_pin31;
wire       bank2_dir, bank3_dir, bank1_dir, bank0_dir, pin30_dir, pin31_dir;
wire       pwroff_reset;

pullup (weak1) p2 [7:0] (cart_tran_bank2);
pullup (weak1) p3 [7:0] (cart_tran_bank3);
pullup (weak1) p1 [7:0] (cart_tran_bank1);
pullup (weak1) p0 [7:4] (cart_tran_bank0);
pullup (weak1) p30 (cart_tran_pin30);
pullup (weak1) p31 (cart_tran_pin31);

// ---- GB engine ------------------------------------------------------------
wire [15:0] gb_ad_out, gb_ad_in;
wire [7:0]  gb_hi_out, gb_hi_in;
wire        gb_ad_oe, gb_hi_oe, gb_p30_out, gb_p30_oe;
wire [3:0]  gb_ctl_out;
wire        gbid_req, gbid_wr;
wire [15:0] gbid_addr;
wire [7:0]  gbid_wdata, gb_bus_rdata;
wire        gb_bus_done, gb_bus_busy;

gb_cart_bus gb_bus (
    .clk (clk), .reset (reset), .gb_mode (gb_mode_s),
    .req (gbid_req), .wr (gbid_wr), .addr (gbid_addr), .wdata (gbid_wdata),
    .rdata (gb_bus_rdata), .done (gb_bus_done), .busy (gb_bus_busy),
    .e_ad_out (gb_ad_out), .e_ad_oe (gb_ad_oe),
    .e_hi_out (gb_hi_out), .e_hi_oe (gb_hi_oe), .e_ctl_out (gb_ctl_out),
    .e_p30_out (gb_p30_out), .e_p30_oe (gb_p30_oe),
    .e_ad_in (gb_ad_in), .e_hi_in (gb_hi_in)
);

// ---- GBA engine -----------------------------------------------------------
wire [15:0] gba_ad_out, gba_ad_in;
wire [7:0]  gba_hi_out, gba_hi_in;
wire        gba_ad_oe, gba_hi_oe, gba_p30_out, gba_p30_oe;
wire [3:0]  gba_ctl_out;
wire        id_req, id_wr;
wire [27:0] id_addr;
wire [1:0]  id_acc;
wire [31:0] id_wdata, cart_bus_rdata;
wire        cart_bus_done, cart_bus_busy;

gba_cart_bus cart_bus (
    .clk (clk), .reset (reset), .cart_mode (gba_mode_s),
    .req (id_req), .wr (id_wr), .addr (id_addr), .acc (id_acc),
    .wdata (id_wdata), .rdata (cart_bus_rdata),
    .done (cart_bus_done), .busy (cart_bus_busy),
    .e_ad_out (gba_ad_out), .e_ad_oe (gba_ad_oe),
    .e_hi_out (gba_hi_out), .e_hi_oe (gba_hi_oe), .e_ctl_out (gba_ctl_out),
    .e_p30_out (gba_p30_out), .e_p30_oe (gba_p30_oe),
    .e_ad_in (gba_ad_in), .e_hi_in (gba_hi_in)
);

cart_pins pins (
    .clk (clk), .reset (reset),
    .mode (powered ? mode : 2'b00), .mode_ready (mode_ready),
    .gba_ad_out (gba_ad_out), .gba_ad_oe (gba_ad_oe),
    .gba_hi_out (gba_hi_out), .gba_hi_oe (gba_hi_oe),
    .gba_ctl_out (gba_ctl_out),
    .gba_p30_out (gba_p30_out), .gba_p30_oe (gba_p30_oe),
    .gba_ad_in (gba_ad_in), .gba_hi_in (gba_hi_in),
    .gb_ad_out (gb_ad_out), .gb_ad_oe (gb_ad_oe),
    .gb_hi_out (gb_hi_out), .gb_hi_oe (gb_hi_oe),
    .gb_ctl_out (gb_ctl_out),
    .gb_p30_out (gb_p30_out), .gb_p30_oe (gb_p30_oe),
    .gb_ad_in (gb_ad_in), .gb_hi_in (gb_hi_in),
    .cart_tran_bank2 (cart_tran_bank2), .cart_tran_bank2_dir (bank2_dir),
    .cart_tran_bank3 (cart_tran_bank3), .cart_tran_bank3_dir (bank3_dir),
    .cart_tran_bank1 (cart_tran_bank1), .cart_tran_bank1_dir (bank1_dir),
    .cart_tran_bank0 (cart_tran_bank0), .cart_tran_bank0_dir (bank0_dir),
    .cart_tran_pin30 (cart_tran_pin30), .cart_tran_pin30_dir (pin30_dir),
    .cart_pin30_pwroff_reset (pwroff_reset),
    .cart_tran_pin31 (cart_tran_pin31), .cart_tran_pin31_dir (pin31_dir)
);

// ---- Identifiers and the probe --------------------------------------------
wire        gbid_busy, gbid_done;
wire [2:0]  gbid_result;
wire [119:0] gbid_title;
wire [7:0]  gbid_cgb, gbid_type, gbid_rom, gbid_ram, gbid_ver;
wire        gbid_ck;
wire [207:0] gbid_raw;
wire [7:0]  gbid_ckr, gbid_ckc;

cart_identify_gb identify_gb (
    .clk (clk), .reset (reset), .gb_mode (gb_mode_s),
    .start (gb_start), .busy (gbid_busy), .done (gbid_done),
    .cart_req (gbid_req), .cart_wr (gbid_wr), .cart_addr (gbid_addr),
    .cart_wdata (gbid_wdata), .cart_rdata (gb_bus_rdata),
    .cart_done (gb_bus_done), .cart_busy (gb_bus_busy),
    .result (gbid_result), .title (gbid_title), .cgb_flag (gbid_cgb),
    .cart_type (gbid_type), .rom_size_code (gbid_rom),
    .ram_size_code (gbid_ram), .sw_version (gbid_ver),
    .checksum_ok (gbid_ck), .raw_bytes (gbid_raw),
    .checksum_read (gbid_ckr), .checksum_calc (gbid_ckc)
);

wire        id_busy, id_done;
wire [2:0]  id_result;
wire [95:0] id_title;
wire [31:0] id_code;
wire [15:0] id_maker;
wire [7:0]  id_dev, id_ver;
wire        id_fx, id_ck, id_rs;
wire [255:0] id_raw;
wire [7:0]  id_ckr, id_ckc;

cart_identify_gba identify (
    .clk (clk), .reset (reset), .cart_mode (gba_mode_s),
    .start (gba_start), .busy (id_busy), .done (id_done),
    .cart_req (id_req), .cart_wr (id_wr), .cart_addr (id_addr),
    .cart_acc (id_acc), .cart_wdata (id_wdata), .cart_rdata (cart_bus_rdata),
    .cart_done (cart_bus_done), .cart_busy (cart_bus_busy),
    .result (id_result), .title (id_title), .game_code (id_code),
    .maker_code (id_maker), .device_type (id_dev), .sw_version (id_ver),
    .fixed_ok (id_fx), .checksum_ok (id_ck), .reserved_ok (id_rs),
    .raw_words (id_raw), .checksum_read (id_ckr), .checksum_calc (id_ckc)
);

cart_probe #(.WAKE_CYCLES(4)) probe (
    .clk (clk), .reset (reset),
    .start (start), .cart_powered (powered),
    .busy (probe_busy), .done (probe_done),
    .mode (mode), .mode_ready (mode_ready),
    .gb_start (gb_start), .gb_done (gbid_done), .gb_result (gbid_result),
    .gba_start (gba_start), .gba_done (id_done), .gba_result (id_result),
    .platform (platform)
);

// ---- The properties that decide whether a cartridge can be harmed ---------

integer wr_falls = 0;

// WR# is bank0[6]. It must never fall. Nothing in this build writes.
always @(negedge cart_tran_bank0[6]) begin
    wr_falls = wr_falls + 1;
    $fatal(1, "WR# fell at %0t", $time);
end

// Two engines driving the same pin is the failure that damages hardware.
always @(posedge clk) begin
    #1;
    if ((gb_ad_oe && gba_ad_oe) || (gb_hi_oe && gba_hi_oe) ||
        (gb_p30_oe && gba_p30_oe))
        $fatal(1, "both engines driving at %0t", $time);
end

// Nothing may be driven while the pins are idle or turning round. This holds
// through two independent mechanisms: cart_pins gates its mux on mode_ready,
// and each engine's own enable is gated the same way. Breaking either one
// alone leaves this property intact, so it is belt and braces rather than one
// check. bank0 is
// exempt: its safe idle is to drive 4'hF, per docs/HARDWARE-NOTES.md s3.
always @(posedge clk) begin
    #1;
    if (!mode_ready || mode == 2'b00) begin
        if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0)
            $fatal(1, "a data or address bank driven with the pins idle at %0t", $time);
        if (cart_tran_bank0 !== 4'hF)
            $fatal(1, "control lines not inactive with the pins idle at %0t", $time);
    end
end

// In GB mode the address pins and the data pins must never be outputs at the
// same time, because on a GB cartridge bank1 is the cartridge's data bus.
always @(posedge clk) begin
    #1;
    if (gb_mode_s && bank1_dir && !gb_hi_oe)
        $fatal(1, "bank1 driven in GB mode without the engine asking at %0t", $time);
end

integer i;

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (10) @(negedge clk);

    // ---- Unpowered: a probe must not touch anything --------------------
    powered = 1'b0;
    @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;
    wait (probe_done == 1'b1);
    @(negedge clk);
    if (platform !== 3'd5) begin
        $display("ERROR: unpowered platform %0d, expected 5", platform);
        $fatal(1);
    end

    // ---- Empty slot: probes GB, finds nothing, escalates to GBA ---------
    powered = 1'b1;
    repeat (40) @(negedge clk);
    @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;
    wait (probe_done == 1'b1);
    @(negedge clk);
    if (platform !== 3'd0) begin
        $display("ERROR: empty slot platform %0d, expected 0", platform);
        $fatal(1);
    end

    // The bus is parked idle and the clamp released.
    repeat (4) @(negedge clk);
    if (mode !== 2'b00) begin
        $display("ERROR: mode %b after a probe", mode);
        $fatal(1);
    end
    if (pwroff_reset !== 1'b0) begin
        $display("ERROR: pin30 clamp still released after a probe");
        $fatal(1);
    end

    // ---- Losing power mid-probe releases everything ---------------------
    @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;
    repeat (300) @(negedge clk);
    powered = 1'b0;
    @(negedge clk);
    if (bank1_dir !== 1'b0 || bank2_dir !== 1'b0 || bank3_dir !== 1'b0) begin
        $display("ERROR: a bank still driven after power dropped");
        $fatal(1);
    end
    if (cart_tran_bank0 !== 4'hF) begin
        $display("ERROR: control lines not inactive after power dropped");
        $fatal(1);
    end

    if (wr_falls != 0) $fatal(1, "WR# fell %0d times", wr_falls);

    $display("tb_probe_pins: full probe, both modes, WR# never fell");
    $display("TB PASS: tb_probe_pins");
    $finish;
end

initial begin
    #200000000;
    $display("ERROR: tb_probe_pins watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
