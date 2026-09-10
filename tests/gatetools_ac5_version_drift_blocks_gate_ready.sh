#!/usr/bin/env bash
# gatetools_ac5_version_drift_blocks_gate_ready.sh —
# PRD-build-burst-gate-tools-scope AC5.
#
# Given a box whose autobuilder version differs from local, When `verify`
# runs, Then `gate_ready=false` and the journal has `gate-tools  version-drift`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC5: up succeeds even though autobuilder's version drifted" \
  "ok  gatetools AC5: gate_ready is false due to version drift" \
  "ok  gatetools AC5: journal names gate-tools version-drift"
