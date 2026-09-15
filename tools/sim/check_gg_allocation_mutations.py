#!/usr/bin/env python3
"""Prove GG allocation checks detect unsafe success/result decoding.

Runs only through the normal build-runner verification suite. These negative
controls exercise the same behavioral bench as the unmodified writer; each
mutation must compile and fail at the intended payload-authorization assertion.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
WRITER = ROOT / "src/fpga/services/dump/apf_file_writer.sv"
BENCH = ROOT / "tools/sim/tb_apf_file_writer_gg.sv"


def main():
    source = WRITER.read_text()
    mutations = (
        (
            "existing create accepted",
            "if (target_dataslot_result == 16'd1) begin",
            "if (target_dataslot_result <= 16'd1) begin",
            "existing or unexpected create result 0000 wrote payload",
        ),
        (
            "probe result truncated",
            "if (target_dataslot_result == 16'd0 ||\n"
            "                            target_dataslot_result == 16'd3) begin",
            "if (target_dataslot_result[2:0] == 3'd0 ||\n"
            "                            target_dataslot_result[2:0] == 3'd3) begin",
            "unexpected full probe result 0008 authorized payload",
        ),
    )
    with tempfile.TemporaryDirectory(prefix="carttools-gg-allocate-") as directory:
        temp = Path(directory)
        for name, original, replacement, failure in mutations:
            if source.count(original) != 1:
                raise AssertionError(f"{name}: mutation location changed")
            mutated = temp / "apf_file_writer.sv"
            mutated.write_text(source.replace(original, replacement))
            executable = temp / "negative.vvp"
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-s", "tb_apf_file_writer_gg", "-o",
                 str(executable), str(BENCH), str(mutated)],
                capture_output=True, text=True, timeout=60,
            )
            if compiled.returncode:
                raise AssertionError(compiled.stdout + compiled.stderr)
            result = subprocess.run(
                ["vvp", str(executable)], capture_output=True, text=True, timeout=30,
            )
            output = result.stdout + result.stderr
            if result.returncode == 0 or failure not in output:
                raise AssertionError(f"{name}: intended assertion did not fail:\n{output}")
    print("GG allocation: occupied-create and full-result negative controls fail as required")


if __name__ == "__main__":
    main()
