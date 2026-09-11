#!/usr/bin/env bash
# paritycad_ac5_local_half_cargo_budget_ledger.sh — PRD-build-burst-parity-
# cadence AC5.
#
# Given parity's local half, When it runs, Then the cargo-budget ledger has
# a row for it with test_threads=4.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC5: parity exits 0" \
  "ok  paritycad AC5: cargo-budget ledger has at least one row for the local run" \
  "ok  paritycad AC5: the wrapped local run saw RUST_TEST_THREADS=4 (CARGO_BUDGET_TEST_THREADS default)"
