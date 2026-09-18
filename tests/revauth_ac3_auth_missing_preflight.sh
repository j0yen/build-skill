#!/usr/bin/env bash
# tests/revauth_ac3_auth_missing_preflight.sh — PRD-build-reviewer-agent-
# auth-contract AC3 (test_prefix revauth).
#
#   AC3 — no source yields a token (env unset, REVIEWER_AUTH_FILE absent,
#         systemctl double answers with none) and the fake `claude` prints
#         the real incident text on stdout with exit 1: the gate ends
#         outcome=incomplete infra=reviewer-agent:auth-missing, `phases=`
#         names no receipt-producer phase, wall time <= 90s, and the
#         reviewer-agent.json's skip_reason starts with
#         infra:reviewer-agent:auth-missing: and lists
#         env,environment.d:<path>,systemctl as the sources checked.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=revauth-common.sh
source "$HERE/revauth-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/revauth-ac3.XXXXXX")"
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
revauth_write_fixture_crate "$REPO"

AUTH_FILE="$T/no-such-90-claude-oauth.conf"
JOURNAL="$T/journal.md"; : > "$JOURNAL"

t0=$(date +%s)
out="$(
  unset CLAUDE_CODE_OAUTH_TOKEN
  export REVIEWER_AUTH_FILE="$AUTH_FILE" FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN"
  revauth_run_gate "$REPO" revauth-ac3-slug "$T/prds" "$JOURNAL" 2>&1
)"
rc=$?
t1=$(date +%s)
echo "$out" >&2

expect "AC3: extend-gate.sh exits 9 (incomplete)" "[ $rc -eq 9 ]"
expect "AC3: wall time under 90s" "[ $((t1 - t0)) -lt 90 ]"

line="$(tail -1 "$JOURNAL")"
expect "AC3: journal line reads outcome=incomplete" "printf '%s' '$line' | grep -q '  incomplete  '"
expect "AC3: journal line carries infra=reviewer-agent:auth-missing" \
  "printf '%s' '$line' | grep -q 'infra=reviewer-agent:auth-missing'"
expect "AC3: journal line's phases= field names no receipt-producer phase" \
  "! printf '%s' '$line' | grep -oE 'phases=[^ ]*' | grep -qE 'risk-gate|intake|proof-receipt|vti-plan|rollback-plan|ci-checks|receipts:'"
expect "AC3: journal line carries reviewer_auth=none" "printf '%s' '$line' | grep -q 'reviewer_auth=none'"

rdir="$REPO/target/autobuilder/receipts"
skip_reason="$(jq -r '.skip_reason // empty' "$rdir/reviewer-agent.json" 2>/dev/null)"
echo "  skip_reason: $skip_reason"
expect "AC3: reviewer-agent.json skip_reason starts with infra:reviewer-agent:auth-missing:" \
  "[[ '$skip_reason' == infra:reviewer-agent:auth-missing:* ]]"
expect "AC3: skip_reason lists env, environment.d:<path>, systemctl as the sources checked" \
  "[[ '$skip_reason' == *'env,environment.d:'*',systemctl'* ]]"

expect "AC3: no other receipt producer ever ran (no receipts dir besides reviewer-agent.json)" \
  "[ \"\$(find '$rdir' -type f ! -name reviewer-agent.json 2>/dev/null | wc -l)\" -eq 0 ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "revauth_ac3_auth_missing_preflight: ALL PASS"
else
  echo "revauth_ac3_auth_missing_preflight: FAILED" >&2
fi
exit "$fail"
