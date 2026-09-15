#!/usr/bin/env bash
# bdrift_ac5_bake_refusal_journals_key.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC5.
#
# Given BUILD_BURST_ENABLED unset and a dormant env, When bake runs, Then
# it exits 3, stderr names BUILD_BURST_ENABLED=1, and the journal has
# `bake  refused  (cause=not-configured key=BUILD_BURST_ENABLED)`
# (requirement 4).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bakegate AC5: bake exits 3 when not configured" \
  "ok  bakegate AC5: stderr names BUILD_BURST_ENABLED=1" \
  "ok  bakegate AC5: journal has bake refused (cause=not-configured key=BUILD_BURST_ENABLED)"
