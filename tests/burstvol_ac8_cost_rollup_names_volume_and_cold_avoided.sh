#!/usr/bin/env bash
# burstvol_ac8_cost_rollup_names_volume_and_cold_avoided.sh —
# PRD-build-burst-persistent-volume AC8.
#
# Given a session with a volume, when the daily rollup is written, then it carries volume_gb and a cold_builds_avoided count.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC8: daily rollup line carries volume_gb=500" \
  "ok  burstvol AC8: daily rollup line carries a cold_builds_avoided count"
