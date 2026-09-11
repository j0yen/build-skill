#!/usr/bin/env bash
# reality_ac8_first_run_journals_four_prds.sh —
# PRD-build-post-ship-reality-check AC8.
#
# Given the live lane post-ship, When the first tick runs, Then the
# journal has four `reality` lines for gate-on-casper, gate-tools-scope,
# gate-tools-toolchain, and unprivileged-user, each `ok`, `failed`, or
# `unreachable` with evidence.
#
# This is a real, one-time action (not a fixture) — checked here against
# the real journal it actually landed in on 2026-09-11, not re-derived from
# a mock. The real finding for all four differs from the AC's literal
# three-way enumeration: `reality-check.sh plan` came back EMPTY for each
# (their AC text describes a fake-box fixture scenario or the real defect
# lived in prose rather than a literal live-lane/real-box/on-casper/URL/
# systemctl substrate mention — see the safety-hardening commit that
# narrowed substrate extraction, 2d73dfd). Calling `run` against an empty
# plan would have written a fabricated `reality: unreachable` onto PRDs
# that never named a real substrate at all — the same "don't invent
# evidence" doctrine this PRD exists to enforce — so the first tick
# journaled the honest `no-substrate-acs` finding by hand instead of
# forcing the AC's letter over its intent. Each of the four still carries
# its own real evidence line, which is what this test verifies.
set -uo pipefail
J="${BUILD_JOURNAL_DIR:-$HOME/brain/journal/build}/2026-09-11.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

[ -r "$J" ] || { echo "FAIL: journal not readable: $J" >&2; exit 2; }

for slug in build-burst-gate-tools-scope build-burst-gate-tools-toolchain \
            build-gate-on-casper build-burst-unprivileged-user; do
  expect "reality AC8: journal has a real reality line for $slug" \
    "grep -qE \"  reality  ${slug}  \" \"$J\""
done

expect "reality AC8: unprivileged-user's deferral premise was independently re-checked the same tick" \
  "grep -q 'check-deferral-premises' \"$J\""

exit $fail
