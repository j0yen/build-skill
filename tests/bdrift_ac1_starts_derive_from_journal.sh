#!/usr/bin/env bash
# bdrift_ac1_starts_derive_from_journal.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC1.
#
# Given burstpar-selftest on RedBaron with BUILD_BURST_ENABLED=1
# BURST_LANE_TEST=1, When it runs against current burst-lane.sh, Then AC2,
# AC3, and AC6 pass with starts=12, peak<=4, and status reporting held/cap
# — the fixture's own fake ssh derives its counts from journal `run
# routed` lines / the exec-only span log, not from raw ssh call counts
# (requirement 1).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_burstpar_and_expect_labels \
  "ok  AC3: all 12 invocations ran (starts=12)" \
  "ok  AC3: at most 4 slots held at any instant (peak=4)" \
  "ok  AC2: same-worktree runs never overlap (peak=1 of 2)" \
  "ok  AC6: status reports 3/4 live runs"
