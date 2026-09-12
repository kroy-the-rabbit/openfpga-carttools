// SOURCES: src/fpga/services/dump/cart_dump_gb.sv src/fpga/core/gb_cart_bus.sv
// Measure paired MBC3 reads through the shipped bus, including bank changes,
// backpressure and reader aborts in each added idle cycle. No bus FSM mock.
`default_nettype none
`timescale 1ns/1ps
module tb_cart_dump_gb_pair_timing;
// Override to 87 only when measuring the pre-experiment BB2B source.
parameter integer PAIR_INTERVAL = 89;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, reader_abort = 0, start = 0, out_ready = 1;
wire req, wr, bus_done, bus_busy, busy, done, valid;
wire [15:0] addr, pin_addr;
wire [7:0] wdata, rdata, data, pin_data, cart_data;
wire addr_oe, data_oe;
wire [3:0] ctl;
wire [23:0] mismatches, even_count, odd_count;
wire [22:0] first_addr;
wire [7:0] first_a, first_b;
cart_dump_gb #(.PAIR_READS(1'b1)) reader (
    .clk(clk), .reset(reset | reader_abort), .start(start),
    .cart_type(8'h10), .rom_size_code(8'd0), .busy(busy), .done(done),
    .total_bytes(), .bus_req(req), .bus_wr(wr), .bus_addr(addr),
    .bus_wdata(wdata), .bus_rdata(rdata), .bus_done(bus_done),
    .out_data(data), .out_valid(valid), .out_ready(out_ready),
    .pair_mismatches(mismatches), .pair_even(even_count), .pair_odd(odd_count),
    .pair_first_addr(first_addr), .pair_first_a(first_a), .pair_first_b(first_b)
);
gb_cart_bus bus (
    .clk(clk), .reset(reset), .gb_mode(1'b1),
    .req(req), .wr(wr), .addr(addr), .wdata(wdata),
    .rdata(rdata), .done(bus_done), .busy(bus_busy),
    .e_ad_out(pin_addr), .e_ad_oe(addr_oe), .e_hi_out(pin_data),
    .e_hi_oe(data_oe), .e_ctl_out(ctl), .e_p30_out(), .e_p30_oe(),
    .e_ad_in(16'd0), .e_hi_in(cart_data)
);

function [7:0] content(input [22:0] linear);
    content = linear[7:0] ^ linear[15:8] ^ {1'b0, linear[22:16]};
endfunction
reg [6:0] selected_bank = 1;
wire [22:0] pin_linear = pin_addr < 16'h4000 ? {9'd0, pin_addr[13:0]} :
                        {2'd0, selected_bank, pin_addr[13:0]};
reg second = 0;
// One deliberate second-read fault in bank 1 proves the retained first byte
// and diagnostics still work through the actual sample edge.
assign cart_data = addr_oe && !ctl[1] ?
    content(pin_linear) ^ ((second && pin_linear == 23'h00408B) ? 8'h01 : 8'h00) :
    8'hFF;

integer cycles = 0, reads = 0, writes = 0, emitted = 0;
integer accepted_at = 0, rd_at = 0, raised_at = 0;
integer last_read_at = 0, last_rd_at = 0, interval;
integer pairs_checked = 0, next_checked = 0, stalled_cycles = 0;
integer stalls_since_read = 0, stalled_next_checked = 0;
reg request_was_high = 0, prior_was_read = 0;
reg [22:0] expected_linear;
reg [15:0] expected_bus_addr;
reg [7:0] held_data;
reg was_stalled = 0;
always @(posedge clk) begin
    cycles = cycles + 1;
    if (!reset && !reader_abort) begin
        if (req) begin
            if (bus_busy || request_was_high)
                $fatal(1, "request repeated or issued while bus busy");
            accepted_at = cycles;
            if (wr) begin
                if (reads != 32768 || addr !== 16'h2000 || wdata !== 8'h01)
                    $fatal(1, "unexpected MBC3 mapper write %04h=%02h at read %0d",
                           addr, wdata, reads);
                prior_was_read = 0;
            end else begin
                expected_linear = reads / 2;
                expected_bus_addr = expected_linear < 23'h4000 ?
                                    {2'b00, expected_linear[13:0]} :
                                    {2'b01, expected_linear[13:0]};
                if (addr !== expected_bus_addr)
                    $fatal(1, "read %0d at %04h, expected %04h", reads, addr, expected_bus_addr);
                second = reads[0];
                if (prior_was_read) begin
                    interval = cycles - last_read_at;
                    if (reads < 4 || reads == 32769 || reads == 32770)
                        $display("TRACE request read=%0d addr=%04h second=%0d interval=%0d phi=%0d",
                                 reads, addr, second, interval, ctl[3]);
                    if (second) begin
                        if (interval != PAIR_INTERVAL)
                            $fatal(1, "paired request interval %0d, expected %0d", interval, PAIR_INTERVAL);
                        pairs_checked = pairs_checked + 1;
                    end else begin
                        if (interval != 89 + stalls_since_read)
                            $fatal(1, "next-byte interval %0d, expected %0d", interval, 89 + stalls_since_read);
                        next_checked = next_checked + 1;
                        if (stalls_since_read > 0)
                            stalled_next_checked = stalled_next_checked + 1;
                    end
                end
                stalls_since_read = 0;
                last_read_at = cycles;
                prior_was_read = 1;
                reads = reads + 1;
            end
        end
        if (was_stalled && (!valid || data !== held_data))
            $fatal(1, "first sample changed under backpressure");
        was_stalled = valid && !out_ready;
        held_data = data;
        if (was_stalled) begin
            stalls_since_read = stalls_since_read + 1;
            stalled_cycles = stalled_cycles + 1;
            if (req) $fatal(1, "request while first sample is stalled");
        end
        if (valid && out_ready) begin
            if (reads != 2 * (emitted + 1) || data !== content(emitted))
                $fatal(1, "wrong first-sample stream at byte %0d", emitted);
            emitted = emitted + 1;
        end
    end
    request_was_high = req;
end

// Measure pin timing independently of the reader and bus state encodings.
always @(negedge ctl[1]) if (!reset) begin
    rd_at = cycles;
    if (rd_at - accepted_at != 21 || !addr_oe || data_oe || !ctl[0])
        $fatal(1, "read setup or pin directions changed");
    if (second && rd_at - last_rd_at != PAIR_INTERVAL)
        $fatal(1, "paired /RD interval %0d, expected %0d", rd_at-last_rd_at, PAIR_INTERVAL);
    if (reads <= 4 || reads == 32770)
        $display("TRACE /RD read=%0d addr=%04h interval=%0d setup=%0d phi=%0d",
                 reads-1, pin_addr, rd_at-last_rd_at, rd_at-accepted_at, ctl[3]);
    last_rd_at = rd_at;
end
always @(posedge ctl[1]) if (!reset) begin
    raised_at = cycles;
    if (cycles - rd_at != 41) $fatal(1, "read strobe width changed");
end
always @(negedge addr_oe) if (!reset) begin
    if (cycles - raised_at != 21) $fatal(1, "address hold duration changed");
end
always @(negedge ctl[2]) if (!reset) begin
    rd_at = cycles;
    if (cycles - accepted_at != 21 || !addr_oe || !data_oe || !ctl[0])
        $fatal(1, "mapper setup or pin directions changed");
end
always @(posedge ctl[2]) if (!reset) begin
    raised_at = cycles;
    if (cycles - rd_at != 41 || !data_oe || pin_addr !== 16'h2000 || pin_data !== 8'h01)
        $fatal(1, "mapper strobe, register, or data changed");
    selected_bank = pin_data[6:0];
    writes = writes + 1;
end

task launch;
    begin
        @(negedge clk);
        reads = 0; writes = 0; emitted = 0;
        pairs_checked = 0; next_checked = 0; stalled_cycles = 0;
        stalls_since_read = 0; stalled_next_checked = 0;
        prior_was_read = 0; was_stalled = 0; selected_bank = 1;
        start = 1;
        @(negedge clk);
        start = 0;
    end
endtask
integer gap_cycle;
initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    launch;
    // Stall a banked byte after its second sample; both requests still use
    // their fixed spacing and only the subsequent byte waits for output.
    wait(emitted == 16400);
    @(negedge clk);
    out_ready = 0;
    wait(valid);
    repeat (7) @(negedge clk);
    out_ready = 1;
    wait(done);
    @(negedge clk);
    if (reads != 65536 || emitted != 32768 || writes != 1 ||
        pairs_checked != 32768 || next_checked != 32766 ||
        stalled_cycles == 0 || stalled_next_checked != 1)
        $fatal(1, "incomplete timing/banking/backpressure coverage: %0d/%0d/%0d pairs=%0d next=%0d stalls=%0d",
               reads, emitted, writes, pairs_checked, next_checked, stalled_cycles);
    if (mismatches !== 24'd1 || even_count !== 24'd0 || odd_count !== 24'd1 ||
        first_addr !== 23'h00408B || first_a !== content(23'h00408B) ||
        first_b !== (content(23'h00408B) ^ 8'h01))
        $fatal(1, "second-read diagnostic or retained first sample changed");
    // These reader-only resets model dump_engine's abort without resetting
    // the bus. At each new gap cycle, no second request may escape afterward.
    if (PAIR_INTERVAL == 89) begin
        for (gap_cycle = 1; gap_cycle <= 2; gap_cycle = gap_cycle + 1) begin
            launch;
            wait(bus_done);
            repeat (gap_cycle + 1) @(negedge clk);
            reader_abort = 1;
            repeat (8) @(negedge clk);
            if (reads != 1 || emitted != 0 || req || valid || busy || bus_busy ||
                {mismatches, even_count, odd_count, first_addr, first_a, first_b} !== 111'd0)
                $fatal(1, "reader abort in gap cycle %0d leaked a read or result", gap_cycle);
            reader_abort = 0;
        end
    end
    $display("Timing: pair=%0d next=89 setup=21 strobe=41 hold=21 core clocks", PAIR_INTERVAL);
    $display("TB PASS: tb_cart_dump_gb_pair_timing");
    $finish;
end
initial begin
    #100000000;
    $fatal(1, "paired timing watchdog: reads=%0d emitted=%0d", reads, emitted);
end
endmodule
`default_nettype wire
