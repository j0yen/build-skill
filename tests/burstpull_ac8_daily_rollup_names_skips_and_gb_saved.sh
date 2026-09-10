#!/usr/bin/env bash
# burstpull_ac8_daily_rollup_names_skips_and_gb_saved.sh — PRD-build-burst-pull-on-demand AC8.
#
# Given the daily rollup, when `down` writes it, then the line includes
# pulls skipped and estimated GB saved.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: exactly one daily burst-cost rollup line after two down calls same day" \
  "ok  burstpull P1 AC8: daily rollup line names pulls skipped and GB saved"
