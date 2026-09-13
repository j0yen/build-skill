#!/usr/bin/env bash
# burstfor_ac5_stale_up_refused_then_reaped.sh — PRD-build-burst-provision-forensics AC5.
#
# Given a fake stale up process for the lane, when up runs, then it
# refuses naming the pid, and when reap runs, then the orphan is killed
# and journaled.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC5: up refuses while the fake stale up process holds the lock" \
  "ok  AC5: up-refused journaled naming the stale process's pid" \
  "ok  AC5 setup: the fake stale up process is still alive before reap" \
  "ok  AC5: reap reports killing the orphan" \
  "ok  AC5: reap actually killed the orphan process" \
  "ok  AC5: reap journaled the killed pid"
