#!/usr/bin/env bash
# Fake burst-lane.sh for routepar-selftest.sh (PRD-build-gate-route-
# parity-ledger). Always reports no active session for extend-gate.sh's
# own legacy route_intended/route-check machinery — the route this PRD's
# tests actually assert on (GATE_ROUTE, from cargo_route_current) is
# driven independently via CARGO_ROUTE_STATUS_JSON, never through this
# fake, so this file only has to answer harmlessly and instantly.
set -uo pipefail
case "${1:-}" in
  status) echo '{"active":false}' ;;
  *) : ;;
esac
exit 0
