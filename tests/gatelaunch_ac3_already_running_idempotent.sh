#!/usr/bin/env bash
# gatelaunch_ac3_already_running_idempotent.sh —
# PRD-build-gate-launch-survives-tick AC(c).
#
# Given a gate already running for <slug> at <head>, when gate-launch.sh
# is called again for the SAME slug+head, then it prints the SAME unit,
# exits 0 without launching a second unit, and journals `already-running`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  second launch, same head, exits 0" \
  "ok  second launch prints the SAME unit" \
  "ok  already-running is journaled"
