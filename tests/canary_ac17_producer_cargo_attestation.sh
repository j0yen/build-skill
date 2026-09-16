#!/usr/bin/env bash
# tests/canary_ac17_producer_cargo_attestation.sh —
# PRD-build-burst-gate-canary-invariant AC17: given a burst-intended gate
# and a fixture extended-receipts.sh that prepends $HOME/.cargo/bin to
# PATH (i.e. no producer's cargo call ever reaches the ledger), the gate
# blocks with cause=producer-cargo-unattested producer=flake-audit and the
# journal names every producer in state/cargo-producers.txt with no
# ledger row; given the shim-first PATH (every producer DOES reach the
# ledger), every listed producer has a ledger row with
# parent_step=<producer> and the gate is not blocked by R15.
#
# Pure logic test, no real gate/cargo/autobuilder run (same rationale as
# tests/canary_ac15_route_block.sh, which this file mirrors): extracts THE
# ACTUAL two code blocks extend-gate.sh runs for R15 (marked
# BEGIN/END canary-r15-producer-attestation[-block]) via sed and sources
# them into a throwaway subshell against a real, hand-built
# cargo-budget.sh-shaped ledger.jsonl fixture — this is the real
# production code under test, not a reimplementation of it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
EXTEND_GATE="$REPO_ROOT/scripts/extend-gate.sh"
[ -f "$EXTEND_GATE" ] || { echo "canary_ac17: $EXTEND_GATE missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

extract_block() {  # $1 = begin marker text (literal, no regex chars)
  sed -n "/# BEGIN $1/,/# END $1/p" "$EXTEND_GATE"
}

detect_block="$(extract_block 'canary-r15-producer-attestation')"
block_block="$(extract_block 'canary-r15-producer-attestation-block')"
if [ -n "$detect_block" ]; then echo "ok  markers found: detect block is non-empty"; else echo "FAIL markers found: detect block is non-empty" >&2; fail=1; fi
if [ -n "$block_block" ]; then echo "ok  markers found: block block is non-empty"; else echo "FAIL markers found: block block is non-empty" >&2; fail=1; fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac17.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PRODUCERS_FILE="$ROOT/cargo-producers.txt"
cat > "$PRODUCERS_FILE" <<'EOF'
flake-audit
mutation-kill
cold-build-time
bench-delta
msrv-verify
hermetic-build
determinism
semver-check
EOF

now_epoch() { date -u +%s; }
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # $1=epoch

write_full_ledger() {  # $1=ledger file, $2=gate_start_epoch -- one row per producer, well inside the window
  local f="$1" g="$2"
  : > "$f"
  local ts; ts="$(iso_at "$((g + 5))")"
  for p in flake-audit mutation-kill cold-build-time bench-delta msrv-verify hermetic-build determinism semver-check; do
    printf '{"ts_start":"%s","ts_end":"%s","parent_step":"%s"}\n' "$ts" "$ts" "$p" >> "$f"
  done
}

run_case() {  # $1=route_intended $2=ledger_file $3=gate_start_epoch $4=producers_file
  local route_intended="$1" CARGO_PRODUCERS_LEDGER="$2" t0="$3" CARGO_PRODUCERS_FILE="$4"
  local outcome="pass" final_rc=0 journal_suffix=""
  eval "$detect_block"
  eval "$block_block"
  printf 'producer_unattested_first=%s producer_unattested_csv=%s outcome=%s final_rc=%s journal_suffix=%s\n' \
    "$producer_unattested_first" "$producer_unattested_csv" "$outcome" "$final_rc" "$journal_suffix"
}

echo "=== AC17 case 1: burst-intended, no ledger at all (PATH-ahead-of-shims fixture: every producer local, nothing ever budgeted) -> block, first=flake-audit, all 8 named ==="
gate_start="$(now_epoch)"
missing_ledger="$ROOT/no-such-ledger.jsonl"
out1="$(run_case burst "$missing_ledger" "$gate_start" "$PRODUCERS_FILE")"
echo "  $out1"
expect "case1: first missing is flake-audit (list order)" "printf '%s' \"$out1\" | grep -q 'producer_unattested_first=flake-audit'"
expect "case1: outcome=block" "printf '%s' \"$out1\" | grep -q 'outcome=block'"
expect "case1: final_rc=1" "printf '%s' \"$out1\" | grep -q 'final_rc=1'"
expect "case1: cause string exact" "printf '%s' \"$out1\" | grep -q 'cause=producer-cargo-unattested producer=flake-audit'"
expect "case1: unattested= names every one of the 8" \
  "printf '%s' \"$out1\" | grep -q 'unattested=flake-audit,mutation-kill,cold-build-time,bench-delta,msrv-verify,hermetic-build,determinism,semver-check'"

echo "=== AC17 case 2: burst-intended, shim-first PATH (fixture: every producer's ledger row present, well inside the gate window) -> not blocked by R15 ==="
full_ledger="$ROOT/full-ledger.jsonl"
write_full_ledger "$full_ledger" "$gate_start"
out2="$(run_case burst "$full_ledger" "$gate_start" "$PRODUCERS_FILE")"
echo "  $out2"
expect "case2: producer_unattested_first empty" "printf '%s' \"$out2\" | grep -q 'producer_unattested_first= '"
expect "case2: outcome unchanged (still pass)" "printf '%s' \"$out2\" | grep -q 'outcome=pass'"
expect "case2: final_rc unchanged (still 0)" "printf '%s' \"$out2\" | grep -q 'final_rc=0'"
expect "case2: journal_suffix carries no producer-cargo-unattested cause" \
  "! printf '%s' \"$out2\" | grep -q 'cause=producer-cargo-unattested'"

echo "=== AC17 case 3 (regression guard): route_intended=local -> R15 never applies regardless of ledger state ==="
out3="$(run_case local "$missing_ledger" "$gate_start" "$PRODUCERS_FILE")"
echo "  $out3"
expect "case3: producer_unattested_first empty (R15 skipped for local intent)" "printf '%s' \"$out3\" | grep -q 'producer_unattested_first= '"
expect "case3: outcome unchanged (still pass)" "printf '%s' \"$out3\" | grep -q 'outcome=pass'"

echo "=== AC17 case 4 (regression guard): ledger rows exist but BEFORE the gate window (stale, from a prior run) -> still blocked, not falsely satisfied ==="
stale_ledger="$ROOT/stale-ledger.jsonl"
write_full_ledger "$stale_ledger" "$((gate_start - 7200))"
out4="$(run_case burst "$stale_ledger" "$gate_start" "$PRODUCERS_FILE")"
echo "  $out4"
expect "case4: still blocked (stale rows don't count)" "printf '%s' \"$out4\" | grep -q 'outcome=block'"
expect "case4: first missing is flake-audit again" "printf '%s' \"$out4\" | grep -q 'producer_unattested_first=flake-audit'"

echo "=== AC17 case 5 (regression guard): one producer (mutation-kill) missing its row, rest present -> block names exactly mutation-kill ==="
partial_ledger="$ROOT/partial-ledger.jsonl"
write_full_ledger "$partial_ledger" "$gate_start"
grep -v '"parent_step":"mutation-kill"' "$partial_ledger" > "$partial_ledger.tmp" && mv "$partial_ledger.tmp" "$partial_ledger"
out5="$(run_case burst "$partial_ledger" "$gate_start" "$PRODUCERS_FILE")"
echo "  $out5"
expect "case5: first missing is mutation-kill" "printf '%s' \"$out5\" | grep -q 'producer_unattested_first=mutation-kill'"
expect "case5: unattested= names only mutation-kill" "printf '%s' \"$out5\" | grep -q 'unattested=mutation-kill '"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac17_producer_cargo_attestation: ALL PASS"
  exit 0
else
  echo "canary_ac17_producer_cargo_attestation: assertion(s) FAILED"
  exit 1
fi
