// SOURCES: src/fpga/services/restore/cart_restore_gb.sv src/fpga/core/gb_cart_bus.sv
// SPDX-License-Identifier: GPL-2.0-or-later
`timescale 1ns/1ps
`default_nettype none

module tb_cart_restore_gb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg bus_reset = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg cart_powered = 1'b1;
reg authorized = 1'b1;
reg [7:0] cart_type = 8'h03;
reg [7:0] ram_size_code = 8'h02;
// The physical model's mapper. Set together with cart_type so a live identity
// change to the writer does not silently change what the cartridge does.
reg mbc3_model = 1'b0;
wire supported, busy, done, failed;
wire [14:0] source_offset;
reg [7:0] source_data;
wire bus_req, bus_wr, bus_done, bus_busy;
wire [15:0] bus_addr;
wire [7:0] bus_wdata, bus_rdata;

cart_restore_gb dut (
    .clk(clk), .reset(reset), .start(start), .abort(abort),
    .cart_powered(cart_powered), .cart_type(cart_type),
    .ram_size_code(ram_size_code), .authorized(authorized),
    .supported(supported), .busy(busy), .done(done), .failed(failed),
    .source_offset(source_offset), .source_data(source_data),
    .bus_req(bus_req), .bus_wr(bus_wr), .bus_addr(bus_addr),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_done(bus_done), .bus_busy(bus_busy)
);

wire [15:0] e_ad_out;
wire e_ad_oe, e_hi_oe;
wire [7:0] e_hi_out;
wire [3:0] e_ctl_out;
wire e_p30_out, e_p30_oe;
wire wr_n = e_ctl_out[2];
wire rd_n = e_ctl_out[1];
wire cs_n = e_ctl_out[0];

// Use the shipped bus timings, including the complete write hold interval.
// A logical reset of the writer must never reset this bus during an active
// transaction. The real pin owner must maintain this separation as well.
gb_cart_bus cart_bus (
    .clk(clk), .reset(bus_reset), .gb_mode(cart_powered), .idle_precharge(1'b1),
    .req(bus_req), .wr(bus_wr), .addr(bus_addr), .wdata(bus_wdata),
    .rdata(bus_rdata), .done(bus_done), .busy(bus_busy),
    .e_ad_out(e_ad_out), .e_ad_oe(e_ad_oe),
    .e_hi_out(e_hi_out), .e_hi_oe(e_hi_oe),
    .e_ctl_out(e_ctl_out), .e_p30_out(e_p30_out), .e_p30_oe(e_p30_oe),
    .e_ad_in(16'h0000), .e_hi_in(8'hFF)
);

function [7:0] restore_byte(input integer offset);
    restore_byte = (offset ^ (offset >> 4) ^ (offset >> 8) ^ 8'h63) & 255;
endfunction

function [7:0] original_byte(input integer offset);
    original_byte = ~restore_byte(offset);
endfunction

// Real synchronous staging memory behavior. Poison its output while a bus
// transfer is underway to prove that accepted data is held independently.
always @(posedge clk) begin
    source_data <= restore_byte({17'd0, source_offset}) ^
                   (bus_busy ? 8'hFF : 8'h00);
end

// A writable MBC1 cartridge model, or with mbc3_model an MBC3 one whose RAM
// bank is always the 0x4000 register and whose 0x6000 is the clock latch.
// Starting in mode1/bank3 with RAM enabled ensures that setup is necessary.
// Unselected MBC1 banks are canaries. The model latches only physical /WR
// edges and never consults the writer's FSM.
reg [7:0] ram [0:32767];
reg ram_enabled = 1'b0;
reg mbc1_mode = 1'b1;
reg [1:0] ram_bank = 2'd3;
integer ram_writes = 0;
integer write_pulses = 0;
integer accepted_data = 0;
reg sweep_active = 1'b0;
integer first_byte_cycle = 0;
integer clock_count = 0;
integer cycles_at_start = 0;
reg check_pins = 1'b0;
reg write_inflight = 1'b0;
reg allow_power_loss = 1'b0;
reg [15:0] pulse_addr;
reg [7:0] pulse_data;
integer low_cycle;
integer high_cycle;
integer physical_offset;
reg [15:0] previous_request_addr;
reg [7:0] previous_request_data;
reg previous_request_wr;
reg previous_busy = 1'b0;

always @(posedge clk) begin
    clock_count = clock_count + 1;
    if (check_pins && bus_req) begin
        if (bus_busy || bus_done)
            $fatal(1, "request submitted before bus became available");
        if (!bus_wr)
            $fatal(1, "writer unexpectedly submitted a read");
        if (bus_addr >= 16'hA000 && bus_addr <= 16'hBFFF) begin
            if (!authorized || abort || reset || !supported)
                $fatal(1, "save request accepted without current authorization");
            accepted_data = accepted_data + 1;
        end
    end
    if (check_pins && bus_busy && previous_busy && !allow_power_loss) begin
        if (bus_addr !== previous_request_addr ||
            bus_wdata !== previous_request_data || bus_wr !== previous_request_wr)
            $fatal(1, "writer changed address, data, or direction while bus busy");
    end
    previous_request_addr = bus_addr;
    previous_request_data = bus_wdata;
    previous_request_wr = bus_wr;
    previous_busy = bus_busy;
end

always @(negedge wr_n) begin
    #1;
    if (check_pins) begin
        if (!e_hi_oe || !e_ad_oe || !rd_n || !e_p30_out || !e_p30_oe)
            $fatal(1, "write strobe without stable driven address and data");
        if (write_inflight)
            $fatal(1, "overlapping physical writes");
        if ((e_ad_out >= 16'hA000 && e_ad_out <= 16'hBFFF) != !cs_n)
            $fatal(1, "incorrect RAM chip select at address %04x", e_ad_out);
        if (e_ad_out >= 16'hA000 && e_ad_out <= 16'hBFFF) begin
            if (!ram_enabled || (!mbc3_model && (mbc1_mode || ram_bank != 2'd0)))
                $fatal(1, "save write before mapper setup completed");
            if (mbc3_model && ram_bank != ram_writes / 8192)
                $fatal(1, "save write to bank %0d for byte %0d", ram_bank, ram_writes);
            if (e_ad_out !== (16'hA000 + ram_writes % 8192))
                $fatal(1, "save address %04x is not expected sequential byte %0d",
                       e_ad_out, ram_writes);
            if (e_hi_out !== restore_byte(ram_writes))
                $fatal(1, "wrong staged byte at offset %0d", ram_writes);
            if (ram_writes == 0)
                first_byte_cycle = clock_count - cycles_at_start;
        end else if (mbc3_model) begin
            if (!((e_ad_out == 16'h0000 && (e_hi_out == 8'h00 || e_hi_out == 8'h0A)) ||
                  (e_ad_out == 16'h4000 && e_hi_out <= 8'h03)))
                $fatal(1, "unexpected MBC3 mapper write %04x=%02x", e_ad_out, e_hi_out);
        end else if (!((e_ad_out == 16'h0000 &&
                        (e_hi_out == 8'h00 || e_hi_out == 8'h0A)) ||
                       (e_ad_out == 16'h4000 && e_hi_out == 8'h00) ||
                       (e_ad_out == 16'h6000 && e_hi_out == 8'h00))) begin
            $fatal(1, "unexpected mapper write %04x=%02x", e_ad_out, e_hi_out);
        end
        pulse_addr = e_ad_out;
        pulse_data = e_hi_out;
        low_cycle = clock_count;
        write_inflight = 1'b1;
        write_pulses = write_pulses + 1;
    end
end

always @(posedge wr_n) begin
    #1;
    if (check_pins && write_inflight) begin
        if (!allow_power_loss) begin
            if (!e_hi_oe || !e_ad_oe || e_ad_out !== pulse_addr || e_hi_out !== pulse_data)
                $fatal(1, "write data/address released or changed at the latching edge");
            if (clock_count - low_cycle != 41)
                $fatal(1, "write pulse truncated to %0d clocks", clock_count - low_cycle);
        end
        high_cycle = clock_count;
        if (cart_powered) begin
            case (pulse_addr)
                16'h0000: ram_enabled = pulse_data[3:0] == 4'hA;
                16'h4000: ram_bank = pulse_data[1:0];
                16'h6000: mbc1_mode = pulse_data[0];
                default: begin
                    if (pulse_addr >= 16'hA000 && pulse_addr <= 16'hBFFF) begin
                        physical_offset = ((mbc3_model || mbc1_mode) ? ram_bank * 8192 : 0) +
                                          (pulse_addr - 16'hA000);
                        ram[physical_offset] = pulse_data;
                        ram_writes = ram_writes + 1;
                    end
                end
            endcase
        end
        write_inflight = 1'b0;
    end
end

always @(negedge e_hi_oe) begin
    #1;
    if (check_pins && !allow_power_loss && write_pulses > 0 && !bus_reset) begin
        if (write_inflight || clock_count - high_cycle < 21)
            $fatal(1, "data released before the complete write hold interval");
    end
end

task setup_case;
    integer i;
    begin
        @(negedge clk);
        check_pins = 1'b0;
        reset = 1'b1;
        bus_reset = 1'b1;
        cart_powered = 1'b1;
        start = 1'b0;
        abort = 1'b0;
        authorized = 1'b1;
        cart_type = 8'h03;
        ram_size_code = 8'h02;
        mbc3_model = 1'b0;
        allow_power_loss = 1'b0;
        repeat (3) @(negedge clk);
        reset = 1'b0;
        bus_reset = 1'b0;
        // Every physical write is checked below. Between short cancellation
        // cases only its known sequential prefix can have changed. Restore
        // that prefix instead of rebuilding all four RAM banks 1700 times.
        for (i = 0; i < ram_writes; i = i + 1)
            ram[i] = original_byte(i);
        ram_enabled = 1'b1;
        mbc1_mode = 1'b1;
        ram_bank = 2'd3;
        ram_writes = 0;
        accepted_data = 0;
        write_pulses = 0;
        write_inflight = 1'b0;
        previous_busy = 1'b0;
        first_byte_cycle = 0;
        repeat (3) @(negedge clk);
        check_pins = 1'b1;
    end
endtask

task launch;
    begin
        @(negedge clk);
        cycles_at_start = clock_count;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task finish_run(input expect_failed);
    integer i;
    integer deadline;
    begin
        deadline = 0;
        // A 32 KiB MBC3 restore is about 2.9 M clocks at the shipped timing.
        while (!done && deadline < 4000000) begin
            @(negedge clk);
            deadline = deadline + 1;
        end
        if (!done || busy || bus_busy || bus_req)
            $fatal(1, "writer did not terminate with an idle bus");
        if (failed !== expect_failed)
            $fatal(1, "unexpected failure result %b, wanted %b", failed, expect_failed);
        if (ram_enabled || (!mbc3_model && mbc1_mode))
            $fatal(1, "termination left RAM enabled or MBC1 mode1 selected");
        if (ram_writes != accepted_data)
            $fatal(1, "accepted %0d bytes but committed %0d", accepted_data, ram_writes);
        // During the sweep check every touched byte and the first untouched
        // byte. The physical model forbids out-of-order or wrong-bank writes.
        // Complete runs additionally compare every byte and all canary banks.
        for (i = 0; i < (sweep_active ? ram_writes + 1 : (mbc3_model ? 32768 : 8192)); i = i + 1) begin
            if (ram[i] !== ((i < ram_writes) ? restore_byte(i) : original_byte(i)))
                $fatal(1, "RAM mismatch after operation at offset %0d", i);
        end
        if (!sweep_active && !mbc3_model) begin
            for (i = 8192; i < 32768; i = i + 1)
                if (ram[i] !== original_byte(i))
                    $fatal(1, "unselected RAM bank changed at %0d", i);
        end
        // Completion has to be a pulse and a revoked run cannot resume.
        reset = 1'b0;
        abort = 1'b0;
        authorized = 1'b1;
        repeat (5) @(negedge clk);
        if (busy || done || bus_req || bus_busy)
            $fatal(1, "completed operation restarted without a new start");
    end
endtask

task refuse_start;
    begin
        launch;
        if (!done || !failed || busy || bus_req)
            $fatal(1, "invalid start was not refused immediately");
        repeat (5) @(negedge clk);
        if (write_pulses != 0 || accepted_data != 0)
            $fatal(1, "refused operation performed cartridge writes");
    end
endtask

integer kind;
integer phase;
integer phase_count;
integer byte_start;
integer before_cancel;
integer i;

initial begin
    for (i = 0; i < 32768; i = i + 1)
        ram[i] = original_byte(i);
    setup_case;
    if (!supported) $fatal(1, "initial MBC1 8 KiB configuration refused");
    launch;
    finish_run(1'b0);
    if (ram_writes != 8192 || write_pulses != 8198)
        $fatal(1, "full restore wrote %0d save bytes and %0d total transactions",
               ram_writes, write_pulses);
    byte_start = first_byte_cycle;
    $display("Full restore: 8192 exact bytes, mapper cleanup, synchronous source, stable pins");

    // MBC3: four banks through 0x4000 = 0..3, no 0x6000 write at all, and
    // one disable at the end. Seven mapper transactions around 32768 bytes.
    setup_case; mbc3_model = 1'b1; cart_type = 8'h10; ram_size_code = 8'h03;
    if (!supported) $fatal(1, "MBC3 32 KiB configuration refused");
    launch;
    finish_run(1'b0);
    if (ram_writes != 32768 || write_pulses != 32775)
        $fatal(1, "MBC3 restore wrote %0d save bytes and %0d total transactions",
               ram_writes, write_pulses);
    $display("MBC3 full restore: 32768 bytes across four banks, no latch writes");
    setup_case; mbc3_model = 1'b1; cart_type = 8'h13; ram_size_code = 8'h03;
    if (!supported) $fatal(1, "MBC3 without timer refused");
    setup_case; cart_type = 8'h10; ram_size_code = 8'h02; refuse_start;
    setup_case; mbc3_model = 1'b1; cart_type = 8'h11; ram_size_code = 8'h03; refuse_start;
    setup_case; mbc3_model = 1'b1; cart_type = 8'h0F; ram_size_code = 8'h03; refuse_start;
    // Cancellation on either side of the first bank switch must still clean
    // up without another accepted byte, including while the bank write itself
    // is on the bus.
    for (kind = 0; kind < 3; kind = kind + 1) begin
        for (i = 8191; i <= 8193; i = i + 1) begin
            setup_case; mbc3_model = 1'b1; cart_type = 8'h10; ram_size_code = 8'h03;
            launch;
            wait (ram_writes == i);
            @(negedge clk);
            before_cancel = accepted_data;
            case (kind)
                0: abort = 1'b1;
                1: authorized = 1'b0;
                2: reset = 1'b1;
            endcase
            finish_run(1'b1);
            if (ram_writes != before_cancel)
                $fatal(1, "MBC3 cancellation kind %0d at byte %0d accepted another byte", kind, i);
        end
    end
    $display("MBC3 cancellation around the bank switch: 9 cases clean");

    setup_case; authorized = 1'b0; refuse_start;
    setup_case; abort = 1'b1; refuse_start;
    setup_case; cart_powered = 1'b0; refuse_start;
    setup_case; cart_type = 8'h01; refuse_start;
    setup_case; cart_type = 8'h02; refuse_start;
    setup_case; cart_type = 8'h13; refuse_start;
    setup_case; cart_type = 8'h1B; refuse_start;
    setup_case; ram_size_code = 8'h00; refuse_start;
    setup_case; ram_size_code = 8'h01; refuse_start;
    setup_case; ram_size_code = 8'h03; refuse_start;
    setup_case; ram_size_code = 8'h04; refuse_start;
    setup_case; ram_size_code = 8'h05; refuse_start;
    $display("Invalid authorization, power, mapper, and capacity starts refused without writes");

    // Sweep every clock of setup plus the complete first two byte transfers.
    // A revoked request must never start, but an already accepted byte must
    // retain its exact payload and full physical pulse through completion.
    phase_count = byte_start + 180;
    sweep_active = 1'b1;
    for (kind = 0; kind < 3; kind = kind + 1) begin
        for (phase = 0; phase <= phase_count; phase = phase + 1) begin
            setup_case;
            launch;
            repeat (phase) @(negedge clk);
            before_cancel = accepted_data;
            case (kind)
                0: abort = 1'b1;
                1: authorized = 1'b0;
                2: reset = 1'b1;
            endcase
            finish_run(1'b1);
            if (ram_writes != before_cancel)
                $fatal(1, "cancellation kind %0d phase %0d accepted another byte", kind, phase);
        end
        $display("Cancellation kind %0d: swept %0d cycle positions", kind, phase_count + 1);
    end
    sweep_active = 1'b0;

    // Live identity changes also revoke the active capability.
    setup_case;
    launch;
    wait (ram_writes == 5);
    @(negedge clk);
    cart_type = 8'h1B;
    finish_run(1'b1);

    // Cancellation in final cleanup still closes the RAM gate, restores mode0,
    // and reports failure, even though every save byte already landed.
    setup_case;
    launch;
    wait (ram_writes == 8192);
    @(negedge clk);
    authorized = 1'b0;
    finish_run(1'b1);

    // Loss of power cannot safely perform mapper cleanup. No further request
    // may occur, and this must never be reported as successful completion.
    setup_case;
    launch;
    wait (ram_writes == 2);
    @(negedge clk);
    allow_power_loss = 1'b1;
    cart_powered = 1'b0;
    @(negedge clk);
    if (!done || !failed || busy || bus_req || e_ad_oe || e_hi_oe)
        $fatal(1, "power loss did not release and fail immediately");
    repeat (20) @(negedge clk);
    if (bus_req || busy || bus_busy)
        $fatal(1, "power loss left pending activity");

    $display("TB PASS: tb_cart_restore_gb");
    $finish;
end

initial begin
    #2_000_000_000;
    $fatal(1, "tb_cart_restore_gb watchdog expired");
end

endmodule

`default_nettype wire
