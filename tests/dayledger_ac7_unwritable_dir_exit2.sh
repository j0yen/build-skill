#!/usr/bin/env bash
# dayledger_ac7_unwritable_dir_exit2.sh — PRD-build-day-ledger AC7: given
# an unwritable output directory, the script exits 2 and no partial file
# exists. One of this PRD's required real failure-mode selftest cases
# (AC11), not just a success-path assertion.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC7: exit code (2)" \
  "ok  AC7: no partial file written"
