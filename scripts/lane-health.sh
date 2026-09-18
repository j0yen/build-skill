#!/usr/bin/env bash
# lane-health.sh — the one tick health line (PRD-build-host-contract
# requirement 3). Runs `host-contract.sh check` and prints/journals a
# single line ending `host=ok` or `host=drift:<csv>` (every drifted key,
# both severities, so the operator sees a warn-only drift here too —
# select-tick.sh's own dispatch refusal is the critical-only gate).
# host-contract.sh's own per-key drift/recovered transition lines are a
# SEPARATE journal write (its own dedup, see its header) — this script
# only ever appends its own one-line summary, never those.
#
# Usage: lane-health.sh [--lane <name>]
#   --lane defaults to `hostname` (same convention as select-tick.sh).
#
# Exit: mirrors host-contract.sh check's own exit (0 ok | 1 worst drift
# is warn | 2 worst drift is critical).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

HOST_CONTRACT_SH="${HOST_CONTRACT_SH:-$HERE/host-contract.sh}"
LANE="$(hostname)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) [ "$#" -ge 2 ] || { echo "usage: lane-health.sh [--lane <name>]" >&2; exit 2; }; LANE="$2"; shift 2 ;;
    *) echo "usage: lane-health.sh [--lane <name>]" >&2; exit 2 ;;
  esac
done

[ -x "$HOST_CONTRACT_SH" ] || { echo "lane-health: $HOST_CONTRACT_SH not found or not executable" >&2; exit 2; }

hc_out="$("$HOST_CONTRACT_SH" check 2>/dev/null)"
hc_rc=$?

if [ "$hc_rc" -eq 0 ]; then
  host_field="host=ok"
else
  drift_csv="$(printf '%s\n' "$hc_out" | grep '=drift(' | sed -E 's/=drift.*$//' | paste -sd, -)"
  host_field="host=drift:$drift_csv"
fi

line="$(date -u +%Y-%m-%dT%H:%M:%SZ)  lane-health  $LANE  $host_field"
echo "$line"
journal_line "$line"
exit "$hc_rc"
