#!/usr/bin/env bash
# Package versions use the UTC calendar date; source commits stay in reports.
pocket_version() {
  local version="${1:-}" day iso parsed
  version="${version#v}"
  [[ -n "$version" ]] || version="0.9999.$(date -u +%Y%m%d)"
  if [[ ! "$version" =~ ^0\.9999\.([0-9]{8})$ ]]; then
    echo "invalid version: $version; expected 0.9999.YYYYMMDD" >&2
    return 2
  fi
  day="${BASH_REMATCH[1]}"
  [[ "${day:0:4}" != 0000 ]] || return 2
  iso="${day:0:4}-${day:4:2}-${day:6:2}"
  parsed=$(date -u -d "$iso" +%Y%m%d 2>/dev/null) || {
    echo "invalid release date: $day" >&2
    return 2
  }
  [[ "$parsed" == "$day" ]] || return 2
  printf '%s\n' "$version"
}

pocket_version_date() {
  local version day
  version=$(pocket_version "$1") || return
  day="${version##*.}"
  printf '%s-%s-%s\n' "${day:0:4}" "${day:4:2}" "${day:6:2}"
}
