#!/usr/bin/env bash
# land-conflicts-report.sh — R5 second half (PRD-build-land-conflict-
# resolver): prints state/land-conflicts.jsonl (land-resolve.sh's ledger,
# see that script's header) grouped by file, ordered by conflict count
# descending, showing each file's class and most recent resolution. This
# is the operator-facing side of R5's goal ("the operator can see which
# files conflict and how often") — no mutation, safe to run any time.
#
# usage: land-conflicts-report.sh [<ledger-path>]
#   Defaults to $BUILD_STATE_DIR/land-conflicts.jsonl (or
#   <skill-dir>/state/land-conflicts.jsonl if unset), same resolution
#   land-resolve.sh's own LAND_CONFLICTS_LEDGER default uses.
#
# Output: one line per distinct file, most-conflicted first:
#   <count>  <file>  class=<class> last_resolution=<resolution>
# Prints "no conflicts recorded" and exits 0 on a missing or empty ledger
# (a quiet ledger is good news, not an error).
#
# Exit: 0 always (a report script never fails the caller); 2 usage error
# (unexpected extra args) is the only non-zero case.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
DEFAULT_LEDGER="${LAND_CONFLICTS_LEDGER:-$STATE_DIR/land-conflicts.jsonl}"

[ $# -le 1 ] || { echo "usage: land-conflicts-report.sh [<ledger-path>]" >&2; exit 2; }
ledger="${1:-$DEFAULT_LEDGER}"

if [ ! -s "$ledger" ]; then
  echo "no conflicts recorded"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "land-conflicts-report: jq required" >&2; exit 2; }

# group_by(.file) requires sorted input; sort_by(-length) then orders the
# groups by conflict count descending, ties broken by file name for
# deterministic output. `.[-1]` on each group is the most recently
# appended record for that file (the ledger is append-only, so the last
# line for a file is its most recent resolution).
jq -rs '
  group_by(.file)
  | sort_by(-(length))
  | .[]
  | "\(length)\t\(.[-1].file)\tclass=\(.[-1].class) last_resolution=\(.[-1].resolution)"
' "$ledger" 2>/dev/null | while IFS=$'\t' read -r count file rest; do
  printf '%s  %s  %s\n' "$count" "$file" "$rest"
done
