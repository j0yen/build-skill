#!/usr/bin/env bash
# shwt-ac-common.sh — shared helper for the tests/shwt_ac<N>_*.sh per-AC
# wrapper files (PRD-build-shell-worktree-isolation). Mirrors
# tests/fixtures/pyworktree-ac-common.sh exactly: scripts/worktree-extend-
# selftest.sh already exercises AC1-5/7-9 as a set of named `ok  <label>`
# assertions against the real worktree-extend.sh/chain-guard.sh code
# against disposable fixture repos — no separate, hand-duplicated
# implementation per AC here, so a future edit that silently drops or
# renames this AC's coverage from the monolith fails this file too.
#
# `want` entries may be a full literal "ok  <label>" line OR a stable
# substring of one (grep -F is a substring match, not a whole-line match).
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/worktree-extend-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: worktree-extend-selftest.sh exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from worktree-extend-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
