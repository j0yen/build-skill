#!/usr/bin/env bash
# costrate_ac1_session_recorded_type.sh — PRD-build-burst-cost-rate-by-type
# AC1.
#
# Given a session recorded as ccx43, When it tears down after 60 minutes
# alive, Then the journal cost line and cost.jsonl both price it at
# ccx43's real 0.522 eur/h (±0.001), not the old hardcoded 0.47.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  costrate AC1: the session records server_type=ccx43 at up time" \
  "ok  costrate AC1: idle-guard tears down the 60-minute-old ccx43 box" \
  "ok  costrate AC1: the journal cost line prices ccx43 at 0.522/h for 60 minutes" \
  "ok  costrate AC1: cost.jsonl prices the same session within 0.001 eur of ccx43's 0.522"
