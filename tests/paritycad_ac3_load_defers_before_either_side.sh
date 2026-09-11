#!/usr/bin/env bash
# paritycad_ac3_load_defers_before_either_side.sh — PRD-build-burst-parity-
# cadence AC3.
#
# Given a fake load above CARGO_BUDGET_MAX_LOAD, When `parity` runs, Then it
# waits, journals `parity  deferred  (cause=load)`, exits 3, and no local
# cargo ran (nor did a box session ever come up).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC3: parity exits 3 when RedBaron's load exceeds the cap" \
  "ok  paritycad AC3: parity prints fallback: load" \
  "ok  paritycad AC3: journal records the deferral with cause=load" \
  "ok  paritycad AC3: no session was ever brought up (neither side ran)" \
  "ok  paritycad AC3: no local test baseline was written" \
  "ok  paritycad AC3: no parity receipt was written"
