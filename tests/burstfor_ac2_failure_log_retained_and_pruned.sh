#!/usr/bin/env bash
# burstfor_ac2_failure_log_retained_and_pruned.sh — PRD-build-burst-provision-forensics AC2.
#
# Given that same failing run, when it completes, then gh's stderr log
# exists under logs/failed/ with the fixture's error text, jq's per-tool
# log is gone (rc=0 path), and running 6 more fixture sessions prunes
# failure logs beyond the newest 5 sessions.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC2: gh's failure log exists under logs/failed/" \
  "ok  AC2: gh's failure log carries the fixture's error text" \
  "ok  AC2: jq's per-tool log is gone (rc=0 path)" \
  "ok  AC2: gate-tools.json records gh's last_rc/last_err under attempts" \
  "ok  AC2: pruning retains at most the newest 5 sessions' failure logs" \
  "ok  AC2: pruning actually dropped the oldest session's log (session #1)"
