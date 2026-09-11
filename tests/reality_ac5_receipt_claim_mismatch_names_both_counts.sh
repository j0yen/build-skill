#!/usr/bin/env bash
# reality_ac5_receipt_claim_mismatch_names_both_counts.sh —
# PRD-build-post-ship-reality-check AC5.
#
# Given a receipt claiming `251/251 0 FAIL` and a selftest that reports
# `245 ok 6 FAIL`, When the archive step runs, Then it exits non-zero with
# `receipt-claim-mismatch` showing both counts. Also covers the matching-
# claim case exiting 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC5: matching receipt claim exits 0" \
  "ok  reality AC5: mismatched receipt claim exits 1 naming both counts"
