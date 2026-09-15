#!/usr/bin/env bash
# provekeep_ac4_status_json_evidence_rollup.sh — PRD-build-burst-prove-
# evidence-preservation AC4 (P0).
#
# Given three evidence sets, When `status --json` is read, Then
# evidence.count=3 and evidence.bytes equals `du -sb` of the directory
# within 1%; `status` (text) prints one `evidence: N sets, X GB, newest
# <ts>` line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC4: status --json evidence.count=3" \
  "ok  provekeep AC4: status --json evidence.bytes matches du -sb within 1%" \
  "ok  provekeep AC4: status (text) prints one evidence: N sets, X GB, newest <ts> line"
