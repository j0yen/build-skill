#!/usr/bin/env bash
# repo-health.sh — per-repo health counters + rule evaluation
# (PRD-build-repo-health-invariants).
#
# The loop's only success signal was a branch gate verdict — a red main, a
# ship-less repo-day, and a retry storm were each visible in the journal
# and invisible to every check the loop ran (09-12..09-15 mcphost: nine
# red-main hours, two one-ship days, 358 lock-wait lines, zero alarms).
# This script is the file `manifest-invariants.sh` reads instead of a
# human reading logs: three rules, computed from files only, no model call.
#
# Usage:
#   repo-health.sh compute [--journal <file>]... [--ci <path>]
#                           [--as-of <ISO-ts>] [--out <path>]
#
# --journal   May be given more than once; each file is scanned in full
#             (no assumption about which file holds which day — the
#             as-of/window math is what scopes lines to "24h ago", not
#             which file they came from). Default: today's + yesterday's
#             production journal ($JOURNAL_ROOT/<date>.md for as-of's date
#             and the day before), so a bare `compute` with no --journal
#             covers a real tick's needs.
# --ci        Path to ci-status.json (default $STATE_DIR/ci-status.json,
#             the file scripts/ci-status.sh --json writes).
# --as-of     ISO-8601 UTC timestamp fixing "now" (default: real now) —
#             the test seam that makes journal replay deterministic.
# --out       Output path (default $STATE_DIR/repo-health.json).
#
# Counters (one 24h window, ending at --as-of, shared by all three —
# "no-ship-with-attempts" and "lock-wait-storm" are both framed as
# per-day in the PRD; using one window keeps the three numbers
# mutually comparable instead of secretly disagreeing on what "recent"
# means):
#   ships_24h            lines matching SHIP_REGEX
#   gate_attempts_24h    lines matching GATE_REGEX
#   lock_wait_lines_24h  lines matching LOCK_REGEX
# A line counts toward repo R iff it ALSO contains R as a whole word
# (\bR\b) — PRD slugs are conventionally prefixed by their target repo
# (`mcphost-tenant-tables`, word-bounded by the following `-`) and
# gate-verdict lines print the repo name as a literal field
# (`gate  mcphost  block  ...`), so a whole-word match on the repo name
# catches both line shapes without a slug->repo lookup table this script
# would otherwise have to keep in sync with the fleet roster by hand.
#
# Rules (env-tunable; PRD requirement 2). Setting any threshold to 0
# disables that rule: it is skipped entirely (never fires, not even on a
# huge count) and the rule name is added to the output's
# "rules_disabled" list, which manifest-invariants.sh journals once as
# `rule-disabled`.
#   REPO_CI_RED_MIN=30      main-ci-red        fires when ci.conclusion is
#                                              red and red_minutes >= this
#   REPO_NO_SHIP_H=24       no-ship-with-attempts window (hours)
#   REPO_MIN_ATTEMPTS=3     no-ship-with-attempts   fires when ships_24h==0
#                                              AND gate_attempts_24h >= this
#   REPO_LOCK_WAIT_MAX=100  lock-wait-storm    fires when
#                                              lock_wait_lines_24h > this
#
# ci-status.json staleness (requirement 6 / AC6): a file whose own
# "generated_at" is more than 30 minutes older than --as-of is treated as
# unknown for EVERY repo (never as green) — the output's top-level
# "ci_stale" is true and "ci_stale_age_s" names the age in seconds, so
# manifest-invariants.sh can journal `ci-status-stale` naming it. A
# missing/unparseable ci-status.json file is the same as maximally stale.
#
# Output: $STATE_DIR/repo-health.json —
#   {"generated_at":..., "as_of":..., "ci_stale":bool,
#    "ci_stale_age_s":n|null, "rules_disabled":[...],
#    "repos": {"<repo>": {"ci":{"conclusion","red_since","red_minutes",
#                                "run_id","head_sha","failing_job"},
#                          "ships_24h","gate_attempts_24h",
#                          "lock_wait_lines_24h","alarms":[...]}}}
#
# Exit: 0 always (a reporter; a missing/malformed --ci or --journal file
# degrades that input, it does not abort the compute) | 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
JOURNAL_ROOT="${BUILD_JOURNAL_ROOT:-$HOME/brain/journal/build}"

# shellcheck source=lib/fleet-repos.sh
source "$HERE/lib/fleet-repos.sh"

REPO_CI_RED_MIN="${REPO_CI_RED_MIN:-30}"
REPO_NO_SHIP_H="${REPO_NO_SHIP_H:-24}"
REPO_MIN_ATTEMPTS="${REPO_MIN_ATTEMPTS:-3}"
REPO_LOCK_WAIT_MAX="${REPO_LOCK_WAIT_MAX:-100}"

log() { printf 'repo-health: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

cmd="${1:-}"
[ "$cmd" = "compute" ] || die "usage: repo-health.sh compute [--journal <file>]... [--ci <path>] [--as-of <ts>] [--out <path>]" 2
shift

journals=()
ci_path="$STATE_DIR/ci-status.json"
as_of=""
out="$STATE_DIR/repo-health.json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --journal) journals+=("$2"); shift 2 ;;
    --ci)      ci_path="$2"; shift 2 ;;
    --as-of)   as_of="$2"; shift 2 ;;
    --out)     out="$2"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

[ -n "$as_of" ] || as_of="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "${#journals[@]}" -eq 0 ]; then
  as_of_date="${as_of%%T*}"
  yday_date="$(date -u -d "$as_of_date -1 day" +%F 2>/dev/null || echo "$as_of_date")"
  for f in "$JOURNAL_ROOT/$as_of_date.md" "$JOURNAL_ROOT/$yday_date.md"; do
    [ -f "$f" ] && journals+=("$f")
  done
fi

mkdir -p "$STATE_DIR" "$(dirname "$out")"

repo_csv="$(IFS=,; echo "${FLEET_REPOS[*]}")"

# ci-status.json is read from disk directly by python below (never
# interpolated into a heredoc as text) so its own content can never
# collide with shell/python quoting.
ci_path_arg="$ci_path"
[ -f "$ci_path_arg" ] || ci_path_arg=""

PYTHONDONTWRITEBYTECODE=1 python3 - \
  "$as_of" "$REPO_NO_SHIP_H" "$repo_csv" "$out" "$ci_path_arg" \
  "$REPO_CI_RED_MIN" "$REPO_MIN_ATTEMPTS" "$REPO_LOCK_WAIT_MAX" \
  "${journals[@]}" <<'PYEOF'
import sys, re, json, datetime

(as_of_s, window_h, repo_csv, out_path, ci_path,
 red_min_s, min_attempts_s, lock_max_s) = sys.argv[1:9]
files = sys.argv[9:]

as_of = datetime.datetime.strptime(as_of_s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
window_start = as_of - datetime.timedelta(hours=float(window_h))

ts_re = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)')
# Documented in this script's own header — keep both copies in step.
ship_re = re.compile(r'archive  shipped')
gate_re = re.compile(r'gate .*(block|pass|delta-pass)')
lock_re = re.compile(r'lock-contended|integrate lock|gate-pending-lock-contention|lock_wait_exhausted')

repos = [r for r in repo_csv.split(",") if r]
repo_word_re = {r: re.compile(r'\b' + re.escape(r) + r'\b') for r in repos}
counts = {r: {"ships": 0, "gates": 0, "locks": 0} for r in repos}

def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return None

for path in files:
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            m = ts_re.match(line)
            if not m:
                continue
            ts = parse_ts(m.group(1))
            if ts is None or not (window_start <= ts <= as_of):
                continue
            is_ship = bool(ship_re.search(line))
            is_gate = bool(gate_re.search(line))
            is_lock = bool(lock_re.search(line))
            if not (is_ship or is_gate or is_lock):
                continue
            for r in repos:
                if repo_word_re[r].search(line):
                    if is_ship: counts[r]["ships"] += 1
                    if is_gate: counts[r]["gates"] += 1
                    if is_lock: counts[r]["locks"] += 1

# ---- ci-status.json: staleness + per-repo conclusion/red_since ------------
ci_stale = True
ci_stale_age_s = None
ci_rows = {}
if ci_path:
    try:
        ci = json.load(open(ci_path))
        gen_at = ci.get("generated_at")
        gen_ts = parse_ts(gen_at) if gen_at else None
        if gen_ts is not None:
            age_s = (as_of - gen_ts).total_seconds()
            ci_stale_age_s = int(age_s)
            ci_stale = age_s > 1800
            ci_rows = ci.get("rows", {}) or {}
    except (OSError, ValueError, json.JSONDecodeError):
        ci_stale = True

REPO_CI_RED_MIN = float(red_min_s)
REPO_MIN_ATTEMPTS = int(min_attempts_s)
REPO_LOCK_WAIT_MAX = float(lock_max_s)
RED_CONCLUSIONS = {"failure", "timed_out"}

rules_disabled = []
if REPO_CI_RED_MIN <= 0: rules_disabled.append("main-ci-red")
if REPO_MIN_ATTEMPTS <= 0: rules_disabled.append("no-ship-with-attempts")
if REPO_LOCK_WAIT_MAX <= 0: rules_disabled.append("lock-wait-storm")

repos_out = {}
for repo, c in counts.items():
    row = {} if ci_stale else (ci_rows.get(repo, {}) or {})
    conclusion = "unknown" if ci_stale else (row.get("conclusion") or "unknown")
    red_since = None if ci_stale else row.get("red_since")
    red_minutes = 0
    if not ci_stale and conclusion in RED_CONCLUSIONS and red_since:
        rsince = parse_ts(red_since)
        if rsince is not None:
            red_minutes = max(0, int((as_of - rsince).total_seconds() // 60))

    alarms = []
    if "main-ci-red" not in rules_disabled and not ci_stale \
       and conclusion in RED_CONCLUSIONS and red_minutes >= REPO_CI_RED_MIN:
        alarms.append("main-ci-red")
    if "no-ship-with-attempts" not in rules_disabled \
       and c["ships"] == 0 and c["gates"] >= REPO_MIN_ATTEMPTS:
        alarms.append("no-ship-with-attempts")
    if "lock-wait-storm" not in rules_disabled and c["locks"] > REPO_LOCK_WAIT_MAX:
        alarms.append("lock-wait-storm")

    repos_out[repo] = {
        "ci": {"conclusion": conclusion, "red_since": red_since, "red_minutes": red_minutes,
               "run_id": (row.get("run_id") if not ci_stale else None),
               "head_sha": (row.get("head_sha") if not ci_stale else None),
               "failing_job": (row.get("failing_job") if not ci_stale else None)},
        "ships_24h": c["ships"],
        "gate_attempts_24h": c["gates"],
        "lock_wait_lines_24h": c["locks"],
        "alarms": alarms,
    }

result = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "as_of": as_of_s,
    "ci_stale": ci_stale,
    "ci_stale_age_s": ci_stale_age_s,
    "rules_disabled": rules_disabled,
    "repos": repos_out,
}

tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
import os
os.rename(tmp, out_path)
print(f"repo-health: wrote {out_path}", file=sys.stderr)
PYEOF
