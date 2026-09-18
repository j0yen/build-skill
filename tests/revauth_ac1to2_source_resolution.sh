#!/usr/bin/env bash
# tests/revauth_ac1to2_source_resolution.sh — PRD-build-reviewer-agent-
# auth-contract AC1/AC2 (test_prefix revauth).
#
#   AC1 — CLAUDE_CODE_OAUTH_TOKEN unset, REVIEWER_AUTH_FILE contains the
#         fixture token: the reviewer child sees it, the receipt has
#         auth_source="environment.d", and the gate summary line carries
#         reviewer_auth=environment.d.
#   AC2 — CLAUDE_CODE_OAUTH_TOKEN set in the environment: auth_source="env"
#         and REVIEWER_AUTH_FILE is never read (fixture file absent, no
#         error).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=revauth-common.sh
source "$HERE/revauth-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/revauth-ac1to2.XXXXXX")"
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
revauth_write_fixture_crate "$REPO"

echo "=== AC1: env unset, REVIEWER_AUTH_FILE has the fixture token ==="
AUTH_FILE="$T/90-claude-oauth.conf"
cat > "$AUTH_FILE" <<EOF
CLAUDE_CODE_OAUTH_TOKEN=$REVAUTH_TOKEN
EOF
JOURNAL1="$T/journal1.md"; : > "$JOURNAL1"
out1="$(
  unset CLAUDE_CODE_OAUTH_TOKEN
  export REVIEWER_AUTH_FILE="$AUTH_FILE" FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN"
  revauth_run_gate "$REPO" revauth-ac1-slug "$T/prds1" "$JOURNAL1" 2>&1
)"
rc1=$?
echo "$out1" >&2

rdir1="$REPO/target/autobuilder/receipts"
expect "AC1: extend-gate.sh ran the producer sequence (rc 0 or 1, never 9=incomplete)" "[ $rc1 -eq 0 ] || [ $rc1 -eq 1 ]"
expect "AC1: reviewer-agent.json has auth_source=environment.d" \
  "[ \"\$(jq -r '.auth_source // empty' '$rdir1/reviewer-agent.json' 2>/dev/null)\" = environment.d ]"
expect "AC1: reviewer-agent.json decision is pass (fake claude saw the token)" \
  "[ \"\$(jq -r '.decision // empty' '$rdir1/reviewer-agent.json' 2>/dev/null)\" = pass ]"
expect "AC1: journal line carries reviewer_auth=environment.d" \
  "grep -q 'reviewer_auth=environment.d' '$JOURNAL1'"

echo "=== AC2: CLAUDE_CODE_OAUTH_TOKEN set in the environment, no REVIEWER_AUTH_FILE ==="
JOURNAL2="$T/journal2.md"; : > "$JOURNAL2"
NO_SUCH_FILE="$T/no-such-90-claude-oauth.conf"
out2="$(
  export CLAUDE_CODE_OAUTH_TOKEN="$REVAUTH_TOKEN" REVIEWER_AUTH_FILE="$NO_SUCH_FILE" \
         FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN"
  revauth_run_gate "$REPO" revauth-ac2-slug "$T/prds2" "$JOURNAL2" 2>&1
)"
rc2=$?
echo "$out2" >&2

rdir2="$REPO/target/autobuilder/receipts"
expect "AC2: extend-gate.sh ran the producer sequence (rc 0 or 1, never 9=incomplete)" "[ $rc2 -eq 0 ] || [ $rc2 -eq 1 ]"
expect "AC2: reviewer-agent.json has auth_source=env" \
  "[ \"\$(jq -r '.auth_source // empty' '$rdir2/reviewer-agent.json' 2>/dev/null)\" = env ]"
expect "AC2: journal line carries reviewer_auth=env" \
  "grep -q 'reviewer_auth=env' '$JOURNAL2'"
expect "AC2: the (nonexistent) REVIEWER_AUTH_FILE was never created/touched by this run" \
  "[ ! -e '$NO_SUCH_FILE' ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "revauth_ac1to2_source_resolution: ALL PASS"
else
  echo "revauth_ac1to2_source_resolution: FAILED" >&2
fi
exit "$fail"
