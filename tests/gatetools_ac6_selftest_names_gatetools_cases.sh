#!/usr/bin/env bash
# gatetools_ac6_selftest_names_gatetools_cases.sh —
# PRD-build-burst-gate-tools-scope AC6.
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `gatetools` cases — one representative label per
# AC1-AC5 (the full set is exercised by the other
# tests/gatetools_ac<N>_*.sh wrappers; this one asserts the suite as a
# whole reports every AC number, not just any one of them).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC1: the autobuilder binary was copied (rsync) to the remote cargo bin dir" \
  "ok  gatetools AC2: run <worktree> -- cargo build still routes despite gate_ready=false" \
  "ok  gatetools AC3: gate prints fallback: gate-tools-missing naming the tool" \
  "ok  gatetools AC4: gate_ready becomes true without a reboot" \
  "ok  gatetools AC5: journal names gate-tools version-drift"
