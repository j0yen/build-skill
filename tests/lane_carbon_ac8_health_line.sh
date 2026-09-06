#!/usr/bin/env bash
# lane_carbon_ac8_health_line.sh — PRD-build-second-lane-carbon AC8 (P1).
#
# Given a day with both lanes active, when the journal is read, then
# per-lane claimed/skipped counts are present for each tick.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LS="$HERE/../scripts/lane-status.sh"
[ -x "$LS" ] || { echo "ac8: $LS not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac8.XXXXXX")"
trap 'rm -rf "$T"' EXIT
J="$T/journal.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$LS" tick-summary RedBaron 5 2 "$J" >/dev/null
"$LS" tick-summary carbon 2 1 "$J" >/dev/null

expect "RedBaron's tick line has claimed/skipped counts" \
  "grep -q 'lane-health  tick  claimed=5 skipped=2  (lane=RedBaron)' \"$J\""
expect "carbon's tick line has claimed/skipped counts" \
  "grep -q 'lane-health  tick  claimed=2 skipped=1  (lane=carbon)' \"$J\""
expect "both lines carry an ISO timestamp" \
  "[ \"\$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \"$J\")\" -eq 2 ]"

exit $fail
