#!/usr/bin/env python3
"""Every synthesised source must be listed in ap_core.qsf.

`make test` cannot catch a missing entry. Each testbench names the files it
needs in its own `// SOURCES:` header, so Icarus compiles a new module the
moment a testbench asks for it, and the whole suite goes green while Quartus
has never heard of the file. That is not hypothetical: cart_save_gb.sv landed
with three testbenches passing and failed synthesis on the build runner with

    Error (12006): Node instance "reader_save" instantiates undefined entity
    "cart_save_gb"

which cost a build, a card write that did not happen, and the time to read a
Quartus log to find out why. Ninety seconds of simulation should be able to
say this.

The rule is deliberately one-directional: every .sv under the synthesised
directories must appear in the qsf. The reverse - a qsf entry with no file -
Quartus already catches loudly, and listing a file that nothing instantiates
is legal and sometimes deliberate.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
QSF = os.path.join(REPO, "src", "fpga", "build", "ap_core.qsf")

# Directories whose contents are compiled into the bitstream. src/fpga/build
# holds the project files themselves and src/fpga/apf is upstream's, listed
# by its own means.
SYNTHESISED = [
    os.path.join("src", "fpga", "core"),
    os.path.join("src", "fpga", "ui"),
    os.path.join("src", "fpga", "services"),
]

# Files under those directories that are deliberately not compiled on their
# own. Add to this list only with a reason, the way the pin allowlist works.
EXEMPT = {
    # Generated into the build copy by tools/podman/build.sh, never committed,
    # and included by ui_screen.sv rather than compiled separately.
    "build_stamp.vh",
}


# A *_FILE assignment, in the qsf or in a .qip it pulls in. The qip form wraps
# the path in a [file join ...] expression, so the name is taken from the last
# quoted string on the line rather than from a bare token.
ASSIGN = re.compile(r"-name\s+\w*FILE\s+(.+)$")
QUOTED = re.compile(r'"([^"]+)"')


def named_files(path):
    """Basenames of every file a qsf or qip assignment names."""
    named = set()
    with open(path) as handle:
        for line in handle:
            if line.lstrip().startswith("#"):
                continue
            match = ASSIGN.search(line.rstrip())
            if not match:
                continue
            rest = match.group(1).strip()
            quoted = QUOTED.findall(rest)
            # [file join $::quartus(qip_path) "sub/name.v"] -> sub/name.v
            token = quoted[-1] if quoted else rest.split()[0]
            named.add(os.path.basename(token))
    return named


def qsf_files():
    """Everything the project compiles, following .qip files one level.

    The PLL megafunction is listed inside mf_pllbase.qip rather than in the
    qsf, and a check that did not follow that would demand qsf lines for
    generated vendor files that must not have them.
    """
    named = named_files(QSF)
    for qip in ("mf_pllbase.qip",):
        path = os.path.join(REPO, "src", "fpga", "core", qip)
        if os.path.exists(path):
            named |= named_files(path)
    return named


def main():
    if not os.path.exists(QSF):
        print("check_qsf_sources: {} not found".format(QSF))
        return 1

    listed = qsf_files()
    missing = []

    for directory in SYNTHESISED:
        root = os.path.join(REPO, directory)
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in sorted(filenames):
                if not name.endswith((".sv", ".v")):
                    continue
                if name in EXEMPT:
                    continue
                if name not in listed:
                    rel = os.path.relpath(os.path.join(dirpath, name), REPO)
                    missing.append(rel)

    if missing:
        print("check_qsf_sources: not listed in src/fpga/build/ap_core.qsf:")
        for rel in sorted(missing):
            print("    {}".format(rel))
        print()
        print("Add a line for each, beside the module it sits next to:")
        print("    set_global_assignment -name SYSTEMVERILOG_FILE "
              "../services/dump/<name>.sv")
        print()
        print("The simulation suite compiles from each testbench's SOURCES "
              "header, so it will stay green without this and the Quartus "
              "build will fail with 'instantiates undefined entity'.")
        return 1

    print("check_qsf_sources: {} synthesised sources, all listed"
          .format(len(listed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
