#!/usr/bin/env bash
# opauth_ac4_dispatch_injects_directive.sh —
# PRD-build-operator-authorization-contract AC4.
#
# Given a PRD carrying `Operator-authorization:`, When the coordinator
# dispatches its branch agent, Then the branch prompt contains the
# authorization string verbatim plus the instruction that an in-scope AC is
# executed, not deferred, and that deferring it requires citing the scope
# mismatch. SKILL.md's `### Dispatch` section is the source of that
# per-branch prompt text (prose, not runnable code — see the rustbuild-PATH/
# cargo-budget directives it sits beside for the established convention of
# testing this kind of directive by grepping its exact required wording).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../SKILL.md"

fail=0

# SKILL.md prose wraps at ~80 cols, so the directive's exact sentence may
# be split across source lines; flatten whitespace before matching so this
# check tracks the rendered text, not this file's line-wrap choices.
flat="$(tr -s '[:space:]' ' ' < "$SKILL")"

grep -qF 'This PRD carries an operator authorization: `Operator-authorization: <the line, verbatim>`' <<<"$flat" \
  && echo "ok  AC4: directive injects the authorization line verbatim" \
  || { echo "FAIL: directive text for verbatim injection not found in SKILL.md" >&2; fail=1; }

grep -qF 'An AC whose action falls within this scope is executed, not deferred.' <<<"$flat" \
  && echo "ok  AC4: directive states in-scope AC is executed, not deferred" \
  || { echo "FAIL: 'executed, not deferred' instruction not found in SKILL.md" >&2; fail=1; }

grep -qF 'Deferring it requires citing, in the deferral text, why the action falls outside the scope string above.' <<<"$flat" \
  && echo "ok  AC4: directive requires citing the scope mismatch to defer" \
  || { echo "FAIL: scope-mismatch citation requirement not found in SKILL.md" >&2; fail=1; }

# The directive must actually be wired into the per-branch prompt checklist
# ("Each agent prompt must include, self-contained:"), not just described
# in prose above it — else it is display-only, the exact bug this PRD fixes.
awk '/Each agent prompt must include, self-contained:/,0' "$SKILL" \
  | grep -qF 'Operator-authorization:' \
  && echo "ok  AC4: the per-branch prompt checklist itself carries the directive" \
  || { echo "FAIL: prompt checklist (after 'Each agent prompt must include') has no Operator-authorization bullet" >&2; fail=1; }

exit $fail
