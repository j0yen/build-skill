#!/usr/bin/env bash
# provekeep_ac2_expression_sh_reproduces_verdict.sh — PRD-build-burst-prove-
# evidence-preservation AC2 (P0).
#
# Given that evidence set, When `bash expression.sh` runs, Then it prints
# verdict=1 for a stale target and verdict=0 after `touch` of one file
# under target/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC2: expression.sh prints verdict=1 against the still-stale preserved target" \
  "ok  provekeep AC2: expression.sh prints verdict=0 after touching one file under target/"
