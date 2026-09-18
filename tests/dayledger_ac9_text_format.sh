#!/usr/bin/env bash
# dayledger_ac9_text_format.sh — PRD-build-day-ledger AC9 (P1): given the
# fixture, --format text prints <=10 lines containing the red count, the
# red slugs, the shipped count, and each landing's repo#pr.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC9: text format <=10 lines" \
  "ok  AC9: text format contains 'red=1'" \
  "ok  AC9: text format contains 'fixture-slug-c'" \
  "ok  AC9: text format contains 'shipped(2)'" \
  "ok  AC9: text format contains 'fixture-repo#42'"
