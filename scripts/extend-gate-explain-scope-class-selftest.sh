#!/usr/bin/env bash
# extend-gate-explain-scope-class-selftest.sh — PRD-build-diff-scoped-gate
# requirement 1 (P0, AC1/AC3): `extend-gate.sh --explain-scope` prints a
# `class` column classifying each local producer `tree` or `history-infra`,
# names `extended-receipts` as per-producer (declared elsewhere, in
# rustbuild's extended-receipts.sh), and gives `gate`/`land` no class
# (they are not producers). No fixtures needed — pure static output.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$EXTEND_GATE" --explain-scope)"

expect "header names class column" '[[ "$out" == *"producer          class"* ]]'
for p in risk-gate intake proof-receipt vti-plan reviewer-agent; do
  expect "$p is class=tree" '[[ "$out" == *"$p"*"tree"* ]]'
done
for p in rollback-plan ci-checks; do
  expect "$p is class=history-infra" '[[ "$out" == *"$p"*"history-infra"* ]]'
done
expect "extended-receipts is per-producer, not a single class" '[[ "$out" == *"extended-receipts per-producer"* ]]'
expect "undeclared extended producer fails safe to history-infra" '[[ "$out" == *"undeclared -> history-infra"* ]]'
expect "gate carries no class" 'grep -Eq "^gate +n/a" <<<"$out"'
expect "land carries no class" 'grep -Eq "^land +n/a" <<<"$out"'

exit "$fail"
