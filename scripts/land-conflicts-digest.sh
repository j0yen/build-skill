#!/usr/bin/env bash
# land-conflicts-digest.sh — PRD-build-land-conflict-resolver R9 (P1): one
# line per day, computed entirely from state/land-conflicts.jsonl (R5's
# ledger, written by land-resolve.sh's ledger_record()), so an operator
# reading the day's journal sees conflicts resolved by class without
# running land-conflicts-report.sh's per-file breakdown by hand. Same
# read-only, no-new-state, no-new-lock convention as
# serialization-digest.sh (PRD-build-gate-before-land requirement 7) —
# this is that script's sibling for the land-conflict ledger instead of
# the shared journal.
#
#   land-conflicts: generated=<n> regen=<n> append_only=<n> union=<n>
#     source=<n> coder=<n> unresolved=<n>
#
# Fields:
#   generated=<n>/regen=<n>       records classified `generated`, and how
#                                 many of those actually resolved via
#                                 `regen` (should be equal in steady state;
#                                 a gap would mean a generated-file record
#                                 landed with a different resolution, which
#                                 land-resolve.sh's own logic never does
#                                 today but the digest doesn't assume).
#   append_only=<n>/union=<n>    same shape for the append_only class.
#   source=<n>/coder=<n>/unresolved=<n>
#                                 source-class records split by their two
#                                 possible resolutions (R4).
#
# Usage: land-conflicts-digest.sh [--days N] [<ledger-path>]
#   Window defaults to today only (--days 1), UTC, matching
#   gate-phase-digest.sh's --days convention but defaulting to 1 day since
#   this is meant to run once per day's digest, not a rolling report (use
#   land-conflicts-report.sh for the all-time per-file view). <ledger-path>
#   defaults to $BUILD_STATE_DIR/land-conflicts.jsonl (or
#   <skill-dir>/state/land-conflicts.jsonl if unset), same resolution
#   land-resolve.sh's own LAND_CONFLICTS_LEDGER default uses.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   LAND_CONFLICTS_DIGEST_NOW   (date -u +%FT%TZ) — the window's end date,
#                                overridable so a fixture ledger dated in
#                                the past is still "recent" from the
#                                test's point of view (same convention
#                                gate-phase-digest.sh's *_NOW uses).
#
# A missing or empty ledger is not an error: every count is 0 (nothing
# recorded, or nothing in the window). Read-only: never writes, never
# takes a lock. Exit: 0 always; 2 usage error (bad --days, unexpected args).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
DEFAULT_LEDGER="${LAND_CONFLICTS_LEDGER:-$STATE_DIR/land-conflicts.jsonl}"

days=1
ledger=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      days="${2:?land-conflicts-digest: --days needs a value}"
      case "$days" in ''|*[!0-9]*) echo "land-conflicts-digest: --days must be a positive integer" >&2; exit 2 ;; esac
      shift 2 ;;
    -*)
      echo "usage: land-conflicts-digest.sh [--days N] [<ledger-path>]" >&2; exit 2 ;;
    *)
      if [ -n "$ledger" ]; then echo "usage: land-conflicts-digest.sh [--days N] [<ledger-path>]" >&2; exit 2; fi
      ledger="$1"; shift ;;
  esac
done
ledger="${ledger:-$DEFAULT_LEDGER}"

zero_line() {
  echo "land-conflicts: generated=0 regen=0 append_only=0 union=0 source=0 coder=0 unresolved=0"
}

if [ ! -s "$ledger" ]; then
  zero_line
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "land-conflicts-digest: jq required" >&2; exit 2; }

now="${LAND_CONFLICTS_DIGEST_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

jq -rs --arg now "$now" --argjson days "$days" '
  ($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $now_e
  | ($days * 86400) as $window_s
  | map(select(
      (try (.ts | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null) as $e
      | $e != null and ($now_e - $e) < $window_s and ($now_e - $e) >= 0
    ))
  | {
      generated: (map(select(.class == "generated")) | length),
      regen: (map(select(.class == "generated" and .resolution == "regen")) | length),
      append_only: (map(select(.class == "append_only")) | length),
      union: (map(select(.class == "append_only" and .resolution == "union")) | length),
      source: (map(select(.class == "source")) | length),
      coder: (map(select(.class == "source" and .resolution == "coder")) | length),
      unresolved: (map(select(.class == "source" and .resolution == "unresolved")) | length)
    }
  | "land-conflicts: generated=\(.generated) regen=\(.regen) append_only=\(.append_only) union=\(.union) source=\(.source) coder=\(.coder) unresolved=\(.unresolved)"
' "$ledger" 2>/dev/null || zero_line
