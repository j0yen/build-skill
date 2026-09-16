#!/usr/bin/env bash
# selslot_ac8_journal_line_literal_format.sh —
# PRD-build-select-guard-depends-before-slot AC8 (selslot_d fixture):
# given a deliberately-gated candidate, when it runs, then the produced
# journal line is asserted with a literal string equality check (not a
# substring or loose regex) against
# `select: <slug> gated (<reason>) slot-not-consumed`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac8-repo
selslot_write_prd depwait "$TARGET" PRD-selslot-ac8-dep-unmet.md
selslot_commit

selslot_guard depwait 0 "" >/dev/null 2>&1 || true

# Literal full-line equality (grep -xF), not a substring/regex match --
# and exactly one line in the journal, so a near-miss extra line can't
# hide behind a loose containment check.
grep -qxF 'select: depwait gated (depends-on) slot-not-consumed' "$SELECT_GUARD_JOURNAL" \
  || { echo "FAIL AC8: journal line is not a literal match" >&2; cat "$SELECT_GUARD_JOURNAL" >&2 2>/dev/null; exit 1; }
# Counts only `select: ` lines, not the file's total line count —
# PRD-build-journal-single-writer requirement 1 routed select-guard.sh
# through the shared journal_line, which appends its own one-time
# `journal  legacy-env  (name=SELECT_GUARD_JOURNAL)` notice the first
# time this process sees that override active (scripts/lib/journal.sh);
# that notice is a legitimate, separate line, not a near-miss duplicate
# of the gated verdict this AC actually guards against.
lines=$(grep -c '^select: ' "$SELECT_GUARD_JOURNAL")
[ "$lines" -eq 1 ] || { echo "FAIL AC8: expected exactly one select: journal line, got $lines" >&2; cat "$SELECT_GUARD_JOURNAL" >&2 2>/dev/null; exit 1; }

echo "ok  AC8: journal line matches the exact contract format, literally"
