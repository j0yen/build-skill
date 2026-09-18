#!/usr/bin/env bash
# dayledger_ac2_deterministic.sh — PRD-build-day-ledger AC2: given the
# fixture, running the script twice produces byte-identical files after
# removing produced_at.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: two runs byte-identical except produced_at"
