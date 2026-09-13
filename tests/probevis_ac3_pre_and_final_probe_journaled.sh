#!/usr/bin/env bash
# probevis_ac3_pre_and_final_probe_journaled.sh —
# PRD-build-burst-probe-visibility AC3.
#
# Given any fixture provision run, When it completes, Then the journal
# contains a `gate-tools probe (phase=pre ...)` record and a
# `(phase=final ...)` record, each listing the tools that probe reported.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC3: journal has a gate-tools probe record for phase=pre" \
  "ok  AC3: journal has a gate-tools probe record for phase=final"
