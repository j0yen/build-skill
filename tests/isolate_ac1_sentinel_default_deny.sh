#!/usr/bin/env bash
# isolate_ac1_sentinel_default_deny.sh — PRD-build-burst-selftest-isolation
# AC1: given BURST_LANE_TEST=1 and BURST_LANE_STATE_DIR unset, burst-lane.sh
# status exits 9 naming the live path, and the live session file's mtime is
# unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "ok  isolate AC1: burst-lane.sh status exits 9 under the sentinel with no overrides" \
  "ok  isolate AC1: refusal names the live state path" \
  "ok  isolate AC1: the live session file's mtime is unchanged"
