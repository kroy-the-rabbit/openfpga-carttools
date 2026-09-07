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

from check_restore_integration import ROOT, TOP, assignment, elaboration_copy, instance, run, uncomment


def main():
    source = uncomment(TOP.read_text())
    file_instance = instance(source, "restore_file_io", "restore_files")
    if not re.search(r"\.observed_bridge_data\s*\(\s*bridge_rd_data\s*\)", file_instance):
        raise AssertionError("file trace must tap the selected top-level bridge response")
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
        peripheral = elaboration_copy(ROOT / "src/fpga/apf/io_bridge_peripheral.v", temp)
        # Quartus accepts procedural assignments to an inout reg. Express
        # the same output register and resolved input net separately for
        # Icarus, without changing the peripheral's state machines or timing.
        peripheral_text = peripheral.read_text()
        for pin in ("phy_spimosi", "phy_spimiso", "phy_spiclk"):
            peripheral_text, count = re.subn(r"inout\s+reg\s+" + pin,
                                             "inout wire " + pin, peripheral_text)
            if count != 1:
                raise AssertionError("peripheral inout declaration changed: " + pin)
            peripheral_text = re.sub(r"\b" + pin + r"\s*<=", pin + "_drive <=", peripheral_text)
            peripheral_text = peripheral_text.replace("endmodule",
                f"reg {pin}_drive;\nassign {pin} = {pin}_drive;\nendmodule")
        peripheral = temp / "io_bridge_peripheral.v"
        peripheral.write_text(peripheral_text)

        def simulate(wiring, expected_failure=None, chunk=66, spi=0, inject=0):
            harness.write_text(template.replace("// TOP_MUX", wiring))
            run(["iverilog", "-g2012", "-s", "tb_restore_bridge", "-o", str(output),
                 f"-Ptb_restore_bridge.CHUNK_WORDS={chunk}",
                 f"-Ptb_restore_bridge.INJECT_WORD={inject}",
                 f"-Ptb_restore_bridge.USE_SPI={spi}", str(peripheral),
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
        simulate(mux, chunk=16)
        simulate(mux, chunk=8)
        simulate(mux, spi=1)
        simulate(mux, chunk=16, spi=1)
        fault_mux = mux.replace("? restore_bridge_rd_data :", "? injected_response :")
        if fault_mux == mux:
            raise AssertionError("missing restore response for diagnostic fault injection")
        simulate(fault_mux, inject=1)
        simulate(fault_mux, chunk=16, spi=1, inject=1)
        simulate(mux.replace("? r_target_struct :", "? d_target_struct :"),
                 "open command selected wrong struct pointer")
        simulate(mux.replace("bridge_rd_data = restore_bridge_rd_hit ?", "bridge_rd_data = 1'b0 ?"),
                 "delivered open structure byte")
    print("check_restore_bridge: full paths, chunked reads, actual SPI, retained fault trace, and two negative controls pass")


if __name__ == "__main__":
    main()
