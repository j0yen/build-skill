#!/usr/bin/env bash
# cargoroute-ac-common.sh — shared helper for the tests/cargoroute_ac<N>_*.sh
# per-AC wrapper files (PRD-build-cargo-route-precedence, test_prefix
# `cargoroute`). scripts/cargo-route-precedence-selftest.sh already
# exercises every one of this PRD's ACs as a set of named `ok  <label>`
# assertions against the real lib/cargo-route.sh, cargo-budget-bin/cargo,
# burst-lane.sh route-check, and extend-gate.sh code — there is no
# separate, hand-duplicated per-AC test body here, deliberately, mirroring
# tests/fixtures/archatomic-ac-common.sh's own convention exactly. Each
# wrapper runs the real suite and requires BOTH that it exits 0 AND that
# the specific labeled assertions for its AC are present in the output.
#
# BUILD_BURST_ENABLED=1 is required here (not optional): the suite's own
# preamble (reused verbatim from burst-lane-selftest.sh) skips its entire
# body under the RedBaron-local dormant-burst policy unless the caller
# opts in — see lib/burst-configured.sh's own header for why this is a
# documented one-off forced-test-run escape hatch, never a resurrection of
# the dormant production lane (every fixture here stays fully offline:
# fake hcloud/ssh/rsync, or no session at all).
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/cargo-route-precedence-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(BURST_LANE_TEST=1 BUILD_BURST_ENABLED=1 bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: cargo-route-precedence-selftest.sh exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from cargo-route-precedence-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
