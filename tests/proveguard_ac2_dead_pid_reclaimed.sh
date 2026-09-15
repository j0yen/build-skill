#!/usr/bin/env bash
# proveguard_ac2_dead_pid_reclaimed.sh — PRD-build-burst-prove-inflight-guard
# AC2.
#
# Given a prove.inflight marker naming a dead pid, When `down` runs, Then it
# journals prove-inflight-stale, removes the marker, and proceeds to its
# normal unproven-box delete exactly as if the marker had never existed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC2: down deletes the unproven box once the stale marker is reclaimed" \
  "ok  proveguard AC2: journal has prove-inflight-stale naming the dead pid" \
  "ok  proveguard AC2: the stale marker file is removed" \
  "ok  proveguard AC2: journal still names the ordinary unproven-box cause"
