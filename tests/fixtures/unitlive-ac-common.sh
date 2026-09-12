#!/usr/bin/env bash
# unitlive-ac-common.sh — shared helper for the tests/unitlive_ac<N>_*.sh
# per-AC wrapper files (PRD-buildloop-unit-liveness, test_prefix: unitlive).
#
# Same rationale as burst-lane-ac-common.sh: scripts/unitlive-selftest.sh
# (and, for AC4, scripts/build-has-work-selftest.sh) already exercise every
# AC as a named `ok  <label>` assertion against the real loop-liveness.sh /
# loop-arm.sh / build-has-work.sh code with a fake systemctl — there is no
# separate, hand-duplicated test body here. Each wrapper runs the real
# suite and requires BOTH that it exits 0 AND that the specific labeled
# assertion(s) for its AC are present, so a future edit that silently drops
# or renames this AC's coverage fails the wrapper too, not just a
# reshuffled label nobody notices.

run_unitlive_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/unitlive-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: unitlive-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from unitlive-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}

run_buildhaswork_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/build-has-work-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: build-has-work-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from build-has-work-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
