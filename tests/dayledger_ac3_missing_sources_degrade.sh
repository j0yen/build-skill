#!/usr/bin/env bash
# dayledger_ac3_missing_sources_degrade.sh — PRD-build-day-ledger AC3:
# given the fixture with decisions.jsonl absent and the gates banner
# script returning non-zero, decisions/gates degrade to their empty
# forms, notes names both missing sources, the file is still written,
# exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: exit code (0)" \
  "ok  AC3: decisions.opened empty ([])" \
  "ok  AC3: decisions.closed empty ([])" \
  "ok  AC3: gates empty form (green) (0)" \
  "ok  AC3: gates empty form (red_slugs) ([])" \
  "ok  AC3: notes has source-missing: decisions" \
  "ok  AC3: notes has source-missing: gates" \
  "ok  AC3: file written despite missing sources"
