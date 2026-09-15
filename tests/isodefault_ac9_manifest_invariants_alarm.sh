#!/usr/bin/env bash
# isodefault_ac9_manifest_invariants_alarm.sh — PRD-build-test-isolation-by-default AC9.
#
# Given one fixture line written to production after landing day, When
# manifest-invariants.sh --report runs, Then it lists
# fixture-lines-today=1 as a would-fire repo-health alarm.
#
# DEFERRED (P1 requirement 7's manifest-invariants.sh wiring specifically):
# scripts/lint-journal-fixtures.sh --corpus (this PRD's P0/P1 requirement 1
# + first half of requirement 7) is fully built and covered by
# tests/isodefault_ac3_corpus_lint_counts_fixtures.sh. Wiring its count
# into manifest-invariants.sh's own --report/alarms pipeline (a read-only
# reporting integration into a DIFFERENT script's existing Python alarm
# list, not a journal/state writer itself) is the piece this test
# documents as not yet landed, per the deferral note in this PRD's build
# summary — it falls outside the operator-authorization's scope ("all
# selftests and every journal/state writer in build-skill") because
# manifest-invariants.sh --report neither writes state nor is a selftest;
# it is a read-only audit script whose alarm LIST this PRD would extend.
#
# This test proves the piece that IS built (a fresh single fixture line
# is counted as exactly 1 by the corpus lint) and then explicitly SKIPs
# the manifest-invariants.sh half rather than claim it passes.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
LINT="$SKILL_DIR/scripts/lint-journal-fixtures.sh"
[ -x "$LINT" ] || { echo "ac9: $LINT not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d /mnt/data/jsy/tmp/isodefault-ac9.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# Isolated fixture journal — this test never writes to the real production
# journal (that would itself be exactly the pollution this PRD exists to
# stop); it proves the corpus lint's counting logic against a private
# BUILD_JOURNAL_ROOT instead, per landing-day date semantics.
export HOME="$T/home"
mkdir -p "$HOME/brain/journal/build"
DATE_FIXTURE="$(date -u +%F)"
echo "select  ac9-slug  same-target-admit  (target=/tmp/does-not-matter-ac9)" \
  > "$HOME/brain/journal/build/$DATE_FIXTURE.md"

out="$("$LINT" --corpus "$DATE_FIXTURE")"
total="$(printf '%s\n' "$out" | grep -oE 'fixture-lines-total=[0-9]+' | grep -oE '[0-9]+')"

expect "corpus lint counts exactly the one injected fixture line" "[ \"\${total:-0}\" -eq 1 ]"

echo "ac9: SKIP — manifest-invariants.sh --report wiring (requirement 7, P1) deferred; see this file's header for the scope justification" >&2

exit $fail
