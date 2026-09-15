#!/usr/bin/env bash
# boxslots_ac3_env_override_pins_cap.sh — PRD-build-burst-run-slots-from-box AC3.
#
# Given that session and BURST_MAX_CONCURRENT_RUNS=3, When `status --json`
# is read, Then `run_slots.cap=3` and `run_slots.source=env`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC3: run_slots.cap=3 when BURST_MAX_CONCURRENT_RUNS pins it" \
  "ok  boxslots AC3: run_slots.source=env"
