#!/usr/bin/env bash
# isodefault_ac3_corpus_lint_counts_fixtures.sh — PRD-build-test-isolation-
# by-default AC3.
#
# Given the real 2026-09-15 journals as fixtures, When
# lint-journal-fixtures.sh --corpus 2026-09-15 runs, Then it reports >= 829
# lines grouped by token with `does-not-matter-ac2` and `step=ac3b` among
# them.
#
# Read-only: this test only ever READS the real production journals for
# the fixed historical date named in the PRD's own Grounding section
# (never today's date, never writes anything) — exactly the corpus lint's
# documented job (Non-goals: "journals are append-only; the lint reports,
# never edits").

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/lint-journal-fixtures.sh"
[ -x "$LINT" ] || { echo "ac3: $LINT not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

DATE_FIXTURE="2026-09-15"
JOURNAL_FILE="$HOME/brain/journal/build/$DATE_FIXTURE.md"

if [ ! -f "$JOURNAL_FILE" ]; then
  echo "ac3: SKIP — no journal for $DATE_FIXTURE on this host ($JOURNAL_FILE absent); nothing to grade" >&2
  exit 0
fi

out="$("$LINT" --corpus "$DATE_FIXTURE")"
total="$(printf '%s\n' "$out" | grep -oE 'fixture-lines-total=[0-9]+' | grep -oE '[0-9]+')"

expect "reports a numeric total"                 "[ -n \"\$total\" ]"
expect "total >= 829"                             "[ \"\${total:-0}\" -ge 829 ]"
expect "does-not-matter-ac2 is among the tokens"  "printf '%s' \"\$out\" | grep -q 'does-not-matter-ac2'"
expect "step=ac3b is among the tokens"            "printf '%s' \"\$out\" | grep -q 'step=ac3b'"

exit $fail
