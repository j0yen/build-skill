#!/usr/bin/env bash
# archatomic-ac-common.sh — shared helper for the tests/archatomic_ac<N>_*.sh
# per-AC wrapper files (PRD-build-archive-atomic-commit, test_prefix
# `archatomic`). scripts/archive-commit-selftest.sh already exercises
# every one of this PRD's ACs as a set of named `ok  <label>` assertions
# against the real archive-commit.sh + lane-claim.sh code, run against
# disposable git fixtures — there is no separate, hand-duplicated
# implementation per AC here, deliberately, mirroring
# tests/fixtures/gateconcurrent-ac-common.sh's convention exactly (a
# second, independent per-AC test body would drift from the real one and
# prove nothing an edit to the actual scripts couldn't silently
# invalidate). Each wrapper runs the real suite and requires BOTH that it
# exits 0 AND that the specific labeled assertions for its AC are present
# in the output.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/archive-commit-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: archive-commit-selftest.sh exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from archive-commit-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
