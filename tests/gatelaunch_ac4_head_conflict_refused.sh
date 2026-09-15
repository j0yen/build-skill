#!/usr/bin/env bash
# gatelaunch_ac4_head_conflict_refused.sh —
# PRD-build-gate-launch-survives-tick AC(d).
#
# Given a gate already running for <slug> at head A, when gate-launch.sh
# is called for the SAME slug at a DIFFERENT head B, then it refuses
# (exit 2) rather than starting a second concurrent unit for that slug,
# and journals `head-conflict`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  a different head while active exits 2" \
  "ok  head-conflict is journaled"
