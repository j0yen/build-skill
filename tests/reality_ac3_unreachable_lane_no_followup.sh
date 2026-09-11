#!/usr/bin/env bash
# reality_ac3_unreachable_lane_no_followup.sh —
# PRD-build-post-ship-reality-check AC3.
#
# Given a fake lane with no session, When `run` executes, Then the
# frontmatter reads `reality: unreachable` with the probe evidence and no
# follow-up is drafted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC3: unreachable lane -> reality: unreachable" \
  "ok  reality AC3: no follow-up drafted when unreachable"
