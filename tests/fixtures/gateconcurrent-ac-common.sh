#!/usr/bin/env bash
# gateconcurrent-ac-common.sh — shared helper for the
# tests/gateconcurrent_ac<N>_*.sh per-AC wrapper files
# (PRD-build-extend-gate-concurrent-isolation). scripts/extend-gate-concurrent-
# selftest.sh already exercises every one of this PRD's ACs as a set of
# named `ok  <label>` assertions against the real extend-gate.sh code
# against a disposable fixture repo — there is no separate,
# hand-duplicated implementation per AC here, deliberately: a second,
# independent per-AC test body would drift from the real one and prove
# nothing an edit to extend-gate.sh's actual locking logic couldn't
# silently invalidate. Instead, each wrapper runs the real suite (matching
# --verify-run's own model of "the script itself is the test unit") and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output — so a future edit that silently
# drops or renames this AC's coverage from the monolith fails this file
# too, not just a reshuffled label nobody notices. Mirrors
# tests/fixtures/burst-lane-ac-common.sh exactly (same convention, same
# repo).
#
# `want` entries may be a full literal "ok  <label>" line OR a stable
# substring of one (grep -F is a substring match, not a whole-line match)
# — used here for labels that embed a dynamic value (a holder pid) that
# can't be pinned to an exact string across runs.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/extend-gate-concurrent-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: extend-gate-concurrent-selftest.sh exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from extend-gate-concurrent-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
