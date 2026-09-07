#!/usr/bin/env python3
"""Exercise real command registers, file service, and extracted top muxes.

The host reproduces the documented/previously measured pipelined bridge read
contract, not Pocket firmware's path parser. Synthetic malformed-path replies
check refusal and retained diagnostics; they do not reproduce the hardware bug.
"""
from pathlib import Path
import re
import subprocess
import tempfile

from check_restore_integration import ROOT, TOP, assignment, elaboration_copy, run, uncomment


def main():
    source = uncomment(TOP.read_text())
    names = (
        "target_dataslot_read", "target_dataslot_write", "target_dataslot_openfile",
        "target_dataslot_getfile", "target_dataslot_flush", "target_dataslot_id",
        "target_dataslot_slotoffset", "target_dataslot_bridgeaddr",
        "target_dataslot_length", "target_buffer_param_struct", "target_buffer_resp_struct",
    )
    mux = "\n".join(f"assign {name} = {assignment(source, name)};" for name in names)
    read_mux = re.search(r"bridge_rd_data = restore_bridge_rd_hit.*?;", source, re.S)
    if not read_mux:
        raise AssertionError("missing top-level bridge response selection")
    mux += "\nassign " + read_mux.group(0)
    template = (ROOT / "tools/sim/restore_bridge_model.sv").read_text()
    with tempfile.TemporaryDirectory(prefix="carttools-restore-bridge-") as directory:
        temp = Path(directory)
        harness = temp / "bridge.sv"
        output = temp / "bridge.vvp"
        def simulate(wiring, expected_failure=None):
            harness.write_text(template.replace("// TOP_MUX", wiring))
            run(["iverilog", "-g2012", "-s", "tb_restore_bridge", "-o", str(output),
                 str(harness), str(ROOT / "src/fpga/services/restore/restore_file_io.sv"),
                 str(ROOT / "src/fpga/apf/common.v"),
                 str(elaboration_copy(ROOT / "src/fpga/core/core_bridge_cmd.v", temp))])
            result = subprocess.run(["vvp", str(output)], capture_output=True,
                                    text=True, timeout=30)
            log = result.stdout + result.stderr
            if expected_failure:
                if result.returncode == 0 or expected_failure not in log:
                    raise AssertionError("bridge mutation escaped: " + expected_failure + "\n" + log)
            elif result.returncode or "TB PASS: restore bridge command integration" not in log:
                raise AssertionError(log)
        simulate(mux)
        simulate(mux.replace("? r_target_struct :", "? d_target_struct :"),
                 "open command selected wrong struct pointer")
        simulate(mux.replace("bridge_rd_data = restore_bridge_rd_hit ?", "bridge_rd_data = 1'b0 ?"),
                 "delivered open structure byte")
    print("check_restore_bridge: commands, muxes, paths, refusal trace, and two negative controls pass")


if __name__ == "__main__":
    main()
