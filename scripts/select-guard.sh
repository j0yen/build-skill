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
# Usage: select-guard.sh <slug> [lane-name] [prd-dir] [branch-count] [admitted-targets]
#   slug         PRD slug (the part after "PRD-" and before ".md").
#   lane-name    defaults to `hostname`, same default as lane-predicate.sh.
#   prd-dir      defaults to ~/Documents/PRDs.
#   branch-count Caller's own running count of PRDs already admitted THIS
#                tick, 0 for the first candidate — same convention as
#                chain-guard.sh's --step-count/CHAIN_MAX_STEPS. Defaults to 0.
#   admitted-targets  Comma-separated `build_into` values of PRDs already
#                admitted THIS tick — same caller-maintained-running-state
#                convention as branch-count (append this candidate's own
#                build_into once it's admitted). Defaults to empty (no
#                targets admitted yet), which never blocks.
#
# Per-tick fan-out cap (PRD-build-max-branches-cap, 2026-09-11):
# BUILD_MAX_BRANCHES caps how many PRDs a tick may admit in total. Unset,
# empty, or non-positive-integer preserves the historic behavior (SKILL.md
# Phase 2's "up to 30 PRDs" prose) — default 30. A candidate whose
# branch-count already meets or exceeds the cap is blocked with reason
# "cap: ...", independent of lane-predicate's busy/cargo-free checks.
#
# Distinct-target rule (PRD-build-distinct-targets-per-tick, 2026-09-11):
# journal-confirmed (mcphost-schedules + mcphost-tests-host-independence,
# same build_into, 2026-09-11 tick): pairing two PRDs that share a
# build_into contended the integrate lock (gate deferred-lock-contended)
# while the other starved on cargo-budget slots (wait slot timeout after
# 1200s) — the session returned, cgroup cleanup reaped the half-done gate,
# the claim went stale, and neither shipped. The same gate ran clean
# (1258s, lock_wait=0) as the only branch on that target. BUILD_DISTINCT_
# TARGETS (default 1 = ON) blocks a candidate whose build_into matches any
# target already in `admitted-targets` this tick, independent of
# lane-predicate's busy/cargo-free checks and of BUILD_MAX_BRANCHES. Set
# to 0 to disable (falls back to the pre-existing worktree-isolation/sub-
# cap behavior in SKILL.md's Selection rules). Only matters once more than
# one PRD can be admitted a tick; a missing build_into is never blocked on.
#
# Exit 0 + "ok: <slug>: <reason>"      dispatch may proceed.
# Exit 1 + "blocked: <slug>: <reason>" dispatch MUST NOT happen this tick —
#                                       reason names the busy claim (or
#                                       cargo-bound skip, sub-cap, the
#                                       BUILD_MAX_BRANCHES cap, or same-
#                                       target) exactly as lane-predicate.sh
#                                       reported it (or, for the cap/same-
#                                       target checks, this script's own).
# Exit 4                               usage error / PRD file not found.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_PREDICATE="$HERE/lane-predicate.sh"

die() { echo "select-guard: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: select-guard.sh <slug> [lane-name] [prd-dir] [branch-count] [admitted-targets]" >&2; exit 4; }

# Same build_into parser as lane-predicate.sh's read_field (PRD-build-
# second-lane-carbon) — duplicated rather than sourced so this script's
# own die/usage/main definitions never collide with lane-predicate.sh's.
read_field() {
  local f="$1" key="$2"
  head -n 80 "$f" \
    | grep -E "^(- *${key}:|${key}:|\*\*${key}:\*\*)" | head -n1 \
    | sed -E "s/^(- *${key}:|${key}:|\*\*${key}:\*\*)[[:space:]]*//" \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]+$//'
}

main() {
  [ $# -ge 1 ] || usage
  local slug="$1" lane="${2:-$(hostname)}" prd_dir="${3:-$HOME/Documents/PRDs}"
  local branch_count="${4:-0}"
  local admitted_targets="${5:-}"
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

  # BUILD_DISTINCT_TARGETS: unset/invalid -> 1 (ON). Only "0" disables.
  local distinct_targets="${BUILD_DISTINCT_TARGETS:-1}"
  case "$distinct_targets" in 0) distinct_targets=0 ;; *) distinct_targets=1 ;; esac
  if [ "$distinct_targets" -eq 1 ] && [ -n "$admitted_targets" ]; then
    local bi; bi=$(read_field "$prd" build_into)
    if [ -n "$bi" ]; then
      local t
      local IFS=','
      for t in $admitted_targets; do
        if [ "$t" = "$bi" ]; then
          echo "blocked: $slug: same-target: $bi already selected this tick (BUILD_DISTINCT_TARGETS=1)"
          exit 1
        fi
      done
    fi
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
