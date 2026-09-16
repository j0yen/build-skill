#!/usr/bin/env bash
# tests/routepar_ac6_cargo_route_current_agreement.sh — PRD-build-gate-
# route-parity-ledger AC6: "Given cargo_route_current and
# cargo_route_path_prefix under the three route fixtures (local, burst,
# burst-refused), When both are called, Then their decisions agree in all
# three."
#
# "Agree" here means: cargo_route_current()'s route decision (local, or
# burst:<id>) is never contradicted by cargo_route_path_prefix()'s own
# PATH-capability decision — burst:<id> only when the prefix actually
# chains through burst-lane-bin (the shim is reachable), and local
# whenever the prefix does NOT chain through it. `local`: burst not
# configured at all. `burst`: configured, armed (BURST_LANE=1), a live
# session. `burst-refused`: configured (the prefix DOES include the burst
# dir — a declared policy), but never armed (BURST_LANE unset, e.g. a
# /build dispatch that chose not to arm it) — cargo_route_current must
# still resolve local, exactly like burst-lane-bin/cargo's own `else`
# fallthrough would (see that script + cargo-route.sh's own header for
# why BURST_LANE_DISPATCH never needs a coded branch here). No real box,
# no real ssh/hcloud — CARGO_ROUTE_STATUS_JSON stands in for `status
# --json` (this function's own documented test seam).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
CARGO_ROUTE_LIB="$SKILL_DIR/scripts/lib/cargo-route.sh"
[ -r "$CARGO_ROUTE_LIB" ] || { echo "selftest: missing $CARGO_ROUTE_LIB" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

# prefix_chains_burst <prefix> -> 0 if the prefix's colon-joined dir list
# names the burst-lane-bin dir (the "capability" half of "agree").
prefix_chains_burst() {
  case ":$1:" in
    *":$SKILL_DIR/scripts/burst-lane-bin:"*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== fixture: local (burst not configured at all) ==="
out_local="$(
  unset BUILD_BURST_ENABLED BURST_LANE BURST_LANE_DISPATCH CARGO_ROUTE_STATUS_JSON 2>/dev/null
  export BURST_LANE_ENV_FILE="/nonexistent/wm-burst-routepar-ac6.env"
  source "$CARGO_ROUTE_LIB"
  echo "route=$(cargo_route_current) prefix=$(cargo_route_path_prefix)"
)"
route_local="$(printf '%s\n' "$out_local" | sed -n 's/^route=\([^ ]*\).*/\1/p')"
prefix_local="$(printf '%s\n' "$out_local" | sed -n 's/.*prefix=//p')"
expect "local: cargo_route_current returns local" "[ '$route_local' = 'local' ]"
expect "local: cargo_route_path_prefix does NOT chain through burst-lane-bin" \
  "! prefix_chains_burst '$prefix_local'"

echo "=== fixture: burst (configured, armed, a live session) ==="
out_burst="$(
  export BUILD_BURST_ENABLED=1
  export BURST_LANE=1
  export CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"42"}'
  source "$CARGO_ROUTE_LIB"
  echo "route=$(cargo_route_current) prefix=$(cargo_route_path_prefix)"
)"
route_burst="$(printf '%s\n' "$out_burst" | sed -n 's/^route=\([^ ]*\).*/\1/p')"
prefix_burst="$(printf '%s\n' "$out_burst" | sed -n 's/.*prefix=//p')"
expect "burst: cargo_route_current returns burst:42" "[ '$route_burst' = 'burst:42' ]"
expect "burst: cargo_route_path_prefix DOES chain through burst-lane-bin" \
  "prefix_chains_burst '$prefix_burst'"

echo "=== fixture: burst-refused (configured, a live session, but never armed) ==="
out_refused="$(
  export BUILD_BURST_ENABLED=1
  export BURST_LANE_DISPATCH=1
  unset BURST_LANE 2>/dev/null
  export CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"42"}'
  source "$CARGO_ROUTE_LIB"
  echo "route=$(cargo_route_current) prefix=$(cargo_route_path_prefix)"
)"
route_refused="$(printf '%s\n' "$out_refused" | sed -n 's/^route=\([^ ]*\).*/\1/p')"
prefix_refused="$(printf '%s\n' "$out_refused" | sed -n 's/.*prefix=//p')"
expect "burst-refused: cargo_route_current still returns local (never armed)" "[ '$route_refused' = 'local' ]"
expect "burst-refused: cargo_route_path_prefix DOES still chain through burst-lane-bin (declared policy, capability != usage)" \
  "prefix_chains_burst '$prefix_refused'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac6: ALL PASS"
else
  echo "routepar_ac6: assertion(s) FAILED"
fi
exit "$fail"
