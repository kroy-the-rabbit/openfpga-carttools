#!/usr/bin/env bash
# Summarise a finished build and gate on timing.
#   tools/podman/report.sh   -> build/cart/report.txt
#
# Quartus exits 0 on a design that misses timing. Upstream's own scripts print
# the slack but do not fail on it, so the gate lives here: a bitstream with
# negative slack may work on one bench and fail on another handheld.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BDIR="$REPO/build/cart"
OUT="$BDIR/work/src/fpga/build/output_files"
RPT="$BDIR/work/build_output/reports"

test -f "$OUT/ap_core.fit.summary" || { echo "no fitter output in $OUT" >&2; exit 1; }

worst() {  # worst slack for one analysis type across all corners
  awk -v want="$1" '
    /^Type/ { t = $0 }
    /^Slack/ {
      split(t, a, " Model ");
      n = index(a[2], " '"'"'");
      typ = substr(a[2], 1, n - 1);
      if (typ == want && (!seen || $3 + 0 < min)) { seen = 1; min = $3 + 0; line = t }
    }
    END { if (seen) printf "%-22s %8.3f ns   %s\n", want, min, substr(line, 9); else printf "%-22s   (none)\n", want }
  ' "$OUT/ap_core.sta.summary"
}

{
  echo "core:      $(basename "$(ls -d "$REPO/pkg/Cores"/*/ | head -1)")"
  echo "commit:    ${GIT_SHA:-unknown}${GIT_DIRTY:+ (dirty)}"
  echo "quartus:   $(cat "$BDIR/quartus.version" 2>/dev/null || echo unknown)"
  echo "elapsed:   $(cat "$BDIR/elapsed" 2>/dev/null || echo '?') s"
  echo
  echo "---- worst slack per analysis type (all corners) ----"
  for t in Setup Hold Recovery Removal "Minimum Pulse Width"; do worst "$t"; done
  echo
  echo "---- utilization ----"
  grep -E "Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total PLLs|Total DSP|Total pins" "$OUT/ap_core.fit.summary"
  echo
  echo "---- fit.summary ----"
  cat "$OUT/ap_core.fit.summary"
  echo
  echo "---- sta.summary ----"
  cat "$OUT/ap_core.sta.summary"
  if [[ -f "$RPT/ap_core.sta.clock_summary.rpt" ]]; then
    echo
    echo "---- clock summary ----"
    cat "$RPT/ap_core.sta.clock_summary.rpt"
  fi
} > "$BDIR/report.txt"

sed -n '1,/^---- utilization/{/^---- utilization/d;p}' "$BDIR/report.txt"
grep -E "Logic utilization|Total registers|Total RAM Blocks|Total block memory bits" "$OUT/ap_core.fit.summary"
echo "full report: $BDIR/report.txt"

rm -f "$BDIR/TIMING_FAILED"
worst_slack=$(awk '/^Slack/ {if (!seen || $3 + 0 < m) {seen = 1; m = $3 + 0}} END {printf "%.3f", m}' \
              "$OUT/ap_core.sta.summary")
if awk -v v="$worst_slack" 'BEGIN {exit !(v < 0)}'; then
  echo
  echo "TIMING FAILED: worst slack ${worst_slack} ns. Not fit to flash."
  echo "  see $BDIR/report.txt; SEED=<n> re-runs the fitter with another placement"
  touch "$BDIR/TIMING_FAILED"
  exit 3
fi
echo "timing met: worst slack ${worst_slack} ns"
