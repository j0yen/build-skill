#!/usr/bin/env bash
# parityr_ac2_raw_log_receipts.sh — PRD-build-burst-parity-robust AC2.
#
# Given nextest present on both fake sides, When `parity` runs, Then both
# captures use nextest, `receipts/parity-box.log` and
# `receipts/parity-local.log` exist and are non-empty, and `box-parity.json`
# names them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  parityr AC2: receipts/parity-box.log exists and is non-empty" \
  "ok  parityr AC2: receipts/parity-local.log exists and is non-empty" \
  "ok  parityr AC2: box-parity.json names both raw-log receipt paths"
