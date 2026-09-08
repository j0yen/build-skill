#!/usr/bin/env bash
# select-guard.sh — dispatch-boundary guard making target-repo exclusivity
# structurally impossible to skip (PRD-build-select-target-busy-unskippable).
#
# lane-predicate.sh select and lane-claim.sh target-busy are correct and
# tested, but SKILL.md only asked a tick-runner to remember to call them
# during Phase 2 selection prose. This script is the single call a tick
# MUST make immediately before every Agent/Task dispatch (Phase 4, right
# before "Issue all calls in a single message") — one slug in, a loud
# pass/fail out. It adds a call-site guarantee, not new busy-detection
# logic: all cargo-free-filter and target-busy decisions are delegated to
# lane-predicate.sh select unchanged (AC4).
#
# Usage: select-guard.sh <slug> [lane-name] [prd-dir]
#   slug      PRD slug (the part after "PRD-" and before ".md").
#   lane-name defaults to `hostname`, same default as lane-predicate.sh.
#   prd-dir   defaults to ~/Documents/PRDs.
#
# Exit 0 + "ok: <slug>: <reason>"      dispatch may proceed.
# Exit 1 + "blocked: <slug>: <reason>" dispatch MUST NOT happen this tick —
#                                       reason names the busy claim (or
#                                       cargo-bound skip, or sub-cap) exactly
#                                       as lane-predicate.sh reported it.
# Exit 4                               usage error / PRD file not found.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_PREDICATE="$HERE/lane-predicate.sh"

die() { echo "select-guard: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: select-guard.sh <slug> [lane-name] [prd-dir]" >&2; exit 4; }

main() {
  [ $# -ge 1 ] || usage
  local slug="$1" lane="${2:-$(hostname)}" prd_dir="${3:-$HOME/Documents/PRDs}"
  local prd="$prd_dir/build-queue/PRD-$slug.md"
  [ -f "$prd" ] || die "no such PRD in build-queue: $prd" 4
  [ -x "$LANE_PREDICATE" ] || die "lane-predicate.sh not found or not executable: $LANE_PREDICATE" 4

  local out rc
  out=$("$LANE_PREDICATE" select "$prd" "$lane" "$prd_dir" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "blocked: $slug: ${out#skip: }"
    exit 1
  fi
  echo "ok: $slug: ${out#ok: }"
  exit 0
}

main "$@"
