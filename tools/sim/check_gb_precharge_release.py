#!/usr/bin/env python3
"""Check a GB read releases FF precharge without a data/enable skew pulse.

The input-only GBA address bank retains the last driven value in this model.
Three bounded data/enable delays exercise both arrival orders. They are a
timing-hazard model, not measurements of the Pocket's level translators and
not evidence that the reported hardware regression is fixed. The old read
assignment must fail the same check before this test is accepted.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BUS = ROOT / "src/fpga/core/gb_cart_bus.sv"

HARNESS = r"""
`timescale 1ns/1ps
module retained_bank #(parameter DATA_DELAY = 1, ENABLE_DELAY = 3) (
    input wire [7:0] data,
    input wire enable,
    output reg [7:0] held = 8'hFF
);
wire [7:0] delayed_data;
wire delayed_enable;
assign #(DATA_DELAY) delayed_data = data;
assign #(ENABLE_DELAY) delayed_enable = enable;
always @(delayed_data or delayed_enable)
    if (delayed_enable === 1'b1) held = delayed_data;
endmodule

module tb_precharge_release;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1, mode = 0, req = 0, wr = 0, precharge = 1;
reg [15:0] addr = 16'h0134;
reg [7:0] wdata = 0;
wire [7:0] data, rdata;
wire enable, done, busy;
wire [3:0] ctl;
wire [7:0] held_fast_data, held_fast_enable, held_long_enable;
retained_bank #(1, 3) a(data, enable, held_fast_data);
retained_bank #(3, 1) b(data, enable, held_fast_enable);
retained_bank #(1, 7) c(data, enable, held_long_enable);

gb_cart_bus dut (
    .clk(clk), .reset(reset), .gb_mode(mode), .idle_precharge(precharge),
    .req(req), .wr(wr), .addr(addr), .wdata(wdata),
    .rdata(rdata), .done(done), .busy(busy),
    .e_hi_out(data), .e_hi_oe(enable), .e_ctl_out(ctl),
    .e_ad_in(16'hFFFF), .e_hi_in(held_fast_data)
);

task read_probe(input [7:0] unused_write_data);
begin
    repeat (4) @(negedge clk);
    if (enable !== 1 || data !== 8'hFF || ctl[2:1] !== 2'b11)
        $fatal(1, "probe did not precharge with inactive strobes");
    wdata = unused_write_data;
    req = 1;
    @(negedge clk); req = 0;
    wait (ctl[1] === 0);
    if (enable !== 0 || ctl[2] !== 1 || ctl[0] !== 1)
        $fatal(1, "probe drives data or selects/writes the cartridge");
    wait (done);
    if ({held_fast_data, held_fast_enable, held_long_enable, rdata} !== 32'hFFFFFFFF)
        $fatal(1, "precharge corrupted by read data/disable skew: %02x %02x %02x read=%02x",
               held_fast_data, held_fast_enable, held_long_enable, rdata);
    @(negedge clk);
end
endtask

integer i;
initial begin
    repeat (4) @(negedge clk);
    reset = 0; mode = 1;
    // Repeated probe reads, with arbitrary values on the unused write port.
    for (i = 0; i < 26; i = i + 1) begin
        addr = 16'h0134 + i;
        read_probe(8'h00);
        read_probe(8'h55);
        read_probe(8'hAA);
    end
    // Silver ROM reads still leave the data bank released between requests.
    precharge = 0;
    repeat (4) @(negedge clk);
    req = 1;
    @(negedge clk); req = 0;
    while (!done) begin
        if (enable !== 0) $fatal(1, "ROM read re-enabled idle precharge");
        @(negedge clk);
    end
    // The write port must still put real mapper data on the pins.
    repeat (4) @(negedge clk);
    wr = 1; wdata = 8'h3C; addr = 16'h2000; req = 1;
    @(negedge clk); req = 0;
    wait (ctl[2] === 0);
    if (enable !== 1 || data !== 8'h3C)
        $fatal(1, "mapper write data was replaced by precharge");
    wait (ctl[2] === 1);
    if (enable !== 1 || data !== 8'h3C)
        $fatal(1, "mapper write data not held through WR rising");
    wait (done);
    $display("TB PASS: precharge release skew");
    $finish;
end
initial begin
    #2000000;
    $fatal(1, "precharge release watchdog");
end
endmodule
"""


def main():
    source = BUS.read_text()
    fixed = "latched_wdata <= wr ? wdata : 8'hFF;"
    if source.count(fixed) != 1:
        raise AssertionError("expected one read-preserving write-data assignment")
    with tempfile.TemporaryDirectory(prefix="carttools-precharge-") as directory:
        temp = Path(directory)
        harness = temp / "probe.sv"
        harness.write_text(HARNESS)
        bus = temp / "gb_cart_bus.sv"
        output = temp / "probe.vvp"
        for negative in (False, True):
            bus.write_text(source.replace(fixed, "latched_wdata <= wdata;") if negative else source)
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-s", "tb_precharge_release", "-o", str(output),
                 str(harness), str(bus)], capture_output=True, text=True, timeout=60)
            if compile_result.returncode:
                raise AssertionError(compile_result.stdout + compile_result.stderr)
            result = subprocess.run(["vvp", str(output)], capture_output=True,
                                    text=True, timeout=30)
            log = result.stdout + result.stderr
            if negative:
                if result.returncode == 0 or "precharge corrupted by read data/disable skew" not in log:
                    raise AssertionError("old assignment did not fail the skew model:\n" + log)
            elif result.returncode or "TB PASS: precharge release skew" not in log:
                raise AssertionError(log)
    print("check_gb_precharge_release: three skew cases, repeated reads, mapper write and old-code negative control pass")


if __name__ == "__main__":
    main()
