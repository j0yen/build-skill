#!/usr/bin/env bash
# three-state_ac1_could_not_check_recorded.sh — PRD-build-three-state-probes
# AC1.
#
# Given a probe whose underlying command errors, when it emits through
# probe-result.sh, then the ledger records state=could-not-check with the
# reason, and stdout carries the canonical line.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/probe-result.sh"
[ -r "$LIB" ] || { echo "ac1: $LIB not found" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export PROBE_JOURNAL_DIR="$T/journal"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=../scripts/probe-result.sh
source "$LIB"

# Simulate a probe whose underlying command failed (empty/error output).
underlying_out="$(false 2>&1)" || true
out="$(probe_emit demo-probe could-not-check "underlying command exited non-zero")"
rc=$?

expect "probe_emit exits 0 (fail-open)" "[ $rc -eq 0 ]"
expect "stdout carries the canonical line (state=could-not-check)" \
  "grep -q 'state=could-not-check' <<<\"\$out\""
expect "stdout carries the reason" \
  "grep -q 'underlying command exited non-zero' <<<\"\$out\""

ledger="$BUILD_STATE_DIR/probes/ledger.jsonl"
expect "ledger file was created" "[ -f '$ledger' ]"
expect "ledger records state=could-not-check" \
  "grep -q '\"state\": *\"could-not-check\"' '$ledger'"
expect "ledger records the reason" \
  "grep -q 'underlying command exited non-zero' '$ledger'"
expect "ledger has exactly one row" "[ \"\$(wc -l < '$ledger')\" -eq 1 ]"

exit $fail
