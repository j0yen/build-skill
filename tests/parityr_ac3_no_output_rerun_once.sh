#!/usr/bin/env bash
# parityr_ac3_no_output_rerun_once.sh — PRD-build-burst-parity-robust AC3.
#
# Given a suite with no output on the box side, When `parity` runs, Then
# exactly one `parity  rerun  (suite=… side=box)` is journaled, and the
# re-run result is used.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  parityr AC3: parity exits 0" \
  "ok  parityr AC3: exactly one rerun journaled for the no-output suite (box side)" \
  "ok  parityr AC3: the rerun actually executed exactly once" \
  "ok  parityr AC3: after the rerun reports, diff=0 (the recovered result is used, not left as a false diff)" \
  "ok  parityr AC3: box-parity.json shows the recovered suite as ok/ok, not no-output"
