#!/usr/bin/env bash
# burstfor_ac6_all_green_gate_ready.sh — PRD-build-burst-provision-forensics AC6.
#
# Given all-green fixture installers, when provision runs, then all 8
# tools journal rc=0 and gate_ready=true. Also covers requirement 5 (apt
# lock tolerance): jq/gh/mold install commands carry
# -o DPkg::Lock::Timeout=120.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC6: provision exits 0 when every tool installs clean" \
  "ok  AC6: provision reports gate_ready=true" \
  "ok  AC6: summary line shows rc=0 for all 8 tools" \
  "ok  goal5: jq/gh/mold install commands carry DPkg::Lock::Timeout=120"
