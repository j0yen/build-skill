#!/usr/bin/env bash
# isolate_ac4_live_counter_and_rollup.sh — PRD-build-burst-selftest-isolation
# AC4: a caller that exports BURST_LANE_TEST=1 by mistake (every other
# override left live) is refused, the refusal is journaled, and the daily
# rollup's isolation_refusals field counts it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "ok  isolate AC4: a mistaken sentinel on run refuses (exit 9)" \
  "ok  isolate AC4: the refusal is journaled (isolation  refused)" \
  "ok  isolate AC4: the daily rollup line carries isolation_refusals>=1"
