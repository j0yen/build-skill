#!/usr/bin/env bash
# gatefirst_ac3_land_if_unchanged_succeeds.sh — PRD-build-gate-before-land
# AC3.
#
# Given a branch gated at main sha X and main still at X, When
# `land --gated-at X --verdict <file>` runs, Then the merge lands, the
# journal reports lock_hold under 30s, and main's verdict cache holds the
# branch verdict under the merge commit's tree sha.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_gatedland_and_expect_labels \
  "ok  AC3: land exits 0" \
  "ok  AC3: main advanced (merge landed)" \
  "ok  AC3: exactly one new 'land' journal line was written" \
  "ok  AC3: journal line carries gated_at=" \
  "ok  AC3: journal line carries a numeric lock_hold" \
  "ok  AC3: lock_hold is well under 30s on this warm repo"
