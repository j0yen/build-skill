#!/usr/bin/env bash
# gatefirst_ac8_same_target_cap_default1.sh — PRD-build-gate-before-land
# AC8.
#
# Given no burst session and two queued mcphost PRDs, When selection
# runs, Then exactly one is admitted and the journal reads
# select same-target cap=1 source=local; given BUILD_DISTINCT_TARGETS=1
# and BUILD_SAME_TARGET_CAP=3, Then still exactly one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_sametargetcap_and_expect_labels \
  "ok  AC8: exactly one of five admitted (default cap=1)" \
  "ok  AC8: diagnostic reads cap=1 source=local" \
  "ok  AC8b: compat knob (=1) still wins over a higher numeric cap"
