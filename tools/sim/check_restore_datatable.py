#!/usr/bin/env python3
"""Keep restore reads aligned with the shipped registered data-table RAM.

The old single-cycle RAM test double hid an early ID/size comparison. The
latency probe uses the file-service testbench's two-stage read and requires
each deliberately shortened wait to fail at its specific table check.
"""

from pathlib import Path
import re
import subprocess
import tempfile

from check_restore_integration import ROOT, instance, run, uncomment


def main():
    vendor = uncomment((ROOT / "src/fpga/apf/mf_datatable.v").read_text())
    for name, expected in (
        ("outdata_reg_a", '"CLOCK0"'),
        ("outdata_reg_b", '"CLOCK1"'),
        ("address_reg_b", '"CLOCK1"'),
        ("numwords_a", "256"), ("numwords_b", "256"),
        ("widthad_a", "8"), ("widthad_b", "8"),
    ):
        if not re.search(r"\." + name + r"\s*=\s*" + re.escape(expected) + r"\s*[,;]", vendor):
            raise AssertionError("data-table simulation contract changed: " + name)
    command = uncomment((ROOT / "src/fpga/core/core_bridge_cmd.v").read_text())
    ram = instance(command, "mf_datatable", "idt")
    for port, signal in (("address_a", "datatable_addr"), ("q_a", "datatable_q")):
        if not re.search(r"\." + port + r"\s*\(\s*" + signal + r"\s*\)", ram):
            raise AssertionError("restore data-table port mapping changed: " + port)

    source = (ROOT / "src/fpga/services/restore/restore_file_io.sv").read_text()
    clocked_blocks = re.split(r"\balways\s*@", uncomment(source))[1:]
    for register in ("debug_bad", "debug_bad_index", "debug_bad_word", "debug_bad_expected"):
        writers = sum(bool(re.search(r"\b" + register + r"\s*<=", block))
                      for block in clocked_blocks)
        if writers != 1:
            raise AssertionError("diagnostic register must have one procedural owner: " + register)
    with tempfile.TemporaryDirectory(prefix="carttools-table-latency-") as directory:
        temp = Path(directory)
        rtl = temp / "restore_file_io.sv"
        output = temp / "probe.vvp"

        def simulate(text, expected_stage=None):
            rtl.write_text(text)
            run(["iverilog", "-g2012", "-s", "tb_restore_file_io", "-o", str(output),
                 str(ROOT / "tools/sim/tb_restore_file_io.sv"), str(rtl)])
            result = subprocess.run(["vvp", str(output), "+table_latency_probe"],
                                    capture_output=True, text=True, timeout=30)
            log = result.stdout + result.stderr
            if expected_stage is None:
                if result.returncode or "TB PASS: registered data-table latency probe" not in log:
                    raise AssertionError(log)
            else:
                expected = f"failed=1 error=9 stage={expected_stage} reads=0"
                if result.returncode == 0 or expected not in log:
                    raise AssertionError("shortened table wait escaped: " + expected + "\n" + log)

        simulate(source)
        for field, stage in (("ID", 2), ("SIZE", 3)):
            original = f"state <= ST_{field}_SETTLE;"
            if source.count(original) != 1:
                raise AssertionError("table wait mutation target changed: " + field)
            simulate(source.replace(original, f"state <= ST_{field}_CHECK;"), stage)
    print("check_restore_datatable: registered RAM contract, input read, and two early-sample negative controls pass")


if __name__ == "__main__":
    main()
