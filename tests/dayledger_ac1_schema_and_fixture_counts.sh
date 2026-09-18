#!/usr/bin/env bash
# dayledger_ac1_schema_and_fixture_counts.sh — PRD-build-day-ledger AC1:
# given frozen fixture sources for one day, day-ledger.sh writes a file
# that validates against build.day_ledger.v1 (every key present, types
# correct) and whose ticks/gates/shipped/landings/decisions counts match
# the fixture exactly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: day-ledger.sh exits 0 on the fixture" \
  "ok  AC1: every key present with the right type" \
  "ok  AC1: schema (build.day_ledger.v1)" \
  "ok  AC1: ticks.started (2)" \
  "ok  AC1: gates.red_slugs" \
  "ok  AC1: shipped" \
  "ok  AC1: landings" \
  "ok  AC1: decisions.opened count (2)" \
  "ok  AC1: decisions.closed count (2)"
