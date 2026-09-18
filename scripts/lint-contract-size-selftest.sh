#!/usr/bin/env bash
# scripts/lint-contract-size-selftest.sh — regression coverage for
# lint-contract-size.sh (PRD-build-branch-contract-split requirement 4 /
# AC3). Uses --contract/--skill overrides so it never touches the real
# docs/branch-contract.md or SKILL.md in this checkout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/lint-contract-size.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
total=0

printf 'line %s\n' $(seq 1 10) > "$tmp/skill-ok.md"
printf 'line %s\n' $(seq 1 10) > "$tmp/contract-ok.md"

expect() { # $1=label $2=expected_rc, remaining = command
  total=$((total+1))
  local label="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "ok: $label -> rc=$rc"
  else
    echo "FAIL: $label expected rc=$want got rc=$rc: $out"
    fails=$((fails+1))
  fi
}

expect "clean pair" 0 "$LINT" --contract "$tmp/contract-ok.md" --skill "$tmp/skill-ok.md"
expect "missing contract is a skip" 0 "$LINT" --contract "$tmp/does-not-exist.md" --skill "$tmp/skill-ok.md"

seq 1 401 > "$tmp/contract-long.md"
out="$("$LINT" --contract "$tmp/contract-long.md" --skill "$tmp/skill-ok.md" 2>&1)"; rc=$?
total=$((total+1))
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$tmp/contract-long.md"; then
  echo "ok: contract >400 lines -> FAIL naming file"
else
  echo "FAIL: contract >400 lines: rc=$rc out=$out"
  fails=$((fails+1))
fi

seq 1 400 > "$tmp/contract-400.md"
expect "contract at exactly 400 lines" 0 "$LINT" --contract "$tmp/contract-400.md" --skill "$tmp/skill-ok.md"

{ seq 1 5; echo "2026-09-18: some incident happened here"; } > "$tmp/contract-dated.md"
out="$("$LINT" --contract "$tmp/contract-dated.md" --skill "$tmp/skill-ok.md" 2>&1)"; rc=$?
total=$((total+1))
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "dated"; then
  echo "ok: contract with date -> FAIL"
else
  echo "FAIL: contract with date: rc=$rc out=$out"
  fails=$((fails+1))
fi

seq 1 201 > "$tmp/skill-long.md"
expect "skill >200 lines fails by default" 1 "$LINT" --contract "$tmp/contract-ok.md" --skill "$tmp/skill-long.md"
expect "skill >200 lines tolerated during migration" 0 "$LINT" --contract "$tmp/contract-ok.md" --skill "$tmp/skill-long.md" --skill-tolerate-migration
expect "missing skill file fails" 1 "$LINT" --contract "$tmp/contract-ok.md" --skill "$tmp/does-not-exist.md"

echo "---"
echo "$((total-fails))/$total passed"
[ "$fails" -eq 0 ]
