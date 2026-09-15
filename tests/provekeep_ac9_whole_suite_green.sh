#!/usr/bin/env bash
# provekeep_ac9_whole_suite_green.sh — PRD-build-burst-prove-evidence-
# preservation AC9 (P0).
#
# Given the whole burst-lane-selftest suite, When it runs on RedBaron under
# BUILD_BURST_ENABLED=1 BURST_LANE_TEST=1, Then every provekeep case is ok
# and no previously green case turns red.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/burst-lane-selftest.sh"
[ -x "$SUITE" ] || { echo "FAIL: $SUITE not executable" >&2; exit 2; }

out="$(BUILD_BURST_ENABLED=1 BURST_LANE_TEST=1 bash "$SUITE" 2>&1)"; rc=$?
fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

expect "provekeep AC9: the whole suite exits 0" "[ $rc -eq 0 ]"
expect "provekeep AC9: the suite reports its own PASS verdict" "grep -q '^=== PASS ===' <<<\"$out\""
expect "provekeep AC9: no FAIL line anywhere in the run" "! grep -q '^FAIL' <<<\"$out\""
expect "provekeep AC9: every provekeep case reports ok (>=22)" \
  "[ \$(grep -cE '^ok  provekeep ' <<<\"$out\") -ge 22 ]"
expect "provekeep AC9: the provekeep block itself reports green" \
  "grep -q '^ok  provekeep: every provekeep case above ran green' <<<\"$out\""

exit $fail
