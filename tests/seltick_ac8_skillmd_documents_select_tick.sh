#!/usr/bin/env bash
# seltick_ac8_skillmd_documents_select_tick.sh —
# PRD-build-select-tick-deterministic AC8: given SKILL.md after this PRD,
# when `grep -c "select-tick.sh" SKILL.md` runs, then it is >= 3 and the
# Phase 2 section contains the sentence "dispatch every entry of
# admitted[] in one message".
#
# Static/documentation check, not fixture-based (same category as the
# other doc-shape ACs elsewhere in this repo, e.g. pyworktree_ac5) — this
# is a real standalone test file per this PRD's own test_prefix
# convention rather than a comment pointing at select-tick-selftest.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"

[ -f "$SKILL_MD" ] || { echo "FAIL AC8: SKILL.md not found at $SKILL_MD" >&2; exit 1; }

n="$(grep -c "select-tick.sh" "$SKILL_MD")"
if [ "$n" -lt 3 ]; then
  echo "FAIL AC8: expected grep -c select-tick.sh SKILL.md >= 3, got $n" >&2
  exit 1
fi

if ! grep -q "dispatch every entry of admitted\[\] in one message" "$SKILL_MD"; then
  echo "FAIL AC8: SKILL.md's Phase 2 section is missing the sentence 'dispatch every entry of admitted[] in one message'" >&2
  exit 1
fi

echo "ok  AC8: SKILL.md mentions select-tick.sh $n times and Phase 2 has the required dispatch sentence"
