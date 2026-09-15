#!/usr/bin/env bash
# teardown_ac6_why_down_replays_trail.sh — PRD-build-burst-teardown-evidence
# AC6 (and AC12's failure-path case).
#
# Given three decision rows for a server ending in delete, when
# `burst-lane.sh why-down <id>` runs, then it prints the three rows in
# order, the final cause, and the matching session.json.deleted-* filename;
# given an id with no decisions.jsonl row at all, why-down prints "no
# decision recorded" (a real failure exit) and journals the gap as its own
# defect.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC6: why-down prints all three rows in order" \
  "ok  teardown AC6: why-down names the final cause" \
  "ok  teardown AC6: why-down names the matching deleted-* archive file" \
  "ok  teardown AC6/AC12: an id with no decisions.jsonl row prints no decision recorded" \
  "ok  teardown AC6/AC12: that case is a real failure exit, not a tautological 0" \
  "ok  teardown AC12: the unrecorded deletion is itself journaled as a defect"
