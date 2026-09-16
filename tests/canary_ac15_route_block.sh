#!/usr/bin/env bash
# tests/canary_ac15_route_block.sh — PRD-build-burst-gate-canary-invariant
# AC15: given a burst-intended gate whose per-gate route.log has zero
# " burst " lines at gate end, extend-gate.sh's verdict must be `block`
# with cause=route-mismatch intended=burst burst=0 local=<n>
# first_local_cause=<cause>, not merely a journaled "dirty" probe (today's
# behavior for the PARTIAL-mismatch case, per PRD-build-gate-cargo-route-
# attest's own non-goal, which R13 deliberately leaves untouched).
#
# Pure logic test, no real gate/cargo/autobuilder run, no cargo work at
# all (this PRD's own build_target is shell) — a full extend-gate.sh
# invocation exercises 17 real extended-receipts producers plus autobuilder
# against real cargo, minutes of wall time this test does not need and
# should not pay for just to prove two conditionals. Instead this extracts
# THE ACTUAL two code blocks extend-gate.sh runs for R13 (marked
# `BEGIN/END canary-r13-*`) via sed and sources them into a throwaway
# subshell with each scenario's inputs pre-set — this is the real
# production code under test, not a reimplementation of it, so a future
# edit to those blocks that breaks the marker pairing fails this test
# loudly (see the "markers found" assertions below) rather than silently
# testing stale logic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
EXTEND_GATE="$REPO_ROOT/scripts/extend-gate.sh"
[ -f "$EXTEND_GATE" ] || { echo "canary_ac15: $EXTEND_GATE missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

extract_block() {  # $1 = begin marker text (literal, no regex chars)
  sed -n "/# BEGIN $1/,/# END $1/p" "$EXTEND_GATE"
}

detect_block="$(extract_block 'canary-r13-no-burst-detect')"
block_block="$(extract_block 'canary-r13-no-burst-block')"

# Plain bash checks, never `eval` — these blocks are the real extracted
# script text (containing its own quotes/brackets), and eval-ing that text
# as a cond STRING (the expect() helper's normal path) would let its
# embedded quotes break out of the cond string's own quoting instead of
# running as the code it actually is.
if [ -n "$detect_block" ]; then echo "ok  markers found: detect block is non-empty"; else echo "FAIL markers found: detect block is non-empty" >&2; fail=1; fi
if [ -n "$block_block" ]; then echo "ok  markers found: block block is non-empty"; else echo "FAIL markers found: block block is non-empty" >&2; fail=1; fi

run_case() {  # $1=route_intended $2=route_burst_n $3=route_local_n $4=route_first_local_cause
  local route_intended="$1" route_burst_n="$2" route_local_n="$3" route_first_local_cause="$4"
  local outcome="pass" final_rc=0 journal_suffix=""
  eval "$detect_block"
  eval "$block_block"
  printf 'route_no_burst=%s outcome=%s final_rc=%s journal_suffix=%s\n' \
    "$route_no_burst" "$outcome" "$final_rc" "$journal_suffix"
}

echo "=== AC15 case 1: intended=burst, burst=0, local=3, cause=burst-lane-disabled -> hard block ==="
out1="$(run_case burst 0 3 burst-lane-disabled)"
echo "  $out1"
expect "case1: route_no_burst=true" "printf '%s' \"$out1\" | grep -q 'route_no_burst=true'"
expect "case1: outcome=block" "printf '%s' \"$out1\" | grep -q 'outcome=block'"
expect "case1: final_rc=1" "printf '%s' \"$out1\" | grep -q 'final_rc=1'"
expect "case1: journal_suffix carries the exact AC15 cause string" \
  "printf '%s' \"$out1\" | grep -q 'cause=route-mismatch intended=burst burst=0 local=3 first_local_cause=burst-lane-disabled'"

echo "=== AC15 case 2: intended=burst, burst=0, local=0, cause=<empty> -> still a hard block (literal 'zero burst lines', regardless of local count) ==="
out2="$(run_case burst 0 0 "")"
echo "  $out2"
expect "case2: route_no_burst=true" "printf '%s' \"$out2\" | grep -q 'route_no_burst=true'"
expect "case2: outcome=block" "printf '%s' \"$out2\" | grep -q 'outcome=block'"
expect "case2: unknown cause falls back to 'unknown', never a blank field" \
  "printf '%s' \"$out2\" | grep -q 'first_local_cause=unknown'"

echo "=== AC15 case 3 (regression guard, non-goal preserved): intended=burst, burst=2, local=1 (PARTIAL mismatch) -> route_mismatch stays non-blocking, outcome untouched by R13 ==="
out3="$(run_case burst 2 1 no-session)"
echo "  $out3"
expect "case3: route_no_burst=false (at least one burst line present)" "printf '%s' \"$out3\" | grep -q 'route_no_burst=false'"
expect "case3: outcome unchanged by R13 (still the pre-set 'pass')" "printf '%s' \"$out3\" | grep -q 'outcome=pass'"
expect "case3: final_rc unchanged by R13 (still 0)" "printf '%s' \"$out3\" | grep -q 'final_rc=0'"
expect "case3: journal_suffix carries no route-mismatch cause (R13 never fires)" \
  "! printf '%s' \"$out3\" | grep -q 'cause=route-mismatch'"

echo "=== AC15 case 4 (regression guard): intended=local -> R13 never applies regardless of counts ==="
out4="$(run_case local 0 5 something)"
echo "  $out4"
expect "case4: route_no_burst=false (route_intended is not burst)" "printf '%s' \"$out4\" | grep -q 'route_no_burst=false'"
expect "case4: outcome unchanged (still 'pass')" "printf '%s' \"$out4\" | grep -q 'outcome=pass'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac15_route_block: ALL PASS"
  exit 0
else
  echo "canary_ac15_route_block: assertion(s) FAILED"
  exit 1
fi
