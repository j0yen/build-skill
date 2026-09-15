#!/usr/bin/env bash
# bdrift_ac2_broken_slots_negative_case.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC2.
#
# Given the same suite with BURSTPAR_TEST_BREAK_SLOTS=1, When it runs, Then
# it exits non-zero and prints "FAIL ... peak=" with a value greater than
# 4 — proving the counter can fail (requirement 2). Deliberately NOT run
# through run_burstpar_and_expect_labels: that helper requires the suite to
# exit 0, and this case's whole point is that it must NOT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/burstpar-selftest.sh"
[ -x "$SUITE" ] || { echo "FAIL: $SUITE not executable" >&2; exit 2; }

out="$(BURST_LANE_TEST=1 BUILD_BURST_ENABLED=1 BURSTPAR_TEST_BREAK_SLOTS=1 bash "$SUITE" 2>&1)"; rc=$?

fail=0
if [ "$rc" -ne 0 ]; then
  echo "ok  AC2: burstpar-selftest exits non-zero under BURSTPAR_TEST_BREAK_SLOTS=1 (rc=$rc)"
else
  echo "FAIL: burstpar-selftest exited 0 under BURSTPAR_TEST_BREAK_SLOTS=1 (should have failed)" >&2
  fail=1
fi

fail_peak_line="$(grep -E '^FAIL .*peak=' <<<"$out" | head -1)"
if [ -n "$fail_peak_line" ]; then
  echo "ok  AC2: a FAIL line names peak= ($fail_peak_line)"
else
  echo "FAIL: no 'FAIL ... peak=' line found in output" >&2
  echo "$out" | tail -20 >&2
  fail=1
fi

peak_val="$(grep -oE 'peak=[0-9]+' <<<"$fail_peak_line" | head -1 | cut -d= -f2)"
if [ -n "$peak_val" ] && [ "$peak_val" -gt 4 ]; then
  echo "ok  AC2: the failing peak value ($peak_val) is greater than the cap (4)"
else
  echo "FAIL: peak value '$peak_val' is not > 4" >&2
  fail=1
fi

exit $fail
