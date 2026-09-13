#!/usr/bin/env bash
# reality_ac2_unreachable_box_only_registers_pending.sh —
# PRD-build-post-ship-reality-check AC2.
#
# Given a box-only AC whose substrate is genuinely down, When the reality
# run registers it pending, Then the receipt says reality-pending with
# the registration timestamp and the journal shows two spaced probes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC2: reality=pending, not a bare unreachable" \
  "ok  AC2: registration timestamp is recorded on the parent PRD" \
  "ok  AC2: registration file exists under state/reality-pending/" \
  "ok  AC2: journal shows two spaced probes (probe-1 and probe-2, both unreachable — the real failure-mode case)"
