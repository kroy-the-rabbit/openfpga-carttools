#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/version.sh"
expect() {
  local input=$1 want=$2 got
  got=$(pocket_version "$input")
  [[ "$got" == "$want" ]] || { echo "wrong version for $input: $got" >&2; exit 1; }
}
expect 0.9999.20260913 0.9999.20260913
expect v0.9999.20260913 0.9999.20260913
expect 0.9999.20240229 0.9999.20240229
expect 0.9999.20000229 0.9999.20000229
for bad in 0.9999 v0.9999.abcdef0 0.99999.20260913 0.9999.20260229 \
           0.9999.19000229 0.9999.20261301 0.9999.20260931 \
           0.9999.20260900 0.9999.2026913 0.9999.00000101 \
           0.9999.20260913.dirty 0.9999.20260913-rc1; do
  if pocket_version "$bad" >/dev/null 2>&1; then
    echo "accepted invalid version: $bad" >&2; exit 1
  fi
done
[[ $(pocket_version_date v0.9999.20240229) == 2024-02-29 ]]
# Freeze the clock at a UTC midnight boundary and vary the local timezone.
# The production helper must explicitly ask date for UTC.
date() {
  if [[ "$*" == '-u +%Y%m%d' ]]; then printf '20260913\n'
  elif [[ "$*" == '+%Y%m%d' ]]; then printf '20260912\n'
  else command date "$@"; fi
}
[[ $(TZ=America/Chicago pocket_version) == 0.9999.20260913 ]]
[[ $(TZ=Pacific/Kiritimati pocket_version) == 0.9999.20260913 ]]
echo 'Calendar version checks passed'
