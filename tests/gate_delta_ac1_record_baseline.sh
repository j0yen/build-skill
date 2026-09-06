#!/usr/bin/env bash
# gate_delta_ac1_record_baseline.sh — PRD-build-gate-delta-baseline AC1.
#
# Given a repo with blocking receipts, when
# `gate-delta.sh record <repo> <gate-output>` runs against a REAL
# 25-receipt gate summary fixture (captured shape of autobuilder's own
# `gate: head=... receipts=... pass=... block=... verdict=...` +
# per-receipt ✓/✗ lines — see autobuilder/src/gate.rs), then
# agent/gate-baseline.json is written listing exactly the current
# blocking receipt names (reviewer-agent, ci-checks) and the command
# prints the recorded set.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-delta.sh"
FIXTURE="$HERE/fixtures/gate-output/two-blocks.txt"
JQ="$(command -v jq)"

[ -x "$GD" ] || { echo "ac1: $GD not executable" >&2; exit 2; }
[ -r "$FIXTURE" ] || { echo "ac1: $FIXTURE missing" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gd-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

set +e
out="$("$GD" record "$REPO" "$FIXTURE")"; rc=$?
set -e

expect "record exits 0"                  "[ $rc -eq 0 ]"
expect "writes agent/gate-baseline.json" "[ -f '$REPO/agent/gate-baseline.json' ]"
expect "printed set matches written file" "[ \"\$out\" = \"\$(cat '$REPO/agent/gate-baseline.json')\" ]"

names="$("$JQ" -r '.receipts[].name' "$REPO/agent/gate-baseline.json" | sort | paste -sd, -)"
expect "recorded names are exactly reviewer-agent,ci-checks" "[ '$names' = 'ci-checks,reviewer-agent' ]"

reviewer_reason="$("$JQ" -r '.receipts[] | select(.name=="reviewer-agent") | .reason' "$REPO/agent/gate-baseline.json")"
expect "reviewer-agent reason carried through" "[[ '$reviewer_reason' == 'prepare exited non-zero'* ]]"

schema="$("$JQ" -r '.schema' "$REPO/agent/gate-baseline.json")"
expect "schema tag present" "[ '$schema' = 'autobuilder.gate_baseline.v1' ]"

exit $fail
