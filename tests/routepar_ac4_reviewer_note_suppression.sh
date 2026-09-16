#!/usr/bin/env bash
# tests/routepar_ac4_reviewer_note_suppression.sh — PRD-build-gate-route-
# parity-ledger AC4: "Given a reviewer-agent producer that passes, When
# the gate line is written, Then no reviewer-agent — note appears; Given
# it fails, Then the note appears once."
#
# The 09-15 22:48:50Z defect this closes: a mechanism failure in THIS
# run's own reviewer invocation (claude CLI errors, JSON parse fails —
# anything before `autobuilder reviewer-agent finalize` ever runs) used
# to note_block unconditionally even though the STALE reviewer-agent.json
# left on disk from the last successful run still said "pass", so a
# 25/25-pass gate line carried a "reviewer-agent — subagent did not
# return" note. Reproduced here: run 1 succeeds (seeds a real
# decision=pass receipt); run 2 forces the claude-fake to fail outright
# (a pure mechanism failure, receipt untouched) — AC4's "passes" half.
# Run 3 lets the fake claude/finalize succeed but return decision=block —
# AC4's "fails" half, with no mechanism error at all.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/routepar-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac4-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC4_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
routepar_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
export FAKE_GH_AUTH_RC=0

echo "=== seed: a normal run leaves a real decision=pass reviewer-agent receipt ==="
seed_out="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
seed_rc=$?
expect "seed: extend-gate.sh exits 0" "[ $seed_rc -eq 0 ]"
expect "seed: reviewer-agent.json decision=pass" \
  "[ \"\$(jq -r '.decision' '$REPO/target/autobuilder/receipts/reviewer-agent.json')\" = pass ]"

echo "=== AC4 (passes): a mechanism failure this run, stale receipt still pass -> no note ==="
export FAKE_REVCLAUDE_RC=1
out_fail="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_fail=$?
unset FAKE_REVCLAUDE_RC
line_fail="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC4 passes: extend-gate.sh still exits 0 (nothing else blocking)" "[ $rc_fail -eq 0 ]"
expect "AC4 passes: gate line verdict is pass" "[[ '$line_fail' == *'  gate  '*'  pass  '* ]]"
expect "AC4 passes: no 'reviewer-agent —' note on this pass line" "[[ '$line_fail' != *'reviewer-agent —'* ]]"
expect "AC4 passes: reviewer-agent.json still reads decision=pass (untouched stale receipt)" \
  "[ \"\$(jq -r '.decision' '$REPO/target/autobuilder/receipts/reviewer-agent.json')\" = pass ]"

echo "=== AC4 (fails): finalize succeeds with decision=block -> the note appears once ==="
export FAKE_REVIEWER_DECISION=block
out_block="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_block=$?
unset FAKE_REVIEWER_DECISION
line_block="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC4 fails: reviewer-agent.json now reads decision=block" \
  "[ \"\$(jq -r '.decision' '$REPO/target/autobuilder/receipts/reviewer-agent.json')\" = block ]"
expect "AC4 fails: the gate line names reviewer-agent as blocking (route-suffixed)" \
  "[[ '$line_block' == *'blocking='*'reviewer-agent@local'* ]]"
# The note's own producer-name prefix gets the @<route> suffix (R2) before
# the em-dash detail, so the full note reads "reviewer-agent@local — ...".
note_count="$(printf '%s' "$line_block" | grep -o 'reviewer-agent@local —' | wc -l | tr -d '[:space:]')"
expect "AC4 fails: the note appears exactly once" "[ '$note_count' = '1' ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac4: ALL PASS"
else
  echo "routepar_ac4: assertion(s) FAILED"
fi
exit "$fail"
