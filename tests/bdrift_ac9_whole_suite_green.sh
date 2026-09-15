#!/usr/bin/env bash
# bdrift_ac9_whole_suite_green.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC9.
#
# Given the whole burst-lane-selftest suite plus burstpar-selftest, When
# they run on RedBaron under the opt-in env, Then every bdrift case is ok
# and no previously green case turns red. This wrapper directly verifies
# the first half (every case THIS PRD added is ok, and burstpar-selftest
# itself is fully green) against the real suites; the second half ("no
# previously green case turns red" against the FULL, much larger monolith
# that also covers dozens of unrelated PRDs) is the delta-pass baseline
# comparison verified-completed.sh's own gate already does across the
# whole tree — re-deriving that from a single wrapper without a stored
# baseline would either be a no-op or a hand-duplicated, driftable copy of
# that gate, exactly what tests/fixtures/*-ac-common.sh's own header
# argues against.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BURSTPAR="$HERE/../scripts/burstpar-selftest.sh"
SUITE="$HERE/../scripts/burst-lane-selftest.sh"
[ -x "$BURSTPAR" ] || { echo "FAIL: $BURSTPAR not executable" >&2; exit 2; }
[ -x "$SUITE" ] || { echo "FAIL: $SUITE not executable" >&2; exit 2; }

fail=0

bp_out="$(BURST_LANE_TEST=1 BUILD_BURST_ENABLED=1 bash "$BURSTPAR" 2>&1)"; bp_rc=$?
if [ "$bp_rc" -eq 0 ] && ! grep -q '^FAIL' <<<"$bp_out"; then
  echo "ok  AC9: burstpar-selftest.sh is fully green"
else
  echo "FAIL: burstpar-selftest.sh is not green (rc=$bp_rc)" >&2
  grep '^FAIL' <<<"$bp_out" >&2
  fail=1
fi

suite_out="$(BURST_LANE_TEST=1 BUILD_BURST_ENABLED=1 bash "$SUITE" 2>&1 || true)"
bdrift_fails="$(grep -E '^FAIL (bakegate|provefx AC14)' <<<"$suite_out" || true)"
if [ -z "$bdrift_fails" ]; then
  echo "ok  AC9: every bakegate/provefx-AC14 case in burst-lane-selftest.sh is ok"
else
  echo "FAIL: this PRD's own cases are red:" >&2
  echo "$bdrift_fails" >&2
  fail=1
fi

exit $fail
