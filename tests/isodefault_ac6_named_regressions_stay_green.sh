#!/usr/bin/env bash
# isodefault_ac6_named_regressions_stay_green.sh — PRD-build-test-isolation-
# by-default AC6.
#
# Given tests/chained-tick_ac2_stop_on_red.sh and
# scripts/gate-wedge-selftest.sh run via the runner, When they finish, Then
# the production journal line count is unchanged and both still pass.
#
# gate-wedge-selftest.sh is the marquee case: it's the one script in the
# six-copy list that wasn't wired to isolation-guard.sh at all before this
# PRD (Grounding). chained-tick_ac2_stop_on_red.sh is the exact 16:36Z
# leak reproduction (select-guard.sh same-target-admit against a
# /tmp/does-not-matter-ac2 fixture target).

# lint-journal-fixtures:tests-exempt PRD-build-journal-single-writer — this
# file's whole job is to read the REAL, un-isolated $HOME/brain journal
# line count before/after running two tests through run-selftests.sh (the
# runner isolates ITSELF internally); sourcing the selftest_init prelude
# here would override $HOME before that count is ever taken, defeating
# the one assertion this file exists to make (production journal line
# count unchanged). See scripts/run-selftests.sh for the real prelude use.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-selftests.sh"
[ -x "$RUNNER" ] || { echo "ac6: $RUNNER not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

REAL_JOURNAL="$HOME/brain/journal/build/$(date -u +%F).md"
before=0
[ -f "$REAL_JOURNAL" ] && before=$(wc -l < "$REAL_JOURNAL")

out="$("$RUNNER" tests/chained-tick_ac2_stop_on_red.sh scripts/gate-wedge-selftest.sh 2>&1)"
rc=$?

after=0
[ -f "$REAL_JOURNAL" ] && after=$(wc -l < "$REAL_JOURNAL")

expect "runner exits 0 (both tests passed)"          "[ $rc -eq 0 ]"
expect "runner reports 2 passed, 0 failed"            "printf '%s' \"\$out\" | grep -q '2 passed, 0 failed'"
expect "production journal line count unchanged"      "[ $before -eq $after ]"

exit $fail
