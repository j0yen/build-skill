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

# Three-state retrofit (PRD-build-three-state-probes): fail-open sourcing so
# an unshipped/missing library never breaks this ExecCondition.
if [ -r "$HERE/probe-result.sh" ]; then
  # shellcheck source=probe-result.sh
  source "$HERE/probe-result.sh"
else
  probe_emit() { :; }
fi
# See lane-defer.sh: an unpaced ExecCondition skip loops the path unit once
# per second. Sleep inside the condition (only when the drop-in sets
# LANE_SKIP_PACE) so the unit holds "activating (condition)" for the window.
pace() { [ -z "${LANE_SKIP_PACE:-}" ] || sleep "$LANE_SKIP_PACE"; }

[ "${me,,}" = "redbaron" ] && exit 0

status_of() {
  head -n 80 "$1" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
    | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//' | awk '{print $1}'
}

# An unreadable/absent build-queue dir is not "zero PRDs queued" (clean) —
# it's "this lane cannot even scan the queue" (could-not-check). Folding the
# two together is exactly the two-state defect this retrofit exists to fix:
# a broken PRD_DIR would otherwise silently read as a permanently-empty,
# healthy-looking queue.
if [ ! -d "$PRD_DIR/build-queue" ]; then
  probe_emit lane-has-work could-not-check "build-queue dir missing or unreadable: $PRD_DIR/build-queue" >/dev/null
  logline "could-not-check: build-queue dir missing or unreadable: $PRD_DIR/build-queue"
  pace
  exit 1
fi

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
  probe_emit lane-has-work dirty "$selectable of $total queued PRD(s) selectable on $me (first: $first)" >/dev/null
  logline "proceed: $selectable of $total queued PRD(s) selectable on $me (first: $first)"
  exit 0
fi
probe_emit lane-has-work clean "0 of $total queued PRD(s) selectable on $me (cargo-free filter / exclusivity)" >/dev/null
logline "skip: 0 of $total queued PRD(s) selectable on $me (cargo-free filter / exclusivity); no tick launched"
pace
exit 1
