#!/usr/bin/env bash
# tests/xrepo_ac7_skill_md_documents_rule.sh — PRD-build-cross-repo-
# commit-gate requirement 6 (P1) / AC7: "Given SKILL.md after land, When
# grepped for cross-repo-gate, Then both the shell-target sequence and the
# main-push-gate section describe the rule."
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_MD="$HERE/../SKILL.md"
[ -f "$SKILL_MD" ] || { echo "selftest: $SKILL_MD not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC7: SKILL.md names cross-repo-gate in both places ==="
hits="$(grep -n "cross-repo-gate" "$SKILL_MD" | wc -l)"
expect "at least two cross-repo-gate mentions exist" "[ \"$hits\" -ge 2 ]"

shell_section="$(sed -n '/^- \*\*Shell scripts \/ hook scripts\*\*/,/^- \*\*Config \/ settings.json changes\*\*/p' "$SKILL_MD")"
expect "the shell-target sequence (Phase 3 Classify) mentions cross-repo-gate" \
  "printf '%s' \"\$shell_section\" | grep -q cross-repo-gate"
expect "the shell-target sequence names gated-targets.sh" \
  "printf '%s' \"\$shell_section\" | grep -q 'gated-targets.sh'"

mpg_section="$(sed -n '/^- \*\*main push gate\*\*/,/^- \*\*push\*\*/p' "$SKILL_MD")"
expect "the main-push-gate section mentions cross-repo-gate" \
  "printf '%s' \"\$mpg_section\" | grep -q cross-repo-gate"
expect "the main-push-gate section names gated-targets.sh" \
  "printf '%s' \"\$mpg_section\" | grep -q 'gated-targets.sh'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac7: ALL PASS"
else
  echo "xrepo_ac7: assertion(s) FAILED"
fi
exit "$fail"
