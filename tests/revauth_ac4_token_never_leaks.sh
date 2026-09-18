#!/usr/bin/env bash
# tests/revauth_ac4_token_never_leaks.sh — PRD-build-reviewer-agent-auth-
# contract AC4 (test_prefix revauth).
#
#   AC4 — given the fixture token value, when any gate run completes
#         (pass, block, or incomplete), grep -r <fixture> over the
#         journal, target/autobuilder/, $raw, $raw.err, and the gate's own
#         stdout/stderr finds zero hits. Exercised on BOTH a run where the
#         token resolves and is actually used (pass path) and one where it
#         does not (auth-missing path).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=revauth-common.sh
source "$HERE/revauth-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

sweep_for_token() {  # $1=label $2=repo $3=journal $4=stdout-capture-file
  local label="$1" repo="$2" journal="$3" capture="$4"
  local hits
  hits="$(grep -rlF "$REVAUTH_TOKEN" "$repo/target/autobuilder" "$journal" "$capture" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "  LEAK ($label): token prefix found in:" >&2
    printf '%s\n' "$hits" >&2
  fi
  expect "$label: fixture token never appears in journal/target/autobuilder/gate output" "[ -z '$hits' ]"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/revauth-ac4.XXXXXX")"
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

echo "=== AC4a: token resolves and is used (pass path) ==="
REPO_A="$T/repo-a"
revauth_write_fixture_crate "$REPO_A"
AUTH_FILE_A="$T/90-claude-oauth-a.conf"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$REVAUTH_TOKEN" > "$AUTH_FILE_A"
JOURNAL_A="$T/journal-a.md"; : > "$JOURNAL_A"
CAPTURE_A="$T/capture-a.log"
(
  unset CLAUDE_CODE_OAUTH_TOKEN
  export REVIEWER_AUTH_FILE="$AUTH_FILE_A" FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN"
  revauth_run_gate "$REPO_A" revauth-ac4a-slug "$T/prds-a" "$JOURNAL_A"
) >"$CAPTURE_A" 2>&1
rc_a=$?
cat "$CAPTURE_A" >&2
expect "AC4a: gate ran (rc 0 or 1)" "[ $rc_a -eq 0 ] || [ $rc_a -eq 1 ]"
sweep_for_token "AC4a" "$REPO_A" "$JOURNAL_A" "$CAPTURE_A"
# the fixture's own auth-file, and $raw/$raw.err specifically, are the two
# artefacts most likely to disagree with the sweep above if the merge/env
# scoping regresses -- checked directly too.
expect "AC4a: review-output.raw.txt (if written) does not carry the token" \
  "! grep -qF '$REVAUTH_TOKEN' '$REPO_A/target/autobuilder/review-output.raw.txt' 2>/dev/null"
expect "AC4a: review-output.raw.txt.err (if written) does not carry the token" \
  "! grep -qF '$REVAUTH_TOKEN' '$REPO_A/target/autobuilder/review-output.raw.txt.err' 2>/dev/null"

echo "=== AC4b: no source yields a token (auth-missing path) ==="
REPO_B="$T/repo-b"
revauth_write_fixture_crate "$REPO_B"
JOURNAL_B="$T/journal-b.md"; : > "$JOURNAL_B"
CAPTURE_B="$T/capture-b.log"
(
  unset CLAUDE_CODE_OAUTH_TOKEN
  export REVIEWER_AUTH_FILE="$T/no-such-file.conf" FAKE_REVAUTH_EXPECTED_TOKEN="$REVAUTH_TOKEN"
  revauth_run_gate "$REPO_B" revauth-ac4b-slug "$T/prds-b" "$JOURNAL_B"
) >"$CAPTURE_B" 2>&1
rc_b=$?
cat "$CAPTURE_B" >&2
expect "AC4b: gate ended incomplete (rc 9, auth-missing)" "[ $rc_b -eq 9 ]"
sweep_for_token "AC4b" "$REPO_B" "$JOURNAL_B" "$CAPTURE_B"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "revauth_ac4_token_never_leaks: ALL PASS"
else
  echo "revauth_ac4_token_never_leaks: FAILED" >&2
fi
exit "$fail"
