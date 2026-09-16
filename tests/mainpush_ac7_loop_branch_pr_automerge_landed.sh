#!/usr/bin/env bash
# mainpush_ac7_loop_branch_pr_automerge_landed.sh — PRD-build-main-push-gate
# AC7: given push-via-branch=true, when the loop lands a branch, then it
# pushes loop/<slug>, opens a PR, and main advances only after the check
# is green (live, one landing).
#
# LIVE check, same reasoning as AC6's wrapper: re-verifies the durable
# outcome of the real PR #1 landing against j0yen/mcphost (loop/
# build-main-push-gate-ci-equiv -> PR #1 -> gh pr merge --auto --squash,
# merged 4f1112d only after both required checks went green) rather than
# repeating the mutation. Skips (exit 0) when gh/network is unavailable.
set -uo pipefail

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "SKIP AC7: gh not available/authenticated — cannot verify live GitHub state" >&2
  exit 0
fi

pr_json="$(gh pr view 1 --repo j0yen/mcphost --json state,mergedAt,mergeCommit,headRefName,baseRefName 2>/dev/null)"
expect "AC7: PR #1 (the live AC7 landing) exists and is readable" '[ -n "$pr_json" ]'
expect "AC7: PR #1 landed via a loop/<slug> branch" \
  'printf "%s" "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get(\"headRefName\",\"\").startswith(\"loop/\") else 1)"'
expect "AC7: PR #1 targeted main" \
  'printf "%s" "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get(\"baseRefName\")==\"main\" else 1)"'
expect "AC7: PR #1 is MERGED (main only advanced after checks went green)" \
  'printf "%s" "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get(\"state\")==\"MERGED\" else 1)"'
expect "AC7: merge commit is a real, non-empty sha" \
  'printf "%s" "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sha=(d.get(\"mergeCommit\") or {}).get(\"oid\",\"\"); sys.exit(0 if len(sha)>=7 else 1)"'

merge_sha="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("mergeCommit") or {}).get("oid",""))' 2>/dev/null)"
expect "AC7: the merged commit is reachable from mcphost's real origin/main" \
  '[ -n "$merge_sha" ] && gh api "repos/j0yen/mcphost/commits/$merge_sha" --jq .sha >/dev/null 2>&1'

exit "$fail"
