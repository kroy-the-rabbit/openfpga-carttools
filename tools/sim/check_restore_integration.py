#!/usr/bin/env python3
"""Elaborate the shipped top and exercise its extracted restore control wiring.

The small simulation compiles the actual core_top expressions, guard instances,
and probe handoff block. It does not maintain a second implementation of the
arbitration rules. The cartridge and file engines have their own protocol tests.
Vendor primitives are black boxes during top elaboration, so this check makes
no claim about PLL behavior, physical pin timing, or hardware file durability.
"""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
TOP = ROOT / "src/fpga/core/core_top.sv"
QSF = ROOT / "src/fpga/build/ap_core.qsf"


def uncomment(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


def assignment(source, name):
    match = re.search(
        r"\b(?:wire(?:\s+\[[^\]]+\])?|assign)\s+" + re.escape(name)
        + r"\s*=\s*(.*?);", source, flags=re.S)
    if not match:
        raise AssertionError(f"missing top-level assignment for {name}")
    return match.group(1)


def instance(source, module, name):
    match = re.search(r"\b" + module + r"\s+" + name + r"\s*\(.*?\);",
                      source, flags=re.S)
    if not match:
        raise AssertionError(f"missing integrated {module} instance {name}")
    return match.group(0)


def qsf_sources(path, seen=None):
    seen = set() if seen is None else seen
    path = path.resolve()
    if path in seen:
        return set()
    seen.add(path)
    sources = set()
    for line in path.read_text().splitlines():
        if line.lstrip().startswith("#"):
            continue
        match = re.search(r"-name\s+(SYSTEMVERILOG_FILE|VERILOG_FILE|QIP_FILE)\s+(.+)", line)
        if not match:
            continue
        kind, value = match.groups()
        quoted = re.findall(r'"([^"]+)"', value)
        filename = quoted[-1] if quoted else value.split()[0]
        target = (path.parent / filename).resolve()
        if not target.is_file():
            raise AssertionError(f"project source missing: {target.relative_to(ROOT)}")
        if kind == "QIP_FILE":
            sources.update(qsf_sources(target, seen))
        else:
            sources.add(target)
    return sources


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def elaboration_copy(path, directory):
    """Normalize only existing Quartus syntax that Icarus does not accept.

    Quartus permits omitted trailing positional synchronizer outputs. Icarus
    requires explicit empty arguments. Its treatment of generated tri0/tri1
    port defaults also changes port direction. Vendor primitive copies are
    for elaboration only. Command/peripheral functional tests use only the
    empty positional-output normalization, which does not change logic.
    """
    content = path.read_text()
    sync_call = re.compile(
        r"(\bsynch_[23](?:\s*#\s*\(\s*\.WIDTH\([^)]*\)\s*\))?\s+\w+\s*\()"
        r"([^;]*?)(\);)")

    def trailing_outputs(match):
        arguments = match.group(2)
        count = len(arguments.split(","))
        if count in (3, 4) and not arguments.lstrip().startswith("."):
            return match.group(1) + arguments + ", " * (5 - count) + match.group(3)
        return match.group(0)

    normalized = sync_call.sub(trailing_outputs, content)
    if path.name.startswith("mf_"):
        normalized = re.sub(r"\btri[01]\s+\w+\s*;", "", normalized)
    if normalized == content:
        return path
    target = directory / path.relative_to(ROOT)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(normalized)
    return target


def control_harness(source):
    names = (
        "restore_overlay", "restore_entry_key", "restore_block", "restore_cancel",
        "restore_stop_request", "restore_transaction_busy", "restore_available", "cart_engine_busy",
        "dump_ready", "save_ready", "scan_start", "restore_owns_cart",
        "gb_req_mux", "gb_wr_mux", "gb_addr_mux", "gb_wdata_mux",
    )
    widths = {"gb_addr_mux": "[15:0] ", "gb_wdata_mux": "[7:0] "}
    expressions = "\n".join(
        "wire " + widths.get(name, "") + name + " = " + assignment(source, name) + ";"
        for name in names)
    guard = instance(source, "restore_guard", "restore_lock").replace(
        "restore_guard restore_lock", "restore_guard #(.DEBOUNCE_CYCLES(2), "
        ".ENTRY_HOLD_CYCLES(16), .HOLD_CYCLES(8)) restore_lock")
    action = instance(source, "cart_action_guard", "action_guard")
    marker = source.index("restore_engine_start <= 0;")
    start = source.rfind("always @(posedge clk_sys) begin", 0, marker)
    end = source.index("\nend", marker) + len("\nend")
    if start < 0:
        raise AssertionError("missing restore probe handoff clocked block")
    handoff = source[start:end]
    marker = source.index("restore_release_count <= 0;")
    start = source.rfind("always @(posedge clk_sys) begin", 0, marker)
    end = source.index("\nend", marker) + len("\nend")
    quarantine = source[start:end]
    return "\n".join((HARNESS_PREFIX, expressions, guard, action, handoff,
                      quarantine, HARNESS_TEST))


HARNESS_PREFIX = r"""
`default_nettype none
`timescale 1ns/1ps
module tb_restore_integration;
reg clk_sys = 0;
always #5 clk_sys = ~clk_sys;
reg pll_core_locked = 0;
reg [31:0] cont1_key_s = 0;
localparam [20:0] RESTORE_RELEASE_CYCLES = 2;
reg restore_input_wait;
reg [20:0] restore_release_count;
wire key_a = cont1_key_s[4], key_x = cont1_key_s[6], key_y = cont1_key_s[7];
reg key_a_d = 0, key_x_d = 0, key_y_d = 0;
wire key_a_edge = key_a && !key_a_d;
wire key_x_edge = key_x && !key_x_d;
wire key_y_edge = key_y && !key_y_d;
always @(posedge clk_sys) begin
    key_a_d <= key_a;
    key_x_d <= key_x;
    key_y_d <= key_y;
end
reg restore_busy = 0, restore_poisoned_s = 0;
reg restore_reset_n_s = 1, restore_menu_s = 0;
reg restore_preflight_done = 0, restore_preflight_ok = 0;
reg restore_done = 0, restore_failed = 0;
reg restore_reprobe_request = 0;
reg [1:0] restore_want_mode = 0;
reg restore_req = 0, restore_wr = 0;
reg [15:0] restore_addr = 16'hA123;
reg [7:0] restore_wdata = 8'hA5;
reg dmp_req = 0, dmp_wr = 0, gbid_req = 0, gbid_wr = 0;
reg [15:0] dmp_addr = 16'hA222, gbid_addr = 16'h0147;
reg [7:0] dmp_wdata = 8'hD5, gbid_wdata = 8'h5A;
wire restore_active, restore_preflight_request, restore_commit_request;
wire restore_authorized;
wire [1:0] restore_hold_progress;
wire [3:0] restore_guard_state;
reg restore_probe_pending, restore_engine_start;
reg cart_mode_change = 0, cart_mode_s = 1, cart_mode_fell = 0, cart_wake_pulse = 0;
reg id_valid = 1;
reg [2:0] platform = 2;
reg [7:0] gbid_cart_type = 3, gbid_ram_size = 2, gbid_cgb_flag = 0, gbid_rom_size = 4;
// Geometry acceptance lives in restore_engine (geometry_ok); the engine's own
// benches cover it. Here it is a supported cartridge.
reg restore_geometry_ok = 1;
reg restore_rom_reading = 0;
reg probe_busy = 0, probe_sizing = 0, sz_start = 0, probe_done = 0;
reg dump_busy = 0, action_rom_available = 1, action_save_available = 1;
reg action_validation_complete = 0;
reg action_validated_rom_available = 1, action_validated_save_available = 1;
wire action_pending, action_scan_start, action_dump_start, action_save_mode;
integer scans = 0, starts = 0, dumps = 0, commits = 0;
integer initial_scans, initial_starts, initial_dumps;
always @(posedge clk_sys) begin
    if (pll_core_locked) begin
        if (scan_start) scans = scans + 1;
        if (restore_engine_start) starts = starts + 1;
        if (action_dump_start) dumps = dumps + 1;
        if (restore_commit_request) commits = commits + 1;
        if (restore_active && (dump_ready || save_ready))
            $fatal(1, "restore activity exposed ordinary X/Y actions");
        if (restore_overlay && (dump_ready || save_ready))
            $fatal(1, "restore overlay exposed ordinary X/Y actions");
        if (restore_busy && (dump_ready || save_ready))
            $fatal(1, "engine cleanup exposed ordinary X/Y actions");
    end
end
"""


HARNESS_TEST = r"""
task tick(input integer n);
    repeat (n) @(negedge clk_sys);
endtask
task tap(input integer key);
    begin
        cont1_key_s = 32'd1 << key;
        tick(5);
        cont1_key_s = 0;
        tick(5);
    end
endtask
task unlock;
    begin
        cont1_key_s = 32'd1 << 14;
        tick(24);
        cont1_key_s = 0;
        tick(6);
        if (restore_guard_state != 2) $fatal(1, "top availability prevented unlock");
    end
endtask
task request_preflight;
    begin
        initial_scans = scans;
        initial_starts = starts;
        tap(4);
        if (scans != initial_scans + 1 || starts != initial_starts || !restore_probe_pending)
            $fatal(1, "preflight bypassed or failed to request fresh probe");
        if (restore_guard_state != 3 || restore_available)
            $fatal(1, "owned probe canceled guard or left new actions available");
    end
endtask
task finish_probe;
    begin
        probe_done = 1;
        tick(1);
        probe_done = 0;
        tick(1);
        if (starts != initial_starts + 1 || restore_probe_pending)
            $fatal(1, "fresh probe completion did not launch exactly once");
        restore_busy = 1;
        restore_failed = 0;
        tick(2);
        if (restore_guard_state != 3)
            $fatal(1, "engine ownership canceled its own guard");
    end
endtask
task request_with_stale_done;
    begin
        initial_scans = scans;
        initial_starts = starts;
        cont1_key_s = 32'd1 << 4;
        tick(5);
        cont1_key_s = 0;
        while (!restore_preflight_request) tick(1);
        // A completion present at the request edge belongs to an earlier
        // scan. The new scan cannot finish before it has even started.
        probe_done = 1;
        tick(1);
        probe_done = 0;
        tick(3);
        if (scans != initial_scans + 1 || starts != initial_starts || !restore_probe_pending)
            $fatal(1, "request-edge stale probe completion launched restore");
    end
endtask
task confirm;
    begin
        restore_preflight_done = 1;
        restore_preflight_ok = 1;
        tick(1);
        restore_preflight_done = 0;
        tick(6);
        cont1_key_s = 32'd1 << 4;
        tick(16);
        if (restore_guard_state != 7 || !restore_authorized)
            $fatal(1, "owned engine blocked valid final confirmation");
        cont1_key_s = 0;
        tick(4);
    end
endtask
task result_blocks_actions(input [3:0] expected_state);
    begin
        initial_scans = scans;
        initial_dumps = dumps;
        tap(4);
        tap(6);
        tap(7);
        if (scans != initial_scans || dumps != initial_dumps || action_pending)
            $fatal(1, "ordinary A/X/Y leaked behind restore result");
        if (restore_guard_state != expected_state || !restore_available)
            $fatal(1, "result overlay cannot retain result and allow fresh unlock");
    end
endtask
task dismiss_and_check_actions;
    begin
        tap(5);
        if (restore_guard_state != 0 || restore_overlay || !dump_ready || !save_ready)
            $fatal(1, "B dismissal did not restore ordinary action availability");
        initial_scans = scans;
        tap(4);
        if (scans != initial_scans + 1)
            $fatal(1, "ordinary A scan did not recover after result dismissal");
        initial_dumps = dumps;
        tap(6);
        if (!action_pending) $fatal(1, "ordinary X did not recover after dismissal");
        action_validation_complete = 1;
        tick(1);
        action_validation_complete = 0;
        tick(2);
        if (dumps != initial_dumps + 1 || action_save_mode)
            $fatal(1, "ordinary ROM dump did not recover after dismissal");
        tap(7);
        if (!action_pending) $fatal(1, "ordinary Y did not recover after dismissal");
        action_validation_complete = 1;
        tick(1);
        action_validation_complete = 0;
        tick(2);
        if (dumps != initial_dumps + 2 || !action_save_mode)
            $fatal(1, "ordinary save dump did not recover after dismissal");
        initial_dumps = dumps;
    end
endtask
initial begin
    tick(3);
    pll_core_locked = 1;
    tick(4);

    // Cancellation of an ordinary scan must not open the restore page.
    probe_busy = 1;
    tap(5);
    if (restore_guard_state != 0 || restore_overlay)
        $fatal(1, "normal scan B acquired restore ownership");
    restore_menu_s = 1;
    tick(1);
    restore_menu_s = 0;
    tick(3);
    if (restore_guard_state != 0 || restore_overlay)
        $fatal(1, "normal scan menu cancellation acquired restore ownership");
    probe_busy = 0;
    tick(4);

    // Establish that the ordinary X path is alive before testing its exclusion.
    tap(6);
    if (!action_pending) $fatal(1, "normal X action unavailable in control fixture");
    action_validation_complete = 1;
    tick(1);
    action_validation_complete = 0;
    tick(2);
    if (dumps != 1) $fatal(1, "normal X action did not reach dump guard");
    initial_dumps = dumps;

    // A Select chord is claimed before debounce or the overlay can react.
    initial_scans = scans;
    cont1_key_s = (32'd1 << 14) | (32'd1 << 6) | (32'd1 << 4);
    tick(1);
    if (action_pending || scans != initial_scans)
        $fatal(1, "raw Select chord leaked before restore entry");
    cont1_key_s = 32'd1 << 6;
    tick(6);
    if (action_pending || dumps != initial_dumps)
        $fatal(1, "interrupted entry leaked held X into dumping");
    if (dump_ready || save_ready)
        $fatal(1, "interrupted entry released ordinary controls before full release");
    cont1_key_s = 0;
    tick(6);

    unlock();
    // In the old sequence these buttons silently abandoned restore and made
    // the next ordinary key press act on the dump screen. They must stay put.
    initial_scans = scans;
    tap(6);
    tap(7);
    if (restore_guard_state != 2 || action_pending || scans != initial_scans ||
        dumps != initial_dumps)
        $fatal(1, "unexpected READY buttons left restore or launched dumping");
    // Stale completion before requesting cannot be reused as the fresh probe.
    probe_done = 1;
    tick(1);
    probe_done = 0;
    request_preflight();
    tap(7);
    tap(6);
    if (dumps != initial_dumps) $fatal(1, "preflight X/Y launched an ordinary dump");
    finish_probe();
    confirm();
    if (dumps != initial_dumps) $fatal(1, "confirmation sequence launched an ordinary dump");

    // Final electrical scan must run while the transaction remains busy,
    // with identification owning the GB bus until restore requests its mode.
    initial_scans = scans;
    restore_reprobe_request = 1;
    gbid_req = 1;
    restore_req = 0;
    restore_wr = 1;
    tick(1);
    if (!scan_start || gb_req_mux != gbid_req || gb_wr_mux != gbid_wr ||
        gb_addr_mux != gbid_addr || gb_wdata_mux != gbid_wdata)
        $fatal(1, "final probe cannot scan or does not own cartridge bus");
    restore_reprobe_request = 0;
    tick(1);
    if (scans != initial_scans + 1) $fatal(1, "final probe request was dropped");
    restore_want_mode = 2;
    tick(1);
    if (gb_req_mux != restore_req || gb_wr_mux != restore_wr ||
        gb_addr_mux != restore_addr || gb_wdata_mux != restore_wdata)
        $fatal(1, "restore did not reacquire cartridge bus after probe");
    initial_scans = scans;
    tap(4);
    if (scans != initial_scans) $fatal(1, "ordinary A leaked into running restore");

    // failed is sticky and precedes cleanup. Only done acknowledges that
    // cleanup has actually finished, so the guard must retain RUN meanwhile.
    restore_failed = 1;
    tick(4);
    if (restore_guard_state != 7) $fatal(1, "failure flag bypassed engine cleanup acknowledgment");
    restore_done = 1;
    tick(1);
    restore_done = 0;
    restore_busy = 0;
    restore_want_mode = 0;
    tick(4);
    if (restore_guard_state != 9) $fatal(1, "completed failed transaction not relocked");
    result_blocks_actions(9);

    // A prior failure must not poison a later valid transaction.
    unlock();
    request_with_stale_done();
    finish_probe();
    confirm();
    if (commits != 2) $fatal(1, "prior sticky failure blocked later RUN");

    // Soft reset cancels and keeps normal actions blocked until engine drain.
    restore_reset_n_s = 0;
    tick(1);
    restore_reset_n_s = 1;
    if (restore_guard_state != 10 || restore_authorized)
        $fatal(1, "soft reset did not request safe stop");
    tap(6);
    tap(7);
    if (dumps != initial_dumps) $fatal(1, "safe stop released normal action guard");
    restore_done = 1;
    tick(1);
    restore_done = 0;
    restore_busy = 0;
    tick(4);
    result_blocks_actions(9);
    dismiss_and_check_actions();

    // Cancel and probe_done on the same clock must not launch the engine.
    unlock();
    request_preflight();
    restore_menu_s = 1;
    probe_done = 1;
    tick(1);
    restore_menu_s = 0;
    probe_done = 0;
    tick(3);
    if (starts != initial_starts || restore_probe_pending || restore_guard_state != 9)
        $fatal(1, "cancel lost race against fresh probe completion");

    // Canceling a pending physical probe cannot manufacture an engine
    // completion. The guard stays visible until actual probe ownership ends.
    unlock();
    request_preflight();
    probe_busy = 1;
    cont1_key_s = (32'd1 << 5) | (32'd1 << 6);
    tick(5);
    if (restore_guard_state != 10 || restore_probe_pending || action_pending)
        $fatal(1, "pending probe cancellation lost its safe-stop gate");
    probe_done = 1;
    tick(1);
    probe_done = 0;
    if (starts != initial_starts || restore_guard_state != 10)
        $fatal(1, "canceled busy probe launched engine or dismissed early");
    probe_busy = 0;
    tick(3);
    cont1_key_s = 32'd1 << 6;
    tick(5);
    if (action_pending || dumps != initial_dumps)
        $fatal(1, "held X leaked after canceled probe");
    cont1_key_s = 0;
    tick(6);
    tap(5);

    // B+X closes an idle page, but X stays quarantined until every button
    // has been released. There is no delayed or replayed ordinary dump.
    unlock();
    cont1_key_s = (32'd1 << 5) | (32'd1 << 6);
    tick(5);
    cont1_key_s = 32'd1 << 6;
    tick(5);
    if (action_pending || dumps != initial_dumps || !restore_input_wait)
        $fatal(1, "B exit leaked into ordinary dump before release");
    cont1_key_s = 0;
    tick(6);

    unlock();
    request_preflight();
    finish_probe();
    confirm();
    restore_done = 1;
    tick(1);
    restore_done = 0;
    restore_busy = 0;
    tick(4);
    result_blocks_actions(8);
    dismiss_and_check_actions();

    restore_poisoned_s = 1;
    cont1_key_s = 32'd1 << 14;
    tick(24);
    cont1_key_s = 0;
    tick(6);
    if (restore_guard_state != 0 || dump_ready || save_ready)
        $fatal(1, "poisoned APF channel exposed new operations");
    $display("TB PASS: extracted restore integration controls");
    $finish;
end
initial begin
    #200000;
    $fatal(1, "restore integration control watchdog expired");
end
endmodule
`default_nettype wire
"""


def main():
    source = uncomment(TOP.read_text())
    if not re.search(r"RESTORE_WRITE_ENABLED\s*=\s*1'b0\s*;", source):
        raise AssertionError("first hardware candidate must clamp save writes off")
    engine = uncomment((ROOT / "src/fpga/services/restore/restore_engine.sv").read_text())
    if not re.search(r"permit_program\s*=\s*WRITE_ENABLED\s*&&", engine):
        raise AssertionError("writer authorization bypasses build write clamp")
    for fragment in (".WRITE_ENABLED(RESTORE_WRITE_ENABLED)",
                     ".write_enabled(RESTORE_WRITE_ENABLED)",
                     ".reprobe_start(restore_reprobe_request)",
                     ".reprobe_done(probe_done)"):
        if fragment not in re.sub(r"\s+", "", source):
            raise AssertionError(f"missing shared restore safety connection: {fragment}")
    with tempfile.TemporaryDirectory(prefix="carttools-restore-integration-") as directory:
        temp = Path(directory)
        # Include QIP Verilog wrappers so every project-defined instance has
        # its real interface checked. -i leaves only external vendor cells black.
        command = ["iverilog", "-g2012", "-i", "-s", "core_top",
                   "-I", str(ROOT / "src/fpga/ui"), "-I", str(ROOT / "src/fpga/apf"),
                   "-o", str(temp / "core.vvp")]
        run(command + [str(elaboration_copy(path, temp)) for path in sorted(qsf_sources(QSF))])
        def simulate(candidate, expected_failure=None):
            harness = temp / "controls.sv"
            harness.write_text(control_harness(candidate))
            output = temp / "controls.vvp"
            run(["iverilog", "-g2012", "-s", "tb_restore_integration", "-o", str(output),
                 str(harness), str(ROOT / "src/fpga/services/restore/restore_guard.sv"),
                 str(ROOT / "src/fpga/core/cart_action_guard.sv")])
            result = subprocess.run(["vvp", str(output)], cwd=ROOT, text=True,
                                    capture_output=True, timeout=30)
            combined = result.stdout + result.stderr
            if expected_failure is None:
                if result.returncode or "TB PASS: extracted restore integration controls" not in combined:
                    raise AssertionError("control wiring simulation failed:\n" + combined)
            elif result.returncode == 0 or expected_failure not in combined:
                raise AssertionError("control test failed to catch mutation: " + expected_failure
                                     + "\nActual output:\n" + combined)

        simulate(source)
        # Negative controls prove the fixture distinguishes safe wiring from
        # specific realistic integration regressions, without modifying files.
        mutations = (
            ("dump_ready", assignment(source, "dump_ready").replace("!restore_block", "1'b1"),
             "interrupted entry released ordinary controls before full release"),
            ("save_ready", assignment(source, "save_ready").replace("!restore_block", "1'b1"),
             "interrupted entry released ordinary controls before full release"),
            ("restore_available", assignment(source, "restore_available") + " && !restore_active",
             "top availability prevented unlock"),
            ("scan_start", assignment(source, "scan_start").replace("restore_preflight_request", "1'b0"),
             "preflight bypassed or failed to request fresh probe"),
            ("restore_owns_cart", "restore_busy",
             "final probe cannot scan or does not own cartridge bus"),
            ("restore_block", assignment(source, "restore_block").replace("restore_input_wait", "1'b0"),
             "interrupted entry released ordinary controls before full release"),
            ("scan_start", assignment(source, "scan_start").replace("~restore_block", "1'b1"),
             "raw Select chord leaked before restore entry"),
        )
        for name, replacement, expected in mutations:
            expression = assignment(source, name)
            if expression == replacement:
                raise AssertionError(f"mutation no longer applies to {name}")
            simulate(source.replace(expression, replacement, 1), expected)
        old = ".operation_done(restore_done)"
        if old not in source:
            raise AssertionError("guard must wait for the engine failure completion acknowledgment")
        simulate(source.replace(old, ".operation_done(restore_done || restore_failed)", 1),
                 "failure flag bypassed engine cleanup acknowledgment")
        old = "restore_stop_request || !restore_active"
        if old not in source:
            raise AssertionError("probe handoff cancellation condition changed; audit it")
        simulate(source.replace(old, "!restore_active", 1),
                 "cancel lost race against fresh probe completion")
    print("check_restore_integration: top elaborates; extracted controls and nine negative controls pass")


if __name__ == "__main__":
    main()
