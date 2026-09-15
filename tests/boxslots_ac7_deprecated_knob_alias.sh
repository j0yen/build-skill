#!/usr/bin/env bash
# boxslots_ac7_deprecated_knob_alias.sh — PRD-build-burst-run-slots-from-box AC7.
#
# Given env `BURST_CORES_PER_BRANCH=8` and no `BURST_CORES_PER_RUN`, When
# `run_slot_cap()` runs, Then it uses 8 and journals one deprecation line
# naming the new key.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC7: run_slots.cap uses the deprecated BURST_CORES_PER_BRANCH alias (32/8=4)" \
  "ok  boxslots AC7: journal names the deprecated knob and its replacement"
