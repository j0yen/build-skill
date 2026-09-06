#!/usr/bin/env bash
# lane-has-work.sh — ExecCondition for claude-build.service on secondary
# lanes: launch a (paid, LLM) /build tick only when at least one queued PRD
# passes this lane's predicate (`lane-predicate.sh select`). Pure bash, no
# model call — a secondary lane facing an all-cargo queue must cost nothing.
#
# Exit 0 => at least one selectable PRD (fire the tick).
# Exit 1 => none (systemd skips the unit; the path unit re-evaluates later).
#
# RedBaron never gates (it takes every target). Statuses that can never be
# selected (blocked, built, parked, needs_classification, archived) are
# skipped before the predicate runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
LOG="${CLAUDE_BUILD_LOG:-$HOME/brain/journal/build-auto.log}"
me="$(hostname)"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { echo "$(ts) lane-has-work: $*" >> "$LOG"; }
# See lane-defer.sh: an unpaced ExecCondition skip loops the path unit once
# per second. Sleep inside the condition (only when the drop-in sets
# LANE_SKIP_PACE) so the unit holds "activating (condition)" for the window.
pace() { [ -z "${LANE_SKIP_PACE:-}" ] || sleep "$LANE_SKIP_PACE"; }

[ "$me" = "RedBaron" ] && exit 0

status_of() {
  head -n 80 "$1" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
    | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//' | awk '{print $1}'
}

total=0 selectable=0 first=""
for prd in "$PRD_DIR"/build-queue/*.md; do
  [ -f "$prd" ] || continue
  total=$((total + 1))
  case "$(status_of "$prd")" in
    blocked|built|parked|needs_classification|archived) continue ;;
  esac
  if "$HERE/lane-predicate.sh" select "$prd" "$me" "$PRD_DIR" >/dev/null 2>&1; then
    selectable=$((selectable + 1))
    [ -n "$first" ] || first="$(basename "$prd")"
  fi
done

if [ "$selectable" -gt 0 ]; then
  logline "proceed: $selectable of $total queued PRD(s) selectable on $me (first: $first)"
  exit 0
fi
logline "skip: 0 of $total queued PRD(s) selectable on $me (cargo-free filter / exclusivity); no tick launched"
pace
exit 1
