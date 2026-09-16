#!/usr/bin/env bash
# gate-status.sh — real state of a gate-launch.sh-managed unit, from the
# marker + systemd, never from narration. PRD-build-gate-launch-survives-tick.
#
# usage: gate-status.sh <slug>
#         gate-status.sh --parity [--since <iso>] [--producer <name>]
#                         [--json] [--min-runs <n>] [--diff-local]
#
# --parity (PRD-build-gate-route-parity-ledger, R3/R7/R8/R9): reads tick
# journal `gate` lines (default $HOME/brain/journal/build/*.md, override
# with GATE_STATUS_JOURNAL_DIR) and prints a producer x route table —
# runs, pass, block, pass_rate, last_block_ts — from the same `phases=`
# and `route=` fields extend-gate.sh's own gate line now carries, so a
# night on the burst box is attributable to route without a hand triage.
# --since <iso>: only gate lines at or after this UTC timestamp (string
# comparison — journal timestamps are already zero-padded ISO8601, so
# lexicographic order is chronological order). --producer <name>: only
# that producer's rows. --json: an array of objects instead of a table.
# --min-runs <n> (default 3): rows tag `eligible_for_worst` false below
# this run count (lane-status.sh's "worst producer" pick honors this; the
# plain table still lists every row it has). --diff-local: instead of the
# full table, print producers whose burst pass_rate is more than 0.15
# below their own local pass_rate, both routes at >= --min-runs. This
# mode is a report, never a gate — always exits 0 (a --parity report is
# read-only, same contract as the plain <slug> invocation below).
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

if [ "${1:-}" = "--parity" ]; then
  shift
  PARITY_PY="${GATE_PARITY_PY:-$HERE/gate-parity.py}"
  [ -r "$PARITY_PY" ] || { echo "gate-status: missing $PARITY_PY" >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "gate-status: python3 not on \$PATH" >&2; exit 2; }
  journal_dir="${GATE_STATUS_JOURNAL_DIR:-$HOME/brain/journal/build}"
  py_args=()
  as_json_flag=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) py_args+=(--since "${2:?--since needs a value}"); shift 2 ;;
      --producer) py_args+=(--producer "${2:?--producer needs a value}"); shift 2 ;;
      --json) py_args+=(--json); as_json_flag=true; shift ;;
      --min-runs) py_args+=(--min-runs "${2:?--min-runs needs a value}"); shift 2 ;;
      --diff-local) py_args+=(--diff-local); shift ;;
      *) echo "usage: gate-status.sh --parity [--since <iso>] [--producer <name>] [--json] [--min-runs <n>] [--diff-local]" >&2; exit 2 ;;
    esac
  done
  shopt -s nullglob
  parity_files=("$journal_dir"/*.md)
  shopt -u nullglob
  if [ "${#parity_files[@]}" -eq 0 ]; then
    if $as_json_flag; then echo '[]'; else echo "gate-status --parity: no journal files under $journal_dir"; fi
    exit 0
  fi
  cat "${parity_files[@]}" | python3 "$PARITY_PY" "${py_args[@]}"
  exit 0
fi

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
