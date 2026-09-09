#!/usr/bin/env bash
# burst-lane_ac3_shim_local_fallback.sh — PRD-build-burst-lane-ccx53 AC3.
#
# Given no session and BURST_LANE=1, when the cargo shim is invoked for
# cargo test, then it runs local cargo and journals
# "burst-lane: no session, local".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  shim falls through to local cargo with no session" \
  "ok  shim journals the no-session fallback to stderr"
