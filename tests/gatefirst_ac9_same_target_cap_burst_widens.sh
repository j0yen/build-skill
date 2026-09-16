#!/usr/bin/env bash
# gatefirst_ac9_same_target_cap_burst_widens.sh — PRD-build-gate-before-land
# AC9.
#
# Given a fake burst-lane.sh status --json reporting an active
# gate_ready=true session with width 8 and BUILD_SAME_TARGET_CAP_BURST=4,
# When selection runs over five queued mcphost PRDs, Then four are
# admitted and the journal reads select same-target cap=4 source=burst
# ... admitted=4; given width 2, Then two.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_sametargetcap_and_expect_labels \
  "ok  AC9a: four of five admitted (min(4,8)=4)" \
  "ok  AC9a: diagnostic reads cap=4 source=burst" \
  "ok  AC9b: two of five admitted (min(4,2)=2)" \
  "ok  AC9b: diagnostic reads cap=2 source=burst"
