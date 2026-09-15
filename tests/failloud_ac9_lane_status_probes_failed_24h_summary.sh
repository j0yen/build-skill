#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC9: lane-status.sh's tick-summary
# prints `PROBES: failed_24h=<n> top=<name>:<count>` sourced from real
# `probe failed` journal lines within the last 24h (excluding older ones).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC9: PROBES: failed_24h=3 top=burst-status:3 line appended"
