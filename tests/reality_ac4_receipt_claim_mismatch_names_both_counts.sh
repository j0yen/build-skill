#!/usr/bin/env bash
# reality_ac4_receipt_claim_mismatch_names_both_counts.sh —
# PRD-build-post-ship-reality-check AC4.
#
# Given a receipt claiming N tests while the tree derives M≠N (the
# 251/245 case as fixture), When archive runs, Then it blocks with
# claim-unreproducible carrying both numbers. Also covers a matching
# claim exiting 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC4: a matching receipt claim exits 0" \
  "ok  AC4 (real failure-mode case: the 251-on-245 defect) — a mismatched claim blocks naming both counts"
