#!/usr/bin/env bash
# tests/cargoroute_ac7_run_id_field.sh —
# PRD-rustbuild-hermetic-route-pid. cargo_route_log() (scripts/lib/
# cargo-route.sh) writes route.log lines as <ts> <pid> <sub> <decision>
# <cause> <cwd>. A concurrent gate/branch-agent building the same repo
# shares that file (both write under the same target/autobuilder/
# route.log), and a consumer that only has the time window to go on can
# misattribute a foreign invocation's line to itself.
#
# Fix: cargo_route_log now appends a 7th field — the caller's own
# HERMETIC_BUILD_RUN_ID — whenever that env var is set, so a caller that
# tagged its own cargo child with a unique run id can match its OWN
# lines back exactly. Proves:
#   Case A — HERMETIC_BUILD_RUN_ID unset: the line has exactly 6
#     whitespace-separated fields (unchanged format, no trailing field).
#   Case B — HERMETIC_BUILD_RUN_ID=<id>: the line has exactly 7 fields
#     and the 7th equals <id>.
#   Case C — two calls under two different run ids write two lines, and
#     grepping by one id's exact 7th field matches only its own line.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib" && pwd -P)"
[ -r "$HERE/cargo-route.sh" ] || { echo "selftest: $HERE/cargo-route.sh not found" >&2; exit 2; }
# shellcheck source=../scripts/lib/cargo-route.sh
source "$HERE/cargo-route.sh"

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/cargoroute-ac7.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# Case A: no run id set at all.
export BURST_ROUTE_LOG="$TMPDIR_TEST/route-a.log"
unset HERMETIC_BUILD_RUN_ID 2>/dev/null || true
cargo_route_log "build" "local" "budget:not-configured"
line_a="$(cat "$BURST_ROUTE_LOG")"
field_count_a="$(awk '{print NF}' <<<"$line_a")"
if [ "$field_count_a" = "6" ]; then
  ok "cargoroute AC7: no HERMETIC_BUILD_RUN_ID -> 6-field line (unchanged format)"
else
  bad "cargoroute AC7: no HERMETIC_BUILD_RUN_ID -> expected 6 fields, got $field_count_a: [$line_a]"
fi

# Case B: run id set — 7 fields, 7th is the id.
export BURST_ROUTE_LOG="$TMPDIR_TEST/route-b.log"
export HERMETIC_BUILD_RUN_ID="run-aaa111"
cargo_route_log "build" "local" "budget:not-configured"
line_b="$(cat "$BURST_ROUTE_LOG")"
field_count_b="$(awk '{print NF}' <<<"$line_b")"
seventh_b="$(awk '{print $7}' <<<"$line_b")"
if [ "$field_count_b" = "7" ] && [ "$seventh_b" = "run-aaa111" ]; then
  ok "cargoroute AC7: HERMETIC_BUILD_RUN_ID=run-aaa111 -> 7-field line, field 7 = run-aaa111"
else
  bad "cargoroute AC7: HERMETIC_BUILD_RUN_ID set -> expected 7 fields/run-aaa111, got $field_count_b/[$seventh_b]"
fi

# Case C: two distinct run ids in one shared log — matching one's exact
# 7th field must not pick up the other's line (the scenario this field
# exists to disambiguate: a foreign gate's burst line in a shared log).
export BURST_ROUTE_LOG="$TMPDIR_TEST/route-c.log"
export HERMETIC_BUILD_RUN_ID="run-own-222"
cargo_route_log "build" "local" "budget:not-configured"
export HERMETIC_BUILD_RUN_ID="run-foreign-333"
cargo_route_log "test" "burst" "budget:burst"
own_matches="$(awk '$7 == "run-own-222"' "$BURST_ROUTE_LOG" | wc -l | tr -d ' ')"
own_burst_matches="$(awk '$7 == "run-own-222" && $4 == "burst"' "$BURST_ROUTE_LOG" | wc -l | tr -d ' ')"
if [ "$own_matches" = "1" ] && [ "$own_burst_matches" = "0" ]; then
  ok "cargoroute AC7: own run id's line found, foreign run id's burst line excluded by exact match"
else
  bad "cargoroute AC7: expected own_matches=1/own_burst_matches=0, got $own_matches/$own_burst_matches"
fi

exit "$fail"
