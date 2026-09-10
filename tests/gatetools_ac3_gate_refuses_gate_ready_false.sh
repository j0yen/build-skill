#!/usr/bin/env bash
# gatetools_ac3_gate_refuses_gate_ready_false.sh —
# PRD-build-burst-gate-tools-scope AC3.
#
# Given `gate_ready=false`, When `gate <repo> --head <sha>` runs, Then it
# exits 3 with `fallback: gate-tools-missing (autobuilder)` and journals
# one line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC3: gate exits 3 when gate_ready=false" \
  "ok  gatetools AC3: gate prints fallback: gate-tools-missing naming the tool" \
  "ok  gatetools AC3: exactly one gate fallback journal line naming the cause"
