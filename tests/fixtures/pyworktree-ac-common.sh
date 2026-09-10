#!/usr/bin/env bash
# pyworktree-ac-common.sh — shared helper for the
# tests/pyworktree_ac<N>_*.sh per-AC wrapper files
# (PRD-build-python-worktree-isolation). scripts/python-worktree-selftest.sh
# already exercises AC1-4 as a set of named `ok  <label>` assertions
# against the real worktree-extend.sh `add`/`land` code against a
# disposable fixture repo — there is no separate, hand-duplicated
# implementation per AC here, deliberately: a second, independent per-AC
# test body would drift from the real one and prove nothing an edit to
# worktree-extend.sh's actual isolation/land logic couldn't silently
# invalidate. Instead, each wrapper runs the real suite (matching
# --verify-run's own model of "the script itself is the test unit") and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output — so a future edit that silently
# drops or renames this AC's coverage from the monolith fails this file
# too, not just a reshuffled label nobody notices. Mirrors
# tests/fixtures/gateconcurrent-ac-common.sh / burst-lane-ac-common.sh
# exactly (same convention, same repo).
#
# `want` entries may be a full literal "ok  <label>" line OR a stable
# substring of one (grep -F is a substring match, not a whole-line match).
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/python-worktree-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: python-worktree-selftest.sh exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from python-worktree-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
