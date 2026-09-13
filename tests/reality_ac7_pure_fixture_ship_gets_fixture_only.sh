#!/usr/bin/env bash
# reality_ac7_pure_fixture_ship_gets_fixture_only.sh —
# PRD-build-post-ship-reality-check AC7.
#
# Given a pure-fixture ship (no substrate-naming ACs), When post-ship
# runs, Then no reality run is attempted and the receipt says
# fixture-only — no false pending.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC7: reality=fixture-only, never a bare skip" \
  "ok  AC7: reality is never pending for a pure-fixture ship" \
  "ok  AC7: the receipt itself says fixture-only"
