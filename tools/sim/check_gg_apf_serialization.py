#!/usr/bin/env python3
"""Run the short real-engine APF test and require serialization mutants to fail.

Run on a simulation runner only. The host model uses the hardware-tested
restore contract independently of the dump producer: strings/payloads are
high-byte-first, while flags and sizes are numeric words. The legacy control
restores the exact 99e2ac6 path and payload instance connections; it must fail
at the first path word, well before a cartridge-image simulation.
"""

from pathlib import Path
import re
import subprocess
import tempfile

from run_all import read_sources, scan_markers


ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "src/fpga/services/dump/dump_engine.sv"
BENCH = ROOT / "tools/sim/tb_dump_engine_gg_apf.sv"


def replace_port(source, instance, port, old, new):
    block = re.search(r"\b" + re.escape(instance) + r"\s*\((.*?)\n\);", source, re.S)
    if not block:
        raise AssertionError(f"missing instance {instance}")
    expression = re.compile(r"(\." + re.escape(port) + r"\s*\(\s*)"
                            + re.escape(old) + r"(\s*\))")
    changed, count = expression.subn(lambda match: match[1] + new + match[2], block[1])
    if count != 1:
        raise AssertionError(f"expected one {instance}.{port} binding to {old}")
    return source[:block.start(1)] + changed + source[block.end(1):]


def variants(source):
    legacy = source
    for instance, port, old, new in (
        ("path_gen", "path_style", "active_path_style", "try_style"),
        ("path_gen", "field_order", "path_field_order", "try_field"),
        ("path_gen", "create_only", "path_create_only", "try_create_only"),
        ("path_gen", "byte_order", "apf_byte_order", "bo_l"),
        ("chunk_buf", "byte_order", "apf_byte_order", "bo_l"),
    ):
        legacy = replace_port(legacy, instance, port, old, new)
    return (
        ("production", source, None),
        ("99e2ac6_serialization", legacy,
         "APF path first word must be /Ass in SPI order: got 7373412f"),
        ("path_byte_order", replace_port(source, "path_gen", "byte_order",
                                        "apf_byte_order", "bo_l"),
         "APF path first word must be /Ass in SPI order: got 7373412f"),
        ("numeric_field_order", replace_port(source, "path_gen", "field_order",
                                            "path_field_order", "try_field"),
         "unexpected GG open flags"),
        ("payload_byte_order", replace_port(source, "chunk_buf", "byte_order",
                                           "apf_byte_order", "bo_l"),
         "APF payload byte 0 differs from ROM: word 03020100"),
        ("native_path_setting", replace_port(source, "path_gen", "path_style",
                                            "active_path_style", "try_style"),
         "APF path first word must be /Ass in SPI order"),
    )


def main():
    sources = [Path(path) for path in read_sources(str(BENCH))]
    with tempfile.TemporaryDirectory(prefix="carttools-gg-apf-") as directory:
        temporary = Path(directory)
        for label, source, expected_failure in variants(ENGINE.read_text()):
            changed_engine = temporary / f"dump_engine_{label}.sv"
            changed_engine.write_text(source)
            executable = temporary / f"{label}.vvp"
            command = ["iverilog", "-g2012", "-s", "tb_dump_engine_gg_apf",
                       "-I", str(ROOT / "src/fpga/ui"), "-o", str(executable), str(BENCH)]
            command += [str(changed_engine if path == ENGINE else path) for path in sources]
            compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=90)
            compile_log = compiled.stdout + compiled.stderr
            if compiled.returncode or scan_markers(compile_log):
                raise AssertionError(f"{label} did not compile:\n{compile_log}")
            simulated = subprocess.run(["vvp", str(executable)], cwd=ROOT,
                                       capture_output=True, text=True, timeout=90)
            log = simulated.stdout + simulated.stderr
            if expected_failure is None:
                if simulated.returncode or scan_markers(log) or "TB PASS: tb_dump_engine_gg_apf" not in log:
                    raise AssertionError(f"production APF serialization failed:\n{log}")
                print("production: short APF bridge test passed", flush=True)
            else:
                if simulated.returncode == 0 or expected_failure not in log:
                    raise AssertionError(f"missed {label} mutation; expected {expected_failure!r}:\n{log}")
                print(f"{label}: observed expected failure: {expected_failure}", flush=True)
    print("check_gg_apf_serialization: canonical APF contract and five negative controls pass")


if __name__ == "__main__":
    main()
