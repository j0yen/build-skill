#!/usr/bin/env bash
# isolate-ac-common.sh — shared helper for the tests/isolate_ac<N>_*.sh
# per-AC wrapper files (PRD-build-burst-selftest-isolation).
# scripts/burst-lane-selftest.sh's own "isolate AC1-6" section already
# exercises every one of this PRD's ACs as a set of named `ok  <label>`
# assertions against the real burst-lane.sh isolation-guard.sh wiring —
# there is no separate, hand-duplicated implementation per AC here,
# deliberately, mirroring tests/fixtures/burst-lane-ac-common.sh's
# convention exactly (a second, independent per-AC test body would drift
# from the real one and prove nothing an edit to the actual guard logic
# couldn't silently invalidate). Each wrapper runs the real suite and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/burst-lane-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(BURST_LANE_TEST=1 bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: burst-lane-selftest.sh exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from burst-lane-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
