// SOURCES: src/fpga/services/dump/cart_save_gb.sv
//
// tb_cart_save_gb.sv - reading a save, and refusing to read the ones it cannot
//
// The bus is stubbed and the mapper modelled here, because what needs proving
// is the reader's own behaviour: that it opens the gate before it reads and
// shuts it after, that it reads the right window in order, that it never
// writes the bank register, that it says whether the RAM actually answered,
// and that it refuses the cartridges no hardware here could verify.
//
// tb_gb_save_write_protect covers the safety invariant through the real bus
// and the real pins. This file covers everything else.
//
// The RAM content is a function of the offset, so an off-by-one in the address
// cannot pass: reading offset 100 while asking for 99 yields a byte that
// belongs somewhere else and the check fails on the first one.
//
`default_nettype none
`timescale 1ns/1ps

module tb_cart_save_gb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg [7:0] cart_type = 8'h03;
reg [7:0] ram_size_code = 8'h02;

wire        supported, busy, done;
wire [31:0] total_bytes;
wire        responded, blank_ff, blank_00;
wire        bus_req, bus_wr;
wire [15:0] bus_addr;
wire [7:0]  bus_wdata;
reg  [7:0]  bus_rdata = 8'd0;
reg         bus_done = 1'b0;
wire [7:0]  out_data;
wire        out_valid;
reg         out_ready = 1'b1;

cart_save_gb dut (
    .clk (clk), .reset (reset),
    .start (start), .abort (abort),
    .cart_type (cart_type), .ram_size_code (ram_size_code),
    .supported (supported),
    .busy (busy), .done (done), .total_bytes (total_bytes),
    .responded (responded), .blank_ff (blank_ff), .blank_00 (blank_00),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_wdata (bus_wdata), .bus_rdata (bus_rdata), .bus_done (bus_done),
    .out_data (out_data), .out_valid (out_valid), .out_ready (out_ready)
);

integer errors = 0;

initial begin
    #20_000_000;
    $fatal(1, "%m: watchdog expired at %0t with busy=%b", $time, busy);
end

// ---- The cartridge ---------------------------------------------------------

// What the save holds. A function of the bank as well as the offset, so a
// bank that is never selected cannot pass: reading bank 3 while the mapper
// still points at bank 0 yields bytes that belong somewhere else and the
// check fails on the first one.
function [7:0] content(input [4:0] bk, input [12:0] off);
    content = off[7:0] ^ {3'd0, off[12:8]} ^ 8'h5A ^ {bk, 3'd0};
endfunction

reg        ram_enabled  = 1'b0;
reg        mode1        = 1'b0;    // as a cartridge comes up
reg [4:0]  cur_bank     = 5'd0;
reg        left_mode1   = 1'b0;    // the run ended with MBC1 still in mode 1
reg        is_mbc1_cart = 1'b1;
reg [31:0] rtc_writes   = 32'd0;   // 0x08-0x0C to 0x4000: the MBC3 hazard
reg [31:0] ram_writes   = 32'd0;
reg [31:0] bank_writes  = 32'd0;   // writes to 0x4000-0x5FFF, the RTC hazard
reg [31:0] enable_ons   = 32'd0;
reg [31:0] enable_offs  = 32'd0;
reg        read_shut    = 1'b0;    // a RAM read happened with the gate closed
reg        read_open    = 1'b0;
reg        blank_mode   = 1'b0;    // make the whole RAM read 0xFF
reg        dead_gate    = 1'b0;    // ignore the enable, as a bad contact would

// One transaction per request, answered on the next cycle. The gate, the
// windows and the open-bus value are all modelled because each of them is
// something the reader can get wrong.
always @(posedge clk) begin
    bus_done <= 1'b0;
    if (bus_req && !bus_done) begin
        if (bus_wr) begin
            if (bus_addr < 16'h2000) begin
                if (bus_wdata[3:0] == 4'hA) begin
                    if (!dead_gate) ram_enabled <= 1'b1;
                    enable_ons <= enable_ons + 1;
                end else begin
                    ram_enabled <= 1'b0;
                    enable_offs <= enable_offs + 1;
                end
            end else if (bus_addr >= 16'h4000 && bus_addr < 16'h6000) begin
                bank_writes <= bank_writes + 1;
                if (bus_wdata >= 8'h08 && bus_wdata <= 8'h0C)
                    rtc_writes <= rtc_writes + 1;
                cur_bank <= bus_wdata[4:0];
            end else if (bus_addr >= 16'h6000 && bus_addr < 16'h8000) begin
                mode1 <= bus_wdata[0];
            end else if (bus_addr >= 16'hA000 && bus_addr < 16'hC000) begin
                ram_writes <= ram_writes + 1;
            end
        end else begin
            if (bus_addr >= 16'hA000 && bus_addr < 16'hC000) begin
                if (ram_enabled) begin
                    read_open <= 1'b1;
                    bus_rdata <= blank_mode
                        ? 8'hFF
                        : content((is_mbc1_cart && !mode1) ? 5'd0 : cur_bank,
                                  bus_addr[12:0]);
                end else begin
                    read_shut <= 1'b1;
                    bus_rdata <= 8'hFF;      // open bus
                end
            end else begin
                bus_rdata <= 8'hFF;
            end
        end
        bus_done <= 1'b1;
    end
end

// ---- Capturing the stream --------------------------------------------------

reg [7:0]  got [0:32767];
integer    n_out = 0;

always @(posedge clk) begin
    if (out_valid && out_ready) begin
        if (n_out < 32768) got[n_out] = out_data;
        n_out = n_out + 1;
    end
end

// ---- Checks ----------------------------------------------------------------

task expect_int(input integer got_v, input integer want, input [255:0] what);
begin
    if (got_v !== want) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got_v, want);
        errors = errors + 1;
    end
end
endtask

task expect_bit(input got_v, input want, input [255:0] what);
begin
    if (got_v !== want) begin
        $display("ERROR: %0s = %b, expected %b", what, got_v, want);
        errors = errors + 1;
    end
end
endtask

task reset_model;
begin
    ram_enabled = 1'b0;
    mode1       = 1'b0;
    cur_bank    = 5'd0;
    rtc_writes  = 32'd0;
    left_mode1  = 1'b0;
    ram_writes  = 32'd0;
    bank_writes = 32'd0;
    enable_ons  = 32'd0;
    enable_offs = 32'd0;
    read_shut   = 1'b0;
    read_open   = 1'b0;
    n_out       = 0;
end
endtask

task run;
begin
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done == 1'b1);
    left_mode1 = mode1;
    @(negedge clk);
end
endtask

integer i;
integer bad;

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    // ---- 1. What this cartridge is, before anything is started -------------
    //
    // supported is combinational so core_top can gate the button on it. A
    // cartridge whose save cannot be read must say so before a button press,
    // not after a file has been opened.
    expect_bit(supported, 1'b1, "MBC1 + 8 KB supported");
    expect_int(total_bytes, 8192, "8 KB total_bytes");

    ram_size_code = 8'h01;  #1;
    expect_bit(supported, 1'b1, "2 KB supported");
    expect_int(total_bytes, 2048, "2 KB total_bytes");

    // 32 KB, four banks. MBC1 reaches it with two bits at 0x4000, and needs
    // mode 1 to make those bits mean a RAM bank at all.
    ram_size_code = 8'h03;  #1;
    expect_bit(supported, 1'b1, "MBC1 + 32 KB supported");
    expect_int(total_bytes, 32768, "32 KB total_bytes");

    // Above 32 KB is MBC5 territory: MBC1 and MBC3 have no bits for it. A
    // size a mapper cannot address is refused, not truncated to one it can -
    // a 128 KB file holding the low four banks four times over would pass
    // every check there is.
    ram_size_code = 8'h05;  #1;
    expect_bit(supported, 1'b0, "MBC1 + 64 KB refused");
    ram_size_code = 8'h04;  #1;
    expect_bit(supported, 1'b0, "MBC1 + 128 KB refused");

    cart_type = 8'h1B;                 // MBC5 + RAM + battery
    ram_size_code = 8'h05;  #1;
    expect_bit(supported, 1'b1, "MBC5 + 64 KB supported");
    expect_int(total_bytes, 65536, "64 KB total_bytes");
    ram_size_code = 8'h04;  #1;
    expect_bit(supported, 1'b1, "MBC5 + 128 KB supported");
    expect_int(total_bytes, 131072, "128 KB total_bytes");
    cart_type = 8'h03;

    // No RAM at all.
    ram_size_code = 8'h00;  #1;
    expect_bit(supported, 1'b0, "no RAM refused");

    // MBC2 keeps 512 nibbles inside the mapper and reports 0x00 here, so the
    // size byte cannot be trusted for it and the type has to be checked too.
    cart_type = 8'h06;  ram_size_code = 8'h02;  #1;
    expect_bit(supported, 1'b0, "MBC2 refused even with a plausible size byte");

    // MBC3 is allowed up to 32 KB. Its hazard is that 0x08-0x0C written to
    // the bank register maps the clock over the RAM window; this reader
    // writes only 0x00-0x03 there, which the banked case below asserts.
    cart_type = 8'h13;  ram_size_code = 8'h02;  #1;
    expect_bit(supported, 1'b1, "MBC3 + 8 KB supported");
    ram_size_code = 8'h03;  #1;
    expect_bit(supported, 1'b1, "MBC3 + 32 KB supported");
    ram_size_code = 8'h05;  #1;
    expect_bit(supported, 1'b0, "MBC3 + 64 KB refused");
    ram_size_code = 8'h02;

    // ---- 2. A whole 8 KB save, MBC1 ----------------------------------------
    cart_type = 8'h03;  ram_size_code = 8'h02;
    reset_model;
    run;

    expect_int(n_out, 8192, "bytes emitted");
    bad = 0;
    for (i = 0; i < 8192; i = i + 1)
        if (got[i] !== content(5'd0, i[12:0])) begin
            if (bad < 4)
                $display("ERROR: byte %0d = %02h, expected %02h",
                         i, got[i], content(5'd0, i[12:0]));
            bad = bad + 1;
        end
    if (bad != 0) begin
        $display("ERROR: %0d bytes wrong", bad);
        errors = errors + 1;
    end

    // The gate opened once and shut once, and it is shut now.
    expect_int(enable_ons, 1, "RAM enables issued");
    expect_int(enable_offs, 1, "RAM disables issued");
    expect_bit(ram_enabled, 1'b0, "gate left open");

    // Not one byte written into the window, and the bank register never
    // touched. The second is what keeps MBC3's RTC out of a save file.
    expect_int(ram_writes, 0, "writes into the RAM window");
    expect_int(bank_writes, 0, "writes to the bank register");

    // MBC1's mode register was set to 0. In mode 1 the 0x4000 bits select a
    // RAM bank instead of extending the ROM bank, so a cartridge left in mode
    // 1 by something else would hand back a bank this reader never asked for.
    expect_bit(left_mode1, 1'b0, "MBC1 left in mode 1");

    // Both passes happened: the probe read with the gate shut, the data pass
    // with it open. Without the first there is nothing to compare against and
    // "the RAM answered" would be an assumption.
    expect_bit(read_shut, 1'b1, "the disabled pass ran");
    expect_bit(read_open, 1'b1, "the enabled pass ran");
    expect_bit(responded, 1'b1, "RAM answered");
    expect_bit(blank_ff, 1'b0, "reported blank on real data");
    expect_bit(blank_00, 1'b0, "reported zeroed on real data");

    // The first four bytes, which is what the screen shows as raw evidence.
    // Checked after a second run as well, because it is a shift register and
    // a version that cleared it only on reset showed run 1's bytes shifted
    // out by run 2's.
    if (dut.first_word !== {content(5'd0, 13'd0), content(5'd0, 13'd1),
                            content(5'd0, 13'd2), content(5'd0, 13'd3)}) begin
        $display("ERROR: first_word = %08h", dut.first_word);
        errors = errors + 1;
    end
    reset_model;
    run;
    if (dut.first_word !== {content(5'd0, 13'd0), content(5'd0, 13'd1),
                            content(5'd0, 13'd2), content(5'd0, 13'd3)}) begin
        $display("ERROR: first_word after a second run = %08h", dut.first_word);
        errors = errors + 1;
    end

    // ---- 3. 2 KB reads 2 KB, not 8 ------------------------------------------
    ram_size_code = 8'h01;
    reset_model;
    run;
    expect_int(n_out, 2048, "2 KB bytes emitted");
    expect_int(enable_offs, 1, "2 KB run still shuts the gate");
    ram_size_code = 8'h02;

    // ---- 3b. 32 KB across four banks ---------------------------------------
    //
    // This is the case the first hardware attempt hit: Link's Awakening DX is
    // MBC5 + RAM + battery with 32 KB of save RAM, and the reader refused it.
    // The model's content depends on the bank, so a missing bank select gives
    // bank 0 four times and fails on the first byte of bank 1.
    cart_type     = 8'h1B;      // MBC5 + RAM + battery
    is_mbc1_cart  = 1'b0;
    ram_size_code = 8'h03;
    reset_model;
    run;
    expect_int(n_out, 32768, "32 KB bytes emitted");
    bad = 0;
    for (i = 0; i < 32768; i = i + 1)
        if (got[i] !== content(i[17:13], i[12:0])) begin
            if (bad < 4)
                $display("ERROR: 32 KB byte %0d (bank %0d off %0d) = %02h, expected %02h",
                         i, i[17:13], i[12:0], got[i], content(i[17:13], i[12:0]));
            bad = bad + 1;
        end
    if (bad != 0) begin
        $display("ERROR: %0d bytes wrong across four banks", bad);
        errors = errors + 1;
    end
    // Four writes, not three: bank 0 is selected explicitly rather than
    // assumed. The register survives whatever ran before this - another tool,
    // a game, an aborted read - and starting a save by trusting its power-on
    // value would put bank 3's contents at the head of the file with nothing
    // to show it had happened.
    expect_int(bank_writes, 4, "bank selects, 4 banks");
    expect_int(enable_offs, 1, "the gate still shuts after four banks");
    expect_int(ram_writes, 0, "writes into the window across four banks");

    // ---- 3c. MBC1's mode trap ----------------------------------------------
    //
    // Same 32 KB, on MBC1. In mode 0 the two bits at 0x4000 extend the ROM
    // bank instead of selecting a RAM bank, so the model returns bank 0
    // whatever is written there. Reading this correctly requires mode 1, and
    // leaving the cartridge in mode 1 would make the next ROM dump bank
    // wrongly - so both halves are checked.
    cart_type    = 8'h03;
    is_mbc1_cart = 1'b1;
    reset_model;
    run;
    expect_int(n_out, 32768, "MBC1 32 KB bytes emitted");
    bad = 0;
    for (i = 0; i < 32768; i = i + 1)
        if (got[i] !== content(i[17:13], i[12:0])) bad = bad + 1;
    if (bad != 0) begin
        $display("ERROR: %0d bytes wrong on MBC1 across four banks", bad);
        $display("       mode 1 is what makes 0x4000 mean a RAM bank");
        errors = errors + 1;
    end
    expect_bit(left_mode1, 1'b0, "MBC1 left in mode 1 after a banked read");

    // ---- 3d. MBC3 never maps its clock over the RAM window -----------------
    //
    // 0x08-0x0C written to the bank register replaces the RAM with the RTC
    // registers, and reading those and filing them as save data is a bug this
    // prevents rather than a feature it adds. Four banks means values 0 to 3
    // and nothing else.
    cart_type    = 8'h13;       // MBC3 + RAM + battery
    is_mbc1_cart = 1'b0;
    reset_model;
    run;
    expect_int(n_out, 32768, "MBC3 32 KB bytes emitted");
    expect_int(rtc_writes, 0, "RTC register selects written");

    cart_type     = 8'h03;
    is_mbc1_cart  = 1'b1;
    ram_size_code = 8'h02;

    // ---- 4. The blank-file trap ---------------------------------------------
    //
    // This is the case the whole presence probe exists for. If the enable
    // does not take - a dirty contact on the write strobe would do it - every
    // read returns open bus and the result is 8 KB of 0xFF that looks exactly
    // like a successful backup of a cartridge with a dead battery.
    //
    // The disabled pass and the enabled pass then return identical bytes, and
    // that, not the 0xFF, is what says the RAM never answered.
    dead_gate = 1'b1;
    reset_model;
    run;
    expect_int(n_out, 8192, "bytes emitted with a dead gate");
    expect_bit(responded, 1'b0, "claimed the RAM answered when it did not");
    expect_bit(blank_ff, 1'b1, "did not notice an all-FF image");
    dead_gate = 1'b0;

    // A genuinely blank save, with the gate working. Same 0xFF image, but the
    // two passes differ because the disabled pass reads open bus and the
    // enabled pass reads RAM - here they happen to be the same value, so this
    // case is honestly indistinguishable and is reported as not responding.
    // Stated rather than hidden: a dead battery and a dead enable look alike
    // from outside, and the screen shows both facts rather than a verdict.
    blank_mode = 1'b1;
    reset_model;
    run;
    expect_bit(blank_ff, 1'b1, "did not notice a blank save");
    expect_bit(blank_00, 1'b0, "called an all-FF save all-00");
    blank_mode = 1'b0;

    // ---- 5. An abort still shuts the gate -----------------------------------
    //
    // Losing the slot part way through is the one failure this module can be
    // asked to survive. An abort that left the RAM enabled would send the
    // cartridge out of the slot with its write gate open, which is worse than
    // any file it failed to write.
    reset_model;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (n_out > 300);          // well into the data pass
    abort = 1'b1;
    wait (done == 1'b1);
    abort = 1'b0;
    @(negedge clk);

    expect_bit(ram_enabled, 1'b0, "gate left open after an abort");
    expect_int(enable_offs, 1, "disables issued on the abort path");
    expect_int(ram_writes, 0, "writes into the window on the abort path");
    if (n_out >= 8192) begin
        $display("ERROR: the abort read the whole save anyway (%0d bytes)", n_out);
        errors = errors + 1;
    end
    // The presence verdict survives the abort, because it is complete after
    // 256 bytes and the abort happened later.
    expect_bit(responded, 1'b1, "lost the presence verdict on abort");

    // ---- 6. Back-to-back runs --------------------------------------------
    // A stale abort must not cut the next run short.
    reset_model;
    run;
    expect_int(n_out, 8192, "bytes emitted on the run after an abort");

    if (errors == 0) $display("TB PASS: tb_cart_save_gb");
    else begin
        $display("tb_cart_save_gb: %0d checks failed", errors);
        $fatal(1, "failed");
    end
    $finish;
end

endmodule

`default_nettype wire
