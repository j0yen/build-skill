#!/usr/bin/env bash
# provefx_ac11_cost_age_from_create_epoch.sh —
# PRD-build-burst-prove-forensics AC11.
#
# Given a fixture session created at T and booted at T+17 min, When down
# runs at T+19 min, Then the cost line and cost.jsonl show 19 minutes /
# 0.32 h, not 2, and status --json age_min reads 19.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC11 setup: up wrote a numeric create_epoch" \
  "ok  provefx AC11: status --json minutes_alive reads 19 (from create_epoch, not boot_epoch's 2)" \
  "ok  provefx AC11: down deletes the unproven box (runs_served=0) immediately" \
  "ok  provefx AC11: the deletion journal line reads minutes=19, not minutes=2" \
  "ok  provefx AC11: cost.jsonl's row reads hours=0.3167 (19/60), not 0.0333 (2/60)"
