#!/usr/bin/env bash
# landing-pending-summary.sh — PRD-build-main-push-gate-pr-path
# requirement 9 (P1, AC12): the data gates-banner.sh's `landing-pending=`
# line is built from. Scans state/landings/<repo>/<slug>.json (written by
# `branch-protection.sh push`, read by `landing-resume.sh`, removed once a
# landing resolves) and prints:
#
#   landing-pending=<n>
#   <repo>#<pr_number> <elapsed>      (one line per entry, n lines total)
#
# A landing record whose slug's manifest status already reads `blocked`
# (landing-resume.sh's own red/closed/timeout outcomes set this but keep
# the record file "as evidence" — AC9) is NOT counted here: it is already
# surfaced through the red-gate alarm / decisions ledger, and showing it
# as still "pending" here would be misleading — this banner is for
# landings actively waiting on GitHub, not ones already escalated.
#
# elapsed is formatted `<h>h<m>m` when >= 1h, else `<m>m` (AC12's own
# example: "12m").
#
# Usage: landing-pending-summary.sh
# Env: BUILD_STATE_DIR, BUILD_MANIFEST (defaults: <skill>/state,
#      <state>/manifest.json)
# Exit: always 0 (fail-open, same posture as gates-banner.sh itself — a
# malformed record or missing manifest just drops that one entry, never
# aborts the whole summary).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
LANDINGS_DIR="$STATE_DIR/landings"

[ -d "$LANDINGS_DIR" ] || { echo "landing-pending=0"; exit 0; }

python3 - "$LANDINGS_DIR" "$MANIFEST" <<'PY'
import glob, json, os, sys, datetime

landings_dir, manifest_path = sys.argv[1], sys.argv[2]

try:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    prds = manifest.get("prds", {})
    if isinstance(prds, list):
        prds = {p.get("slug"): p for p in prds if isinstance(p, dict) and p.get("slug")}
except (OSError, json.JSONDecodeError):
    prds = {}

def fmt_elapsed(armed_at):
    if not armed_at:
        return "?"
    try:
        armed = datetime.datetime.strptime(armed_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return "?"
    secs = max(0, int((datetime.datetime.now(datetime.timezone.utc) - armed).total_seconds()))
    h, rem = divmod(secs, 3600)
    m = rem // 60
    return f"{h}h{m}m" if h > 0 else f"{m}m"

entries = []
for path in sorted(glob.glob(os.path.join(landings_dir, "*", "*.json"))):
    repo_slug = os.path.basename(os.path.dirname(path))
    slug = os.path.basename(path)[: -len(".json")]
    status = (prds.get(slug) or {}).get("status")
    if status == "blocked":
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, json.JSONDecodeError):
        continue
    pr_number = rec.get("pr_number") or "?"
    entries.append(f"{repo_slug}#{pr_number} {fmt_elapsed(rec.get('armed_at'))}")

print(f"landing-pending={len(entries)}")
for line in entries:
    print(line)
PY
