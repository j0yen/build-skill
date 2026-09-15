#!/usr/bin/env bash
# proveguard_ac3_down_force_overrides.sh — PRD-build-burst-prove-inflight-
# guard AC3.
#
# Given a live prove.inflight marker, When `down --force` runs, Then it
# still deletes the box (operator override, never blocked) but journals
# that it overrode an in-flight prove, naming the live pid.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC3: down --force still exits 0 despite a live prove.inflight" \
  "ok  proveguard AC3: down --force still deletes (decision=force-deleted)" \
  "ok  proveguard AC3: the box is actually gone" \
  "ok  proveguard AC3: journal names the prove-inflight override, naming the live pid"
