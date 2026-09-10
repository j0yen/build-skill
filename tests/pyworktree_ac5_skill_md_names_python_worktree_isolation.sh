#!/usr/bin/env bash
# pyworktree_ac5_skill_md_names_python_worktree_isolation.sh — PRD-build-python-worktree-isolation AC5.
#
# Given SKILL.md after this PRD ships, When grepping for "python" under the
# "Worktree isolation" section, Then it is named alongside rust-extend/
# kernel-extend (closing the gap this PRD's own five-whys used as evidence).
# This is a documentation-shape check (this PRD's own AC5 wording), not a
# behavioral one, so it re-runs the PRD's own literal verification command
# rather than duplicating a hand-rolled equivalent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
[ -f "$SKILL_MD" ] || { echo "FAIL: $SKILL_MD not found" >&2; exit 2; }

fail=0
check() {  # <label> <bool-command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
run_pipe() {  # helper so `check` can wrap a pipeline as a single boolean command
  grep -n python "$SKILL_MD" | grep -qi "worktree\|isolat"
}
header_names_python() {
  grep -A1 '^### Worktree isolation' "$SKILL_MD" | grep -qi python
}
phase3_documents_unconditional() {
  grep -qi 'Worktree isolation, unconditional' "$SKILL_MD"
}

check "AC5: grep -n python SKILL.md | grep -i worktree/isolat matches at least one line" run_pipe
check "AC5: the 'Worktree isolation' section header (incl. its continuation line) names python" header_names_python
check "AC5: Phase 3's python routing paragraph documents unconditional add/land" phase3_documents_unconditional

exit "$fail"
