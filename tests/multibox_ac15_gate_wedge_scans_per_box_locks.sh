#!/usr/bin/env bash
# multibox_ac15_gate_wedge_scans_per_box_locks.sh —
# PRD-build-burst-state-keyed-by-server-v2 AC15.
#
# Given two boxes with a pending flock waiter on boxes/<b>/locks/wt-x, When
# gate-wedge.sh probes lock waits with the default GATE_WEDGE_LOCK_DIRS,
# Then it reports the wait (it scans boxes/*/locks and boxes/*/slots), and
# the tripwire finds no top-level state/burst-lane/{locks,slots} literal in
# gate-wedge.sh or isolation-guard.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC15: gate-wedge.sh's default LOCK_SCAN_DIRS glob-expands to boxes/111/locks" \
  "ok  multibox AC15: gate-wedge.sh's default LOCK_SCAN_DIRS glob-expands to boxes/111/slots" \
  "ok  multibox AC15: tripwire finds no top-level {locks,slots} literal in gate-wedge.sh/isolation-guard.sh" \
  "ok  multibox AC15: tripwire fails on a stray top-level locks/slots literal in an external reader"
