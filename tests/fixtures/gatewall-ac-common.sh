#!/usr/bin/env bash
# gatewall-ac-common.sh — shared helper for the tests/gatewall_ac<N>_*.sh
# per-AC wrapper files (PRD-build-gate-wall-clock).
#
# Unlike the single-mechanism precedents this mirrors
# (tests/fixtures/gateconcurrent-ac-common.sh,
# tests/fixtures/pyworktree-ac-common.sh, tests/fixtures/burst-lane-ac-
# common.sh — one wrapped suite each), this PRD's requirements are already
# covered across FOUR separate, already-shipped fixture selftests
# (scripts/gate-wedge-selftest.sh, scripts/sccache-assert-selftest.sh,
# scripts/cargo-budget-sccache-selftest.sh,
# scripts/gate-wedge-rollup-selftest.sh — one per mechanism: the wedge
# probe, the restart precondition, the cargo-budget choke point, and the
# daily rollup). Duplicating a second, hand-written test body per AC here
# would drift from the real ones and prove nothing an edit to the actual
# scripts could not silently invalidate — same reasoning as every sibling
# common helper, just parameterized over which suite to run since there
# are several. Each wrapper runs the real suite it's paired with and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output.
#
# `want` entries may be a full literal output line OR a stable substring
# of one (grep -F is a substring match).
run_suite_and_expect_labels() {  # $1 = suite script (relative to tests/../scripts), $@[2:] = wanted lines/substrings
  local here suite_name suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite_name="$1"; shift
  suite="$here/../scripts/$suite_name"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $suite_name exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from $suite_name: $want" >&2
      fail=1
    fi
  done
  return $fail
}
