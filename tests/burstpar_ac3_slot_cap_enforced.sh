#!/usr/bin/env bash
# burstpar_ac3_slot_cap_enforced.sh — PRD-build-burst-parallel-runs AC3.
#
# Given 12 concurrent run invocations with cap 4, when launched, then at
# most 4 hold slots at any instant and all 12 complete.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: all 12 invocations ran (starts=12)" \
  "ok  AC3: at most 4 slots held at any instant (peak=4)"
