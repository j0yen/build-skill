#!/usr/bin/env bash
# probevis_ac7_crlf_values_normalized.sh —
# PRD-build-burst-probe-visibility AC7.
#
# Given a fixture probe emitting values with trailing carriage returns,
# When provision runs, Then the values are normalized and tools are
# classified correctly (no silent skip).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC7: a CRLF-padded MISSING value still gets attempted" \
  "ok  AC7: a CRLF-padded present value still gets skipped, normalized" \
  "ok  AC7: no raw carriage return ever lands in the journal"
