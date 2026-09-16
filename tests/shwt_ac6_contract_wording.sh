#!/usr/bin/env bash
# shwt_ac6_contract_wording.sh — PRD-build-shell-worktree-isolation AC6.
#
# Given the shipped build-contract.md, When a reviewer reads "Language
# routing", Then shell/hooks/config with build_into name worktree-extend.sh
# add/land and the exit-4/exit-5 contract, and the bare "direct edits"
# wording is gone for the build_into case. Documentation-shape check, same
# convention as tests/pyworktree_ac5_skill_md_names_python_worktree_isolation.sh
# — re-runs the literal grep this AC's own wording describes rather than a
# hand-rolled equivalent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACT="$HERE/../build-contract.md"
[ -f "$CONTRACT" ] || { echo "FAIL: $CONTRACT not found" >&2; exit 2; }

fail=0
check() {  # <label> <bool-command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
names_add_land() {
  grep -A20 '^## Language routing' "$CONTRACT" | grep -q 'worktree-extend.sh add' \
    && grep -A20 '^## Language routing' "$CONTRACT" | grep -q 'worktree-extend.sh.*land'
}
names_exit_contract() {
  grep -A20 '^## Language routing' "$CONTRACT" | grep -q 'exits 4' \
    && grep -A20 '^## Language routing' "$CONTRACT" | grep -q 'exits 5'
}
no_bare_direct_edits_for_build_into() {
  # The old unconditional line ("shell/hooks/config -> direct edits") must
  # be gone; a *conditional* "WITHOUT build_into ... direct edits" survivor
  # is fine and expected (new-repo PRDs still scaffold directly).
  ! grep -qE '`shell`/`hooks`/`config` → direct edits\.' "$CONTRACT"
}
new_repo_case_preserved() {
  grep -A20 '^## Language routing' "$CONTRACT" | grep -qi 'WITHOUT .build_into.'
}

check "AC6: Language routing names worktree-extend.sh add/land" names_add_land
check "AC6: Language routing names the exit-4/exit-5 contract" names_exit_contract
check "AC6: the bare 'direct edits' wording is gone for the build_into case" no_bare_direct_edits_for_build_into
check "AC6: the no-build_into (new-repo) direct-edits case is still documented" new_repo_case_preserved

exit "$fail"
