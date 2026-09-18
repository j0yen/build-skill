#!/usr/bin/env bash
# dayledger-ac-common.sh — shared helper for the tests/dayledger_ac<N>_*.sh
# per-AC wrapper files (PRD-build-day-ledger, test_prefix `dayledger`).
# scripts/day-ledger-selftest.sh already exercises every one of this
# PRD's ACs as a set of named `ok  <label>` assertions against the real
# day-ledger.sh code, run against disposable git/journal fixtures — there
# is no separate, hand-duplicated implementation per AC here, deliberately
# (mirrors tests/fixtures/archatomic-ac-common.sh's convention exactly).
#
# DAY_LEDGER_SELFTEST_SKIP_LIVE=1: the suite's own AC11 phase runs
# day-ledger.sh for real against $HOME/Documents/PRDs (a genuine commit +
# push — that IS day-ledger.sh's job, and AC11 says "(Live, one run.)").
# These per-AC wrapper files are meant to run often (gate sweeps,
# run-selftests.sh, any future PRD's regression pass) — SKIP_LIVE=1 here
# keeps every one of THOSE runs to the disposable fixtures only, so the
# real PRDs repo gets a new day-ledger commit once per deliberate live
# run of day-ledger-selftest.sh itself, not once per AC wrapper per gate.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/day-ledger-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(DAY_LEDGER_SELFTEST_SKIP_LIVE=1 bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: day-ledger-selftest.sh exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from day-ledger-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
