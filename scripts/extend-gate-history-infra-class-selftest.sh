#!/usr/bin/env bash
# extend-gate-history-infra-class-selftest.sh — PRD-build-diff-scoped-gate
# requirement 1 (P0, AC2): the two local history-infra producers
# (rollback-plan, ci-checks), when their block is a branch-scope
# artifact (head-untagged / push-disabled / push-failed / no-runs-on-ref)
# and gets rewritten pass+scope_deferred, also get `class: "history-infra"`
# on the receipt, so a `last-verdict.json` reader can tell WHY a deferred
# receipt was never allowed to block without re-deriving it from the
# skip_reason string.
#
# Unit-level: reproduces the exact jq filters extend-gate.sh runs at each
# of its three history-infra defer sites (rather than driving the full
# cargo/autobuilder fixture in extend-gate-scope-selftest.sh, which this
# sandbox's isolated BUILD_TEST_ROOT cannot satisfy — rustbuild's
# extended-receipts.sh is outside the test root's HOME, a pre-existing
# gap unrelated to this change; confirmed failing identically on
# unmodified main).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -f "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# 1. rollback-plan in-place rewrite (extend-gate.sh's rollback_deferred branch).
rb_in='{"schema":"autobuilder.rollback_plan_receipt.v1","verdict":"block","block_reason":"head-untagged","head_sha":"deadbeef"}'
rb_out="$(jq -n --argjson r "$rb_in" '$r | .verdict = "pass" | .scope_deferred = true | .class = "history-infra"')"
expect "rollback-plan defer sets verdict=pass"        '[ "$(jq -r .verdict <<<"$rb_out")" = pass ]'
expect "rollback-plan defer sets scope_deferred=true" '[ "$(jq -r .scope_deferred <<<"$rb_out")" = true ]'
expect "rollback-plan defer sets class=history-infra"  '[ "$(jq -r .class <<<"$rb_out")" = history-infra ]'

# 2. ci-checks synthesized defer receipt (write_ci_defer_receipt's jq -n template).
ci_out="$(jq -n --arg head deadbeef --arg reason "push-disabled: test" '{
  schema: "autobuilder.ci_checks_receipt.v1",
  head_sha: $head, repo: "", run_count: 0, success_count: 0,
  failure_count: 0, pending_count: 0, runs: [],
  verdict: "pass", scope_deferred: true, class: "history-infra", skip_reason: $reason,
  captured_at: (now | todateiso8601), receipt_digest: ""
}')"
expect "ci-checks synth defer sets verdict=pass"        '[ "$(jq -r .verdict <<<"$ci_out")" = pass ]'
expect "ci-checks synth defer sets class=history-infra" '[ "$(jq -r .class <<<"$ci_out")" = history-infra ]'

# 3. ci-checks in-place rewrite (the run_count==0-with-a-written-receipt branch).
ci_in='{"schema":"autobuilder.ci_checks_receipt.v1","verdict":"block","run_count":0}'
ci_rw_out="$(jq -n --argjson r "$ci_in" '$r | .verdict = "pass" | .scope_deferred = true | .class = "history-infra"')"
expect "ci-checks in-place defer sets class=history-infra" '[ "$(jq -r .class <<<"$ci_rw_out")" = history-infra ]'

# Guard against drift: the exact filter strings above must still appear
# verbatim in extend-gate.sh, so this selftest fails loudly if a future
# edit changes the filter without updating this test.
expect "rollback-plan filter string present verbatim in extend-gate.sh" \
  'grep -qF '"'"'.verdict = "pass" | .scope_deferred = true | .class = "history-infra"'"'"' "$EXTEND_GATE"'
expect "ci-checks synth-defer class field present verbatim in extend-gate.sh" \
  'grep -qF '"'"'verdict: "pass", scope_deferred: true, class: "history-infra", skip_reason: $reason'"'"' "$EXTEND_GATE"'

exit "$fail"
