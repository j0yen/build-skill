#!/usr/bin/env bash
# gatefirst_ac6_gate_block_land_ungated.sh — PRD-build-gate-before-land AC6.
#
# Given a branch whose gate verdict is block, When
# `land --gated-at X --verdict <file>` runs, Then it exits 7
# land-ungated, main is unchanged, and last_error=gate-block:branch:
# <blockers> is written.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_gatedland_and_expect_labels \
  "ok  AC6a: land exits 7 (land-ungated)" \
  "ok  AC6a: message names land-ungated verdict=block" \
  "ok  AC6a: main is unchanged" \
  "ok  AC6b: land exits 7 (land-ungated)" \
  "ok  AC6b: message names land-ungated verdict=missing" \
  "ok  AC6b: main is unchanged"
