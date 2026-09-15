#!/usr/bin/env bash
# gatelaunch_ac6_chain_guard_relaunch_once_then_blocked.sh —
# PRD-build-gate-launch-survives-tick AC(f).
#
# Given a PRD whose last_error narrates a gate as running, when
# chain-guard.sh consults gate-status.sh (never the narration) and finds
# `lost`, then it relaunches ONCE via gate-launch.sh (journaling `gate
# lost ... relaunching` and stamping the fresh marker's
# relaunch_count=1); when THAT relaunched attempt is ALSO lost, chain-
# guard.sh stops with `gate-lost-twice` and records
# status=blocked/last_error=gate-lost-twice via the sidecar instead of
# relaunching forever. Narration with no marker at all (nothing to
# consult) falls through to the normal precondition checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pre-check: gate-status.sh agrees it's lost" \
  "ok  first lost: chain-guard stops (never continues on narration)" \
  "ok  first lost: reason is gate-relaunched" \
  "ok  first lost: journaled as gate lost relaunching" \
  "ok  a fresh marker exists after relaunch" \
  "ok  the fresh marker is stamped relaunch_count=1" \
  "ok  the relaunched unit is also lost" \
  "ok  second lost: chain-guard stops" \
  "ok  second lost: reason is gate-lost-twice" \
  "ok  second lost: sidecar records status=blocked" \
  "ok  second lost: sidecar records last_error=gate-lost-twice" \
  "ok  no marker: chain-guard falls through to preconditions-hold"
