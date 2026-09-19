#!/usr/bin/env python3
"""Include the synthetic standalone dump/DAT verification cases in the gate."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(ROOT / "scripts/test_dump_tools.py")],
               cwd=ROOT, check=True, timeout=90)
