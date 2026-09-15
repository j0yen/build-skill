#!/usr/bin/env bash
# gatelaunch_ac5_status_lost_when_unit_vanished.sh —
# PRD-build-gate-launch-survives-tick AC(e).
#
# Given a gate-inflight marker whose unit has vanished (the 2026-09-15
# tick-teardown defect: --collect'd away with no trace), when
# gate-status.sh checks it, then it reports `lost` iff no receipt is
# newer than the marker's started_ts — and, the paired positive case,
# reports `finished:<rc>` from the cached verdict when the unit vanished
# AFTER writing real receipts (the ordinary --collect-races-the-poll
# case, not a loss).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gate-status.sh sees it running before the vanish" \
  "ok  gate-status.sh reports lost" \
  "ok  gate-status.sh reads finished:1 from the collected unit's receipts"
