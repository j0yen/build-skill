#!/usr/bin/env bash
# reality_ac3_deferral_premise_false_names_evidence.sh —
# PRD-build-post-ship-reality-check AC3.
#
# Given a deferral premise "box unreachable" while the lane ledger shows
# the box active (the 09-11 case as fixture), When archive runs, Then the
# archive blocks with premise-contradicted naming both sources. Also
# covers the true-premise case (a genuinely unreachable box) passing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC3: deferral-premise-false exits non-zero when the lane the deferral called unreachable is actually active" \
  "ok  AC3: names the contradicting AC and evidence" \
  "ok  AC3 (real failure-mode case: genuinely unreachable) — the true premise passes archive"
