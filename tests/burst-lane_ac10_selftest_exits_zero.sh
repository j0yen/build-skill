#!/usr/bin/env bash
# burst-lane_ac10_selftest_exits_zero.sh — PRD-build-burst-lane-ccx53 AC10.
#
# Given scripts/burst-lane-selftest.sh, when run, then it exits 0 with one
# line per assertion above that the fakes cover.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/burst-lane-selftest.sh"
[ -x "$SUITE" ] || { echo "FAIL: $SUITE not executable" >&2; exit 2; }

out="$(bash "$SUITE" 2>&1)"; rc=$?
fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

expect "burst-lane-selftest.sh exits 0" "[ $rc -eq 0 ]"
expect "burst-lane-selftest.sh prints one line per assertion (ok/FAIL, >=40)" \
  "[ \$(grep -cE '^(ok|FAIL)' <<<\"$out\") -ge 40 ]"
expect "burst-lane-selftest.sh reports its own PASS verdict" "grep -q '^=== PASS ===' <<<\"$out\""

exit $fail
