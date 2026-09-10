#!/usr/bin/env bash
# gate-wedge-rollup.sh — daily journal rollup of gate-wedge activity
# (PRD-build-gate-wall-clock requirement 8). Everything this needs is
# already recorded by shipped mechanisms: gate-wedge.sh's own
# wedge-receipt.json files (requirement 3/4/6) carry `classification`,
# and sccache-assert.sh (requirement 2, this same PRD's step 4) now logs
# one NDJSON line per successful restart to
# state/sccache-assert/restarts.log. This script is read-only aggregation
# over both — no new detection logic, just counting what already exists.
#
# Usage:
#   gate-wedge-rollup.sh [--date YYYY-MM-DD] [--dry-run]
#
# --date defaults to today (UTC, matching the rest of this toolkit's
# `date -u +%F`/`+%Y%m%dT%H%M%SZ` convention). Prints exactly one summary
# line to STDOUT:
#   gate-wedge-rollup: date=<d> wedges_total=<n> wedges={<class>:<n>,...} sccache_restarts=<n>
# and, unless --dry-run, appends the same line (ISO-timestamped, same
# `journal()` convention as cargo-budget.sh) to
# $HOME/brain/journal/build/<date>.md. A day with zero wedges and zero
# restarts still prints/journals a line (wedges={} sccache_restarts=0) —
# "nothing happened" is itself the rollup's answer on a quiet day, not an
# omission the reader has to infer from silence.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   GATE_WEDGE_STATE_DIR         (<skill-dir>/state/gate-wedge)          same as gate-wedge.sh
#   SCCACHE_ASSERT_RESTART_LOG   (<skill-dir>/state/sccache-assert/restarts.log)  same as sccache-assert.sh
#   GATE_WEDGE_ROLLUP_JOURNAL    ($HOME/brain/journal/build/<date>.md)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
WEDGE_STATE_DIR="${GATE_WEDGE_STATE_DIR:-$SKILL_DIR/state/gate-wedge}"
RESTART_LOG="${SCCACHE_ASSERT_RESTART_LOG:-$SKILL_DIR/state/sccache-assert/restarts.log}"

date_arg=""
dry_run=0

usage() { echo "usage: gate-wedge-rollup.sh [--date YYYY-MM-DD] [--dry-run]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --date)    date_arg="${2:?gate-wedge-rollup: --date needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

day="${date_arg:-$(date -u +%F)}"
day_compact="${day//-/}"  # 2026-09-10 -> 20260910, matches receipt filename prefix

# --- 1. wedge receipts for this day, grouped by classification ----------
wedges_json='{}'
wedges_total=0
if [ -d "$WEDGE_STATE_DIR" ]; then
  shopt -s nullglob
  receipts=("$WEDGE_STATE_DIR/${day_compact}"*-wedge-receipt.json)
  shopt -u nullglob
  if [ "${#receipts[@]}" -gt 0 ]; then
    wedges_json="$(jq -sc '[.[].classification] | group_by(.) | map({(.[0]): length}) | add // {}' "${receipts[@]}" 2>/dev/null || echo '{}')"
    wedges_total="${#receipts[@]}"
  fi
fi

# --- 2. sccache-assert restarts for this day -----------------------------
sccache_restarts=0
if [ -f "$RESTART_LOG" ]; then
  sccache_restarts="$(jq -sc --arg day "$day" '[.[] | select(.ts | startswith($day))] | length' "$RESTART_LOG" 2>/dev/null || echo 0)"
  [ -n "$sccache_restarts" ] || sccache_restarts=0
fi

line="gate-wedge-rollup: date=$day wedges_total=$wedges_total wedges=$wedges_json sccache_restarts=$sccache_restarts"
echo "$line"

if [ "$dry_run" -eq 0 ]; then
  jf="${GATE_WEDGE_ROLLUP_JOURNAL:-$HOME/brain/journal/build/${day}.md}"
  mkdir -p "$(dirname "$jf")" 2>/dev/null || true
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s  gate-wedge-rollup  %s\n' "$now_iso" "$line" >> "$jf"
fi

exit 0
