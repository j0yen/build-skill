#!/usr/bin/env bash
# vcrbps_ac4_gate_route_parity_regression.sh — PRD-build-verified-completed-
# realbox-perserver AC4.
#
# Given PRD-build-gate-route-parity-ledger's real on-disk state shape as of
# this PRD's drafting (a real-box AC backed only by a per-server proof, plus
# a whole-suite AC with no per-AC file whose number collides with an
# unrelated sibling's own declared-prefix file), When
# `verified-completed.sh --derive` runs against it, Then AC1 reads PAIRED
# (not MISSING) and AC8 reads PAIRED (not ac-number-collision) — reproduced
# here against a same-shaped disposable fixture, since the live PRD file
# this defect was hand-caught against is not a stable fixture (it moves
# under concurrent /build ticks).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/vcrbps-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4 real-box AC2 PAIRED (per-server-only proof, no flat file)" \
  "ok  AC4 whole-suite AC3 PAIRED (not ac-number-collision against othersib_ac3)"
