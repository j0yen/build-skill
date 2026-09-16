#!/usr/bin/env bash
# repo-health-evidence.sh — one evidence blob per (repo, day), shared by
# alert-deliver.sh's banner line and repo-health-seed-prd.sh's `## Evidence`
# section (PRD-build-repo-health-invariants requirements 4 & 5). Built
# once per firing repo by manifest-invariants.sh rather than twice
# (banner vs PRD) so the two surfaces never disagree about what happened.
#
# Usage:
#   repo-health-evidence.sh <repo> <repo-health.json> [--journal <file>]...
#                            [--rule <rule>] [--value <n>] [--threshold <m>]
#
# Prints to stdout:
#   line 1: "value=<n> threshold=<m> — <one-line summary>" (the line
#           alert-deliver.sh's --evidence-file first line becomes the
#           banner text; --rule/--value/--threshold are optional context
#           for that summary, blank if omitted)
#   blank line
#   "CI: conclusion=<c> red_since=<ts> run_id=<id> head=<sha>
#    failing_job=<job>" (when the repo's ci block in repo-health.json is
#    non-stale; always emitted when available regardless of which rule
#    is firing, so every seeded PRD for this repo/day carries the CI run
#    id — AC5)
#   "Matching journal lines (last 20, any of ships/gate-attempts/
#    lock-wait):"
#   up to 20 journal lines (across all --journal files given, any of the
#   three repo-health regexes, whole-word repo match — same matching
#   logic as repo-health.sh compute, kept here rather than shared code
#   because this pass also needs the raw line TEXT, not just a count)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo="${1:-}"; health_json="${2:-}"
[ -n "$repo" ] && [ -n "$health_json" ] || {
  echo "usage: repo-health-evidence.sh <repo> <repo-health.json> [--journal <file>]... [--rule R] [--value N] [--threshold M]" >&2
  exit 2
}
shift 2

journals=()
rule=""; value=""; threshold=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --journal)   journals+=("$2"); shift 2 ;;
    --rule)      rule="$2"; shift 2 ;;
    --value)     value="$2"; shift 2 ;;
    --threshold) threshold="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

python3 - "$repo" "$health_json" "$rule" "$value" "$threshold" "${journals[@]}" <<'PYEOF'
import sys, re, json

repo, health_path, rule, value, threshold = sys.argv[1:6]
files = sys.argv[6:]

try:
    health = json.load(open(health_path))
except Exception:
    health = {}

row = (health.get("repos", {}) or {}).get(repo, {})
ci = row.get("ci", {}) or {}

summary = f"value={value or '?'} threshold={threshold or '?'}"
if rule:
    summary += f" — {rule} on {repo}"
print(summary)
print()

if ci.get("conclusion") not in (None, "unknown") and not health.get("ci_stale"):
    print(f"CI: conclusion={ci.get('conclusion')} red_since={ci.get('red_since')} "
          f"red_minutes={ci.get('red_minutes')} run_id={ci.get('run_id', '')} "
          f"head={ci.get('head_sha', '')} failing_job={ci.get('failing_job', '')}")

print("Matching journal lines (last 20, any of ships/gate-attempts/lock-wait):")

ship_re = re.compile(r'archive  shipped')
gate_re = re.compile(r'gate .*(block|pass|delta-pass)')
lock_re = re.compile(r'lock-contended|integrate lock|gate-pending-lock-contention|lock_wait_exhausted')
repo_word_re = re.compile(r'\b' + re.escape(repo) + r'\b')

matched = []
for path in files:
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            line = line.rstrip("\n")
            if not repo_word_re.search(line):
                continue
            if ship_re.search(line) or gate_re.search(line) or lock_re.search(line):
                matched.append(line)

for line in matched[-20:]:
    print(line)
PYEOF
