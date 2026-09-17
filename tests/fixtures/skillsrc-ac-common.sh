#!/usr/bin/env bash
# skillsrc-ac-common.sh — shared helper for the tests/skillsrc_ac<N>_*.sh
# per-AC wrapper files (PRD-build-skill-instruction-single-source).
# scripts/skill-single-source-selftest.sh already exercises every one of
# this PRD's buildable ACs (AC1-AC10; AC11 is Live and resolves in
# production, not at build time) as a set of named "ok  <label>"
# assertions against the real archive-gate.sh/gate-launch.sh/
# skill-prose-lint.sh code — same rationale as
# tests/fixtures/gatelaunch-ac-common.sh: no separate, hand-duplicated
# per-AC test body here, deliberately, so a future edit that silently
# drops or reshapes this PRD's coverage in the real suite fails this
# file too.
#
# `want` entries may be a full literal "ok  <label>" line OR a stable
# substring of one (grep -F is a substring match) — used for labels that
# embed a dynamic value.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/skill-single-source-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  out="$(TMPDIR="${TMPDIR:-/tmp}" bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: skill-single-source-selftest.sh exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from skill-single-source-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
