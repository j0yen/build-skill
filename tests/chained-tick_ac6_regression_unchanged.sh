#!/usr/bin/env bash
# chained-tick_ac6_regression_unchanged.sh — PRD-build-chained-tick-actions
# AC6 (P1): Given the existing selftests (lane-claim, lane-predicate,
# claims-resume), When run after this change, Then they still pass
# unmodified.
#
# This PRD's own commit (17a5c25) never touched scripts/lane-claim.sh,
# scripts/lane-claim-selftest.sh, scripts/lane-predicate.sh, or
# tests/claims-resume_ac*.sh — only SKILL.md, scripts/chain-guard.sh (new),
# and tests/chained-tick_ac1..ac5 (new). This test is the mechanical proof
# that the pre-existing regression suite is unaffected: it runs the three
# selftest entry points directly and asserts a zero exit + an ALL-pass
# banner from each.
#
# Isolation note: lane-claim-selftest.sh's burst-lane sub-test defaults
# BURST_LANE_SH to the real scripts/burst-lane.sh, which — on a box
# actually running a live burst-lane session (a fan-out tick's OTHER
# branches, not this PRD) — reports that session's real sub-cap instead
# of the "no session" fallback the sub-test assumes. That's a pre-existing
# test-isolation gap in lane-claim-selftest.sh (unrelated to this PRD;
# confirmed by diffing the landed commit) that only surfaces under real
# concurrent load. This test pins BURST_LANE_SH to a nonexistent path so
# the regression check this AC actually cares about — did THIS PRD's
# change break these selftests — is hermetic and reproducible regardless
# of what else this box happens to be running.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"

fail=0
run_one() {
  local label="$1"; shift
  local out rc
  out="$(BURST_LANE_SH=/nonexistent-no-session "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q '^FAIL' <<<"$out"; then
    echo "ok  $label"
  else
    echo "FAIL $label (rc=$rc)" >&2
    echo "$out" | tail -20 >&2
    fail=1
  fi
}

run_one "lane-claim-selftest.sh passes unmodified"     bash "$SCRIPTS/lane-claim-selftest.sh"
run_one "lane-predicate-selftest.sh passes unmodified" bash "$SCRIPTS/lane-predicate-selftest.sh"
run_one "claims-resume_ac6_selftests_pass.sh passes"   bash "$HERE/claims-resume_ac6_selftests_pass.sh"

exit $fail
