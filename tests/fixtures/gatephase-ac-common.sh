#!/usr/bin/env bash
# gatephase-ac-common.sh — shared helper for the tests/gatephase_ac<N>_*.sh
# per-AC wrapper files (PRD-build-gate-phase-timing, test_prefix
# `gatephase`). scripts/extend-gate-phase-timing-selftest.sh already
# exercises every one of this PRD's ACs as a set of named `ok  <label>`
# assertions against the real extend-gate.sh and gate-phase-digest.sh code,
# driven through a fake toolchain (tests/fixtures/gatephase-fake) — there
# is no separate, hand-duplicated implementation per AC here, deliberately
# (same rationale as tests/fixtures/gateconcurrent-ac-common.sh: a second,
# independent per-AC test body would drift from the real one and prove
# nothing an edit to extend-gate.sh's actual timing logic couldn't
# silently invalidate). Each wrapper runs the real suite and requires BOTH
# that it exits 0 AND that the specific labeled assertions for its AC are
# present in the output.
#
# `want` entries may be a full literal "ok  <label>" line OR a stable
# substring of one (grep -F is a substring match) — used for labels that
# embed a dynamic value.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/extend-gate-phase-timing-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: extend-gate-phase-timing-selftest.sh exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from extend-gate-phase-timing-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
