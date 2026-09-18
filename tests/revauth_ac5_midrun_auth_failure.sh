#!/usr/bin/env bash
# tests/revauth_ac5_midrun_auth_failure.sh — PRD-build-reviewer-agent-
# auth-contract AC5 (test_prefix revauth).
#
#   AC5 — the preflight probe succeeds (call #1 of the fake `claude`), but
#         the REAL reviewer call (call #2) prints "Failed to authenticate"
#         on stdout with exit 1 (token revoked mid-run, simulated by the
#         double's own call counter). The reviewer-agent.json this run
#         writes carries a skip_reason naming "auth failed (source=...)"
#         and the real error text, and its infra_detail carries the
#         stdout text even though stderr was empty (extend-gate.sh's own
#         .err-only read is exactly the pre-PRD bug this proves fixed).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=revauth-common.sh
source "$HERE/revauth-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/revauth-ac5.XXXXXX")"
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
revauth_write_fixture_crate "$REPO"

AUTH_FILE="$T/90-claude-oauth.conf"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$REVAUTH_TOKEN" > "$AUTH_FILE"
JOURNAL="$T/journal.md"; : > "$JOURNAL"
COUNTER="$T/call-counter"; : > "$COUNTER"

out="$(
  unset CLAUDE_CODE_OAUTH_TOKEN
  export REVIEWER_AUTH_FILE="$AUTH_FILE" FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN" \
         FAKE_REVAUTH_CALL_COUNTER="$COUNTER" FAKE_REVAUTH_FAIL_ON_CALL=2
  revauth_run_gate "$REPO" revauth-ac5-slug "$T/prds" "$JOURNAL" 2>&1
)"
rc=$?
echo "$out" >&2

expect "AC5: the probe (call 1) and the real reviewer (call 2) both ran" "[ \"\$(cat '$COUNTER' 2>/dev/null)\" -ge 2 ]"
line_early="$(tail -1 "$JOURNAL")"
expect "AC5: the preflight probe itself passed (other producers ran too — risk-gate/intake appear in phases=)" \
  "printf '%s' '$line_early' | grep -oE 'phases=[^ ]*' | grep -q 'risk-gate'"
expect "AC5: extend-gate.sh's own outcome is incomplete (rc 9) — the mid-run auth failure, not the preflight, is what caught this" \
  "[ $rc -eq 9 ]"

rdir="$REPO/target/autobuilder/receipts"
skip_reason="$(jq -r '.skip_reason // empty' "$rdir/reviewer-agent.json" 2>/dev/null)"
infra_detail="$(jq -r '.infra_detail // empty' "$rdir/reviewer-agent.json" 2>/dev/null)"
echo "  skip_reason: $skip_reason"
echo "  infra_detail: $infra_detail"

expect "AC5: skip_reason names the auth phase (reviewer-agent:auth-missing)" \
  "[[ '$skip_reason' == infra:reviewer-agent:auth-missing:* ]]"
expect "AC5: skip_reason's note reads 'auth failed (source=environment.d)'" \
  "[[ '$skip_reason' == *'auth failed (source=environment.d)'* ]]"
expect "AC5: skip_reason carries the real incident error text" \
  "[[ '$skip_reason' == *'Failed to authenticate: OAuth session expired and could not be refreshed'* ]]"
expect "AC5: infra_detail carries the stdout text even though stderr was empty" \
  "[[ '$infra_detail' == *'Failed to authenticate'* ]]"

line="$(tail -1 "$JOURNAL")"
expect "AC5: journal line carries infra=reviewer-agent:auth-missing" \
  "printf '%s' '$line' | grep -q 'infra=reviewer-agent:auth-missing'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "revauth_ac5_midrun_auth_failure: ALL PASS"
else
  echo "revauth_ac5_midrun_auth_failure: FAILED" >&2
fi
exit "$fail"
