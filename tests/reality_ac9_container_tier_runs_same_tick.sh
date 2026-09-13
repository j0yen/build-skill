#!/usr/bin/env bash
# reality_ac9_container_tier_runs_same_tick.sh —
# PRD-build-post-ship-reality-check AC9.
#
# Given a ship with container-coverable ACs and an unreachable real
# substrate, When the post-ship tick runs, Then those ACs execute in the
# SAME tick in a fresh container on RedBaron (assertable inside: no
# preinstalled gate tools, non-root uid) under the load guard, and the
# receipt records tier=container.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC9: run exits 0" \
  "ok  AC9: reality=ok (container tier answered for real)" \
  "ok  AC9: receipt records tier=container" \
  "ok  AC9: receipt shows the sandbox ran as a non-root uid (65534)" \
  "ok  AC9: receipt shows gh genuinely absent inside the sandbox (real assertion, not fixture)" \
  "ok  AC9: no dedicated box was needed — probe-1 shows unreachable before the container ran"
