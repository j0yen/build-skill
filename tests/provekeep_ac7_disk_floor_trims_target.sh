#!/usr/bin/env bash
# provekeep_ac7_disk_floor_trims_target.sh — PRD-build-burst-prove-
# evidence-preservation AC7 (P1).
#
# Given BURST_LOCAL_DISK_FLOOR_GB set above the worktree filesystem's free
# space, When a fixture prove fails at assert, Then the evidence set holds
# logs, proof.json, and expression.sh but no target/, and the journal has
# `prove  evidence-trimmed  (reason=disk-floor)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC7: prove still fails at assert (no-fresh-artifact) under the inflated floor" \
  "ok  provekeep AC7: the evidence set holds logs/proof.json/expression.sh but no target/" \
  "ok  provekeep AC7: journal has prove evidence-trimmed (reason=disk-floor)"
