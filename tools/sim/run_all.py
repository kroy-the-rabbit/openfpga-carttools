#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Run every RTL testbench in this directory, plus the structural checks.
#
# This exists because the hardware these modules drive cannot be put in CI. A
# cartridge that gets a wrong write back is not recoverable, so the only cheap
# place to catch a bus-timing or pin-direction mistake is here, before a
# bitstream is ever flashed.
#
# Icarus is lenient by design: vvp exits 0 for a testbench that printed nothing,
# for one that ended on $finish halfway through, and for one that only issued
# $error. None of those are passes, so this runner does not trust the exit code
# alone. A testbench passes only by saying so, on its own last breath.
#
#   python3 tools/sim/run_all.py            everything
#   python3 tools/sim/run_all.py -k cart    only testbenches matching "cart"
#   python3 tools/sim/run_all.py -v         show output from passing runs too
#   python3 tools/sim/run_all.py -j 4       four independent testbenches at once
#
# Stdlib only, and meant to be run inside the sim container (see the Makefile).

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))

# A testbench declares what it needs to compile against, in its own header, so
# the runner never has to guess a file list from a module name:
#
#   // SOURCES: src/fpga/core/gba_cart_bus.sv
#
# Paths are relative to the repo root. One line, space separated.
SOURCES_RE = re.compile(r"^\s*//\s*SOURCES:\s*(.+?)\s*$", re.MULTILINE)

# Long full-image benches may declare one explicit wall-clock budget. The
# default stays 300s; malformed, duplicate, or unbounded declarations fail
# before compilation instead of silently changing the suite's time limit.
TIMEOUT_RE = re.compile(r"^[ \t]*//[ \t]*TIMEOUT:[ \t]*(.*?)[ \t]*$", re.MULTILINE)
DEFAULT_TIMEOUT = 300
MAX_TIMEOUT = 1800

# And it declares success by printing this as the last thing it does, after the
# final check and before $finish:
#
#   $display("TB PASS: tb_gba_cart_bus");
#
# Silence is failure. A testbench that dies early, or that is still being
# written, cannot accidentally look like a pass.
PASS_RE = re.compile(r"^TB PASS:", re.MULTILINE)

# Icarus and the SystemVerilog severity tasks both keep running after $error, so
# these have to be scanned for rather than waited on.
FAILURE_MARKERS = ("$error", "ERROR", "FATAL", "$fatal")


class Result:
    def __init__(self, name, ok, output, reason=""):
        self.name = name
        self.ok = ok
        self.output = output
        self.reason = reason


def discover(keyword):
    names = sorted(f for f in os.listdir(HERE)
                   if f.startswith("tb_") and f.endswith(".sv"))
    if keyword:
        names = [f for f in names if keyword in f]
    return [os.path.join(HERE, f) for f in names]


def read_sources(tb_path):
    with open(tb_path, "r", encoding="utf-8", errors="replace") as fh:
        head = fh.read()
    found = SOURCES_RE.findall(head)
    if not found:
        raise ValueError(
            "no '// SOURCES:' header in {}. Add one naming the RTL this "
            "testbench compiles against, relative to the repo root.".format(
                os.path.relpath(tb_path, REPO)))
    if len(found) > 1:
        raise ValueError(
            "{} has {} '// SOURCES:' lines; there must be exactly one.".format(
                os.path.relpath(tb_path, REPO), len(found)))
    sources = found[0].split()
    missing = [s for s in sources if not os.path.isfile(os.path.join(REPO, s))]
    if missing:
        raise ValueError("{} names sources that do not exist: {}".format(
            os.path.relpath(tb_path, REPO), " ".join(missing)))
    return [os.path.join(REPO, s) for s in sources]


def scan_markers(text):
    for marker in FAILURE_MARKERS:
        if marker in text:
            return "output contains {!r}".format(marker)
    return ""


def read_timeout(tb_path):
    with open(tb_path, "r", encoding="utf-8", errors="replace") as fh:
        declarations = TIMEOUT_RE.findall(fh.read())
    if not declarations:
        return DEFAULT_TIMEOUT
    if len(declarations) != 1:
        raise ValueError("expected at most one '// TIMEOUT:' header")
    value = declarations[0]
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError("TIMEOUT must be an integer from 1 to {} seconds".format(MAX_TIMEOUT))
    timeout = int(value)
    if not 1 <= timeout <= MAX_TIMEOUT:
        raise ValueError("TIMEOUT must be between 1 and {} seconds".format(MAX_TIMEOUT))
    return timeout


def run_testbench(tb_path):
    name = os.path.splitext(os.path.basename(tb_path))[0]
    try:
        sources = read_sources(tb_path)
    except ValueError as exc:
        return Result(name, False, str(exc), "bad SOURCES header")
    try:
        timeout = read_timeout(tb_path)
    except ValueError as exc:
        return Result(name, False, str(exc), "bad TIMEOUT header")

    with tempfile.TemporaryDirectory() as tmp:
        vvp_out = os.path.join(tmp, name + ".vvp")
        # src/fpga/ui is on the include path because ui_screen includes
        # build_stamp.vh, which the Quartus build regenerates per commit and
        # simulation takes from the committed placeholder.
        compile_cmd = (["iverilog", "-g2012",
                        "-I", os.path.join(REPO, "src", "fpga", "ui"),
                        "-o", vvp_out, tb_path] + sources)
        proc = subprocess.run(compile_cmd, cwd=REPO, capture_output=True,
                              text=True)
        log = proc.stdout + proc.stderr
        if proc.returncode != 0:
            return Result(name, False, log, "iverilog exit {}".format(
                proc.returncode))
        # Warnings are not fatal, but a compile that emitted an error marker and
        # still exited 0 is not something to build on.
        marker = scan_markers(log)
        if marker:
            return Result(name, False, log, "compile " + marker)

        proc = subprocess.run(["vvp", vvp_out], cwd=REPO, capture_output=True,
                              text=True, timeout=timeout)
        log = proc.stdout + proc.stderr

    if proc.returncode != 0:
        return Result(name, False, log, "vvp exit {}".format(proc.returncode))
    marker = scan_markers(log)
    if marker:
        return Result(name, False, log, marker)
    if not PASS_RE.search(log):
        return Result(name, False, log,
                      "no 'TB PASS:' line; the testbench never reached its end")
    return Result(name, True, log)


def run_structural_checks(keyword=None):
    # Structural checks are ordinary scripts that exit non-zero and explain
    # themselves. They live alongside the testbenches because a layering
    # violation is the same class of bug as a timing one: it reaches the pins.
    results = []
    checks = sorted(f for f in os.listdir(HERE)
                    if f.startswith("check_") and f.endswith(".py")
                    and (not keyword or keyword in f))
    for check in checks:
        proc = subprocess.run([sys.executable, os.path.join(HERE, check)],
                              cwd=REPO, capture_output=True, text=True)
        log = proc.stdout + proc.stderr
        name = os.path.splitext(check)[0]
        results.append(Result(name, proc.returncode == 0, log,
                              "" if proc.returncode == 0
                              else "exit {}".format(proc.returncode)))
    return results


def checked_testbench(tb_path):
    """Keep one failed invocation from discarding the rest of the suite."""
    try:
        return run_testbench(tb_path)
    except subprocess.TimeoutExpired as exc:
        def decoded(output):
            if isinstance(output, bytes):
                return output.decode("utf-8", errors="replace")
            return output or ""

        return Result(os.path.splitext(os.path.basename(tb_path))[0], False,
                      decoded(exc.stdout) + decoded(exc.stderr),
                      "timeout after {}s".format(exc.timeout))
    except Exception as exc:
        return Result(os.path.splitext(os.path.basename(tb_path))[0], False,
                      str(exc), "runner {}".format(type(exc).__name__))


def run_testbenches(testbenches, jobs=1):
    if not 1 <= jobs <= 8:
        raise ValueError("jobs must be between 1 and 8")
    if jobs == 1:
        return [checked_testbench(tb) for tb in testbenches]
    # Every bench already owns a separate temporary compile directory. map
    # schedules independently but returns discovery order, keeping the final
    # report and failure list identical to the serial runner's ordering.
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        return list(pool.map(checked_testbench, testbenches))


def job_count(value):
    try:
        jobs = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("jobs must be an integer from 1 to 8")
    if not 1 <= jobs <= 8:
        raise argparse.ArgumentTypeError("jobs must be between 1 and 8")
    return jobs


def report(result, verbose):
    status = "PASS" if result.ok else "FAIL"
    suffix = "" if result.ok else "  ({})".format(result.reason)
    print("{:<4} {}{}".format(status, result.name, suffix))
    if (not result.ok or verbose) and result.output.strip():
        for line in result.output.rstrip().splitlines():
            print("       | " + line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-k", metavar="SUBSTRING",
                    help="only run testbenches and checks whose name contains "
                         "SUBSTRING")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print output from passing runs too; failures always "
                         "print in full")
    ap.add_argument("-j", "--jobs", type=job_count, default=1, metavar="1..8",
                    help="independent testbenches to run concurrently (default: 1); "
                         "structural checks remain serial")
    args = ap.parse_args()

    results = run_structural_checks(args.k)
    testbenches = discover(args.k)
    results.extend(run_testbenches(testbenches, args.jobs))

    if not results:
        print("no testbenches or checks matched {!r}".format(args.k))
        return 1

    for result in results:
        report(result, args.verbose)

    failed = [r for r in results if not r.ok]
    print()
    print("{} run, {} passed, {} failed".format(
        len(results), len(results) - len(failed), len(failed)))
    if failed:
        print("failed: " + " ".join(r.name for r in failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
