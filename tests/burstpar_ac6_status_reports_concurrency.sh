#!/usr/bin/env bash
# burstpar_ac6_status_reports_concurrency.sh — PRD-build-burst-parallel-runs AC6.
#
# Given 3 held slots of cap 4, when status runs, then it reports 3/4 live
# runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: status reports 3/4 live runs"
