#!/usr/bin/env bash
# dayledger_ac4_identifier_closure_and_secrets.sh — PRD-build-day-ledger
# AC4: identifier-closure holds on a produced file (every slug/repo/
# hostname/sha/PR-number/decision-id match is inside identifiers[]) and no
# HCLOUD_TOKEN=/sk-/40-hex-with-token string appears anywhere; the negative
# cases (an injected foreign identifier, an injected secret) are correctly
# DETECTED by the checkers — one of this PRD's required real
# failure-mode selftest cases (AC11), not just a success-path assertion.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: identifier closure holds on AC1's fixture output" \
  "ok  AC4: no secret-shaped string in AC1's fixture output" \
  "ok  AC4/AC11-neg: identifier-closure violation correctly detected" \
  "ok  AC4/AC11-neg: secrets checker correctly detected an injected HCLOUD_TOKEN="
