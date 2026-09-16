#!/usr/bin/env bash
# tests/bgscope_ac8_selftest_fixture_real_origin_tag.sh — PRD-build-
# branch-gate-scope-artifacts requirement 6 (P0) / AC8: "Given the shipped
# selftest suite, When it runs, Then the branch-scope fixture has an
# origin remote and tag v0.1.0, and both AC5 and AC6 shapes are exercised
# green." This AC is about the test suite's OWN shape, so its own test IS
# scripts/extend-gate-branch-scope-realfixture-selftest.sh -- this file
# proves it exists, actually builds a real origin+tag (not just claims
# to), and passes end-to-end (both AC5 and AC6 shapes green in one run).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELFTEST="$HERE/../scripts/extend-gate-branch-scope-realfixture-selftest.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC8: the branch-scope selftest fixture has a real origin + tag, exercises AC5+AC6 ==="
expect "scripts/extend-gate-branch-scope-realfixture-selftest.sh exists and is executable" "[ -x \"$SELFTEST\" ]"
expect "it builds a real bare origin (not a stub)" "grep -q 'git init -q --bare' \"$SELFTEST\""
expect "it tags the fixture v0.1.0" "grep -qF 'tag v0.1.0' \"$SELFTEST\""
expect "it exercises the AC5 shape (correct branch -> pass, deferred=ci-checks)" \
  "grep -q 'AC5:' \"$SELFTEST\""
expect "it exercises the AC6 shape (incorrect branch -> block, reviewer-agent present)" \
  "grep -q 'AC6:' \"$SELFTEST\""

echo "--- running the full selftest end-to-end (this is the actual proof) ---"
out="$(mktemp "${TMPDIR:-/tmp}/bgscope-ac8-run.XXXXXX")"
timeout 300 bash "$SELFTEST" > "$out" 2>&1
run_rc=$?
tail -20 "$out"
expect "the full selftest exits 0 (ALL PASS)" "[ $run_rc -eq 0 ]"
expect "its own summary line reads ALL PASS" "grep -q 'ALL PASS' \"$out\""
rm -f "$out"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac8: ALL PASS"; else echo "bgscope_ac8: assertion(s) FAILED"; fi
exit "$fail"
