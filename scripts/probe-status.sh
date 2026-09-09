#!/usr/bin/env bash
# probe-status.sh — one table of every three-state probe's last state, last
# change time, and live could-not-check streak (PRD-build-three-state-probes
# P1, "Law 14 shape": one command answers "what does the loop's own health
# look like right now" without hand-grepping the ledger).
#
# Usage: probe-status.sh [--json]
#
# Reads the same ledger probe-result.sh writes ($PROBE_LEDGER, defaulting to
# <skill>/state/probes/ledger.jsonl — override via the same env vars
# probe-result.sh honors, e.g. for tests: BUILD_STATE_DIR / PROBE_LEDGER).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=probe-result.sh
source "$HERE/probe-result.sh"

FORMAT="text"
[ "${1:-}" = "--json" ] && FORMAT="json"

python3 - "$PROBE_LEDGER" "$FORMAT" <<'PY'
import json, sys

ledger_path, fmt = sys.argv[1:3]
rows = []
try:
    with open(ledger_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
except FileNotFoundError:
    pass

order = []
last = {}
for row in rows:
    name = row.get("probe")
    if name is None:
        continue
    if name not in last:
        order.append(name)
    prev = last.get(name)
    last_change = row.get("ts")
    if prev is not None and prev.get("state") == row.get("state"):
        last_change = prev.get("last_change", row.get("ts"))
    streak = row.get("streak", 0) if row.get("state") == "could-not-check" else 0
    last[name] = {
        "state": row.get("state"),
        "ts": row.get("ts"),
        "last_change": last_change,
        "streak": streak,
    }

if fmt == "json":
    print(json.dumps({n: last[n] for n in order}, sort_keys=True))
    sys.exit(0)

if not order:
    print("probe-status: no probes recorded yet")
    sys.exit(0)

w = max(len(n) for n in order)
print(f"{'PROBE'.ljust(w)}  STATE            LAST-CHANGE           STREAK")
for name in order:
    p = last[name]
    print(f"{name.ljust(w)}  {str(p['state']).ljust(15)}  {str(p['last_change']):<20}  {p['streak']}")
PY
