#!/usr/bin/env bash
# reality_ac1_reachable_run_writes_ok_and_receipt.sh —
# PRD-build-post-ship-reality-check AC1.
#
# Given a shipped PRD with one substrate-naming AC and a reachable
# substrate, When the next tick runs, Then a reality receipt exists with
# that AC's real pass/fail and a journal line names it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC1: run exits 0" \
  "ok  AC1: reality=ok with a real pass/fail verdict" \
  "ok  AC1: a reality receipt file exists" \
  "ok  AC1: journal names the slug with an ok verdict"
