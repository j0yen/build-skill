#!/usr/bin/env bash
# cargoroute_ac4_not_configured_no_route_lines.sh —
# PRD-build-cargo-route-precedence AC4 (spec test d). Given burst is not
# configured at all (BUILD_BURST_ENABLED=0, no live env file), when
# route-check runs, then it is a pure no-op: state=clean, resolved is
# whatever real cargo the caller's own PATH already had, exit 0, and no
# "route" journal lines are written at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC4: burst-not-configured is state=clean" \
  "ok  cargoroute AC4: burst-not-configured resolved is the real cargo (no shim involved)" \
  "ok  cargoroute AC4: route-check exits 0" \
  "ok  cargoroute AC4: no 'route' journal lines at all"
