#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Structural check: nothing outside the cartridge bus touches the cartridge pins.
#
# Phase 2 of plan.md says service logic must not manipulate cartridge pins
# directly, and the reason is not tidiness. These nets drive level translators
# wired to a real cartridge edge connector. Two drivers disagreeing about
# direction is a short across a cartridge that somebody owns one of. Keeping
# every direction decision inside one module is what makes that reviewable.
#
# This is a grep, not a simulation, so it holds even for code paths no testbench
# reaches yet. It runs as part of `make test`.

import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    os.pardir, os.pardir))
SRC = os.path.join(REPO, "src")

# ---------------------------------------------------------------------------
# ALLOWLIST. Widening this is a deliberate, visible change to the safety
# boundary, and should be argued for in the commit message that does it.
#
# OWNER drives the pins and owns every direction decision. Protocol engines,
# gba_cart_bus.sv included, sit below it behind a flat interface and fail this
# check if they ever name a pin again.
OWNER = "src/fpga/core/cart_pins.sv"
# PASSTHROUGH files sit above the owner and are only allowed to name these
# signals in a port declaration or a named port connection. They wire the pins
# down to the owner; they must never read or assign one.
PASSTHROUGH = (
    "src/fpga/core/core_top.sv",   # the core's top level
    "src/fpga/apf/apf_top.v",      # the APF wrapper, where the pins enter the design
)
# ---------------------------------------------------------------------------

GUARDED = (
    "cart_tran_bank0",
    "cart_tran_bank1",
    "cart_tran_bank2",
    "cart_tran_bank3",
    "cart_tran_pin30",
    "cart_tran_pin31",
    "cart_pin30_pwroff_reset",
)

HDL_SUFFIXES = (".sv", ".v", ".vhd", ".vhdl")

# Match the base names and their _dir companions, but not a longer identifier
# that merely starts the same way.
GUARDED_RE = re.compile(r"\b(" + "|".join(GUARDED) + r")(_dir)?\b")

# A port declaration:            inout  wire [7:0] cart_tran_bank2,
# A named port connection:       .cart_tran_bank2 ( cart_tran_bank2 ),
# Anything else in a passthrough file is the module using the pin itself.
PORT_DECL_RE = re.compile(r"^\s*(input|output|inout)\b")
PORT_CONN_RE = re.compile(
    r"^\s*\.\s*(\w+)\s*\(\s*(\w+)\s*\)\s*,?\s*(//.*)?$")


def hdl_files():
    for root, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if name.endswith(HDL_SUFFIXES):
                path = os.path.join(root, name)
                yield path, os.path.relpath(path, REPO).replace(os.sep, "/")


def strip_comment(line):
    return line.split("//", 1)[0]


def check():
    violations = []
    seen_owner = False

    for path, rel in hdl_files():
        if rel == OWNER:
            seen_owner = True
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()

        for number, raw in enumerate(lines, 1):
            line = strip_comment(raw)
            if not GUARDED_RE.search(line):
                continue
            if rel not in PASSTHROUGH:
                violations.append((rel, number, raw.rstrip(),
                                   "only {} may use the cartridge pins".format(OWNER)))
                continue
            if PORT_DECL_RE.match(line):
                continue
            conn = PORT_CONN_RE.match(line)
            if conn and conn.group(1) == conn.group(2):
                continue
            violations.append((rel, number, raw.rstrip(),
                               "passthrough file must only declare or forward this pin"))

    if not seen_owner:
        print("check_pin_isolation: {} not found; the allowlist is stale"
              .format(OWNER), file=sys.stderr)
        return 1

    if violations:
        print("cartridge pin isolation violated:", file=sys.stderr)
        for rel, number, text, why in violations:
            print("  {}:{}: {}".format(rel, number, text.strip()), file=sys.stderr)
            print("      {}".format(why), file=sys.stderr)
        print("", file=sys.stderr)
        print("Route the access through cart_pins, or widen the allowlist at "
              "the top of tools/sim/check_pin_isolation.py and say why.",
              file=sys.stderr)
        return 1

    print("pin isolation: {} owns the cartridge pins, {} forward them".format(
        os.path.basename(OWNER), len(PASSTHROUGH)))
    return 0


if __name__ == "__main__":
    sys.exit(check())
