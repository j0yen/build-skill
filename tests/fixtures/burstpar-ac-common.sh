#!/usr/bin/env bash
# burstpar-ac-common.sh — shared helper for the tests/burstpar_ac<N>_*.sh
# per-AC wrapper files (PRD-build-burst-parallel-runs). Mirrors
# burst-lane-ac-common.sh's convention exactly: scripts/burstpar-selftest.sh
# already exercises every AC as a set of named `ok  <label>` assertions
# against the real burst-lane.sh code (fake ssh/rsync, real flock/slot
# logic) — there is no separate, hand-duplicated per-AC test body here,
# deliberately, so an edit that silently drops this AC's coverage from the
# monolith fails the wrapper too, not just a label nobody notices.
run_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/burstpar-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: burstpar-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from burstpar-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
