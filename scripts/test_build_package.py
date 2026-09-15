#!/usr/bin/env python3
"""Exercise real package stamping with fixture outputs; no FPGA tools run."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class PackageVersion(unittest.TestCase):
    def test_display_commit_does_not_replace_calendar_version(self):
        with tempfile.TemporaryDirectory(prefix="carttools-package-test-") as directory:
            repo = Path(directory)
            harness = repo / "tools/podman"
            harness.mkdir(parents=True)
            for name in ("build.sh", "version.sh"):
                shutil.copy2(ROOT / "tools/podman" / name, harness / name)
            (harness / "report.sh").write_text("#!/bin/sh\nexit 0\n")
            (harness / "report.sh").chmod(0o755)
            (repo / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/reverse_bitstream.py", repo / "scripts/reverse_bitstream.py")
            source = repo / "src/fpga"
            (source / "build/output_files").mkdir(parents=True)
            (source / "ui").mkdir()
            (source / "build/ap_core.qsf").write_text("")
            (repo / "generate.tcl").write_text("")
            work = repo / "build/cart/work/src/fpga/build/output_files"
            work.mkdir(parents=True)
            (work / "ap_core.rbf").write_bytes(bytes(range(256)))
            (repo / "build/cart/venv").symlink_to(Path(sys.executable).parent.parent, target_is_directory=True)
            core = repo / "pkg/Cores/kroy.CartTools"
            core.mkdir(parents=True)
            shutil.copy2(ROOT / "pkg/Cores/kroy.CartTools/core.json", core / "core.json")
            binaries = repo / "bin"
            binaries.mkdir()
            (binaries / "git").write_text("#!/bin/sh\ncase \"$*\" in *rev-parse*) echo 7c2c56d ;; esac\n")
            (binaries / "git").chmod(0o755)
            (binaries / "no-fpga-tools").write_text("#!/bin/sh\necho unexpected FPGA invocation >&2\nexit 91\n")
            (binaries / "no-fpga-tools").chmod(0o755)
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                       SKIP_COMPILE="1", RELEASE_NAME="0.9999.20260914",
                       PODMAN=str(binaries / "no-fpga-tools"), NPROC="1")
            run = subprocess.run(["bash", str(harness / "build.sh")], env=env,
                                 text=True, capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            archive = repo / "build/cart/kroy.CartTools_0.9999.20260914.zip"
            self.assertTrue(archive.is_file(), run.stdout)
            with zipfile.ZipFile(archive) as package:
                metadata = json.loads(package.read("Cores/kroy.CartTools/core.json"))["core"]["metadata"]
            self.assertEqual(metadata["version"], "0.9999.20260914")
            self.assertEqual(metadata["date_release"], "2026-09-14")
            stamp = (repo / "build/cart/work/src/fpga/ui/build_stamp.vh").read_text()
            self.assertIn("16'h7C2C", stamp)


if __name__ == "__main__":
    unittest.main()
