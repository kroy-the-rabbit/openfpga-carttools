#!/usr/bin/env python3
"""Exercise diagnostic producer-to-screen connections through the shipped top.

The reader and file/UI behaviors have their own testbenches. This check drives
the actual dump instance's output ports and observes the actual screen inputs,
including high bits, without replacing the wiring under test. Vendor primitives
are black boxes, as in the existing full-top elaboration check.
"""
from pathlib import Path
import re
import subprocess
import tempfile

from check_restore_integration import ROOT, TOP, QSF, qsf_sources, elaboration_copy, run


HARNESS = r"""
`timescale 1ns/1ps
module tb_dump_pair_wiring;
core_top dut ();
initial begin
    force dut.dump.pair_checked = 1;
    force dut.dump.pair_mismatches = 24'hEF1234;
    force dut.dump.pair_even = 24'h123456;
    force dut.dump.pair_odd = 24'hDCDDDE;
    force dut.dump.pair_first_addr = 23'h7FC08B;
    force dut.dump.pair_first_a = 8'h12;
    force dut.dump.pair_first_b = 8'hE3;
    #1;
    if ({dut.screen.pair_checked, dut.screen.pair_mismatches,
         dut.screen.pair_even, dut.screen.pair_odd, dut.screen.pair_first_addr,
         dut.screen.pair_first_a, dut.screen.pair_first_b} !==
        {1'b1, 24'hEF1234, 24'h123456, 24'hDCDDDE, 23'h7FC08B, 8'h12, 8'hE3})
        $fatal(1, "diagnostic output lost or changed between engine and screen");
    force dut.dump.pair_checked = 0;
    force dut.dump.pair_mismatches = 0;
    force dut.dump.pair_even = 0;
    force dut.dump.pair_odd = 0;
    force dut.dump.pair_first_addr = 0;
    force dut.dump.pair_first_a = 0;
    force dut.dump.pair_first_b = 0;
    #1;
    if ({dut.screen.pair_checked, dut.screen.pair_mismatches,
         dut.screen.pair_even, dut.screen.pair_odd, dut.screen.pair_first_addr,
         dut.screen.pair_first_a, dut.screen.pair_first_b} !== 112'd0)
        $fatal(1, "diagnostic clear did not reach screen");
    force dut.dump.gb_rom_reading = 1;
    #1;
    if (dut.gb_bus.idle_precharge !== 1'b0)
        $fatal(1, "GB ROM dump does not release the idle precharge");
    force dut.dump.gb_rom_reading = 0;
    #1;
    if (dut.gb_bus.idle_precharge !== 1'b1)
        $fatal(1, "idle precharge not restored outside a GB ROM dump");
    $display("TB PASS: dump diagnostic top wiring");
    $finish;
end
endmodule
"""


def main():
    with tempfile.TemporaryDirectory(prefix="carttools-dump-pair-") as directory:
        temp = Path(directory)
        harness = temp / "wiring.sv"
        harness.write_text(HARNESS)
        sources = {path: elaboration_copy(path, temp) for path in sorted(qsf_sources(QSF))}
        top_text = sources[TOP].read_text()
        top_copy = temp / "paired_top.sv"
        sources[TOP] = top_copy
        output = temp / "wiring.vvp"

        def simulate(text, negative=False):
            top_copy.write_text(text)
            run(["iverilog", "-g2012", "-i", "-s", "tb_dump_pair_wiring",
                 "-I", str(ROOT / "src/fpga/ui"), "-I", str(ROOT / "src/fpga/apf"),
                 "-o", str(output), str(harness)] + [str(p) for p in sources.values()])
            result = subprocess.run(["vvp", str(output)], cwd=ROOT, text=True,
                                    capture_output=True, timeout=30)
            log = result.stdout + result.stderr
            if negative:
                if result.returncode == 0 or not any(
                        m in log for m in ("diagnostic output lost or changed",
                                           "does not release the idle precharge")):
                    raise AssertionError("wiring test missed a mutation:\n" + log)
            elif result.returncode or "TB PASS: dump diagnostic top wiring" not in log:
                raise AssertionError("diagnostic top wiring failed:\n" + log)

        simulate(top_text)
        # Compile mutations only in the temporary top, never in the worktree.
        split = top_text.index("ui_screen screen")
        for port, replacement in (
            ("pair_mismatches", "{8'd0, dump_pair_mismatches[15:0]}"),
            ("pair_even", "dump_pair_odd"),
            ("pair_first_addr", "{7'd0, dump_pair_first_addr[15:0]}"),
        ):
            tail, count = re.subn(
                r"(\." + port + r"\s*\()\s*dump_" + port + r"\s*(\))",
                lambda m: m[1] + replacement + m[2], top_text[split:])
            if count != 1:
                raise AssertionError(f"expected one screen connection for {port}")
            simulate(top_text[:split] + tail, negative=True)
        # A precharge left on during the dump must be caught too.
        mutated, count = re.subn(r"(\.idle_precharge\s*\()\s*~dump_gb_rom_reading\s*(\))",
                                 lambda m: m[1] + "1'b1" + m[2], top_text)
        if count != 1:
            raise AssertionError("expected one idle_precharge connection on gb_bus")
        simulate(mutated, negative=True)
    print("check_dump_pair_integration: actual top wiring and four negative controls pass")


if __name__ == "__main__":
    main()
