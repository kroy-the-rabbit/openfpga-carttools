#!/usr/bin/env python3
"""Prove GG pin/bus tests reject four distinct electrical regressions.

This checker belongs to runner verification; do not run HDL tools on the
laptop. Each temporary mutant must compile and fail the intended assertion,
so a compiler failure or an unrelated watchdog cannot count as detection.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / "src/fpga/core/cart_pins.sv"
BUS = ROOT / "src/fpga/core/gg_cart_bus.sv"
MODEL = ROOT / "tools/sim/gg_cart_model.sv"


def main():
    mutations = (
        (
            "A0/A1 transposed", PINS, "tb_gg_cart_pins", (),
            "gg_ad_out[10], gg_ad_out[0],\n"
            "    gg_ad_out[1], gg_ad_out[2]",
            "gg_ad_out[10], gg_ad_out[1],\n"
            "    gg_ad_out[0], gg_ad_out[2]",
            "GG address 0001 mapped to",
        ),
        (
            "memory CE inactive", BUS, "tb_gg_cart_bus", (MODEL,),
            "ce_n <= 1'b0;", "ce_n <= 1'b1;",
            "GG invalid ROM-read controls",
        ),
        (
            "mapper write whitelist bypassed", BUS, "tb_gg_cart_bus", (MODEL,),
            "wire request_allowed = wr ? write_allowed : addr < 16'hC000;",
            "wire request_allowed = wr ? 1'b1 : addr < 16'hC000;",
            "GG whitelist result for fffe=00",
        ),
        (
            "write hold shortened", BUS, "tb_gg_cart_bus", (MODEL,),
            "wait_count <= HOLD_COUNT;", "wait_count <= 0;",
            "GG mapper write-data/address hold shortened",
        ),
    )
    with tempfile.TemporaryDirectory(prefix="carttools-gg-electrical-") as directory:
        temp = Path(directory)
        for name, source_path, top, extra_sources, original, replacement, failure in mutations:
            source = source_path.read_text()
            if source.count(original) != 1:
                raise AssertionError(f"{name}: mutation location changed")
            mutated = temp / source_path.name
            mutated.write_text(source.replace(original, replacement))
            executable = temp / "negative.vvp"
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-s", top, "-o", str(executable),
                 str(ROOT / "tools/sim" / f"{top}.sv"), str(mutated),
                 *(str(path) for path in extra_sources)],
                capture_output=True, text=True, timeout=60,
            )
            if compiled.returncode:
                raise AssertionError(compiled.stdout + compiled.stderr)
            result = subprocess.run(
                ["vvp", str(executable)], capture_output=True, text=True, timeout=60,
            )
            output = result.stdout + result.stderr
            if result.returncode == 0 or failure not in output:
                raise AssertionError(f"{name}: intended assertion did not fail:\n{output}")
    print("GG electrical: address permutation, CE, write whitelist, and hold negative controls fail as required")


if __name__ == "__main__":
    main()
