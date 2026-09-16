#!/usr/bin/env bash
# tests/bgscope_ac10_skillmd_documents_scope_policy.sh — PRD-build-branch-
# gate-scope-artifacts requirement 8 (P1) / AC10: "Given SKILL.md after
# land, When grepped, Then the rust-extend sequence names the scope
# policy for rollback-plan, ci-checks, and reviewer-agent at branch scope
# and states that land re-runs deferrals."
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_MD="$HERE/../SKILL.md"
[ -f "$SKILL_MD" ] || { echo "selftest: $SKILL_MD not found" >&2; exit 2; }

fail=0
# Not eval-based on purpose: the extracted section is markdown containing
# backticks/parens (code spans), which `eval`'d inside a cond string would
# get re-parsed as command substitution / subshells. Grep a FILE instead
# of embedding the section's raw content in any string that's ever eval'd.
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bgscope-ac10-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SECTION="$T/section.md"

echo "=== AC10: SKILL.md's rust-extend sequence documents the branch-scope policy ==="
sed -n '/Branch-scope policy (PRD-build-branch-gate-scope-artifacts)/,/Post-land main check is now a cache hit/p' "$SKILL_MD" > "$SECTION"

if [ -s "$SECTION" ]; then ok "the branch-scope policy section exists"; else bad "the branch-scope policy section exists"; fi
if grep -q 'rollback-plan' "$SECTION"; then ok "it names rollback-plan's deferral rule"; else bad "it names rollback-plan's deferral rule"; fi
if grep -q 'no-runs-on-ref' "$SECTION"; then ok "it names ci-checks' deferral rule (BRANCH_GATE_PUSH / no-runs-on-ref)"; else bad "it names ci-checks' deferral rule (BRANCH_GATE_PUSH / no-runs-on-ref)"; fi
if grep -q 'reviewer-agent' "$SECTION"; then ok "it names reviewer-agent's branch-scope-always-runs rule"; else bad "it names reviewer-agent's branch-scope-always-runs rule"; fi
if grep -qi 'land.*re-runs' "$SECTION"; then ok "it states land re-runs deferrals at main scope"; else bad "it states land re-runs deferrals at main scope"; fi

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac10: ALL PASS"; else echo "bgscope_ac10: assertion(s) FAILED"; fi
exit "$fail"
