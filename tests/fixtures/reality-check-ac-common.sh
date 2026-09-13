#!/usr/bin/env bash
# reality-check-ac-common.sh — shared helper for the
# tests/reality_ac<N>_*.sh per-AC wrapper files (PRD-build-post-ship-
# reality-check). scripts/reality-check-selftest.sh already exercises
# every one of this PRD's ACs as a set of named `ok  <label>` assertions
# against the real reality-check.sh / verified-completed.sh / prd-lint.sh
# code with fake burst-lane scripts — there is no separate, hand-
# duplicated implementation per AC here, deliberately: a second
# implementation per AC would drift from the real one and prove nothing an
# edit to the real logic couldn't silently invalidate. Instead, each
# wrapper runs the real suite (matching --verify-run's own model of "the
# script itself is the test unit") and requires BOTH that it exits 0 AND
# that the specific labeled assertions for its AC are present in the
# output — so a future edit that silently drops or renames this AC's
# coverage fails this file too, not just a reshuffled label nobody notices.
#
# 2026-09-13 finding (this PRD's own dogfood defect): the ORIGINAL
# tests/reality_ac<N>_*.sh wrappers pointed at scripts/burst-lane-
# selftest.sh's own `reality` fixture section via
# fixtures/burst-lane-ac-common.sh's run_suite_and_expect_labels — but
# that whole suite SKIPs (exit 0, no cases run) under the RedBaron-local
# dormant-burst-lane policy (lib/burst-configured.sh), so every one of
# those wrappers was silently failing to find its labels (verified by
# actually running them: all but the AC8 one-time-evidence wrapper FAILed
# with "expected label missing"). None of the reality-check ACs need the
# real burst lane — they use fakes throughout — so this helper targets
# the standalone, ungated scripts/reality-check-selftest.sh instead.
run_reality_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/reality-check-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: reality-check-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from reality-check-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
