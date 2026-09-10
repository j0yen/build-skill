#!/usr/bin/env bash
# gatewall_ac9_daily_rollup_names_both_counts.sh — PRD-build-gate-wall-clock AC9.
#
# Given a day with two wedges and one assert-restart, When the rollup
# runs, Then the journal line names both counts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels gate-wedge-rollup-selftest.sh \
  "ok  case1 wedges_total=2 (not 3)" \
  "ok  case1 unknown count=1" \
  "ok  case1 sccache-client-orphans=1" \
  "ok  case1 sccache_restarts=1 (not 2)"
