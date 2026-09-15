#!/usr/bin/env python3
"""Reject clipped rows independently of SystemVerilog's argument truncation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
COLS = 30


def validate(screen, bench):
    for number, line in enumerate(screen.splitlines(), 1):
        for literal in re.findall(r'"([^"]*)"', line.split("//", 1)[0]):
            if len(literal) > COLS:
                raise ValueError(f"ui_screen:{number}: {len(literal)} characters exceeds {COLS}: {literal!r}")
    expected = re.findall(r'expect_row\(\s*"[^"]*"\s*,\s*\d+\s*,\s*"([^"]*)"\s*\)', bench)
    if not expected:
        raise ValueError("no literal row expectations found")
    for literal in expected:
        if len(literal) != COLS:
            raise ValueError(f"tb_ui_screen: expected row has {len(literal)} characters: {literal!r}")


def main():
    screen = (ROOT / "src/fpga/ui/ui_screen.sv").read_text()
    bench = (ROOT / "tools/sim/tb_ui_screen.sv").read_text()
    validate(screen, bench)
    row = "SELECTED RANGE CRC AGREES     "
    if row not in screen or row not in bench:
        raise ValueError("missing selected-range CRC row fixture")
    # The original regression passed when both actual and expected strings
    # lost their first character. Independently reject either side and both.
    for label, mutated_screen, mutated_bench in (
            ("production row", screen.replace(row, row + " "), bench),
            ("expected row", screen, bench.replace(row, row + " ")),
            ("matching truncation", screen.replace(row, row + " "), bench.replace(row, row + " "))):
        try:
            validate(mutated_screen, mutated_bench)
        except ValueError:
            continue
        raise AssertionError(f"accepted mutation: {label}")
    print("check_gg_ui_strings: row widths and three clipping mutations pass")


if __name__ == "__main__":
    main()
