#!/usr/bin/env bash
# repo-health-banner.sh — SessionStart hook: print active repo-health
# alarms from state/alerts.banner (PRD-build-repo-health-invariants
# requirement 7 / AC7). Silent (no output, exit 0) when there's nothing to
# say — same posture as token-ledger-banner.sh, the sibling hook this one
# is installed alongside.
#
# Reads the last 7 days of state/alerts.banner lines. Two shapes:
#   "<ts> <repo> <rule> value=<n> — <evidence>"   (a firing)
#   "<ts> <repo> <rule> resolved"                 (alert-deliver.sh resolve)
# An alarm line is PRINTED unless a resolved line for the SAME (repo,rule)
# exists with a timestamp >= the alarm's own — a handoff (a new Claude
# session, possibly days later) must never lose an alarm that's still
# active, and must never show one that's already been resolved.
#
# Exit: always 0 — a SessionStart hook must never block a session on a
# state file read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
BANNER="${ALERT_BANNER:-$STATE_DIR/alerts.banner}"

[ -r "$BANNER" ] || exit 0

python3 - "$BANNER" <<'PYEOF' 2>/dev/null || exit 0
import sys, datetime, re

path = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=7)

ts_re = re.compile(r'^(\S+) (\S+) (\S+) (.*)$')

def parse_ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None

alarms = []   # (ts, repo, rule, rest_text)
resolved = {} # (repo,rule) -> latest resolved ts

with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        m = ts_re.match(line)
        if not m:
            continue
        ts_s, repo, rule, rest = m.groups()
        ts = parse_ts(ts_s)
        if ts is None or ts < cutoff:
            continue
        if rest.strip() == "resolved":
            key = (repo, rule)
            if key not in resolved or ts > resolved[key]:
                resolved[key] = ts
        else:
            alarms.append((ts, repo, rule, rest))

lines_out = []
for ts, repo, rule, rest in alarms:
    r = resolved.get((repo, rule))
    if r is not None and r >= ts:
        continue
    since = ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    lines_out.append(f"repo-health: {repo} {rule} since={since} — {rest}")

if lines_out:
    print("\n".join(lines_out))
PYEOF
