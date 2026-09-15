#!/usr/bin/env python3
"""Prove the CDC test rejects overwriting an unacknowledged payload."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUS = ROOT / "src/fpga/core/cart_adapter_state.sv"
TB = ROOT / "tools/sim/tb_cart_adapter_state.sv"

def main():
    source = BUS.read_text()
    needle = "ack_sync[2] == request &&"
    if source.count(needle) != 1:
        raise AssertionError("mailbox ownership condition changed; review mutation")
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        for broken in (False, True):
            candidate = temp / "cart_adapter_state.sv"
            candidate.write_text(source.replace(needle, "1'b1 &&") if broken else source)
            executable = temp / "test.vvp"
            subprocess.run(["iverilog", "-g2012", "-o", str(executable), str(TB), str(candidate)],
                           check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run(["vvp", str(executable)], capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            if broken:
                if result.returncode == 0 or "payload changed before acknowledgement" not in output:
                    raise AssertionError("test did not reject overwritten mailbox: " + output)
            elif result.returncode or "TB PASS:" not in output:
                raise AssertionError("mailbox test failed: " + output)
    print("PASS: coherent adapter mailbox and overwrite mutation")

if __name__ == "__main__":
    main()
