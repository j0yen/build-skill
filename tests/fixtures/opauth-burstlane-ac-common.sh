#!/usr/bin/env bash
# opauth-burstlane-ac-common.sh — shared helper for the
# tests/opauth_ac<N>_*.sh wrapper files whose evidence lives in
# scripts/burst-lane-selftest.sh's "opauth" block
# (PRD-build-operator-authorization-contract requirement 5/6). Same model
# as probevis-ac-common.sh: run the real, dedicated fixture (not a second,
# hand-duplicated implementation that could drift) and require the exact
# labeled assertions to be present in its output.
#
# BUILD_BURST_ENABLED=1: burst-lane-selftest.sh gates its entire run behind
# burst_configured() (lib/burst-configured.sh) under the 2026-09-11
# RedBaron-local policy — without this the suite prints one
# "SKIP: burst lane dormant" line and exits 0 before any assertion runs.
# This is safe here: the suite's fresh_env() always overrides PATH/env to
# point at its own fake hcloud/ssh/rsync before any burst-lane.sh command
# that could touch a real box ever runs (this PRD's own non-goal: no AC may
# require a real Hetzner box).
run_burstlane_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/burst-lane-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(BUILD_BURST_ENABLED=1 bash "$suite" 2>&1)"; rc=$?
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
