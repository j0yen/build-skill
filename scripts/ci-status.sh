#!/usr/bin/env bash
# ci-status.sh — one-line-per-repo fleet CI report (PRD-fleet-ci-green).
#
# For each fleet repo: workflow present y/n, total runs, latest run's
# conclusion, and the latest run's age. A reporter, not a gate — always
# exits 0, even when `gh` is missing/unauthenticated or a repo has no
# workflow at all (those print as best-effort rows, never abort the loop).
#
# Usage: scripts/ci-status.sh [owner]   # owner defaults to j0yen
set -uo pipefail

OWNER="${1:-j0yen}"
REPOS=(agorabus rustbuild autobuilder wm-node adopt summa mcphost)

if ! command -v gh >/dev/null 2>&1; then
  echo "ci-status: gh CLI not found on PATH — cannot query GitHub Actions" >&2
  exit 0
fi

age_of() {
  # $1 = ISO8601 UTC timestamp. Prints "<n>h" / "<n>d" best-effort.
  local ts="$1" then now diff
  then="$(date -u -d "$ts" +%s 2>/dev/null)" || { echo "?"; return; }
  now="$(date -u +%s)"
  diff=$(( now - then ))
  if [ "$diff" -lt 0 ]; then diff=0; fi
  if [ "$diff" -lt 86400 ]; then
    echo "$(( diff / 3600 ))h"
  else
    echo "$(( diff / 86400 ))d"
  fi
}

printf '%-14s %-10s %8s %-12s %s\n' "repo" "workflow" "runs" "latest" "age"
for repo in "${REPOS[@]}"; do
  wf_json="$(gh api "repos/${OWNER}/${repo}/actions/workflows" 2>/dev/null)"
  if [ -z "$wf_json" ]; then
    printf '%-14s %-10s %8s %-12s %s\n' "$repo" "n/a" "-" "no-repo/err" "-"
    continue
  fi
  wf_count="$(echo "$wf_json" | grep -o '"total_count":[0-9]*' | head -1 | cut -d: -f2)"
  if [ -z "$wf_count" ] || [ "$wf_count" = "0" ]; then
    printf '%-14s %-10s %8s %-12s %s\n' "$repo" "n" "0" "-" "-"
    continue
  fi

  runs_json="$(gh api "repos/${OWNER}/${repo}/actions/runs?per_page=1" 2>/dev/null)"
  total_runs="$(echo "$runs_json" | grep -o '"total_count":[0-9]*' | head -1 | cut -d: -f2)"
  total_runs="${total_runs:-0}"

  if [ "$total_runs" = "0" ]; then
    printf '%-14s %-10s %8s %-12s %s\n' "$repo" "y" "0" "never-run" "-"
    continue
  fi

  conclusion="$(gh api "repos/${OWNER}/${repo}/actions/runs?per_page=1" --jq '.workflow_runs[0].conclusion // .workflow_runs[0].status // "unknown"' 2>/dev/null)"
  created_at="$(gh api "repos/${OWNER}/${repo}/actions/runs?per_page=1" --jq '.workflow_runs[0].created_at // empty' 2>/dev/null)"
  age="-"
  [ -n "$created_at" ] && age="$(age_of "$created_at")"
  printf '%-14s %-10s %8s %-12s %s\n' "$repo" "y" "$total_runs" "${conclusion:-unknown}" "$age"
done

exit 0
