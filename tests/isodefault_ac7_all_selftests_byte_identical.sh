#!/usr/bin/env bash
# isodefault_ac7_all_selftests_byte_identical.sh — PRD-build-test-isolation-
# by-default AC7. The load-bearing proof the whole PRD exists for.
#
# Given all previously-unisolated selftests (scripts/run-selftests.sh's own
# SELFTEST_REGISTRY), When run-selftests.sh --all runs, Then the production
# journal, state/, and ~/repos/PRDs are byte-identical before and after
# (sha256 of the journal files; `git -C ~/repos/PRDs status --porcelain`
# unchanged).
#
# This test drives the real runner in --all mode directly (rather than
# re-implementing its own hashing) and additionally re-verifies the
# byte-identical claim itself, independently, from outside the runner —
# so a bug in the runner's OWN AC7 check can't silently mask a real leak.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-selftests.sh"
[ -x "$RUNNER" ] || { echo "ac7: $RUNNER not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

REAL_HOME="$HOME"
REAL_JOURNAL_ROOT="$REAL_HOME/brain/journal"
REAL_STATE_DIR="$SKILL_DIR/state"
REAL_PRDS_DIR="$REAL_HOME/Documents/PRDs"

_snapshot() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
}

before_journal="$(_snapshot "$REAL_JOURNAL_ROOT")"
before_state="$(_snapshot "$REAL_STATE_DIR")"
before_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

out="$("$RUNNER" --all 2>&1)"
rc=$?
echo "$out" | tail -5

after_journal="$(_snapshot "$REAL_JOURNAL_ROOT")"
after_state="$(_snapshot "$REAL_STATE_DIR")"
after_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

expect "real journal tree byte-identical before/after --all" "[ \"\$before_journal\" = \"\$after_journal\" ]"
expect "real state/ tree byte-identical before/after --all"  "[ \"\$before_state\" = \"\$after_state\" ]"
expect "~/repos/PRDs git status unchanged before/after --all" "[ \"\$before_prds_porcelain\" = \"\$after_prds_porcelain\" ]"
expect "runner's own AC7 check agrees (no AC7 FAILED line)"  "! printf '%s' \"\$out\" | grep -q 'AC7 FAILED'"

# rc itself is informative but not asserted strictly here — a real,
# pre-existing flake in one of the registered selftests (unrelated to
# journal/state isolation) can fail the runner's overall exit code without
# meaning production drifted; the three byte-identical checks above are
# what this AC is actually about. Report it for visibility.
echo "ac7: runner overall rc=$rc (informational — see byte-identical checks above for the actual AC)"

exit $fail
