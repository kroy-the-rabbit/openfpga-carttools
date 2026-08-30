// SOURCES: src/fpga/services/identify/cart_identify_gb.sv src/fpga/core/gb_cart_bus.sv tools/sim/gb_cart_model.sv
//
// tb_cart_identify_gb.sv - GB identification, end to end
//
// The identifier through the real bus into a cartridge model, at the shipped
// timing parameters. The GBA equivalent uses a bus stub; this one does not,
// because the GB bus is new here and its timing has never been exercised by
// anything above it.
//
`default_nettype none
`timescale 1ns/1ps

module tb_cart_identify_gb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset   = 1'b1;
reg gb_mode = 1'b0;
reg start   = 1'b0;

wire        busy, done;
wire [2:0]  result;
wire [119:0] title;
wire [7:0]  cgb_flag, cart_type, rom_size_code, ram_size_code, sw_version;
wire        checksum_ok;
wire [207:0] raw_bytes;
wire [7:0]  checksum_read, checksum_calc;

wire        id_req, id_wr;
wire [15:0] id_addr;
wire [7:0]  id_wdata;
wire [7:0]  bus_rdata;
wire        bus_done, bus_busy;

localparam [2:0] RESULT_GB       = 3'd0;
localparam [2:0] RESULT_NO_CART  = 3'd1;
localparam [2:0] RESULT_UNSTABLE = 3'd2;
localparam [2:0] RESULT_NOT_GB   = 3'd3;
localparam [2:0] RESULT_NO_POWER = 3'd4;

cart_identify_gb dut (
    .clk (clk), .reset (reset), .gb_mode (gb_mode),
    .start (start), .busy (busy), .done (done),
    .cart_req (id_req), .cart_wr (id_wr), .cart_addr (id_addr),
    .cart_wdata (id_wdata), .cart_rdata (bus_rdata),
    .cart_done (bus_done), .cart_busy (bus_busy),
    .result (result), .title (title), .cgb_flag (cgb_flag),
    .cart_type (cart_type), .rom_size_code (rom_size_code),
    .ram_size_code (ram_size_code), .sw_version (sw_version),
    .checksum_ok (checksum_ok), .raw_bytes (raw_bytes),
    .checksum_read (checksum_read), .checksum_calc (checksum_calc)
);

wire [15:0] e_ad_out;
wire        e_ad_oe;
wire [7:0]  e_hi_out;
wire        e_hi_oe;
wire [3:0]  e_ctl_out;
wire        e_p30_out, e_p30_oe;
wire [7:0]  e_hi_in;

gb_cart_bus bus (
    .clk (clk), .reset (reset), .gb_mode (gb_mode),
    .req (id_req), .wr (id_wr), .addr (id_addr), .wdata (id_wdata),
    .rdata (bus_rdata), .done (bus_done), .busy (bus_busy),
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

gb_cart_model #(.CONTENTION_FATAL(1)) cart (
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
integer reads_at_start;

task expect8(input [255:0] what, input [7:0] got, input [7:0] want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %02x, expected %02x", what, got, want);
            errors = errors + 1;
        end
    end
endtask

task expect3(input [255:0] what, input [2:0] got, input [2:0] want);
    begin
        if (got !== want) begin
            $display("ERROR: %0s = %0d, expected %0d", what, got, want);
            errors = errors + 1;
        end
    end
endtask

// A real header. Checksum 0x0D computed in Python, not here, so an error in
// the module's arithmetic cannot agree with an error in the fixture.
task load_good;
    begin
        for (i = 0; i < 32768; i = i + 1) cart.rom[i] = 8'h00;
        cart.rom[16'h0134] = "T"; cart.rom[16'h0135] = "E";
        cart.rom[16'h0136] = "S"; cart.rom[16'h0137] = "T";
        cart.rom[16'h0138] = "C"; cart.rom[16'h0139] = "A";
        cart.rom[16'h013A] = "R"; cart.rom[16'h013B] = "T";
        cart.rom[16'h0143] = 8'hC0;    // CGB only
        cart.rom[16'h0144] = "0"; cart.rom[16'h0145] = "1";
        cart.rom[16'h0147] = 8'h13;    // MBC3 + RAM + BATTERY
        cart.rom[16'h0148] = 8'h05;    // 1 MiB
        cart.rom[16'h0149] = 8'h03;    // 32 KiB
        cart.rom[16'h014A] = 8'h01; cart.rom[16'h014B] = 8'h33;
        cart.rom[16'h014D] = 8'h0D;
    end
endtask

task fill(input [7:0] v);
    begin
        for (i = 0; i < 32768; i = i + 1) cart.rom[i] = v;
    end
endtask

task identify;
    begin
        @(negedge clk);
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

    // ---- 1. Refuses to touch a bus that is not there ---------------------
    gb_mode = 1'b0;
    load_good();
    identify();
    expect3("no power: result", result, RESULT_NO_POWER);
    if (rom_read_count != 0) begin
        $display("ERROR: issued %0d reads with gb_mode low", rom_read_count);
        errors = errors + 1;
    end

    gb_mode = 1'b1;
    repeat (4) @(negedge clk);

    // ---- 2. A good cartridge ---------------------------------------------
    identify();
    expect3("good: result", result, RESULT_GB);
    expect8("good: checksum stored", checksum_read, 8'h0D);
    expect8("good: checksum computed", checksum_calc, 8'h0D);
    expect8("good: cart type", cart_type, 8'h13);
    expect8("good: rom size", rom_size_code, 8'h05);
    expect8("good: ram size", ram_size_code, 8'h03);
    expect8("good: cgb flag", cgb_flag, 8'hC0);
    if (checksum_ok !== 1'b1) begin
        $display("ERROR: good header reported a bad checksum");
        errors = errors + 1;
    end
    if (title[119:112] !== "T" || title[111:104] !== "E" ||
        title[103:96]  !== "S" || title[95:88]   !== "T") begin
        $display("ERROR: title starts %s, expected TEST", title[119:88]);
        errors = errors + 1;
    end
    // 26 bytes, twice.
    if (rom_read_count != 52) begin
        $display("ERROR: %0d reads for one identification, expected 52", rom_read_count);
        errors = errors + 1;
    end

    // ---- 3. An empty slot -------------------------------------------------
    fill(8'hFF);
    identify();
    expect3("all ones: result", result, RESULT_NO_CART);

    fill(8'h00);
    identify();
    expect3("all zeros: result", result, RESULT_NO_CART);

    // ---- 4. Present, stable, wrong checksum -------------------------------
    load_good();
    cart.rom[16'h0134] = "U";       // one byte of the title moves
    identify();
    expect3("bad checksum: result", result, RESULT_NOT_GB);
    if (checksum_ok !== 1'b0) begin
        $display("ERROR: corrupt header reported a good checksum");
        errors = errors + 1;
    end

    // ---- 5. A marginal cartridge, answering differently the second time ----
    //
    // The header is only checksummed on the first pass, so a cartridge whose
    // second pass disagrees still has a valid checksum behind it. Anything
    // that judged one pass would call this good and report a title it read
    // once.
    load_good();
    begin
        reads_at_start = rom_read_count;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        // 26 reads in, the check pass is about to start.
        wait (rom_read_count == reads_at_start + 26);
        cart.rom[16'h0139] = "X";
        wait (done == 1'b1);
        @(negedge clk);
    end
    expect3("unstable: result", result, RESULT_UNSTABLE);

    // ---- 6. Safety properties held for every read above --------------------
    if (cs_during_rom_read) begin
        $display("ERROR: /CS was asserted during a ROM read");
        errors = errors + 1;
    end
    if (contention_seen) begin
        $display("ERROR: the cartridge model saw contention");
        errors = errors + 1;
    end
    if (last_write_addr !== 16'h0000 || last_write_data !== 8'h00) begin
        $display("ERROR: identification wrote to the cartridge at %04x",
                 last_write_addr);
        errors = errors + 1;
    end

    if (errors != 0) begin
        $display("tb_cart_identify_gb: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_cart_identify_gb");
    $finish;
end

initial begin
    #100000000;
    $display("ERROR: tb_cart_identify_gb watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
