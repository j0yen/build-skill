#!/usr/bin/env bash
# cargoroute_ac3_unhealable_mismatch_exits_9.sh —
# PRD-build-cargo-route-precedence AC3 (spec test c). Given BOTH shim
# directories genuinely absent from disk (an isolated copy of scripts/
# with cargo-budget-bin and burst-lane-bin removed) and burst configured,
# when route-check runs, then self-heal cannot invent a shim that was
# never there: it reports state=mismatch cause=shim-not-first, journals
# "route mismatch" to the shared burst-lane journal UNCONDITIONALLY (no
# $BURST_ROUTE_LOG set at all), exits 9 (its own documented, distinct
# rc), and never runs cargo itself.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC3: unhealable mismatch reports intended=burst" \
  "ok  cargoroute AC3: unhealable mismatch is state=mismatch cause=shim-not-first" \
  "ok  cargoroute AC3: exits 9 (distinct, documented rc)" \
  "ok  cargoroute AC3: journaled to the burst-lane journal UNCONDITIONALLY (no \$BURST_ROUTE_LOG set)" \
  "ok  cargoroute AC3: route-check itself never runs cargo (no fake-cargo marker written)"
