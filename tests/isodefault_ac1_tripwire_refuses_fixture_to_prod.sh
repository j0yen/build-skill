#!/usr/bin/env bash
# isodefault_ac1_tripwire_refuses_fixture_to_prod.sh — PRD-build-test-
# isolation-by-default AC1.
#
# Given BUILD_JOURNAL_ROOT unset and text
# "select red-fixture same-target-admit (target=/tmp/does-not-matter-ac2)",
# When journal_line runs, Then nothing is appended to the production
# journal, stderr says "refused fixture-shaped line", and rc is 3.
#
# This test intentionally exercises the PRODUCTION default (it must, to
# prove the tripwire — requirement 3's whole point), so it captures the
# real journal's line count before/after itself and asserts NO growth,
# rather than relying on run-selftests.sh's own outer isolation (this file
# tests the innermost layer directly).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/lib/journal.sh"
[ -r "$LIB" ] || { echo "ac1: $LIB not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

REAL_JOURNAL="$HOME/brain/journal/build/$(date -u +%F).md"
before_lines=0
[ -f "$REAL_JOURNAL" ] && before_lines=$(wc -l < "$REAL_JOURNAL")

unset BUILD_JOURNAL_ROOT BURST_LANE_JOURNAL GATE_WEDGE_JOURNAL SELECT_GUARD_JOURNAL \
      JOURNAL_DIR BUILD_JOURNAL_DIR TICK_JOURNAL_DIR CARGO_BUDGET_JOURNAL BUILD_TEST BUILD_TEST_ALLOW_PROD

# shellcheck source=../scripts/lib/journal.sh
source "$LIB"

text='select red-fixture same-target-admit (target=/tmp/does-not-matter-ac2)'
stderr_out="$(journal_line "$text" 2>&1 1>/dev/null)"
rc=$?

after_lines=0
[ -f "$REAL_JOURNAL" ] && after_lines=$(wc -l < "$REAL_JOURNAL")

expect "rc is 3"                                   "[ $rc -eq 3 ]"
expect "stderr says refused fixture-shaped line"    "printf '%s' \"\$stderr_out\" | grep -q 'refused fixture-shaped line'"
expect "nothing appended to the real production journal" "[ $before_lines -eq $after_lines ]"

exit $fail
