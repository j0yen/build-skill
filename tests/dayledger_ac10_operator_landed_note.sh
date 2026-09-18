#!/usr/bin/env bash
# dayledger_ac10_operator_landed_note.sh — PRD-build-day-ledger AC10 (P1):
# given a merged loop/<slug> PR with no landing-pending journal line that
# day, notes contains 'operator-landed <repo> via pr #<n>'.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC10: operator-landed note present for the un-flagged merge"
