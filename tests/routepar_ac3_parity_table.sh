#!/usr/bin/env bash
# tests/routepar_ac3_parity_table.sh — PRD-build-gate-route-parity-ledger
# AC3: "Given a fixture journal with 6 gate lines across both routes,
# When gate-status.sh --parity --since <ts> runs, Then the table shows
# per-producer runs/pass/block/pass_rate/last_block_ts for each route and
# the numbers equal the fixture's hand count."
#
# No live gate here — gate-status.sh --parity is a pure journal reader
# (scripts/gate-parity.py), so this hand-builds 6 `gate` lines (3 local,
# 3 burst) with a `phases=` + `route=` shape matching exactly what a real
# extend-gate.sh run now writes (routepar_ac1/ac2 already prove the real
# writer produces this shape), and hand-counts the expected aggregate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
GATE_STATUS="$SKILL_DIR/scripts/gate-status.sh"
[ -x "$GATE_STATUS" ] || { echo "selftest: $GATE_STATUS not executable" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac3-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC3_KEEP:-}" ] || rm -rf "$T"' EXIT

JDIR="$T/journal"
mkdir -p "$JDIR"
# 3 local runs: risk-gate always passes; ci-checks blocks once (2 pass, 1
# block -> local pass_rate 0.67). 3 burst runs: ci-checks blocks twice (1
# pass, 2 block -> burst pass_rate 0.33) — the exact "box looks worse"
# shape --diff-local exists to surface. risk-gate: 3/3 pass on both
# routes (never the cause). One `skip` (risk-gate on the 2nd local line)
# is excluded from risk-gate's own local run count entirely.
{
  printf '2026-09-15T01:00:00Z  gate  widget  pass  (head=a base=v1 gate: head=a pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:1,ci-checks:2 lock_wait=0s cargo=burst:0/local:0 routed=0/2 route=local)\n'
  printf '2026-09-15T02:00:00Z  gate  widget  pass  (head=b base=v1 gate: head=b pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:skip,ci-checks:2 lock_wait=0s cargo=burst:0/local:0 routed=0/1 route=local)\n'
  printf '2026-09-15T03:00:00Z  gate  widget  block  (head=c base=v1 gate: head=c pass=24 block=1 verdict=block blocking=ci-checks@local wall=10s phases=risk-gate:1,ci-checks:2! lock_wait=0s cargo=burst:0/local:0 routed=0/2 route=local)\n'
  printf '2026-09-15T04:00:00Z  gate  widget  pass  (head=d base=v1 gate: head=d pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:1,ci-checks:2 lock_wait=0s cargo=burst:3/local:0 routed=2/2 route=burst:9)\n'
  printf '2026-09-15T05:00:00Z  gate  widget  block  (head=e base=v1 gate: head=e pass=24 block=1 verdict=block blocking=ci-checks@burst:9 wall=10s phases=risk-gate:1,ci-checks:2! lock_wait=0s cargo=burst:3/local:0 routed=2/2 route=burst:9)\n'
  printf '2026-09-15T06:00:00Z  gate  widget  block  (head=f base=v1 gate: head=f pass=24 block=1 verdict=block blocking=ci-checks@burst:9 wall=10s phases=risk-gate:1,ci-checks:2! lock_wait=0s cargo=burst:3/local:0 routed=2/2 route=burst:9)\n'
} > "$JDIR/2026-09-15.md"

echo "=== AC3: --parity --json produces the hand-counted aggregate ==="
json_out="$(GATE_STATUS_JOURNAL_DIR="$JDIR" "$GATE_STATUS" --parity --since 2026-09-15T00:00:00Z --json 2>&1)"
rc=$?
expect "AC3: gate-status.sh --parity exits 0" "[ $rc -eq 0 ]"
expect "AC3: output is valid JSON" "printf '%s' '$json_out' | python3 -c 'import json,sys; json.load(sys.stdin)'"

check_row() {  # $1=producer $2=route $3=runs $4=pass $5=block
  local got
  got="$(printf '%s' "$json_out" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    if r['producer'] == '$1' and r['route'] == '$2':
        print('%d %d %d' % (r['runs'], r['pass'], r['block']))
        break
else:
    print('MISSING')
")"
  expect "AC3: $1 @ $2 -> runs=$3 pass=$4 block=$5 (got: $got)" "[ '$got' = '$3 $4 $5' ]"
}

check_row risk-gate local 2 2 0
check_row ci-checks local 3 2 1
check_row risk-gate burst:9 3 3 0
check_row ci-checks burst:9 3 1 2

echo "=== AC3: plain table mode also runs clean (0 rc, has a header) ==="
table_out="$(GATE_STATUS_JOURNAL_DIR="$JDIR" "$GATE_STATUS" --parity --since 2026-09-15T00:00:00Z 2>&1)"
expect "AC3: table mode names 'producer' in its header" "[[ '$table_out' == *'producer'* ]]"
expect "AC3: table mode names ci-checks" "[[ '$table_out' == *'ci-checks'* ]]"

echo "=== AC3: --producer filters to one producer only ==="
prod_json="$(GATE_STATUS_JOURNAL_DIR="$JDIR" "$GATE_STATUS" --parity --since 2026-09-15T00:00:00Z --producer ci-checks --json 2>&1)"
expect "AC3: --producer ci-checks excludes risk-gate rows" \
  "printf '%s' '$prod_json' | python3 -c \"import json,sys; rows=json.load(sys.stdin); sys.exit(0 if all(r['producer']=='ci-checks' for r in rows) and rows else 1)\""

echo "=== AC3: --since excludes lines before the cutoff ==="
since_json="$(GATE_STATUS_JOURNAL_DIR="$JDIR" "$GATE_STATUS" --parity --since 2026-09-15T04:30:00Z --producer ci-checks --json 2>&1)"
expect "AC3: --since 04:30Z only counts the two later burst runs (2 runs)" \
  "printf '%s' '$since_json' | python3 -c \"import json,sys; rows=json.load(sys.stdin); sys.exit(0 if rows and rows[0]['runs']==2 else 1)\""

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac3: ALL PASS"
else
  echo "routepar_ac3: assertion(s) FAILED"
fi
exit "$fail"
