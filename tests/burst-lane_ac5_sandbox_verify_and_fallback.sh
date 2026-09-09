#!/usr/bin/env bash
# burst-lane_ac5_sandbox_verify_and_fallback.sh — PRD-build-burst-lane-ccx53 AC5.
#
# Given a session up, when burst-lane.sh up verifies the sandbox, then a
# sandboxed python3 run on the box exits 0; given the check fails, then the
# session is marked sandbox: unavailable and the tick's rust selection
# falls back to the local cap (requirement 6: cap 2).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  sub-cap falls back to local cap 2 when sandbox is unavailable (req 6 / AC5)" \
  "ok  sub-cap journals the sandbox-unavailable reason"
