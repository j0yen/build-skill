#!/usr/bin/env bash
# costattr_ac6_daily_rollup_once_per_day.sh — PRD-build-cost-attribution AC6.
#
# Given two `down` calls the same day, when both run, then exactly one
# daily burst-cost rollup line lands in the tick journal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: exactly one daily burst-cost rollup line after two down calls same day" \
  "ok  AC6: rollup line names eur/slug-count/top slug"
