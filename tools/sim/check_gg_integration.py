#!/usr/bin/env python3
"""Exercise actual top-level GG dispatch, ownership, and action qualification.

The harness extracts shipped expressions, instance connections, and clocked
blocks; the cartridge identifiers and dump engine are completion fixtures.
Their bus protocols have separate benches. The official adapter reported ID 1
in the C982 hardware capture 20260914_205342.png (raw report 01010001). The
production ID must exercise the enabled GG path; explicit FF/00 refusal and
passive-diagnostic settings are checked independently. Run on a build runner,
never on the laptop.
"""

from pathlib import Path
import re
import subprocess
import tempfile

from check_restore_integration import ROOT, TOP, assignment, instance, run, uncomment


def port_expression(source, module, name, port):
    text = instance(source, module, name)
    match = re.search(r"\." + re.escape(port) + r"\s*\(", text)
    if not match:
        raise AssertionError(f"missing {name}.{port} connection")
    start = match.end()
    depth = 1
    for end in range(start, len(text)):
        depth += (text[end] == "(") - (text[end] == ")")
        if depth == 0:
            return text[start:end].strip()
    raise AssertionError(f"unbalanced {name}.{port} connection")


def clocked_block(source, marker):
    at = source.index(marker)
    start = source.rfind("always @(posedge clk_sys) begin", 0, at)
    end = source.index("\nend", at) + len("\nend")
    if start < 0:
        raise AssertionError(f"missing top clocked block at {marker}")
    return source[start:end]


def replace_assignment(source, name, change):
    pattern = (r"(\b(?:wire(?:\s+\[[^\]]+\])?|assign)\s+" + re.escape(name)
               + r"\s*=\s*)(.*?)(;)")

    def replacement(match):
        updated = change(match[2])
        if updated == match[2]:
            raise AssertionError(f"mutation did not change {name}")
        return match[1] + updated + match[3]

    mutated, count = re.subn(pattern, replacement, source, flags=re.S)
    if count != 1:
        raise AssertionError(f"expected one assignment for {name}, got {count}")
    return mutated


def replace_port(source, module, name, port, change):
    original = instance(source, module, name)
    expression = port_expression(source, module, name, port)
    updated = change(expression)
    if updated == expression:
        raise AssertionError(f"mutation did not change {name}.{port}")
    return source.replace(original, original.replace(expression, updated, 1), 1)


def replace_clocked_block(source, marker, change):
    original = clocked_block(source, marker)
    updated = change(original)
    if updated == original:
        raise AssertionError(f"mutation did not change block at {marker}")
    return source.replace(original, updated, 1)


def control_harness(source):
    names = (
        "native_adapter", "gg_adapter", "adapter_supported", "adapter_diagnostic",
        "cart_powered_s", "cart_mode_s", "cart_run_allowed", "slot_protocol",
        "cart_mode_req_raw", "gb_mode_s", "gba_mode_s",
        "gg_mode_s", "cart_mode_change", "cart_mode_fell", "cart_engine_busy", "scan_start", "sz_start",
        "gg_left", "gg_right", "gg_size_change", "gg_size_bytes", "cart_kind",
        "action_rom_available", "action_save_available", "dump_ready", "save_ready",
        "action_validation_complete", "action_validated_rom_available",
        "action_validated_save_available", "restore_available", "dump_start",
    )
    widths = {"slot_protocol": "[1:0] ", "cart_mode_req_raw": "[1:0] ",
              "gg_size_bytes": "[31:0] ", "cart_kind": "[2:0] "}
    expressions = ["wire " + widths.get(name, "") + name + " = "
                   + assignment(source, name) + ";" for name in names]
    for name, width, module, inst, port in (
        ("connected_to_dump", "", "dump_engine", "dump", "gg_connected"),
        ("routed_dump_cancel", "", "dump_engine", "dump", "cancel"),
        ("routed_rom_source", "[1:0] ", "dump_engine", "dump", "rom_source"),
        ("routed_gg_size", "[31:0] ", "dump_engine", "dump", "gg_size_bytes"),
        ("routed_pin_mode", "[1:0] ", "cart_pins", "cart_pins_inst", "mode"),
        ("native_gb_reset", "", "cart_identify_gb", "identify_gb", "reset"),
        ("native_gba_reset", "", "cart_identify_gba", "identify", "reset"),
        ("routed_gg_req", "", "gg_cart_bus", "gg_bus", "req"),
        ("routed_gg_wr", "", "gg_cart_bus", "gg_bus", "wr"),
        ("routed_gg_addr", "[15:0] ", "gg_cart_bus", "gg_bus", "addr"),
        ("routed_gg_wdata", "[7:0] ", "gg_cart_bus", "gg_bus", "wdata"),
    ):
        expressions.append("wire " + width + name + " = "
                           + port_expression(source, module, inst, port) + ";")
    probe = instance(source, "cart_probe", "probe").replace(
        "cart_probe probe", "cart_probe #(.WAKE_CYCLES(1)) probe")
    blocks = [clocked_block(source, marker) for marker in (
        "cart_session_admitted <= 1'b0;",
        "gg_left_d <= gg_left;", "id_seq <= 4'd0;", "id_valid <= 1'b0;",
        "dump_state <= D_IDLE;",
    )]
    return "\n".join((HARNESS_PREFIX, *expressions,
                      instance(source, "cart_mode_hold", "mode_hold"), probe,
                      instance(source, "cart_action_guard", "action_guard"),
                      *blocks, HARNESS_TEST))


HARNESS_PREFIX = r"""
`default_nettype none
`timescale 1ns/1ps
module tb_gg_integration;
// Model the hardware-confirmed official adapter report ID. The Python runner
// also extracts the production constant and independently tests FF and 00.
parameter [7:0] GG_ADAPTER_ID = 8'h01;
parameter bit ADAPTER_DIAGNOSTIC_ONLY = 1'b0;
reg clk_sys = 0;
always #5 clk_sys = ~clk_sys;
reg pll_core_locked = 0;
reg cart_report_valid_s = 0;
reg [31:0] cart_report_s = 0;
reg cart_mode_live_s = 1, core_reset_n_s = 1, cart_report_changed_s = 0;
reg cart_mode_d = 0, cart_mode_ready = 1, cart_wake_pulse = 0;
reg cart_session_admitted;
reg [7:0] cart_session_adapter;
reg [31:0] cont1_key_s = 0;
wire key_a = cont1_key_s[4], key_x = cont1_key_s[6], key_y = cont1_key_s[7];
reg key_a_d = 0, key_x_d = 0, key_y_d = 0;
wire key_a_edge = key_a && !key_a_d;
wire key_x_edge = key_x && !key_x_d;
wire key_y_edge = key_y && !key_y_d;
always @(posedge clk_sys) begin
    cart_mode_d <= cart_mode_s;
    key_a_d <= key_a;
    key_x_d <= key_x;
    key_y_d <= key_y;
end
reg [1:0] restore_want_mode = 0, dump_want_mode = 0;
reg sz_want_gba = 0, save_scan_want_gba = 0, save_scan_start = 0;
reg ee_probe_busy = 0, ee_probe_start = 0;
reg gba_write_active = 0, gg_write_active = 0;
wire [1:0] cart_mode_req, probe_mode, probe_answered_protocol;
wire [2:0] platform;
wire probe_busy, probe_done, gb_start, gba_start, gg_start;
reg probe_sizing = 0;
reg gbid_done = 0, id_done = 0, ggid_done = 0, ggid_busy = 0;
reg [2:0] gbid_result = 0, id_result = 0, ggid_result = 0;
reg restore_block = 0, restore_busy = 0, restore_probe_pending = 0;
reg restore_preflight_request = 0, restore_reprobe_request = 0;
reg restore_poisoned_s = 0, restore_geometry_ok = 1;
// Stale native metadata is deliberately all permissive. A GG screen must
// exclude native save and restore actions even when these bits remain set.
reg dump_save_supported = 1, gba_save_ok = 1, sz_size_valid = 1;
reg gba_sram_ok = 1, gba_flash_ok = 1;
reg sz_done = 0, save_scan_done = 0, ee_probe_done = 0;
reg svs_eeprom = 0, svs_ambiguous = 0, svs_complete = 1;
reg [7:0] gbid_cgb_flag = 8'hC0;
reg id_valid, gg_size_512, gg_left_d, gg_right_d;
reg [3:0] id_seq;
wire action_pending, action_scan_start, action_dump_start, action_save_mode;
localparam [1:0] D_IDLE = 0, D_RUN = 1, D_OK = 2, D_FAIL = 3;
reg [1:0] dump_state;
reg dump_busy = 0, dump_done = 0, dump_failed = 0;
reg [31:0] latched_size = 0;
reg [1:0] latched_source = 0;
reg [2:0] latched_kind = 0;
reg ggid_req = 1, ggid_wr = 0, ggdmp_req = 0, ggdmp_wr = 1;
reg [15:0] ggid_addr = 16'h7FF0, ggdmp_addr = 16'hFFFF;
reg [7:0] ggid_wdata = 8'hA5, ggdmp_wdata = 8'h1F;
integer gb_starts = 0, gba_starts = 0, gg_starts = 0, dump_starts = 0;
integer previous_dumps, previous_seq, result_code;
always @(posedge clk_sys) begin
    if (!pll_core_locked) begin
        dump_busy <= 0;
        latched_size <= 0;
        latched_source <= 0;
        latched_kind <= 0;
        gb_starts <= 0;
        gba_starts <= 0;
        gg_starts <= 0;
        dump_starts <= 0;
    end else begin
        if (gb_start) gb_starts <= gb_starts + 1;
        if (gba_start) gba_starts <= gba_starts + 1;
        if (gg_start) gg_starts <= gg_starts + 1;
        // Model only the actual engine's start edge and busy/result lifetime.
        if (dump_start) begin
            dump_busy <= 1;
            latched_size <= routed_gg_size;
            latched_source <= routed_rom_source;
            latched_kind <= cart_kind;
            dump_starts <= dump_starts + 1;
        end else if (dump_done) dump_busy <= 0;
        if (!gg_adapter && gg_mode_s)
            $fatal(1, "GG_QUALIFICATION: unqualified adapter enabled GG bus");
        if (!native_adapter && (gb_mode_s || gba_mode_s))
            $fatal(1, "NATIVE_QUALIFICATION: adapter enabled native bus");
        if (gg_adapter && (gb_start || gba_start))
            $fatal(1, "GG_FALLTHROUGH_NATIVE: GG scan started native identifier");
        if (gg_adapter && sz_start)
            $fatal(1, "GG_FALLTHROUGH_NATIVE: GG result started native size probe");
        if (action_dump_start && (dump_ready || save_ready))
            $fatal(1, "HANDOFF_READY: second action exposed on dump start");
    end
end
"""


HARNESS_TEST = r"""
task tick(input integer n);
    repeat (n) begin @(negedge clk_sys); #1; end
endtask
task session(input [7:0] adapter_id);
    begin
        pll_core_locked = 0;
        cart_report_valid_s = 1;
        cart_report_s = 32'h01010000 | {24'd0, adapter_id};
        cart_mode_live_s = 1;
        core_reset_n_s = 1;
        cart_report_changed_s = 0;
        cart_mode_ready = 1;
        cart_wake_pulse = 0;
        cont1_key_s = 0;
        dump_done = 0;
        dump_failed = 0;
        dump_want_mode = 0;
        restore_want_mode = 0;
        gba_write_active = 0;
        gg_write_active = 0;
        gbid_done = 0;
        id_done = 0;
        ggid_done = 0;
        ggid_busy = 0;
        tick(3);
        pll_core_locked = 1;
        tick(3);
    end
endtask
task scan;
    begin cart_wake_pulse = 1; tick(1); cart_wake_pulse = 0; end
endtask
task wait_identifier(input integer protocol);
    integer timeout_count;
    begin
        timeout_count = 0;
        while (!(protocol == 0 ? gb_start : protocol == 1 ? gba_start : gg_start)) begin
            tick(1);
            timeout_count = timeout_count + 1;
            if (timeout_count > 40) $fatal(1, "IDENTIFIER_TIMEOUT: wrong top dispatch");
        end
        if (protocol == 2) ggid_busy = 1;
    end
endtask
task finish_identifier(input integer protocol, input [2:0] result_value);
    begin
        case (protocol)
            0: begin gbid_result = result_value; gbid_done = 1; end
            1: begin id_result = result_value; id_done = 1; end
            2: begin ggid_result = result_value; ggid_done = 1; ggid_busy = 0; end
        endcase
        tick(1);
        gbid_done = 0;
        id_done = 0;
        ggid_done = 0;
    end
endtask
task wait_probe;
    integer timeout_count;
    begin
        timeout_count = 0;
        while (!probe_done) begin
            tick(1);
            timeout_count = timeout_count + 1;
            if (timeout_count > 40) $fatal(1, "PROBE_TIMEOUT: GG response did not finish");
        end
        tick(2);
    end
endtask
task wait_dump_start;
    integer timeout_count;
    begin
        timeout_count = 0;
        while (!action_dump_start) begin
            tick(1);
            timeout_count = timeout_count + 1;
            if (timeout_count > 40) $fatal(1, "ACTION_TIMEOUT: fresh GG action did not start");
        end
    end
endtask
task start_gg_dump;
    begin
        cont1_key_s = 1 << 6; tick(1); cont1_key_s = 0;
        wait_identifier(2); finish_identifier(2, 0); wait_dump_start();
        tick(1);
        if (!dump_busy || dump_state != D_RUN)
            $fatal(1, "RESULT_FIXTURE: validated GG action did not enter RUN");
    end
endtask
task assert_disabled;
    begin
        if (gb_mode_s || gba_mode_s || gg_mode_s || routed_pin_mode != 0 ||
            connected_to_dump || !native_gb_reset || !native_gba_reset)
            $fatal(1, "SESSION_RESET: lost/unsupported session retained bus authority");
    end
endtask
initial begin
    // Production-disable and passive-diagnostic runs must remain electrically
    // idle even with plausible powered reports and clients requesting modes.
    if (ADAPTER_DIAGNOSTIC_ONLY || GG_ADAPTER_ID == 8'hFF || GG_ADAPTER_ID == 0) begin
        session(8'h01);
        dump_want_mode = 3; tick(3); assert_disabled();
        dump_want_mode = 2; tick(3); assert_disabled();
        dump_want_mode = 1; tick(3); assert_disabled();
        dump_want_mode = 0;
        scan(); wait_probe();
        if (gb_starts || gba_starts || gg_starts || dump_ready || save_ready || restore_available)
            $fatal(1, "PASSIVE_DISPATCH: disabled adapter started a cartridge action");
        if (ADAPTER_DIAGNOSTIC_ONLY) begin
            session(8'h00);
            dump_want_mode = 2; tick(3); assert_disabled();
            dump_want_mode = 1; tick(3); assert_disabled();
        end
        $display("TB PASS: GG integration disabled/passive fixture");
        $finish;
    end

    session(8'h02);
    dump_want_mode = 3; tick(3); assert_disabled();
    if (slot_protocol != 3 || !adapter_diagnostic)
        $fatal(1, "UNSUPPORTED_DISPATCH: unknown adapter did not fail closed");
    dump_want_mode = 0;
    scan(); wait_probe();
    if (platform != 7 || gb_starts || gba_starts || gg_starts)
        $fatal(1, "UNSUPPORTED_DISPATCH: unknown adapter ran an identifier");

    session(8'h01);
    dump_want_mode = 3; tick(3);
    if (!gg_mode_s || gb_mode_s || gba_mode_s || routed_pin_mode != 3 || !connected_to_dump)
        $fatal(1, "GG_QUALIFICATION: fixture GG report failed to select only GG");
    cart_mode_ready = 0; tick(1);
    if (gg_mode_s || !connected_to_dump)
        $fatal(1, "GG_CONNECTED: physical connection incorrectly follows turnaround");
    cart_mode_ready = 1;
    dump_want_mode = 0; tick(2);
    if (gg_mode_s || !connected_to_dump)
        $fatal(1, "GG_CONNECTED: physical connection incorrectly follows parked mode");
    dump_want_mode = 3; tick(2);
    cart_report_valid_s = 0; tick(2); assert_disabled();
    cart_report_valid_s = 1;
    cart_report_s[24] = 0; tick(2); assert_disabled();
    cart_report_s[24] = 1;
    cart_report_s[16] = 0; tick(2); assert_disabled();
    cart_report_s[16] = 1;
    cart_mode_live_s = 0; tick(2); assert_disabled();

    // A powered report at boot cannot admit a session before Reset Exit.
    session(8'h01);
    pll_core_locked = 0;
    core_reset_n_s = 0; tick(3);
    pll_core_locked = 1;
    dump_want_mode = 3; tick(3); assert_disabled();
    if (cart_run_allowed || cart_session_admitted)
        $fatal(1, "RESET_ADMISSION: powered report bypassed Reset Exit");
    core_reset_n_s = 1; tick(4);
    if (!cart_run_allowed || !gg_mode_s)
        $fatal(1, "RESET_ADMISSION: Reset Exit did not admit the powered adapter");

    // Reset Enter cancels the owner but must not revoke its physical bus.
    // The real bus/write-drain waveform has its own extracted-top test.
    gg_write_active = 1;
    core_reset_n_s = 0; tick(3);
    if (!cart_mode_s || !connected_to_dump || !gg_mode_s || routed_pin_mode != 3 ||
        !routed_dump_cancel || cart_run_allowed)
        $fatal(1, "GG_SOFT_RESET: reset cut owner mode instead of requesting cancellation");
    cont1_key_s = (1 << 4) | (1 << 6) | (1 << 7);
    cart_wake_pulse = 1; tick(2);
    if (scan_start || dump_ready || save_ready || restore_available || action_pending || dump_start)
        $fatal(1, "RESET_ADMISSION: reset admitted a new action");
    cont1_key_s = 0;
    cart_wake_pulse = 0;
    // Observing another adapter revokes admission permanently until the next
    // Reset Exit, even if the original numeric ID returns while reset holds.
    cart_report_s[7:0] = 8'h00; tick(2); assert_disabled();
    cart_report_s[7:0] = 8'h01; tick(2); assert_disabled();
    if (cart_session_admitted)
        $fatal(1, "RESET_ADMISSION: returning adapter inherited expired admission");
    gg_write_active = 0;
    core_reset_n_s = 1; tick(4);

    session(8'h01);
    dump_want_mode = 3; tick(3);
    gg_write_active = 1;
    dump_want_mode = 0; tick(3);
    if (cart_mode_req != 3 || !gg_mode_s || routed_pin_mode != 3)
        $fatal(1, "GG_WRITE_HOLD: internal cancellation cut the mapper write mode");
    cart_report_s[7:0] = 8'h02; tick(1); assert_disabled();
    gg_write_active = 0; tick(2);

    session(8'h00);
    if (native_gb_reset || native_gba_reset)
        $fatal(1, "SESSION_RESET: native identifier reset while merely parked");
    cart_report_changed_s = 1; tick(1);
    if (!native_gb_reset || !native_gba_reset)
        $fatal(1, "SESSION_REPORT_RESET: same-ID report change did not reset native identifiers");
    cart_report_changed_s = 0; tick(1);
    if (native_gb_reset || native_gba_reset)
        $fatal(1, "SESSION_REPORT_RESET: native reset outlived report-change pulse");
    dump_want_mode = 2; tick(3);
    if (!gb_mode_s || gba_mode_s || gg_mode_s || connected_to_dump)
        $fatal(1, "NATIVE_QUALIFICATION: GB request routed incorrectly");
    dump_want_mode = 1; tick(3);
    if (!gba_mode_s || gb_mode_s || gg_mode_s || connected_to_dump)
        $fatal(1, "NATIVE_QUALIFICATION: GBA request routed incorrectly");
    cart_report_s[7:0] = 8'h01; tick(1);
    if (!native_gb_reset || !native_gba_reset)
        $fatal(1, "SESSION_RESET: adapter switch did not abort native identifiers");

    // Native dispatch still escalates only the entirely undriven GB result.
    session(8'h00);
    scan(); wait_identifier(0); finish_identifier(0, 3); wait_probe();
    if (platform != 3 || gb_starts != 1 || gba_starts || gg_starts)
        $fatal(1, "GB_SAFETY_GATE: responsive unknown GB escalated or misrouted");
    scan(); wait_identifier(0); finish_identifier(0, 1);
    wait_identifier(1); finish_identifier(1, 0); wait_probe();
    if (platform != 1 || gb_starts != 2 || gba_starts != 1 || gg_starts)
        $fatal(1, "NATIVE_ESCALATION: empty GB response failed to reach GBA");

    // Every GG verdict stays in the GG protocol, including blank or invalid
    // headers. There is no native probing fallback on any GG read result.
    for (result_code = 1; result_code < 8; result_code = result_code + 1) begin
        session(8'h01);
        scan(); wait_identifier(2); finish_identifier(2, result_code[2:0]); wait_probe();
        if (gb_starts || gba_starts || gg_starts != 1 || probe_answered_protocol != 2 || dump_ready)
            $fatal(1, "GG_FALLTHROUGH_NATIVE: failed GG identification used native facts");
    end

    session(8'h01);
    scan(); wait_identifier(2); finish_identifier(2, 0); wait_probe();
    if (platform != 6 || !id_valid || !dump_ready || routed_rom_source != 2 || cart_kind != 4)
        $fatal(1, "GG_ROM_ROUTE: successful GG header did not select GG dump source/type");
    if (save_ready || action_save_available || action_validated_save_available)
        $fatal(1, "GG_SAVE_EXCLUSION: stale native save metadata enabled GG saves");
    if (restore_available)
        $fatal(1, "GG_RESTORE_EXCLUSION: stale native geometry enabled GG restore");
    if ({routed_gg_req, routed_gg_wr, routed_gg_addr, routed_gg_wdata} !==
        {ggid_req, ggid_wr, ggid_addr, ggid_wdata})
        $fatal(1, "GG_MASTER_ROUTE: idle GG bus did not select identifier");
    cont1_key_s = 1 << 7; tick(2); cont1_key_s = 0; tick(2);
    if (action_pending || dump_starts) $fatal(1, "GG_SAVE_EXCLUSION: Y queued a GG save");

    // A completion without a running operation cannot publish a result.
    dump_done = 1; tick(1); dump_done = 0;
    if (dump_state != D_IDLE)
        $fatal(1, "STALE_COMPLETION: idle completion resurrected a result");
    // A real previous result must disappear when its displayed length changes.
    start_gg_dump();
    dump_done = 1; tick(1); dump_done = 0;
    if (dump_state != D_OK) $fatal(1, "RESULT_FIXTURE: expected completed dump display");
    previous_seq = id_seq;
    cont1_key_s = 1 << 3; tick(1); cont1_key_s = 0; tick(1);
    if (gg_size_bytes != 524288 || dump_state != D_IDLE || id_seq == previous_seq)
        $fatal(1, "GG_SIZE_RESULT: length change retained stale result or screen snapshot");

    previous_dumps = dump_starts;
    cont1_key_s = 1 << 6; tick(1);
    if (!action_pending || !action_scan_start || action_dump_start)
        $fatal(1, "GG_FRESHNESS: X bypassed new identification");
    // The pending action exists one cycle before cart_probe takes ownership.
    cont1_key_s = 1 << 2; tick(1); cont1_key_s = 0;
    if (gg_size_bytes != 524288)
        $fatal(1, "GG_PENDING_SIZE: length changed during pending action handoff");
    wait_identifier(2); tick(3);
    if (!action_pending || dump_starts != previous_dumps || action_dump_start)
        $fatal(1, "GG_FRESHNESS: cached header started dump before fresh response");
    finish_identifier(2, 0); wait_dump_start();
    if (dump_busy || action_pending || dump_ready || save_ready)
        $fatal(1, "HANDOFF_READY: dump start did not reserve the handoff cycle");
    // The engine sees this start pulse on the next edge. A fresh direction
    // edge or second X on that same edge must not change/queue the operation.
    cont1_key_s = (1 << 2) | (1 << 6); tick(1); cont1_key_s = 0;
    if (gg_size_bytes != 524288 || latched_size != 524288)
        $fatal(1, "GG_START_SIZE: selected length changed while engine latched start");
    if (!dump_busy || action_pending || latched_source != 2 || latched_kind != 4)
        $fatal(1, "GG_START_ROUTE: wrong source, type, or duplicate action at handoff");
    if ({routed_gg_req, routed_gg_wr, routed_gg_addr, routed_gg_wdata} !==
        {ggdmp_req, ggdmp_wr, ggdmp_addr, ggdmp_wdata})
        $fatal(1, "GG_MASTER_ROUTE: active dump did not own GG bus");
    tick(2);
    cont1_key_s = 1 << 2; tick(1); cont1_key_s = 0; tick(1);
    if (gg_size_bytes != 524288 || dump_ready || save_ready)
        $fatal(1, "GG_BUSY_SIZE: active dump allowed length or action change");
    dump_done = 1; tick(1); dump_done = 0; tick(1);
    cont1_key_s = 1 << 2; tick(1); cont1_key_s = 0; tick(1);
    if (gg_size_bytes != 262144 || dump_state != D_IDLE)
        $fatal(1, "GG_SIZE_RESULT: new manual length retained old CRC verdict");

    // A valid cached GG header cannot authorize the newly failed cartridge.
    previous_dumps = dump_starts;
    cont1_key_s = 1 << 6; tick(1); cont1_key_s = 0;
    wait_identifier(2); finish_identifier(2, 3); wait_probe();
    if (action_pending || action_dump_start || dump_starts != previous_dumps || dump_ready)
        $fatal(1, "GG_FRESHNESS: failed fresh header used cached GG permission");

    // A coherent report change invalidates metadata even when the power bit
    // stays high and cancels an action waiting for a fresh header.
    scan(); wait_identifier(2); finish_identifier(2, 0); wait_probe();
    cont1_key_s = 1 << 6; tick(1); cont1_key_s = 0;
    wait_identifier(2);
    cart_report_s[7:0] = 8'h02;
    cart_report_changed_s = 1; tick(1); cart_report_changed_s = 0;
    if (id_valid || action_pending || action_dump_start || connected_to_dump)
        $fatal(1, "GG_SESSION_CHANGE: report change retained cached identity or action");
    ggid_busy = 0; tick(2);
    // The probe's explicit aborted/no-platform result may become the next
    // display-valid result. It must never restore the previous GG permission.
    if (platform == 6 || action_pending || action_dump_start || connected_to_dump || dump_ready)
        $fatal(1, "GG_SESSION_CHANGE: report change retained identity or pending action");

    // Reset and session invalidation outrank a completion arriving on the
    // same edge. Completions arriving after Reset Exit cannot resurrect it.
    session(8'h01);
    scan(); wait_identifier(2); finish_identifier(2, 0); wait_probe();
    start_gg_dump();
    core_reset_n_s = 0;
    dump_done = 1; tick(1); dump_done = 0;
    if (dump_state != D_IDLE)
        $fatal(1, "RESET_RESULT_PRIORITY: completion won over Reset Enter");
    core_reset_n_s = 1; tick(4);
    dump_done = 1; tick(1); dump_done = 0;
    if (dump_state != D_IDLE)
        $fatal(1, "STALE_COMPLETION: late completion revived pre-reset result");
    scan(); wait_identifier(2); finish_identifier(2, 0); wait_probe();
    start_gg_dump();
    cart_report_changed_s = 1;
    dump_done = 1; tick(1);
    cart_report_changed_s = 0;
    dump_done = 0;
    if (dump_state != D_IDLE)
        $fatal(1, "RESET_RESULT_PRIORITY: completion won over session invalidation");

    $display("TB PASS: GG integration actual top control wiring");
    $finish;
end
initial begin #100000; $fatal(1, "GG integration watchdog"); end
endmodule
"""


def main():
    source = uncomment(TOP.read_text())
    production_id = re.search(r"localparam\s+\[7:0\]\s+GG_ADAPTER_ID\s*=\s*(.*?);", source)
    if not production_id:
        raise AssertionError("missing production GG adapter ID constant")
    sources = [ROOT / path for path in (
        "src/fpga/core/cart_mode_hold.sv", "src/fpga/core/cart_action_guard.sv",
        "src/fpga/services/identify/cart_probe.sv",
    )]
    with tempfile.TemporaryDirectory(prefix="carttools-gg-integration-") as directory:
        temp = Path(directory)
        harness = temp / "integration.sv"
        executable = temp / "integration.vvp"

        def simulate(text, expected_failure=None, parameters=(),
                     expected_pass="TB PASS: GG integration actual top control wiring"):
            harness.write_text(control_harness(text))
            run(["iverilog", "-g2012", "-s", "tb_gg_integration", *parameters,
                 "-o", str(executable), str(harness), *map(str, sources)])
            result = subprocess.run(["vvp", str(executable)], cwd=ROOT, text=True,
                                    capture_output=True, timeout=30)
            log = result.stdout + result.stderr
            if expected_failure:
                if result.returncode == 0 or expected_failure not in log:
                    raise AssertionError(f"missed {expected_failure} mutation:\n{log}")
            elif result.returncode or expected_pass not in log:
                raise AssertionError("GG top integration failed:\n" + log)

        simulate(source)
        simulate(source, parameters=("-Ptb_gg_integration.GG_ADAPTER_ID=" + production_id[1],))
        disabled_pass = "TB PASS: GG integration disabled/passive fixture"
        simulate(source, parameters=("-Ptb_gg_integration.GG_ADAPTER_ID=255",),
                 expected_pass=disabled_pass)
        simulate(source, parameters=("-Ptb_gg_integration.GG_ADAPTER_ID=0",),
                 expected_pass=disabled_pass)
        simulate(source, parameters=("-Ptb_gg_integration.ADAPTER_DIAGNOSTIC_ONLY=1",),
                 expected_pass=disabled_pass)
        mutations = (
            ("gg_mode_s", lambda e: re.sub(r"&&\s*gg_adapter\b", "", e), "GG_QUALIFICATION"),
            ("slot_protocol", lambda e: e.replace("? 2'd2", "? 2'd0", 1), "GG_FALLTHROUGH_NATIVE"),
            ("action_save_available", lambda e: e.replace("platform == 3'd2", "(platform == 3'd2 || platform == 3'd6)", 1), "GG_SAVE_EXCLUSION"),
            ("action_validated_save_available", lambda e: e.replace("platform == 3'd2", "(platform == 3'd2 || platform == 3'd6)", 1), "GG_SAVE_EXCLUSION"),
            ("restore_available", lambda e: e.replace("platform == 3'd2", "(platform == 3'd2 || platform == 3'd6)", 1), "GG_RESTORE_EXCLUSION"),
            ("gg_size_change", lambda e: re.sub(r"&&\s*!action_pending\b", "", e), "GG_PENDING_SIZE"),
            ("gg_size_change", lambda e: re.sub(r"&&\s*!action_dump_start\b", "", e), "GG_START_SIZE"),
            ("dump_ready", lambda e: re.sub(r"&&\s*!action_dump_start\b", "", e), "HANDOFF_READY"),
        )
        for name, change, failure in mutations:
            simulate(replace_assignment(source, name, change), expected_failure=failure)
        for module, name in (("cart_identify_gb", "identify_gb"),
                             ("cart_identify_gba", "identify")):
            simulate(replace_port(source, module, name, "reset",
                                  lambda e: re.sub(r"\|\|\s*!native_adapter\b", "", e)),
                     expected_failure="SESSION_RESET")
            simulate(replace_port(source, module, name, "reset",
                                  lambda e: re.sub(r"\|\|\s*cart_report_changed_s\b", "", e)),
                     expected_failure="SESSION_REPORT_RESET")
        simulate(replace_port(source, "dump_engine", "dump", "gg_connected",
                              lambda e: "gg_mode_s"), expected_failure="GG_CONNECTED")
        simulate(replace_port(source, "cart_mode_hold", "mode_hold", "write_active",
                              lambda e: re.sub(r"\|\|\s*gg_write_active\b", "", e)),
                 expected_failure="GG_WRITE_HOLD")
        stale_result = replace_clocked_block(source, "dump_state <= D_IDLE;",
                                             lambda b: re.sub(r"\|\|\s*gg_size_change\b", "", b))
        simulate(stale_result, expected_failure="GG_SIZE_RESULT")
        simulate(replace_assignment(source, "cart_mode_s", lambda e: "(" + e + ") && core_reset_n_s"),
                 expected_failure="GG_SOFT_RESET")
        simulate(replace_clocked_block(source, "dump_state <= D_IDLE;",
                                       lambda b: re.sub(r"&&\s*dump_state\s*==\s*D_RUN\b", "", b)),
                 expected_failure="STALE_COMPLETION")
        simulate(replace_clocked_block(source, "dump_state <= D_IDLE;",
                                       lambda b: re.sub(r"\|\|\s*!core_reset_n_s\b", "", b)),
                 expected_failure="RESET_RESULT_PRIORITY")
    print("check_gg_integration: enabled production controls, disabled/passive fixtures, and 18 negative controls pass")


if __name__ == "__main__":
    main()
