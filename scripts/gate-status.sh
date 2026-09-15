#!/usr/bin/env bash
# gate-status.sh — real state of a gate-launch.sh-managed unit, from the
# marker + systemd, never from narration. PRD-build-gate-launch-survives-tick.
#
# usage: gate-status.sh <slug>
#
# Prints exactly one of:
#   running        marker exists, `systemctl --user is-active` says the
#                   unit is active/activating.
#   finished:<rc>   the unit is loaded but not active and
#                   `systemctl --user show -p ExecMainStatus --value`
#                   returned a real exit code — OR the unit has already
#                   been garbage-collected (--collect unloads it shortly
#                   after it exits) but the repo's receipts directory (or
#                   its cached last-verdict.json) has a file newer than
#                   the marker's started_ts, in which case <rc> is read
#                   from last-verdict.json's `verdict` field
#                   (pass/delta-pass -> 0, block -> 1; unreadable despite
#                   fresh receipts -> 0, since receipts existing at all
#                   means the gate ran to completion before collection).
#   lost            marker exists, unit is gone, and no receipt is newer
#                   than started_ts — the tick-teardown defect this PRD
#                   fixes: a gate that died with no trace.
#   none            no marker for this slug.
#
# Exit 0 always (this is a read, never a gate verdict).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
INFLIGHT_DIR="$STATE_DIR/gate-inflight"
SYSTEMCTL="${GATE_STATUS_SYSTEMCTL:-systemctl}"
JQ="${JQ:-jq}"

slug="${1:-}"
if [ -z "$slug" ]; then
  echo "usage: gate-status.sh <slug>" >&2
  exit 4
fi

marker="$INFLIGHT_DIR/$slug.json"
if [ ! -f "$marker" ]; then
  echo "none"
  exit 0
fi

unit="$("$JQ" -r '.unit // empty' "$marker" 2>/dev/null)"
repo="$("$JQ" -r '.repo // empty' "$marker" 2>/dev/null)"
started_ts="$("$JQ" -r '.started_ts // empty' "$marker" 2>/dev/null)"

if [ -z "$unit" ]; then
  echo "none"
  exit 0
fi

state="$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null)"
case "$state" in
  active|activating|reloading)
    echo "running"
    exit 0
    ;;
esac

# Not active. Still loaded (inactive/failed) -> a real ExecMainStatus.
load_state="$("$SYSTEMCTL" --user show -p LoadState --value "$unit" 2>/dev/null)"
if [ -n "$load_state" ] && [ "$load_state" != "not-found" ]; then
  rc="$("$SYSTEMCTL" --user show -p ExecMainStatus --value "$unit" 2>/dev/null)"
  case "$rc" in
    ''|*[!0-9]*) ;;
    *) echo "finished:$rc"; exit 0 ;;
  esac
fi

# Unit fully collected (--collect unloaded it) or systemctl gave nothing
# usable. Fall back to receipt freshness against started_ts.
started_epoch=0
if [ -n "$started_ts" ]; then
  started_epoch="$(date -u -d "$started_ts" +%s 2>/dev/null || echo 0)"
fi

newest_epoch=0
if [ -n "$repo" ] && [ -d "$repo/target/autobuilder/receipts" ]; then
  newest_epoch="$(find "$repo/target/autobuilder/receipts" -type f -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d. -f1)"
  [ -n "$newest_epoch" ] || newest_epoch=0
fi

if [ "${newest_epoch:-0}" -le "${started_epoch:-0}" ] 2>/dev/null; then
  echo "lost"
  exit 0
fi

# Gone, but the gate clearly ran (fresh receipts) — read the verdict cache
# for a real rc when we can, else assume pass (receipts existing at all
# means the producer sequence completed before collection).
rc=0
verdict_file="$repo/target/autobuilder/last-verdict.json"
if [ -f "$verdict_file" ]; then
  v="$("$JQ" -r '.verdict // empty' "$verdict_file" 2>/dev/null)"
  case "$v" in
    block) rc=1 ;;
    pass|delta-pass) rc=0 ;;
  esac
fi
echo "finished:$rc"
exit 0
