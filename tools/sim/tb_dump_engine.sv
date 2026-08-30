// SOURCES: src/fpga/services/dump/dump_engine.sv src/fpga/services/dump/dump_buffer.sv src/fpga/services/dump/dump_path_gen.sv src/fpga/services/dump/dump_chunk_src.sv src/fpga/services/dump/dump_checksum.sv src/fpga/services/dump/apf_file_writer.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_dump_gba.sv src/fpga/services/dump/cart_save_gb.sv src/fpga/services/dump/dump_crc32.sv src/fpga/apf/common.v
//
// tb_dump_engine.sv - a whole file, end to end, through both clock domains
//
// This is the testbench the dumper is for. Everything else checks a piece;
// this one reads a modelled cartridge, crosses the payload into the bridge
// domain, answers the target commands the way APF does, reassembles the file
// the way a little endian host would, and compares it byte for byte with what
// was on the cartridge. If it passes, the only things left that simulation
// cannot reach are the real bus timing and APF's actual behaviour.
//
// HOW THE HOST IS MODELLED, and why that is the interesting part
// --------------------------------------------------------------
// io_bridge_peripheral.v sends spis_word MSB first, and spis_word is
// bridge_rd_data byte reversed when the host declares little endian. So:
//
//   V, the 32-bit value the host assembles = bridge_rd_data reversed
//   the host stores it with a native word store, so file[n+0] = V[7:0]
//
// which is what the two lines in read_chunk do. That chain is the reason
// byte_order exists at all, and it is why one of the cases below deliberately
// runs with the wrong setting: the file it produces, 03 02 01 00 07 06 05 04,
// is the exact signature to look for in a hex editor after the first hardware
// dump. Seeing it means flipping one runtime toggle, not another Quartus run.
//
`default_nettype none
`timescale 1ns/1ps

module tb_dump_engine;

localparam integer CHUNK = 256;

reg clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;               // 100 MHz

reg clk_74a = 1'b0;
always #6.734 clk_74a = ~clk_74a;           // 74.25 MHz, unrelated

reg reset_sys = 1'b1;
reg reset_74a = 1'b1;

reg         start = 1'b0;
reg         selftest = 1'b0;
reg         save_mode = 1'b0;
reg  [7:0]  ram_size_code = 8'h00;
reg         byte_order = 1'b1;
reg  [2:0]  path_style = 3'd0;
wire [2:0]  used_style;
wire        used_order;
wire [7:0]  tries;
wire        no_open;
wire        sum_checked, sum_ok;
wire [15:0] sum_computed, sum_stored;
wire [15:0] dbg_reads, dbg_struct_reads;
wire [31:0] dbg_last_addr;
reg [119:0] title = "TESTCART       ";
reg [7:0]   cart_type = 8'h19;
reg [1:0]   cart_kind = 2'd0;   // 0 gb, 1 gbc, 2 gba, 3 save
reg [7:0]   rom_size_code = 8'd0;

wire        busy, done, failed;
wire [2:0]  err;
wire [15:0] fail_chunk, chunks_done, chunks_total;
wire [31:0] total_bytes;
wire [31:0] crc32;
wire [1:0]  want_mode;
reg         mode_ready = 1'b1;
reg         cart_powered = 1'b1;

// Which reader this dump uses, and the size the probe measured. Both are set
// before run_dump and latched by the engine at start, exactly as a caller
// must hold them.
reg         plat_gba = 1'b0;
reg [31:0]  gba_size = 32'd0;

wire        bus_req, bus_wr;
wire [15:0] bus_addr;
wire [7:0]  bus_wdata;
reg  [7:0]  bus_rdata = 8'd0;
reg         bus_done = 1'b0;
reg         bus_busy = 1'b0;

wire        gba_req, gba_wr;
wire [27:0] gba_addr;
wire [1:0]  gba_acc;
wire [31:0] gba_wdata;
reg  [31:0] gba_rdata = 32'd0;
reg         gba_done = 1'b0;
reg         gba_busy = 1'b0;

reg  [31:0] bridge_addr = 32'd0;
reg         bridge_rd = 1'b0;
reg         bridge_endian_little = 1'b1;
wire [31:0] bridge_rd_data;
wire        bridge_rd_hit;

wire        t_write, t_openfile, t_flush;
wire [15:0] t_id;
wire [31:0] t_slotoffset, t_bridgeaddr, t_length, t_param_struct;
reg         t_done = 1'b0;
reg  [2:0]  t_err = 3'd0;

dump_engine #(
    .SLOT_ID     (16'd20),
    .BUF_BASE    (32'h6000_0000),
    .STRUCT_BASE (32'h7000_0000),
    .CHUNK_BYTES (CHUNK),
    .BUF_WORDS   (CHUNK/4),
    .BUF_AW      (6),
    .WAKE_CYCLES (8),
    // Deliberately not a multiple of the chunk, and its tail deliberately not
    // a multiple of four: 302 bytes is one full chunk, then 46, which is
    // eleven whole bridge words and a partial one. A cartridge size can never
    // produce either, so this is the only place they get exercised.
    .SELFTEST_BYTES (302)
) dut (
    .clk_sys (clk_sys), .reset_sys (reset_sys),
    .start (start), .selftest (selftest), .save_mode (save_mode),
    .ram_size_code (ram_size_code),
    .byte_order (byte_order),
    .path_style (path_style),
    .used_style (used_style), .used_order (used_order), .tries (tries),
    .no_open (no_open),
    .sum_checked (sum_checked), .sum_ok (sum_ok),
    .sum_computed (sum_computed), .sum_stored (sum_stored),
    .dbg_reads (dbg_reads), .dbg_struct_reads (dbg_struct_reads),
    .dbg_last_addr (dbg_last_addr),
    .title (title), .cart_kind (cart_kind),
    .cart_type (cart_type), .rom_size_code (rom_size_code),
    .platform_gba (plat_gba), .gba_size_bytes (gba_size),
    .crc32 (crc32),
    .busy (busy), .done (done), .failed (failed), .err (err),
    .fail_chunk (fail_chunk), .chunks_done (chunks_done),
    .chunks_total (chunks_total), .total_bytes (total_bytes),
    .want_mode (want_mode), .mode_ready (mode_ready),
    .cart_powered (cart_powered),
    .bus_req (bus_req), .bus_wr (bus_wr), .bus_addr (bus_addr),
    .bus_wdata (bus_wdata), .bus_rdata (bus_rdata), .bus_done (bus_done),
    .bus_busy (bus_busy),
    .gba_req (gba_req), .gba_wr (gba_wr), .gba_addr (gba_addr),
    .gba_acc (gba_acc), .gba_wdata (gba_wdata), .gba_rdata (gba_rdata),
    .gba_done (gba_done), .gba_busy (gba_busy),
    .clk_74a (clk_74a), .reset_74a (reset_74a),
    .bridge_addr (bridge_addr), .bridge_rd (bridge_rd),
    .bridge_endian_little (bridge_endian_little),
    .bridge_rd_data (bridge_rd_data), .bridge_rd_hit (bridge_rd_hit),
    .target_dataslot_write      (t_write),
    .target_dataslot_openfile   (t_openfile),
    .target_dataslot_flush      (t_flush),
    .target_dataslot_id         (t_id),
    .target_dataslot_slotoffset (t_slotoffset),
    .target_dataslot_bridgeaddr (t_bridgeaddr),
    .target_dataslot_length     (t_length),
    .target_buffer_param_struct (t_param_struct),
    .target_dataslot_done       (t_done),
    .target_dataslot_err        (t_err)
);

integer errors = 0;

// ---------------------------------------------------------------------------
// The one thing here that can damage a cartridge.
//
// Dropping want_gb changes the connector mode, and cart_pins honours it
// immediately: /WR rises and the data pins release on the same edge, which is
// the edge a cartridge latches a mapper register on. So want_gb must never
// fall while the bus is mid-transaction, and this watches for it continuously
// rather than at a chosen moment, because the dangerous window is one cycle
// wide and an abort can land anywhere.
// ---------------------------------------------------------------------------
integer mode_violations = 0;
reg [1:0] want_mode_d = 2'b00;
always @(posedge clk_sys) begin
    want_mode_d <= want_mode;
    // Either mode leaving while the engine it selects is mid-transaction. The
    // GB half is the one that can damage a cartridge; the GBA half is here so
    // that the two paths are held to the same rule rather than one of them
    // being trusted because its consequences are milder.
    if (want_mode_d !== want_mode &&
        ((want_mode_d == 2'b10 && bus_busy) ||
         (want_mode_d == 2'b01 && gba_busy))) begin
        mode_violations = mode_violations + 1;
        $display("ERROR: want_mode left %b at %0t with the bus mid-transaction",
                 want_mode_d, $time);
    end
end

// ---------------------------------------------------------------------------
// The cartridge. Content is a function of the linear address so a banking
// mistake shows up as a wrong byte rather than as plausible looking data.
// ---------------------------------------------------------------------------
function [7:0] content(input [23:0] lin);
    content = lin[7:0] ^ lin[15:8] ^ {4'd0, lin[19:16]};
endfunction

reg [8:0] cur_bank = 9'd1;
reg       mbc5_hi = 1'b0;
integer   n_bus_writes = 0;

// The save RAM and its gate. A cartridge answers in 0xA000-0xBFFF only after
// 0x0A has been written to 0x0000-0x1FFF, and reads open bus until then, so a
// reader that forgot to open the gate would otherwise pass its own test with
// 8 KB of 0xFF - the blank-file trap in docs/GB-SAVE-PLAN.md.
reg       ram_enabled = 1'b0;
integer   n_ram_writes = 0;

function [7:0] save_content(input [12:0] off);
    save_content = off[7:0] ^ {3'd0, off[12:8]} ^ 8'hC3;
endfunction

// How long a bus transaction takes. Raised for the abort test so that an
// abort lands while one is genuinely in flight: at the default three cycles
// the transaction always finishes before the abort has crossed into the
// bridge domain and back, so the dangerous window is never reached and a
// monitor watching for it would pass whether the fix were present or not.
integer   bus_delay = 3;

function [8:0] eff_bank(input [15:0] a);
    begin
        if (a < 16'h4000) eff_bank = 9'd0;
        else              eff_bank = cur_bank;
    end
endfunction

// bus_busy models gb_cart_bus: high for the whole transaction, and the thing
// the mode must not change underneath. See gb_cart_bus.sv.
always @(posedge clk_sys) begin
    bus_done <= 1'b0;
    if (bus_req) begin
        bus_busy <= 1'b1;
        repeat (bus_delay) @(posedge clk_sys);
        if (bus_wr) begin
            n_bus_writes = n_bus_writes + 1;
            if (bus_addr < 16'h2000)       ram_enabled <= (bus_wdata[3:0] == 4'hA);
            else if (bus_addr == 16'h2000) cur_bank <= {mbc5_hi, bus_wdata};
            else if (bus_addr == 16'h3000) begin
                mbc5_hi  <= bus_wdata[0];
                cur_bank <= {bus_wdata[0], cur_bank[7:0]};
            end
            else if (bus_addr >= 16'hA000 && bus_addr < 16'hC000)
                n_ram_writes = n_ram_writes + 1;
        end else if (bus_addr >= 16'hA000 && bus_addr < 16'hC000) begin
            bus_rdata <= ram_enabled ? save_content(bus_addr[12:0]) : 8'hFF;
        end else begin
            bus_rdata <= content({eff_bank(bus_addr), bus_addr[13:0]});
        end
        bus_done <= 1'b1;
        @(posedge clk_sys);
        bus_busy <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// The GBA side of the connector.
//
// Not the real gba_cart_bus: this testbench is about the engine, the clock
// crossing and the file, and tb_cart_dump_gba already drives the real bus, the
// real pins and a cartridge model at shipped timings. What is modelled here is
// only the handshake shape the reader has to obey - busy for the whole
// transaction, req sampled once, done at the end - plus the two claims the
// engine depends on: 32-bit accesses, and a ROM that never sees a write.
//
// The content is the same function of the linear address the GB cartridge
// uses, so the file check at the end is the same check.
// ---------------------------------------------------------------------------
integer n_gba_reads = 0;

// What the engine actually asked the connector for while it was running. The
// mode is the thing that decides which engine owns the pins, so a dump that
// read the right bytes through the wrong mode request would be a core that
// works in simulation and drives a GB cartridge with GBA timings on hardware.
reg [1:0] mode_seen = 2'b00;
always @(posedge clk_sys)
    if (busy && want_mode != 2'b00) mode_seen <= want_mode;

always @(posedge clk_sys) begin
    gba_done <= 1'b0;
    if (gba_req) begin
        if (gba_wr !== 1'b0) begin
            $display("ERROR: the GBA reader asserted wr at %0t", $time);
            errors = errors + 1;
        end
        // ACCESS_8BIT is 2'b00 and ACCESS_16BIT is 2'b01, so a 32-bit access
        // is anything else. The reader has to ask for one: two 16-bit reads
        // would cost a second address phase per word and would restart the
        // cartridge's internal counter every halfword.
        if (gba_acc === 2'b00 || gba_acc === 2'b01) begin
            $display("ERROR: the GBA reader asked for acc %b, not a 32-bit access",
                     gba_acc);
            errors = errors + 1;
        end
        gba_busy <= 1'b1;
        repeat (bus_delay) @(posedge clk_sys);
        gba_rdata <= {content({4'd0, gba_addr[23:0]} + 24'd3),
                      content({4'd0, gba_addr[23:0]} + 24'd2),
                      content({4'd0, gba_addr[23:0]} + 24'd1),
                      content({4'd0, gba_addr[23:0]})};
        n_gba_reads = n_gba_reads + 1;
        gba_done <= 1'b1;
        @(posedge clk_sys);
        gba_busy <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// The host side of the bridge
// ---------------------------------------------------------------------------
reg [7:0]  fdata [0:65535];
integer    fsize = 0;
reg [7:0]  pathbuf [0:263];

integer n_open = 0, n_write = 0, n_flush = 0;
reg [2:0] next_open_err = 3'd0;
reg [2:0] next_write_err = 3'd0;

// Which path this modelled APF will accept. -1 means any. Anything else is
// the one path style whose first character matches; every other open is
// refused with 4, malformed path, exactly as the real one did.
integer accept_style = -1;

// io_bridge_peripheral.v plus the host's own pipelining, reproduced. Both
// halves matter and the testbench has now had each one wrong in turn.
//
// The peripheral holds the address from the SPI phase, spends four clocks,
// samples the core's bridge_rd_data, and only then pulses bridge_rd. So a
// core that waits for bridge_rd to start looking answers too late.
//
// And the value the host keeps is the one presented during the PREVIOUS
// transaction, which is what core_bridge_cmd.v has always done with the
// datatable and what APF is driven against. So a core that answers the
// address currently on the bus answers one word early.
//
// The first version of this task idealised it as request-then-respond and
// passed a design that could not work. The second removed the lag and passed
// a design that wrote source word k+1 into word k. This one keeps both.
task bridge_xfer(input [31:0] a, output reg [31:0] d, input check);
begin
    @(negedge clk_74a);
    bridge_addr = a;            // held from here, as pmp_addr is

    repeat (4) @(negedge clk_74a);   // ST_READ_0, read_cnt 0 to 3
    d = bridge_rd_data;              // spis_word_tx <= pmp_rd_data_e
    // Only meaningful once something is in flight: the hit flag describes the
    // previous transaction, and a priming read has no previous.
    if (check && !bridge_rd_hit) begin
        $display("ERROR: no window answered a read of %08h", a);
        errors = errors + 1;
    end

    @(negedge clk_74a);
    bridge_rd = 1'b1;                // ST_READ_1, after the fact
    @(negedge clk_74a);
    bridge_rd = 1'b0;
    @(negedge clk_74a);
end
endtask

task bridge_read(input [31:0] a, output reg [31:0] d);
begin
    bridge_xfer(a, d, 1'b1);
end
endtask

// One transaction of lag means every burst needs a priming read whose result
// is thrown away, exactly as the host must do.
task bridge_prime(input [31:0] a);
    reg [31:0] junk;
begin
    bridge_xfer(a, junk, 1'b0);
end
endtask

// Undo the peripheral's endian reversal to get the value the host would hold,
// then store it the way a little endian host stores a 32-bit word.
task host_word(input [31:0] raw, output reg [31:0] v);
begin
    v = bridge_endian_little
        ? {raw[7:0], raw[15:8], raw[23:16], raw[31:24]}
        : raw;
end
endtask

reg [31:0] rw, hw;
integer    bi;

task read_struct;
begin
    bridge_prime(t_param_struct);
    for (bi = 0; bi < 66; bi = bi + 1) begin
        bridge_read(t_param_struct + (bi+1)*4, rw);
        host_word(rw, hw);
        pathbuf[bi*4 + 0] = hw[7:0];
        pathbuf[bi*4 + 1] = hw[15:8];
        pathbuf[bi*4 + 2] = hw[23:16];
        pathbuf[bi*4 + 3] = hw[31:24];
    end
end
endtask

integer wi;

task read_chunk;
begin
    bridge_prime(t_bridgeaddr);
    for (wi = 0; wi < (t_length + 3) / 4; wi = wi + 1) begin
        bridge_read(t_bridgeaddr + (wi+1)*4, rw);
        host_word(rw, hw);
        if (t_slotoffset + wi*4 + 0 < t_slotoffset + t_length)
            fdata[t_slotoffset + wi*4 + 0] = hw[7:0];
        if (t_slotoffset + wi*4 + 1 < t_slotoffset + t_length)
            fdata[t_slotoffset + wi*4 + 1] = hw[15:8];
        if (t_slotoffset + wi*4 + 2 < t_slotoffset + t_length)
            fdata[t_slotoffset + wi*4 + 2] = hw[23:16];
        if (t_slotoffset + wi*4 + 3 < t_slotoffset + t_length)
            fdata[t_slotoffset + wi*4 + 3] = hw[31:24];
    end
    if (t_slotoffset + t_length > fsize) fsize = t_slotoffset + t_length;
end
endtask

// APF. One command at a time, because the writer never issues a second before
// the first reports done.
initial begin
    t_done = 1'b0;
    t_err  = 3'd0;
    forever begin
        @(posedge clk_74a);
        if (t_openfile) begin
            t_done = 1'b0;
            n_open = n_open + 1;
            read_struct;
            if (accept_style >= 0 && pathbuf[0] !== style_lead(accept_style))
                t_err = 3'd4;      // malformed path, the hardware answer
            else
                t_err = next_open_err;
            t_done = 1'b1;
        end else if (t_write) begin
            t_done = 1'b0;
            if (t_id !== 16'd20) begin
                $display("ERROR: write went to slot %0d, expected 20", t_id);
                errors = errors + 1;
            end
            read_chunk;
            n_write = n_write + 1;
            t_err   = next_write_err;
            t_done  = 1'b1;
        end else if (t_flush) begin
            t_done  = 1'b0;
            n_flush = n_flush + 1;
            repeat (3) @(posedge clk_74a);
            t_err   = 3'd0;
            t_done  = 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------
// First character of each root, which is enough to tell the eight apart for
// the purpose of refusing seven of them.
function [7:0] style_lead(input integer st);
    begin
        case (st)
            0: style_lead = "/";   // /Assets/...
            1: style_lead = "A";   // Assets/...
            2: style_lead = "S";   // bare, so the name itself: SELFTEST.bin
            3: style_lead = "/";   // /Saves/...
            4: style_lead = "c";   // common/...
            5: style_lead = "c";   // carttools/...
            6: style_lead = "/";   // /carttools/...
            default: style_lead = "S";  // Saves/...
        endcase
    end
endfunction

task reset_model;
begin
    n_open = 0; n_write = 0; n_flush = 0; n_bus_writes = 0; n_gba_reads = 0;
    n_ram_writes = 0;
    ram_enabled = 1'b0;
    mode_seen = 2'b00;
    fsize = 0;
    cur_bank = 9'd1;
    mbc5_hi  = 1'b0;
    next_open_err = 3'd0;
    next_write_err = 3'd0;
end
endtask

task run_save(input [7:0] ramcode);
begin
    @(negedge clk_sys);
    selftest      = 1'b0;
    save_mode     = 1'b1;
    // core_top drives this to KIND_SAV on the same edge it asserts save_mode,
    // so the file is named for what it holds rather than for the platform.
    cart_kind     = 2'd3;
    ram_size_code = ramcode;
    byte_order    = 1'b1;
    start         = 1'b1;
    @(negedge clk_sys);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk_sys);
    save_mode = 1'b0;
end
endtask

task run_dump(input st, input bo, input [7:0] szcode);
begin
    @(negedge clk_sys);
    selftest      = st;
    save_mode     = 1'b0;
    cart_kind     = 2'd0;
    byte_order    = bo;
    rom_size_code = szcode;
    start         = 1'b1;
    @(negedge clk_sys);
    start = 1'b0;
    wait (done == 1'b1);
    @(negedge clk_sys);
end
endtask

integer k;
reg [7:0] want;

task check_path(input [2047:0] s, input integer len, input [255:0] what);
begin
    for (k = 0; k < len; k = k + 1) begin
        if (pathbuf[k] !== s[8*(len-1-k) +: 8]) begin
            $display("ERROR: %0s path byte %0d = %02h '%0s', expected '%0s'",
                     what, k, pathbuf[k], pathbuf[k], s[8*(len-1-k) +: 8]);
            errors = errors + 1;
        end
    end
    if (pathbuf[len] !== 8'h00) begin
        $display("ERROR: %0s path is not terminated at %0d", what, len);
        errors = errors + 1;
    end
end
endtask

task expect_eq(input integer got, input integer wnt, input [255:0] what);
begin
    if (got !== wnt) begin
        $display("ERROR: %0s = %0d, expected %0d", what, got, wnt);
        errors = errors + 1;
    end
end
endtask

initial begin
    repeat (8) @(negedge clk_sys);
    reset_sys = 1'b0;
    reset_74a = 1'b0;
    repeat (4) @(negedge clk_sys);

    // --- the self test ramp, the byte order the design defaults to ----------
    // 256 bytes, one chunk, no cartridge involved. If this file is not a
    // clean ascending ramp then byte_order is wrong and nothing else in this
    // testbench means anything.
    reset_model;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on the self test");
    expect_eq(n_open, 1, "self test open count");
    expect_eq(n_write, 2, "self test write count, a full chunk and a tail");
    expect_eq(n_flush, 0, "flushes issued, which APF never answers");
    expect_eq(fsize, 302, "self test file size");
    expect_eq(total_bytes, 302, "self test total_bytes");
    expect_eq(chunks_total, 2, "self test chunks_total");
    expect_eq(chunks_done, 2, "self test chunks_done");
    expect_eq(n_bus_writes, 0, "cartridge writes during a self test");
    check_path("/Assets/carttools/common/SELFTEST.bin", 37, "self test");
    for (k = 0; k < 302; k = k + 1) begin
        if (fdata[k] !== k[7:0]) begin
            if (errors < 8)
                $display("ERROR: self test byte %0d = %02h, expected %02h",
                         k, fdata[k], k[7:0]);
            errors = errors + 1;
        end
    end

    // --- the same ramp with byte_order 0 ------------------------------------
    // Every group of four comes out reversed. This is here so the signature
    // is documented and so a change that quietly stopped byte_order doing
    // anything would fail rather than pass.
    // Checked only over the whole words: the last two bytes of this file sit
    // in a partial bridge word, and a partial word has no fourth byte to swap
    // with, so its layout is not a reversal of anything.
    reset_model;
    run_dump(1'b1, 1'b0, 8'd0);
    expect_eq(failed, 0, "failed on the reversed self test");
    for (k = 0; k < 300; k = k + 1) begin
        want = {k[7:2], ~k[1:0]};
        if (fdata[k] !== want) begin
            if (errors < 12)
                $display("ERROR: reversed ramp byte %0d = %02h, expected %02h",
                         k, fdata[k], want);
            errors = errors + 1;
        end
    end

    // --- a whole 32 KB cartridge --------------------------------------------
    reset_model;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on a 32 KB cartridge");
    expect_eq(total_bytes, 32768, "32 KB total_bytes");
    expect_eq(fsize, 32768, "32 KB file size");
    expect_eq(n_open, 1, "32 KB open count");
    expect_eq(n_write, 128, "32 KB write count at 256 bytes a chunk");
    expect_eq(n_flush, 0, "flushes issued for a 32 KB cartridge");
    expect_eq(chunks_done, 128, "32 KB chunks_done");
    expect_eq(chunks_total, 128, "32 KB chunks_total");
    // One mapper write, to select bank 1. Bank 0 needs none.
    expect_eq(n_bus_writes, 1, "mapper writes for a two bank cartridge");
    check_path("/Assets/carttools/common/TESTCART.gb", 36, "cartridge");
    for (k = 0; k < 32768; k = k + 1) begin
        if (fdata[k] !== content(k[23:0])) begin
            if (errors < 8)
                $display("ERROR: rom byte %0d = %02h, expected %02h",
                         k, fdata[k], content(k[23:0]));
            errors = errors + 1;
        end
    end

    // --- a save backup, end to end ------------------------------------------
    //
    // Same engine, same buffer, same file writer; a different reader and a
    // different extension. What is being proven here is the wiring: that the
    // save reader's bytes reach the card, that the file is named .sav and not
    // .gb, and that the length comes from 0x0149 rather than from the ROM
    // size that is still sitting in rom_size_code.
    reset_model;
    run_save(8'h02);
    expect_eq(failed, 0, "failed on a save backup");
    expect_eq(total_bytes, 8192, "save total_bytes");
    expect_eq(fsize, 8192, "save file size");
    expect_eq(n_open, 1, "save open count");
    expect_eq(n_write, 32, "save write count at 256 bytes a chunk");
    check_path("/Assets/carttools/common/TESTCART.sav", 37, "save");
    for (k = 0; k < 8192; k = k + 1) begin
        if (fdata[k] !== save_content(k[12:0])) begin
            if (errors < 8)
                $display("ERROR: save byte %0d = %02h, expected %02h",
                         k, fdata[k], save_content(k[12:0]));
            errors = errors + 1;
        end
    end

    // The gate was opened and shut again, and nothing was written into the
    // RAM window. tb_gb_save_write_protect proves the second at the pins;
    // this proves it survives being driven through the whole engine.
    expect_eq(n_ram_writes, 0, "writes into the RAM window during a save");
    if (ram_enabled !== 1'b0) begin
        $display("ERROR: the save left the cartridge's RAM gate open");
        errors = errors + 1;
    end

    // A save carries no checksum of any kind, so the engine must claim none.
    // The GB reader's checksum module runs on ROM dumps and would otherwise
    // report a sum over save bytes as though the cartridge had vouched for it.
    if (sum_checked !== 1'b0) begin
        $display("ERROR: the engine claimed a checksum verdict for a save");
        errors = errors + 1;
    end

    // 2 KB is the other supported size, and the length must follow the size
    // byte rather than a constant.
    reset_model;
    run_save(8'h01);
    expect_eq(total_bytes, 2048, "2 KB save total_bytes");
    expect_eq(fsize, 2048, "2 KB save file size");

    // A ROM dump straight after a save goes back to .gb and to the ROM size.
    // The engine latches which operation it is at start; a leftover save_mode
    // would produce an 8 KB file called .gb with save data in it.
    reset_model;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(fsize, 32768, "ROM dump after a save");
    check_path("/Assets/carttools/common/TESTCART.gb", 36, "cartridge after a save");

    // --- the mode is requested for a cartridge dump and released after ------
    if (want_mode !== 2'b00) begin
        $display("ERROR: want_mode is still %b after the dump finished",
                 want_mode);
        errors = errors + 1;
    end

    // --- the image is checked against the cartridge's own checksum ----------
    //
    // Super Mario Land 2 dumped once with a floating D7 and the core called
    // it a success: the header checksum cannot see a uniform bit-7 offset and
    // reading the header twice cannot see a fault that is consistent. This is
    // what closes that, and it has to work on the real reader, not just on
    // the checksum module in isolation.
    //
    // The modelled cartridge's content is a function of its address, so its
    // stored checksum is whatever that function produces; the testbench
    // computes the same sum and checks the core agrees.
    reset_model;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on the checksummed dump");
    expect_eq(sum_checked, 1, "sum_checked for a cartridge dump");
    begin : sumcheck
        integer k, want;
        reg [15:0] stored_want;
        want = 0;
        for (k = 0; k < 32768; k = k + 1)
            if (k != 24'h14E && k != 24'h14F)
                want = (want + content(k[23:0])) & 16'hFFFF;
        stored_want = {content(24'h14E), content(24'h14F)};
        if (sum_computed !== want[15:0]) begin
            $display("ERROR: computed sum %04h, expected %04h",
                     sum_computed, want[15:0]);
            errors = errors + 1;
        end
        if (sum_stored !== stored_want) begin
            $display("ERROR: captured stored sum %04h, expected %04h",
                     sum_stored, stored_want);
            errors = errors + 1;
        end
    end

    // The self test has no header, so there is nothing to compare against and
    // the screen must not claim there is.
    reset_model;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(sum_checked, 0, "sum_checked for the self test");

    // --- the same engine, through the GBA reader ----------------------------
    //
    // 1 KiB, which is four chunks at this testbench's chunk size. The size
    // comes from gba_size_bytes rather than from a header byte, which is the
    // whole difference: there is nothing in a GBA cartridge that says how big
    // it is, so the number the size probe measured has to survive the latch
    // at start, the chunk arithmetic, the open struct and the file.
    reset_model;
    plat_gba = 1'b1;
    gba_size = 32'd1024;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on a GBA dump");
    expect_eq(total_bytes, 1024, "GBA total_bytes, from the probed size");
    expect_eq(fsize, 1024, "GBA file size");
    expect_eq(chunks_total, 4, "GBA chunks_total");
    expect_eq(chunks_done, 4, "GBA chunks_done");
    expect_eq(n_write, 4, "GBA write count at 256 bytes a chunk");
    // Four bytes per bus transaction, and not one more: a reader that fell
    // back to 16-bit accesses would need 512.
    expect_eq(n_gba_reads, 256, "GBA bus reads for 1 KiB at 32 bits a time");
    // The GB reader never started, so the GB connector saw nothing at all.
    expect_eq(n_bus_writes, 0, "GB bus writes during a GBA dump");
    // 2'b01 is GBA in cart_pins' encoding. A GBA dump held in GB mode would
    // read a cartridge with the wrong pins entirely.
    expect_eq(mode_seen, 2'b01, "the connector mode a GBA dump asked for");
    // No checksum is claimed, because a GBA cartridge carries none over its
    // own contents.
    expect_eq(sum_checked, 0, "sum_checked for a GBA dump");
    for (k = 0; k < 1024; k = k + 1) begin
        if (fdata[k] !== content(k[23:0])) begin
            if (errors < 8)
                $display("ERROR: GBA byte %0d = %02h, expected %02h",
                         k, fdata[k], content(k[23:0]));
            errors = errors + 1;
        end
    end

    // The CRC32 is the only identity a GBA dump has. It has no reference of
    // its own, so what can be asserted here is that it is computed at all and
    // that it is repeatable - which is the property a second dump is compared
    // against on hardware. The values themselves are checked against zlib in
    // tb_dump_crc32.
    begin : gbacrc
        reg [31:0] first_crc;
        first_crc = crc32;
        if (first_crc === 32'd0) begin
            $display("ERROR: the GBA dump produced a CRC32 of zero");
            errors = errors + 1;
        end
        reset_model;
        run_dump(1'b0, 1'b1, 8'd0);
        expect_eq(failed, 0, "failed on the repeated GBA dump");
        if (crc32 !== first_crc) begin
            $display("ERROR: two identical GBA dumps gave CRC32 %08h and %08h",
                     first_crc, crc32);
            errors = errors + 1;
        end
    end

    // Back to the GB path, and it must be exactly as it was. The engine
    // latches the platform at start, so a caller that changes it between dumps
    // gets the platform it asked for and nothing left over from the last one.
    plat_gba = 1'b0;
    gba_size = 32'd0;
    reset_model;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on the GB dump after a GBA one");
    expect_eq(total_bytes, 32768, "GB total_bytes after a GBA dump");
    expect_eq(fsize, 32768, "GB file size after a GBA dump");
    expect_eq(n_gba_reads, 0, "GBA bus reads during a GB dump");
    expect_eq(mode_seen, 2'b10, "the connector mode a GB dump asked for");
    expect_eq(sum_checked, 1, "sum_checked for a GB dump after a GBA one");

    // --- the cartridge is pulled halfway through -----------------------------
    // gb_cart_bus drops a transaction when the mode goes away and never
    // asserts done, so without an abort path the reader waits forever and so
    // does everything above it. What matters as much as the failure being
    // reported is that the next dump still works.
    reset_model;
    // Long enough that the reader is certainly mid-transaction when the abort
    // crosses back, which is the only way the mode-change window is real.
    bus_delay = 4000;
    fork
        run_dump(1'b0, 1'b1, 8'd0);
        begin
            wait (n_write == 2);
            @(negedge clk_sys);
            cart_powered = 1'b0;
        end
    join
    bus_delay = 3;
    expect_eq(failed, 1, "failed flag after the slot lost power");
    expect_eq(err, 7, "reported err after the slot lost power");
    cart_powered = 1'b1;

    reset_model;
    run_dump(1'b0, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on the dump after an aborted one");
    expect_eq(fsize, 32768, "file size after an aborted dump");
    for (k = 0; k < 32768; k = k + 1) begin
        if (fdata[k] !== content(k[23:0])) begin
            if (errors < 4)
                $display("ERROR: recovery byte %0d = %02h, expected %02h",
                         k, fdata[k], content(k[23:0]));
            errors = errors + 1;
        end
    end

    // --- the core finds the right path root by itself ------------------------
    //
    // Two hardware sessions were spent pressing buttons through this search
    // space one Quartus run at a time. An open costs one target command, so
    // the core does it in under a millisecond instead. What is checked is
    // that it converges, that it converges on the root the model accepts,
    // and that the file is still correct afterwards.
    reset_model;
    accept_style = 4;                 // common/SELFTEST.bin
    path_style   = 3'd0;              // start somewhere else entirely
    byte_order   = 1'b1;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed while searching for a path root");
    expect_eq(used_style, 4, "the root the search settled on");
    expect_eq(used_order, 1, "the byte order the search settled on");
    expect_eq(n_open, 5, "opens tried before root 4 was accepted");
    expect_eq(fsize, 302, "file size after a search");
    for (k = 0; k < 302; k = k + 1) begin
        if (fdata[k] !== k[7:0]) begin
            if (errors < 4)
                $display("ERROR: searched dump byte %0d = %02h, expected %02h",
                         k, fdata[k], k[7:0]);
            errors = errors + 1;
        end
    end

    // Having found it once, the next dump goes straight there.
    reset_model;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed on the dump after a successful search");
    expect_eq(n_open, 1, "opens on the second dump, having learned the root");
    expect_eq(tries,  1, "attempts on the second dump");

    // Unless the operator says otherwise, in which case their setting wins.
    // A remembered combination that silently overrode an explicit one would
    // make the diagnostics page a liar.
    reset_model;
    accept_style = 6;
    path_style   = 3'd6;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed, 0, "failed after the operator picked the root");
    expect_eq(n_open, 1, "opens when the operator picked the right root");
    expect_eq(used_style, 6, "the root the operator picked");

    // When no combination is accepted, the dump does not give up: it writes
    // into whatever file the slot already has. data.json gives slot 20 a
    // filename and APF associates a real path with it, so 0x0184 has
    // somewhere to go without 0x0192 ever succeeding. The file is named by
    // the slot rather than by the cartridge, which is worse, and a dump that
    // exists is better than one that does not.
    reset_model;
    accept_style  = -1;
    next_open_err = 3'd4;
    path_style    = 3'd0;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed,  0, "failed after falling back to the slot's own file");
    expect_eq(no_open, 1, "no_open flag after the fallback");
    expect_eq(n_open, 64, "opens tried before falling back");
    expect_eq(tries,  65, "attempts, the search plus the fallback");
    expect_eq(n_write, 2, "writes made by the fallback");
    expect_eq(fsize,  302, "file size from the fallback");

    // And if the write fails too, that is a real failure and it says so.
    reset_model;
    accept_style   = -1;
    next_open_err  = 3'd4;
    next_write_err = 3'd5;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed, 1, "failed flag when the fallback cannot write either");
    expect_eq(err,    5, "reported err when the fallback cannot write");
    next_write_err = 3'd0;
    next_open_err  = 3'd0;
    accept_style   = -1;

    // --- an open that is refused everywhere still reaches the card ----------
    reset_model;
    next_open_err = 3'd5;
    run_dump(1'b1, 1'b1, 8'd0);
    expect_eq(failed,  0, "failed after every open returned 5");
    expect_eq(no_open, 1, "no_open flag after every open returned 5");
    expect_eq(fsize, 302, "file size after every open returned 5");
    next_open_err = 3'd0;

    // Checked once at the end because the monitor above runs for the whole
    // simulation, including every abort, every stall and every one of the
    // sixty-four opens.
    if (mode_violations != 0) begin
        $display("ERROR: the connector mode changed mid-write %0d times",
                 mode_violations);
        errors = errors + mode_violations;
    end

    if (errors != 0) begin
        $display("tb_dump_engine: %0d checks failed", errors);
        $fatal(1);
    end

    $display("TB PASS: tb_dump_engine");
    $finish;
end

initial begin
    #400000000;
    $display("ERROR: tb_dump_engine watchdog expired at %0t", $time);
    $fatal(1);
end

endmodule

`default_nettype wire
