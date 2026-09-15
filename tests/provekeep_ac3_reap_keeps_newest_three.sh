#!/usr/bin/env bash
# provekeep_ac3_reap_keeps_newest_three.sh — PRD-build-burst-prove-
# evidence-preservation AC3 (P0).
#
# Given four failed fixture proves in sequence with BURST_EVIDENCE_KEEP=3,
# When the fourth exits [and reap runs], Then exactly three evidence
# directories remain, the oldest was removed, and the journal has one
# `reap  evidence-deleted` line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC3 setup: four evidence dirs exist before reap" \
  "ok  provekeep AC3: exactly three evidence dirs remain after reap" \
  "ok  provekeep AC3: the oldest evidence dir was removed" \
  "ok  provekeep AC3: the journal has exactly one reap evidence-deleted line"
