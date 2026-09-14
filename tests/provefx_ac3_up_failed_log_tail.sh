#!/usr/bin/env bash
# provefx_ac3_up_failed_log_tail.sh — PRD-build-burst-prove-forensics AC3.
#
# Given a fixture cmd_up that prints three lines and exits 1, When prove
# runs, Then logs/prove.<epoch>.up.log holds those lines and the
# `prove failed (cause=up-failed …)` journal line carries them collapsed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC3: prove exits 1 when up itself fails" \
  "ok  provefx AC3: a prove.<epoch>.up.log was written under state/burst-lane/logs" \
  "ok  provefx AC3: the up log holds cmd_up's own captured output" \
  "ok  provefx AC3: the failure journal line carries the up log's tail"
