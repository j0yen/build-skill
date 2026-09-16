#!/usr/bin/env bash
# failloud-ac-common.sh — shared helper for the tests/failloud_ac<N>_*.sh
# per-AC wrapper files (PRD-build-fail-loud-evidence-kept, test_prefix
# `failloud`). scripts/failloud-selftest.sh already exercises every one of
# this PRD's ACs as a set of named `ok  <label>` assertions against the
# real scripts/lib/probe.sh, scripts/burst-lane.sh, scripts/extend-gate.sh,
# scripts/select-guard.sh, and scripts/lane-status.sh code — there is no
# separate, hand-duplicated implementation per AC here, deliberately
# (mirrors tests/fixtures/archatomic-ac-common.sh's own convention exactly:
# a second, independent per-AC test body would drift from the real one and
# prove nothing an edit to the actual scripts couldn't silently
# invalidate). Each wrapper runs the real suite once and requires BOTH
# that it exits 0 AND that the specific labeled assertions for its AC are
# present in the output.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/failloud-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  # PRD-build-journal-single-writer requirement 3: structural isolation
  # exported into the child `bash "$suite"` process below, belt-and-
  # suspenders alongside failloud-selftest.sh's own per-case
  # BUILD_JOURNAL_ROOT/SELECT_GUARD_JOURNAL overrides (not every one of
  # its internal cases sets its own).
  # shellcheck source=../../scripts/lib/isolation.sh
  source "$here/../scripts/lib/isolation.sh"
  selftest_init || { echo "FAIL: failloud-ac-common: selftest_init failed" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: failloud-selftest.sh exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from failloud-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
