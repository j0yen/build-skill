#!/usr/bin/env bash
# burst-lane-ac-common.sh — shared helper for the tests/burst-lane_ac<N>_*.sh
# per-AC wrapper files (PRD-build-burst-lane-ccx53). Requirement 9's own
# selftest (scripts/burst-lane-selftest.sh) already exercises every one of
# this PRD's ACs as a set of named `ok  <label>` assertions against the
# real burst-lane.sh code with fake hcloud/ssh/rsync — there is no separate,
# independently-implemented per-AC test body here, deliberately: a second,
# hand-duplicated implementation per AC would drift from the real one and
# prove nothing an edit to burst-lane.sh's actual logic couldn't silently
# invalidate. Instead, each wrapper runs the real suite (matching
# --verify-run's own model of "the script itself is the test unit") and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output — so a future edit that silently
# drops or renames this AC's coverage from the monolith fails this file
# too, not just a reshuffled label nobody notices.
run_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/burst-lane-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  # PRD-build-burst-selftest-isolation requirement 1: belt-and-suspenders —
  # burst-lane-selftest.sh already self-exports this at its own top, but
  # every tests/*.sh is required to export it too, so this wrapper does not
  # rely solely on the suite it calls remembering to.
  out="$(BURST_LANE_TEST=1 bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: burst-lane-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
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
