#!/usr/bin/env bash
# bdrift_ac6_bake_proceeds_same_env_prove_accepts.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC6.
#
# Given BUILD_BURST_ENABLED=1 and a fixture box that is gate_ready, When
# bake runs, Then it proceeds to `bake done` (existing fixture path) — the
# same env prove accepts (requirement 4). Covered by the pre-existing
# "reenable AC1" bake-success fixture, which already runs under
# BUILD_BURST_ENABLED=1 — named again here under this PRD's own AC so a
# future regression that breaks bake's opt-in specifically fails a
# bdrift-scoped case too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC1: bake exits 0" \
  "ok  reenable AC1: bake prints the new image_id" \
  "ok  reenable AC1: journal has bake done (image_id=... superseded=none secs=...)"
