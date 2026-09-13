#!/usr/bin/env bash
# probevis_ac4_summary_na_for_not_attempted.sh —
# PRD-build-burst-probe-visibility AC4.
#
# Given a fixture run where 6 tools are never attempted, When the summary
# is journaled, Then those 6 render as na (not 0) and only genuinely
# attempted tools carry numeric rc values.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC4: summary shows na for every non-attempted tool and 0 for the 2 attempted" \
  "ok  AC4: provision's own stdout also carries na (never 0) for a skipped tool"
