#!/usr/bin/env bash
# shipped-count.sh — count `<slug>  archive  archived` journal lines in the
# last N hours (default 24), for gates-banner.sh's "PRDs shipped last 24h"
# line (PRD-build-gate-red-alarm-invariant R5). Kept as its own tiny script
# (rather than inlined in gates-banner.sh) so a remote SessionStart hook can
# invoke it directly over ssh on RedBaron, one round trip, same as it reads
# state/gate-red.summary.
#
# Usage: shipped-count.sh [--hours N]
# Prints a bare integer on stdout. Exit: always 0 (a banner input, never
# fatal — an unreadable/missing journal just counts 0).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

hours=24
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hours) hours="${2:-24}"; shift 2 ;;
    *) shift ;;
  esac
done

root="$(journal_root)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
since="$(date -u -d "$now - ${hours} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -z "$since" ] && { echo 0; exit 0; }

today="$root/$(date -u +%F).md"
yday="$root/$(date -u -d yesterday +%F).md"

cat "$yday" "$today" 2>/dev/null | awk -v since="$since" -v now="$now" '
  /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
    if ($1 >= since && $1 <= now && $3 == "archive" && $4 == "archived") c++
  }
  END { print c+0 }
'
exit 0
