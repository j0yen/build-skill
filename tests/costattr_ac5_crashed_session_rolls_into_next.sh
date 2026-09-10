#!/usr/bin/env bash
# costattr_ac5_crashed_session_rolls_into_next.sh — PRD-build-cost-attribution AC5.
#
# Given attribution rows from a crashed prior session, when the next
# teardown prorates, then those rows are included with a journal note, not
# silently discarded.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: teardown with an orphaned prior-session row still deletes cleanly" \
  "ok  AC5: the orphaned session's slug is included in this teardown's proration" \
  "ok  AC5: journal names the orphaned session by id, not a silent discard"
