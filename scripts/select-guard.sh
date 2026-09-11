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
# Usage: select-guard.sh <slug> [lane-name] [prd-dir] [branch-count]
#   slug         PRD slug (the part after "PRD-" and before ".md").
#   lane-name    defaults to `hostname`, same default as lane-predicate.sh.
#   prd-dir      defaults to ~/Documents/PRDs.
#   branch-count Caller's own running count of PRDs already admitted THIS
#                tick, 0 for the first candidate — same convention as
#                chain-guard.sh's --step-count/CHAIN_MAX_STEPS. Defaults to 0.
#
# Per-tick fan-out cap (PRD-build-max-branches-cap, 2026-09-11):
# BUILD_MAX_BRANCHES caps how many PRDs a tick may admit in total. Unset,
# empty, or non-positive-integer preserves the historic behavior (SKILL.md
# Phase 2's "up to 30 PRDs" prose) — default 30. A candidate whose
# branch-count already meets or exceeds the cap is blocked with reason
# "cap: ...", independent of lane-predicate's busy/cargo-free checks.
#
# Exit 0 + "ok: <slug>: <reason>"      dispatch may proceed.
# Exit 1 + "blocked: <slug>: <reason>" dispatch MUST NOT happen this tick —
#                                       reason names the busy claim (or
#                                       cargo-bound skip, sub-cap, or the
#                                       BUILD_MAX_BRANCHES cap) exactly as
#                                       lane-predicate.sh reported it (or,
#                                       for the cap, this script's own count).
# Exit 4                               usage error / PRD file not found.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_PREDICATE="$HERE/lane-predicate.sh"

die() { echo "select-guard: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: select-guard.sh <slug> [lane-name] [prd-dir] [branch-count]" >&2; exit 4; }

main() {
  [ $# -ge 1 ] || usage
  local slug="$1" lane="${2:-$(hostname)}" prd_dir="${3:-$HOME/Documents/PRDs}"
  local branch_count="${4:-0}"
  local prd="$prd_dir/build-queue/PRD-$slug.md"
  [ -f "$prd" ] || die "no such PRD in build-queue: $prd" 4
  [ -x "$LANE_PREDICATE" ] || die "lane-predicate.sh not found or not executable: $LANE_PREDICATE" 4

  # BUILD_MAX_BRANCHES: unset/empty/non-positive-integer -> default 30
  # (preserves current unenforced-by-script behavior exactly).
  local limit="${BUILD_MAX_BRANCHES:-30}"
  case "$limit" in ''|*[!0-9]*|0) limit=30 ;; esac
  case "$branch_count" in ''|*[!0-9]*) branch_count=0 ;; esac
  if [ "$branch_count" -ge "$limit" ]; then
    echo "blocked: $slug: cap: $branch_count branches already selected this tick (cap=$limit)"
    exit 1
  fi

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
