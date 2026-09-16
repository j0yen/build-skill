#!/usr/bin/env bash
# ci-status.sh — one-line-per-repo fleet CI report (PRD-fleet-ci-green),
# plus a `--json` machine-readable snapshot (PRD-build-repo-health-
# invariants requirement 6).
#
# The table mode (default, unchanged since PRD-fleet-ci-green) is a
# reporter, not a gate — always exits 0, even when `gh` is missing/
# unauthenticated or a repo has no workflow at all.
#
# `--json` mode writes state/ci-status.json (one row per repo in
# scripts/lib/fleet-repos.sh's FLEET_REPOS, the same list ci-status.sh's
# table mode has always used): {conclusion, red_since, head_sha, run_id,
# created_at, failing_job}. It is the file `repo-health.sh compute` reads
# instead of shelling out to `gh` itself — `gh` runs only here, under the
# timer, never inside the invariant (Technical considerations: "the
# invariant never calls the network, so --report stays offline and
# deterministic").
#
# red_since tracking: a repo whose latest run is red (failure/timed_out)
# and whose PREVIOUS snapshot row was also red keeps that previous row's
# red_since unchanged (the streak's original onset) even though the run_id
# changes on every retry-push; a repo newly gone red this poll gets
# red_since = this run's own created_at (the run that turned it red, not
# "now" — "now" would drift later on every 10-minute poll and understate
# how long main has actually been red). A repo that goes green clears
# red_since to null. This requires reading the file this run is about to
# overwrite, once, before writing.
#
# Usage:
#   scripts/ci-status.sh [owner]              # table mode (unchanged)
#   scripts/ci-status.sh --json [owner]        # writes state/ci-status.json
#
# Env: BUILD_STATE_DIR (state dir; default $SKILL_DIR/state),
#      CI_STATUS_OUT (json output path override, default
#      $BUILD_STATE_DIR/ci-status.json — the selftest sandbox knob).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
OUT="${CI_STATUS_OUT:-$STATE_DIR/ci-status.json}"

# shellcheck source=lib/fleet-repos.sh
source "$HERE/lib/fleet-repos.sh"

json_mode=false
OWNER="j0yen"
for arg in "$@"; do
  case "$arg" in
    --json) json_mode=true ;;
    *) OWNER="$arg" ;;
  esac
done
REPOS=("${FLEET_REPOS[@]}")

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

RED_CONCLUSIONS="failure timed_out"
is_red() {
  local c="$1" w
  for w in $RED_CONCLUSIONS; do [ "$c" = "$w" ] && return 0; done
  return 1
}

if $json_mode; then
  mkdir -p "$STATE_DIR"
  prev_json="{}"
  [ -r "$OUT" ] && prev_json="$(cat "$OUT" 2>/dev/null || echo '{}')"

  ndjson_tmp="$(mktemp)"
  trap 'rm -f "$ndjson_tmp"' EXIT

  for repo in "${REPOS[@]}"; do
    wf_json="$(gh api "repos/${OWNER}/${repo}/actions/workflows" 2>/dev/null)"
    if [ -z "$wf_json" ]; then
      python3 -c 'import json,sys
print(json.dumps({"repo": sys.argv[1], "workflow": False, "runs": 0,
                   "conclusion": "unknown", "head_sha": None, "run_id": None,
                   "created_at": None, "failing_job": None, "red_since": None}))' \
        "$repo" >> "$ndjson_tmp"
      continue
    fi
    wf_count="$(echo "$wf_json" | grep -o '"total_count":[0-9]*' | head -1 | cut -d: -f2)"
    if [ -z "$wf_count" ] || [ "$wf_count" = "0" ]; then
      python3 -c 'import json,sys
print(json.dumps({"repo": sys.argv[1], "workflow": False, "runs": 0,
                   "conclusion": "unknown", "head_sha": None, "run_id": None,
                   "created_at": None, "failing_job": None, "red_since": None}))' \
        "$repo" >> "$ndjson_tmp"
      continue
    fi

    runs_json="$(gh api "repos/${OWNER}/${repo}/actions/runs?per_page=1" 2>/dev/null)"
    total_runs="$(echo "$runs_json" | grep -o '"total_count":[0-9]*' | head -1 | cut -d: -f2)"
    total_runs="${total_runs:-0}"

    if [ "$total_runs" = "0" ]; then
      python3 -c 'import json,sys
print(json.dumps({"repo": sys.argv[1], "workflow": True, "runs": 0,
                   "conclusion": "unknown", "head_sha": None, "run_id": None,
                   "created_at": None, "failing_job": None, "red_since": None}))' \
        "$repo" >> "$ndjson_tmp"
      continue
    fi

    conclusion="$(echo "$runs_json" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    r=d.get("workflow_runs",[{}])[0]
    print(r.get("conclusion") or r.get("status") or "unknown")
except Exception:
    print("unknown")')"
    head_sha="$(echo "$runs_json" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("workflow_runs",[{}])[0].get("head_sha") or "")
except Exception:
    print("")')"
    run_id="$(echo "$runs_json" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("workflow_runs",[{}])[0].get("id") or "")
except Exception:
    print("")')"
    created_at="$(echo "$runs_json" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("workflow_runs",[{}])[0].get("created_at") or "")
except Exception:
    print("")')"

    failing_job=""
    if is_red "$conclusion" && [ -n "$run_id" ]; then
      failing_job="$(gh api "repos/${OWNER}/${repo}/actions/runs/${run_id}/jobs" 2>/dev/null | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for j in d.get("jobs", []):
        if j.get("conclusion") == "failure":
            print(j.get("name") or "")
            break
except Exception:
    pass')"
    fi

    red_since=""
    if is_red "$conclusion"; then
      prev_row="$(python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1]); r=d.get("rows",{}).get(sys.argv[2],{})
    print(json.dumps(r))
except Exception:
    print("{}")' "$prev_json" "$repo")"
      red_since="$(python3 -c 'import json,sys
r=json.loads(sys.argv[1])
if r.get("conclusion") in ("failure","timed_out") and r.get("red_since"):
    print(r["red_since"])
else:
    print(sys.argv[2])' "$prev_row" "$created_at")"
    fi

    python3 -c 'import json,sys
repo, workflow, runs, conclusion, head_sha, run_id, created_at, failing_job, red_since = sys.argv[1:10]
print(json.dumps({
  "repo": repo, "workflow": workflow == "y", "runs": int(runs or 0),
  "conclusion": conclusion or "unknown",
  "head_sha": head_sha or None, "run_id": int(run_id) if run_id else None,
  "created_at": created_at or None,
  "failing_job": failing_job or None,
  "red_since": red_since or None,
}))' "$repo" "y" "$total_runs" "$conclusion" "$head_sha" "$run_id" "$created_at" "$failing_job" "$red_since" \
      >> "$ndjson_tmp"
  done

  python3 -c 'import json,sys,datetime
rows={}
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    r=json.loads(line)
    rows[r.pop("repo")]=r
out={"generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
     "owner": sys.argv[2], "rows": rows}
tmp=sys.argv[3]+".tmp"
with open(tmp,"w") as f:
    json.dump(out,f,indent=2)
    f.write("\n")
import os
os.rename(tmp, sys.argv[3])' "$ndjson_tmp" "$OWNER" "$OUT"

  echo "ci-status: wrote $OUT" >&2
  exit 0
fi

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
