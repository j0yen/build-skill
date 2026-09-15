#!/usr/bin/env bash
# costrate_ac2_env_override_wins.sh — PRD-build-burst-cost-rate-by-type AC2.
#
# Given BURST_COST_PER_HOUR_EUR=2.0 set, When a session tears down, Then
# the journal cost line and cost.jsonl both price it at the env override
# rate, regardless of the table's per-type rates.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  costrate AC2: idle-guard tears down the 60-minute-old box" \
  "ok  costrate AC2: BURST_COST_PER_HOUR_EUR=2.0 wins over the table" \
  "ok  costrate AC2: cost.jsonl records the overridden 2.0 rate"
