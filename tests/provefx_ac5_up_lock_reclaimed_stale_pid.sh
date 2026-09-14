#!/usr/bin/env bash
# provefx_ac5_up_lock_reclaimed_stale_pid.sh — PRD-build-burst-prove-forensics
# AC5.
#
# Given up.pid naming a dead pid and no process on up.lock, When up runs,
# Then the journal has `up lock-reclaimed (stale_pid=…)` and up proceeds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC5: up succeeds despite a stale up.pid (the lock itself was free)" \
  "ok  provefx AC5: journal has up lock-reclaimed naming the stale pid"
