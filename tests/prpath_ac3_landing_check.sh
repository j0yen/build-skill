#!/usr/bin/env bash
# tests/prpath_ac3_landing_check.sh — PRD-build-main-push-gate-pr-path AC3.
#
# Given a landing record and a stub `gh pr view` returning MERGED with all
# required contexts SUCCESS and mergeCommit.oid=M, `landing-check` prints
# "merged M" and exits 0; one required context PENDING -> "pending" exit 3;
# one required context FAILURE named X -> "red X" exit 4; PR CLOSED
# unmerged -> "closed" exit 5. Each invocation makes exactly one `gh` call.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac3.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR"

work="$(prpath_mk_repo "$ROOT/repo")"
repo_slug="$(basename "$work")"
slug="fixture-slug"

mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"
cat > "$BUILD_STATE_DIR/landings/$repo_slug/$slug.json" <<EOF
{"pr_number": 42, "pr_url": "https://github.com/j0yen/$repo_slug/pull/42", "head_sha": "abc123", "armed_at": "2026-09-16T22:00:00Z"}
EOF

cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
export PATH="$bindir:$PATH"

run_case() {
  : > "$bindir/pr-view-calls.log"
  export PRPATH_GH_PR_JSON="$1"
  out="$("$PRPATH_BP" landing-check "$work" "$slug")"
  rc=$?
  calls="$(wc -l < "$bindir/pr-view-calls.log" | tr -d ' ')"
}

# --- merged, all required SUCCESS --------------------------------------
run_case '{"state":"MERGED","mergeCommit":{"oid":"deadbeef"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
prpath_expect "AC3: merged prints 'merged <sha>'" '[ "$out" = "merged deadbeef" ]'
prpath_expect "AC3: merged exits 0" '[ "$rc" -eq 0 ]'
prpath_expect "AC3: merged makes exactly one gh call" '[ "$calls" -eq 1 ]'

# --- one required context PENDING ---------------------------------------
run_case '{"state":"OPEN","mergeCommit":null,"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}]}'
prpath_expect "AC3: pending prints 'pending'" '[ "$out" = "pending" ]'
prpath_expect "AC3: pending exits 3" '[ "$rc" -eq 3 ]'
prpath_expect "AC3: pending makes exactly one gh call" '[ "$calls" -eq 1 ]'

# --- one required context FAILURE, named -------------------------------
run_case '{"state":"OPEN","mergeCommit":null,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}'
prpath_expect "AC3: red names the failing check" '[ "$out" = "red ci" ]'
prpath_expect "AC3: red exits 4" '[ "$rc" -eq 4 ]'
prpath_expect "AC3: red makes exactly one gh call" '[ "$calls" -eq 1 ]'

# --- PR CLOSED, unmerged --------------------------------------------------
run_case '{"state":"CLOSED","mergeCommit":null,"statusCheckRollup":[]}'
prpath_expect "AC3: closed prints 'closed'" '[ "$out" = "closed" ]'
prpath_expect "AC3: closed exits 5" '[ "$rc" -eq 5 ]'
prpath_expect "AC3: closed makes exactly one gh call" '[ "$calls" -eq 1 ]'

exit "$prpath_fail"
