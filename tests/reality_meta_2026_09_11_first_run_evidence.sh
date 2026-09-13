#!/usr/bin/env bash
# reality_meta_2026_09_11_first_run_evidence.sh — one-time historical
# evidence for PRD-build-post-ship-reality-check, deliberately NOT named
# `reality_ac<N>_*.sh` (renamed 2026-09-13 from its original
# `reality_ac8_*.sh` name): it pairs to no single current numbered AC —
# current AC8 is the P2 digest-surface requirement (unbuilt, see this
# PRD's `deferred_acs`), which this file does not test. Keeping it at an
# `ac8`-shaped filename would have made verified-completed.sh --derive
# silently PAIR AC8 to a file that never exercised the digest at all — a
# false green of exactly the kind this PRD exists to prevent. The
# assertions below stay: they're real, one-time evidence the 2026-09-11
# first tick actually landed four `reality` journal lines (its own
# original justification for existing), just no longer claimed as AC
# coverage.
#
# Checked here against the real journal it actually landed in on
# 2026-09-11, not re-derived from a mock. The real finding for all four
# differs from the (pre-revision) AC's literal three-way enumeration:
# `reality-check.sh plan` came back EMPTY for each (their AC text
# describes a fake-box fixture scenario or the real defect lived in prose
# rather than a literal live-lane/real-box/on-casper/URL/systemctl
# substrate mention — see the safety-hardening commit that narrowed
# substrate extraction, 2d73dfd). Calling `run` against an empty plan
# would have written a fabricated `reality: unreachable` onto PRDs that
# never named a real substrate at all — the same "don't invent evidence"
# doctrine this PRD exists to enforce — so the first tick journaled the
# honest `no-substrate-acs` finding by hand instead of forcing the letter
# over the intent. Each of the four still carries its own real evidence
# line, which is what this test verifies.
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
  expect "reality meta (2026-09-11): journal has a real reality line for $slug" \
    "grep -qE \"  reality  ${slug}  \" \"$J\""
done

expect "reality meta (2026-09-11): unprivileged-user's deferral premise was independently re-checked the same tick" \
  "grep -q 'check-deferral-premises' \"$J\""

exit $fail
