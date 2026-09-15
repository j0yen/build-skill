#!/usr/bin/env bash
# pin_ac7_skill_md_static_check.sh — PRD-build-select-tick-run-pin AC7.
#
# Given the shipped SKILL.md, When a reviewer greps for "regardless of the
# priority rules", Then the phrase is gone and both the "Manual invocation"
# `run` bullet and the "One script decides" section name `--pin`, the
# pre-filter exception, and the coordinator's no-second-wave rule.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../SKILL.md"

fail=0

# Line-wrapped prose: flatten to one line so a check spanning a markdown
# line-wrap still matches (a human reviewer reading rendered prose would
# not care about the wrap either).
FLAT="$(tr '\n' ' ' < "$SKILL")"

if grep -q "regardless of the priority rules" "$SKILL"; then
  echo "FAIL: SKILL.md still contains 'regardless of the priority rules'"
  fail=1
else
  echo "ok  AC7: 'regardless of the priority rules' phrase is gone"
fi

if grep -q -- '--pin' "$SKILL"; then
  echo "ok  AC7: SKILL.md names --pin"
else
  echo "FAIL: SKILL.md never mentions --pin"
  fail=1
fi

if grep -qE 'pin skips the queue' "$SKILL"; then
  echo "ok  AC7: SKILL.md states the pre-filter exception (pin skips the queue, not the safety checks)"
else
  echo "FAIL: SKILL.md missing the pre-filter-exception statement"
  fail=1
fi

if printf '%s' "$FLAT" | grep -qE 'never[[:space:]]+call[[:space:]]+`select-guard\.sh`'; then
  echo "ok  AC7: SKILL.md states the coordinator must never call select-guard.sh itself"
else
  echo "FAIL: SKILL.md missing the no-second-wave rule for the coordinator"
  fail=1
fi

if printf '%s' "$FLAT" | grep -qE '22:23:55Z'; then
  echo "ok  AC7: the 22:23:55Z second-wave incident is cited"
else
  echo "FAIL: SKILL.md missing the 22:23:55Z incident citation"
  fail=1
fi

exit "$fail"
