#!/usr/bin/env python3
"""Exercise the shipped reset/power qualification against real cartridge buses.

Only the outer operation ownership is a fixture. Native GB save cancellation
uses the real RAM enable/disable sequencer; GB, GBA and GG write strobes reach
the real cart_pins owner. Run on a build runner, never on the laptop.
"""
from pathlib import Path
import subprocess
import tempfile

from check_restore_integration import ROOT, TOP, assignment, instance, uncomment
from check_gg_integration import clocked_block, port_expression, replace_assignment, replace_port


def harness(source):
    widths = {"cart_mode_req_raw": "[1:0] "}
    names = ("native_adapter", "gg_adapter", "adapter_supported", "cart_powered_s",
             "cart_mode_s", "cart_run_allowed", "cart_mode_req_raw", "gb_mode_s",
             "gba_mode_s", "gg_mode_s", "cart_mode_change")
    expressions = ["wire " + widths.get(name, "") + name + " = "
                   + assignment(source, name) + ";" for name in names]
    for name, port in (("operation_cancel", "cancel"), ("gg_connected", "gg_connected")):
        expressions.append("wire " + name + " = "
                           + port_expression(source, "dump_engine", "dump", port) + ";")
    return "\n".join((PREFIX, *expressions,
                      clocked_block(source, "cart_session_admitted <= 1'b0;"),
                      instance(source, "cart_mode_hold", "mode_hold"),
                      instance(source, "cart_pins", "cart_pins_inst"), BUSES, TEST))


PREFIX = r"""
`default_nettype none
`timescale 1ns/1ps
module tb_cart_reset_admission;
// Fixture ID only; this does not establish the official adapter's APF ID.
localparam [7:0] GG_ADAPTER_ID = 8'h01;
localparam bit ADAPTER_DIAGNOSTIC_ONLY = 0;
reg clk_sys = 0;
always #5 clk_sys = ~clk_sys;
reg pll_core_locked = 0;
reg cart_mode_live_s = 0, cart_report_valid_s = 0, core_reset_n_s = 0;
reg [31:0] cart_report_s = 0;
reg cart_report_changed_s = 0, cart_mode_d = 0;
reg cart_session_admitted;
reg [7:0] cart_session_adapter;
always @(posedge clk_sys) cart_mode_d <= cart_mode_s;
wire key_a_edge = 0;
reg [1:0] restore_want_mode = 0, dump_want_mode = 0;
wire sz_want_gba = 0, save_scan_want_gba = 0, save_scan_start = 0;
wire ee_probe_busy = 0, ee_probe_start = 0;
wire [1:0] probe_mode = 0;
wire [1:0] cart_mode_req;
wire cart_mode_ready;
wire [15:0] gba_ad_out, gb_ad_out, gg_ad_out, gba_ad_in, gb_ad_in;
wire [7:0] gba_hi_out, gb_hi_out, gg_hi_out, gba_hi_in, gb_hi_in, gg_hi_in;
wire gba_ad_oe, gb_ad_oe, gg_ad_oe, gba_hi_oe, gb_hi_oe, gg_hi_oe;
wire [3:0] gba_ctl_out, gb_ctl_out, gg_ctl_out;
wire gba_p30_out, gb_p30_out, gg_p30_out, gba_p30_oe, gb_p30_oe, gg_p30_oe;
wire gba_write_active, gg_write_active;
wire [7:0] cart_tran_bank2, cart_tran_bank3, cart_tran_bank1;
wire [7:4] cart_tran_bank0;
wire cart_tran_bank2_dir, cart_tran_bank3_dir, cart_tran_bank1_dir, cart_tran_bank0_dir;
wire cart_tran_pin30, cart_tran_pin31, cart_tran_pin30_dir, cart_tran_pin31_dir;
wire cart_pin30_pwroff_reset;
wire [15:0] connector_addr = {cart_tran_bank2, cart_tran_bank3};
reg ram_enabled = 0;
wire native_read = gb_mode_s && !cart_tran_bank0[5];
assign cart_tran_bank1 = native_read ? (ram_enabled ? 8'h55 : 8'hFF) : 8'hZZ;
assign cart_tran_pin31 = 1'b0;
"""


BUSES = r"""
reg save_start = 0, gg_start = 0;
wire save_busy, save_done, gb_req, gb_wr, gb_done, gb_busy;
wire [15:0] gb_addr;
wire [7:0] gb_wdata, gb_rdata;
cart_save_gb save_reader (
    .clk(clk_sys), .reset(~pll_core_locked), .start(save_start), .abort(operation_cancel),
    .cart_type(8'h13), .ram_size_code(8'h02), .supported(), .busy(save_busy), .done(save_done),
    .total_bytes(), .responded(), .blank_ff(), .blank_00(), .first_word(),
    .bus_req(gb_req), .bus_wr(gb_wr), .bus_addr(gb_addr), .bus_wdata(gb_wdata),
    .bus_rdata(gb_rdata), .bus_done(gb_done), .out_data(), .out_valid(), .out_ready(1'b0)
);
gb_cart_bus #(.ADDR_SETUP_CYCLES(2), .STROBE_CYCLES(3), .HOLD_CYCLES(3)) gb_bus (
    .clk(clk_sys), .reset(~pll_core_locked), .gb_mode(gb_mode_s), .idle_precharge(1'b1),
    .req(gb_req), .wr(gb_wr), .addr(gb_addr), .wdata(gb_wdata),
    .rdata(gb_rdata), .done(gb_done), .busy(gb_busy),
    .e_ad_out(gb_ad_out), .e_ad_oe(gb_ad_oe), .e_hi_out(gb_hi_out), .e_hi_oe(gb_hi_oe),
    .e_ctl_out(gb_ctl_out), .e_p30_out(gb_p30_out), .e_p30_oe(gb_p30_oe),
    .e_ad_in(gb_ad_in), .e_hi_in(gb_hi_in)
);

reg gba_req = 0;
wire gba_done, gba_busy;
gba_cart_bus gba_bus (
    .clk(clk_sys), .reset(~pll_core_locked), .cart_mode(gba_mode_s),
    .req(gba_req), .wr(1'b1), .addr(28'hE000100), .acc(2'b00), .wdata(32'hA5),
    .rdata(), .done(gba_done), .busy(gba_busy), .write_active(gba_write_active),
    .e_ad_out(gba_ad_out), .e_ad_oe(gba_ad_oe), .e_hi_out(gba_hi_out), .e_hi_oe(gba_hi_oe),
    .e_ctl_out(gba_ctl_out), .e_p30_out(gba_p30_out), .e_p30_oe(gba_p30_oe),
    .e_ad_in(gba_ad_in), .e_hi_in(gba_hi_in)
);

wire gg_busy, gg_done, gg_aborted, gg_req, gg_wr, gg_bus_done, gg_bus_busy;
wire [15:0] gg_addr;
wire [7:0] gg_wdata, gg_rdata;
cart_dump_gg gg_reader (
    .clk(clk_sys), .reset(~pll_core_locked || !gg_connected), .cancel(operation_cancel),
    .start(gg_start), .size_bytes(32'h40000), .verify_enable(1'b1),
    .busy(gg_busy), .done(gg_done), .aborted(gg_aborted), .error(), .total_bytes(),
    .bus_req(gg_req), .bus_wr(gg_wr), .bus_addr(gg_addr), .bus_wdata(gg_wdata),
    .bus_rdata(gg_rdata), .bus_done(gg_bus_done), .bus_busy(gg_bus_busy),
    .out_data(), .out_valid(), .out_ready(1'b0), .verify_checked(), .verify_ok(),
    .first_crc32(), .verify_crc32()
);
gg_cart_bus #(.ADDR_SETUP_CYCLES(2), .STROBE_CYCLES(3), .HOLD_CYCLES(3)) gg_bus (
    .clk(clk_sys), .reset(~pll_core_locked), .gg_mode(gg_mode_s),
    .req(gg_req), .wr(gg_wr), .addr(gg_addr), .wdata(gg_wdata),
    .rdata(gg_rdata), .done(gg_bus_done), .busy(gg_bus_busy), .write_active(gg_write_active), .rejected(),
    .e_ad_out(gg_ad_out), .e_ad_oe(gg_ad_oe), .e_hi_out(gg_hi_out), .e_hi_oe(gg_hi_oe),
    .e_ctl_out(gg_ctl_out), .e_p30_out(gg_p30_out), .e_p30_oe(gg_p30_oe), .e_hi_in(gg_hi_in)
);

integer gb_enables = 0, gb_disables = 0, gg_writes = 0, gba_writes = 0;
integer gb_requests = 0, gb_completions = 0;
always @(posedge clk_sys) begin
    if(gb_req) begin
        gb_requests = gb_requests + 1;
        if(gb_requests < 5) $display("GB request%0d addr=%h state=%0d mode=%b refuse=%b", gb_requests, gb_addr, gb_bus.state, gb_mode_s, gb_bus.refuse);
    end
    if(gb_done) begin
        gb_completions = gb_completions + 1;
        if(gb_completions < 5) $display("GB done%0d state=%0d save=%0d",gb_completions,gb_bus.state,save_reader.state);
    end
end
reg in_write = 0;
reg [1:0] writing_mode = 0;
time write_rise = 0;
integer minimum_hold = 0;
reg [15:0] held_address;
reg [7:0] held_data;
always @(negedge cart_tran_bank0[6]) begin
    if (pll_core_locked && cart_mode_s) begin
        in_write = 1;
        writing_mode = cart_mode_req;
    end
end
always @(posedge cart_tran_bank0[6]) begin
    #0;
    if (in_write && cart_powered_s &&
        cart_session_adapter == cart_report_s[7:0]) begin
        if (!cart_tran_bank1_dir || !cart_tran_bank2_dir || !cart_tran_bank3_dir)
            $fatal(1, "SOFT_RESET_WRITE_HOLD: physical data/address released at /WR rise");
        write_rise = $time;
        held_address = connector_addr;
        held_data = cart_tran_bank1;
        minimum_hold = writing_mode == 2'b10 ? 40 : writing_mode == 2'b11 ? 30 : 10;
        if (writing_mode == 2'b10 && connector_addr == 0) begin
            if (cart_tran_bank1 == 8'h0A) begin ram_enabled = 1; gb_enables = gb_enables + 1; end
            if (cart_tran_bank1 == 0) begin ram_enabled = 0; gb_disables = gb_disables + 1; end
        end
        if (writing_mode == 2'b01) gba_writes = gba_writes + 1;
        if (writing_mode == 2'b11) gg_writes = gg_writes + 1;
    end
    in_write = 0;
end
always @(connector_addr or cart_tran_bank1 or cart_tran_bank1_dir or
         cart_tran_bank2_dir or cart_tran_bank3_dir) begin
    #0;
    if (cart_powered_s && cart_session_adapter == cart_report_s[7:0] &&
        minimum_hold != 0 && $time - write_rise < minimum_hold &&
        (!cart_tran_bank1_dir || !cart_tran_bank2_dir || !cart_tran_bank3_dir ||
         connector_addr !== held_address || cart_tran_bank1 !== held_data))
        $fatal(1, "SOFT_RESET_WRITE_HOLD: physical data/address changed before hold completed");
end
"""


TEST = r"""
task tick(input integer count);
    repeat(count) begin @(negedge clk_sys); #1; end
endtask
task wait_mode(input [1:0] requested);
    integer count;
    begin
        count = 0;
        // Sample after clocks, as the real operation owners do. A bare wait
        // can consume a delta-cycle pulse while idle mode_ready propagates
        // through the combinational qualification on initial admission.
        while ((requested == 2'b10 ? gb_mode_s :
                requested == 2'b01 ? gba_mode_s : gg_mode_s) !== 1'b1 && count < 50) begin
            tick(1); count = count + 1;
        end
        if(count == 50) $fatal(1, "MODE_SETTLE: requested mode did not become ready");
    end
endtask
task assert_idle;
    begin
        #1;
        if (cart_tran_bank1_dir || cart_tran_bank2_dir || cart_tran_bank3_dir ||
            cart_tran_bank0 !== 4'hF || cart_tran_pin30_dir)
            $fatal(1, "PHYSICAL_LOSS: connector not immediately idle");
    end
endtask
task soft_reset;
    begin
        @(negedge clk_sys); core_reset_n_s = 0;
        #1;
        if (!cart_mode_s || !cart_tran_bank1_dir || !cart_tran_bank2_dir ||
            cart_tran_bank0[6] !== 0)
            $fatal(1, "SOFT_RESET_CUT_WRITE: reset discarded the active physical transaction");
        if (cart_run_allowed) $fatal(1, "RESET_ACTION: reset still admitted new work");
        if (!operation_cancel) $fatal(1, "RESET_CANCEL: reset did not cancel the owner");
    end
endtask
integer n, saved_writes;
integer test_stage = 0;
initial begin
    $display("reset test: boot admission");
    tick(5); pll_core_locked = 1;
    cart_report_valid_s = 1; cart_report_s = 32'h01010000; cart_mode_live_s = 1;
    dump_want_mode = 2'b10;
    tick(25);
    if (cart_mode_s || cart_run_allowed) $fatal(1, "RESET_ADMISSION: boot report admitted pins before Reset Exit");
    assert_idle();
    core_reset_n_s = 1;
    test_stage = 1; $display("reset test: native GB mode");
    wait_mode(2'b10); tick(2);
    save_start = 1; tick(1); save_start = 0;
    test_stage = 2; $display("reset test: native GB disabled probe then RAM enable");
    // The real save reader first performs its 256-byte RAM-disabled probe.
    // Cancel during RAM enable, then require its actual disable cleanup.
    wait(cart_tran_bank0[6] === 0 && connector_addr === 16'h0000);
    soft_reset();
    test_stage = 3; $display("reset test: native GB cancellation cleanup");
    n = 0;
    while (!save_done && n < 250) begin tick(1); n = n + 1; end
    if (!save_done || save_busy || gb_enables != 1 || gb_disables != 1 || ram_enabled)
        $fatal(1, "RESET_CLEANUP: native GB RAM disable did not finish after soft reset");
    dump_want_mode = 0; tick(25); assert_idle();

    // The GBA owner releases its request on cancellation. The actual mode
    // holder must keep the write's address/data through the rising edge.
    core_reset_n_s = 1; dump_want_mode = 2'b01;
    test_stage = 4; $display("reset test: GBA mode");
    wait_mode(2'b01); tick(2);
    gba_req = 1; tick(1); gba_req = 0;
    test_stage = 5; $display("reset test: GBA write");
    wait(cart_tran_bank0[6] === 0);
    soft_reset(); dump_want_mode = 0;
    n = 0;
    while (!gba_done && n < 100) begin tick(1); n = n + 1; end
    if (!gba_done || gba_writes != 1) $fatal(1, "RESET_CLEANUP: GBA write did not drain");
    tick(25); assert_idle();

    // Changing the adapter revokes the old session immediately; returning
    // to its ID while reset stays held must not resurrect old admission.
    cart_report_s = 32'h01010001; dump_want_mode = 2'b11;
    test_stage = 6; $display("reset test: adapter change during held reset");
    #1;
    if(cart_mode_s) $fatal(1, "ADAPTER_ID: new adapter inherited old admission");
    assert_idle(); tick(3);
    cart_report_s = 32'h01010000; tick(3);
    if(cart_mode_s) $fatal(1, "ADAPTER_ID: old adapter admission resurrected without Reset Exit");
    cart_report_s = 32'h01010001; tick(3);
    core_reset_n_s = 1;
    test_stage = 7; $display("reset test: GG mode");
    wait_mode(2'b11); tick(2);
    gg_start = 1; tick(1); gg_start = 0;
    test_stage = 8; $display("reset test: GG mapper write");
    wait(cart_tran_bank0[6] === 0);
    soft_reset();
    test_stage = 9; $display("reset test: GG cancellation cleanup");
    n = 0;
    while (!gg_done && n < 100) begin tick(1); n = n + 1; end
    if(!gg_done || gg_busy || !gg_aborted || gg_writes != 1)
        $fatal(1, "RESET_CLEANUP: GG mapper transaction did not drain");
    dump_want_mode = 0; tick(25); assert_idle();

    // Physical power loss is allowed to break a pulse and must never wait
    // for the software owner or sticky Reset Exit admission.
    core_reset_n_s = 1; dump_want_mode = 2'b11;
    test_stage = 10; $display("reset test: GG mode for power-loss test");
    wait_mode(2'b11); tick(2);
    gg_start = 1; tick(1); gg_start = 0;
    test_stage = 11; $display("reset test: GG write for power-loss test");
    wait(cart_tran_bank0[6] === 0);
    @(negedge clk_sys); cart_mode_live_s = 0;
    assert_idle(); tick(3);
    if(cart_mode_s || cart_session_admitted) $fatal(1, "PHYSICAL_LOSS: admission survived power loss");
    core_reset_n_s = 0; cart_mode_live_s = 1; tick(25);
    if(cart_mode_s) $fatal(1, "RESET_ADMISSION: power return admitted session during reset");
    assert_idle();
    $display("TB PASS: actual top reset admission and physical GB/GBA/GG cleanup");
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "reset admission watchdog stage=%0d mode=%b ready=%b admitted=%b run=%b GB=%b save_state=%0d offset=%0d gb_state=%0d gb_req=%b gb_done=%b requests=%0d completions=%0d GG=%b gg_reader=%0d gg_bus=%0d",
        test_stage, cart_mode_req, cart_mode_ready, cart_session_admitted, cart_run_allowed,
        gb_mode_s, save_reader.state, save_reader.offset, gb_bus.state, gb_req, gb_done,gb_requests,gb_completions,
        gg_mode_s, gg_reader.state, gg_bus.state);
end
endmodule
`default_nettype wire
"""


def main():
    source = uncomment(TOP.read_text())
    mutants = (
        ("soft reset cuts power", replace_assignment(source, "cart_mode_s",
            lambda value: "core_reset_n_s && (" + value + ")"), "SOFT_RESET"),
        ("boot admission bypassed", replace_assignment(source, "cart_mode_s",
            lambda value: value.replace("cart_session_admitted", "1'b1")), "RESET_ADMISSION"),
        ("owner cancellation missing", replace_port(source, "dump_engine", "dump", "cancel",
            lambda value: value.replace("!core_reset_n_s", "1'b0")), "RESET_CANCEL"),
    )
    dependencies = [
        "src/fpga/core/cart_pins.sv", "src/fpga/core/cart_mode_hold.sv",
        "src/fpga/core/gb_cart_bus.sv", "src/fpga/core/gba_cart_bus.sv",
        "src/fpga/core/gg_cart_bus.sv", "src/fpga/services/dump/cart_save_gb.sv",
        "src/fpga/services/dump/cart_dump_gg.sv",
    ]
    with tempfile.TemporaryDirectory(prefix="carttools-reset-admission-") as directory:
        temp = Path(directory)
        for name, candidate, expected in (("shipped qualification", source, None), *mutants):
            bench = temp / "reset.sv"
            bench.write_text(harness(candidate))
            executable = temp / "reset.vvp"
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-s", "tb_cart_reset_admission", "-o", str(executable),
                 str(bench), *(str(ROOT / path) for path in dependencies)],
                capture_output=True, text=True, timeout=60,
            )
            if compiled.returncode:
                raise AssertionError(compiled.stdout + compiled.stderr)
            result = subprocess.run(["vvp", str(executable)], capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            if expected is None:
                if result.returncode or "TB PASS:" not in output:
                    raise AssertionError(f"{name}: {output}")
            elif result.returncode == 0 or expected not in output:
                raise AssertionError(f"{name}: intended assertion did not fail:\n{output}")
    print("PASS: actual top reset admission, GB disable, GBA/GG write drain, and three mutations")


if __name__ == "__main__":
    main()
