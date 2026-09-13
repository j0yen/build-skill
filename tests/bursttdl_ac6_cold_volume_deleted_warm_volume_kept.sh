#!/usr/bin/env bash
# bursttdl_ac6_cold_volume_deleted_warm_volume_kept.sh —
# PRD-build-burst-teardown-lifecycle AC6.
#
# Given a final teardown with volume_used_pct=1, When it runs, Then the
# cache volume is deleted and journaled with id and used_pct; Given
# volume_used_pct=40 (and the volume has served a build), Then it is kept
# with volume-kept (used_pct=40).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC6: a cold (1% used, never-served) volume is deleted at the lane-ending teardown" \
  "ok  bursttdl AC6: the deletion is journaled with the volume's id and used_pct" \
  "ok  bursttdl AC6: a warm (40% used, has served a build) volume is kept, not deleted" \
  "ok  bursttdl AC6: the keep decision is journaled as volume-kept (used_pct=40)"
