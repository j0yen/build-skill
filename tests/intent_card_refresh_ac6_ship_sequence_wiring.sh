#!/usr/bin/env bash
# intent_card_refresh_ac6_ship_sequence_wiring.sh — PRD-build-intent-card-
# refresh AC6.
#
# Given the updated SKILL.md ship sequence, when a rust-extend ship
# executes, then the refresh step runs between integrate and the gate
# run and the card change is part of the shipped commits.
#
# SKILL.md IS the ship sequence (build-skill has no separate binary that
# executes it step-by-step) — asserting the prose is honestly the only
# way to test "the sequence gains a step" for a doc-driven skill. This
# checks the numbered rust-extend ship list names the refresh script,
# places it after integrate/before gate, and documents the exit-3 defer
# behavior so a malformed PRD can't push a card-stale head.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../SKILL.md"

[ -r "$SKILL" ] || { echo "ac6: $SKILL missing" >&2; exit 2; }

fail=0
expect_grep() {
  local label="$1" pattern="$2"
  if grep -qF "$pattern" "$SKILL"; then
    echo "ok  $label"
  else
    echo "FAIL $label — pattern not found: $pattern" >&2
    fail=1
  fi
}

expect_grep "ship sequence names the refresh script" \
  "scripts/intent-card-refresh.sh <repo> <prd-path>"
expect_grep "step commits under the ship's own identity" \
  "agent: refresh intent card for"
expect_grep "exit-3 malformed-PRD defer is documented" \
  "Exit 3 (malformed PRD, no parseable"

# Ordering: the refresh step's numbered heading must appear AFTER
# "integrate" and BEFORE "push + cleanup" / "gate" in the rust-extend
# ship sequence list (the PRD requires "between integrate and the gate
# run").
integrate_line="$(grep -n '^[0-9]\+\.\s*\*\*integrate' "$SKILL" | head -1 | cut -d: -f1)"
refresh_line="$(grep -n 'intent card refresh (serial, locked)' "$SKILL" | head -1 | cut -d: -f1)"
gate_line="$(grep -n '^[0-9]\+\.\s*\*\*gate\*\*' "$SKILL" | head -1 | cut -d: -f1)"

if [ -n "$integrate_line" ] && [ -n "$refresh_line" ] && [ -n "$gate_line" ] \
   && [ "$integrate_line" -lt "$refresh_line" ] && [ "$refresh_line" -lt "$gate_line" ]; then
  echo "ok  refresh step ordered between integrate ($integrate_line) and gate ($gate_line): $refresh_line"
else
  echo "FAIL refresh step not ordered between integrate and gate (integrate=$integrate_line refresh=$refresh_line gate=$gate_line)" >&2
  fail=1
fi

exit $fail
