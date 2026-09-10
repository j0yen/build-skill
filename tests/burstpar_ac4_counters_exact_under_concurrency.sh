#!/usr/bin/env bash
# burstpar_ac4_counters_exact_under_concurrency.sh — PRD-build-burst-parallel-runs AC4.
#
# Given 12 concurrent completed runs, when session.json and
# attribution.jsonl are inspected, then runs_served increased by exactly 12
# and 12 attribution rows exist.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: runs_served increased by exactly 12" \
  "ok  AC4: exactly 12 attribution rows exist"
