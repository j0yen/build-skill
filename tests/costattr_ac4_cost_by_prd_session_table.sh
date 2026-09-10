#!/usr/bin/env bash
# costattr_ac4_cost_by_prd_session_table.sh — PRD-build-cost-attribution AC4.
#
# Given `cost --by-prd --session <id>`, when run, then the table lists the
# 3 slugs sorted by eur and a totals row matching the session total.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: cost --by-prd --session exits 0 (conservation check passes)" \
  "ok  AC4: cost --by-prd lists all 3 slugs" \
  "ok  AC4: cost --by-prd prints a TOTAL row"
