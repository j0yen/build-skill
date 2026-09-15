#!/usr/bin/env bash
# gatelaunch_ac1_launch_writes_marker_and_returns_unit.sh —
# PRD-build-gate-launch-survives-tick AC(a).
#
# Given a clean repo and head sha, when gate-launch.sh launches
# extend-gate.sh under a fake systemd-run unit, then it prints the unit
# name and writes state/gate-inflight/<slug>.json = {unit, pid, head,
# scope, repo, started_ts} BEFORE returning, and gate-status.sh sees
# "running" while the fake gate is still mid-flight.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  prints a unit name" \
  "ok  unit name matches gate-<slug>-<sha7> shape" \
  "ok  marker file was written" \
  "ok  marker has the launched unit" \
  "ok  marker has the requested head" \
  "ok  marker has the requested scope" \
  "ok  marker has the repo path" \
  "ok  marker has a started_ts" \
  "ok  gate-status.sh sees it running while it's mid-flight"
