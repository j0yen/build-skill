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
# Same-target cap (PRD-build-gate-before-land requirement 5, 2026-09-14,
# superseding the binary distinct-target rule below): originally
# PRD-build-distinct-targets-per-tick, 2026-09-11 — journal-confirmed
# (mcphost-schedules + mcphost-tests-host-independence, same build_into,
# 2026-09-11 tick): pairing two PRDs that share a build_into contended the
# integrate lock (gate deferred-lock-contended) while the other starved on
# cargo-budget slots (wait slot timeout after 1200s) — the session
# returned, cgroup cleanup reaped the half-done gate, the claim went stale,
# and neither shipped. The same gate ran clean (1258s, lock_wait=0) as the
# only branch on that target. That incident was land-before-gate holding
# the crate lock for the gate's whole run (see PRD-build-gate-before-land);
# with requirement 1's branch-scoped gate removing that lock contention,
# the binary "1 per target" rule can widen to a real cap:
#
# BUILD_SAME_TARGET_CAP (default 1 — reproduces the old always-1 outcome
# exactly) caps how many candidates sharing one build_into this tick may
# admit. BUILD_DISTINCT_TARGETS=1, EXPLICITLY set, still forces the cap to
# 1 (the old compat knob keeps working for anyone still setting it) — it no
# longer defaults to ON, since BUILD_SAME_TARGET_CAP's own default already
# reproduces the old default outcome with nothing set. When a burst-lane
# session reports `gate_ready=true` (via BURST_LANE_SH, default
# $HERE/burst-lane.sh), the cap for `build_target: rust-extend` candidates
# widens to min(BUILD_SAME_TARGET_CAP_BURST (default 4), the box's own
# reported `width`) — unless the BUILD_DISTINCT_TARGETS=1 compat knob
# already pinned it to 1. Every candidate this script is asked about
# prints `select same-target cap=<n> source=local|burst target=<build_into>
# admitted=<k>` to stderr; deduping that to one line per target per tick
# (requirement 5's own wording) is the tick parent's job, same as the
# lane-health/resumed= folding SKILL.md's Phase 2 already documents for a
# different per-tick summary line. Only matters once more than one PRD can
# be admitted a tick; a missing build_into is never blocked on.
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

  # Same-target cap (PRD-build-gate-before-land requirement 5, replacing the
  # old binary BUILD_DISTINCT_TARGETS check): BUILD_SAME_TARGET_CAP (default
  # 1 — today's behavior exactly) caps how many candidates sharing one
  # build_into this tick may admit. BUILD_DISTINCT_TARGETS=1, EXPLICITLY set,
  # still forces the cap to 1 for anyone relying on the old compat knob
  # (AC8) — it no longer defaults to ON, since BUILD_SAME_TARGET_CAP's own
  # default already reproduces the old default outcome.
  # BUILD_DISTINCT_TARGETS=0, EXPLICITLY set, is ALSO preserved for back-
  # compat with its old "disable the check" meaning — a same-target cap
  # effectively unbounded within this tick (BUILD_MAX_BRANCHES above is
  # still the real ceiling, exactly as when the old binary check was off).
  local same_target_cap="${BUILD_SAME_TARGET_CAP:-1}"
  case "$same_target_cap" in ''|*[!0-9]*|0) same_target_cap=1 ;; esac
  local distinct_targets_forced=0
  case "${BUILD_DISTINCT_TARGETS:-}" in
    1) distinct_targets_forced=1; same_target_cap=1 ;;
    0) same_target_cap=999999 ;;
  esac
  [ "$distinct_targets_forced" -eq 1 ] && same_target_cap=1

  local bi; bi=$(read_field "$prd" build_into)
  local cap_source="local"
  # Burst-aware widening (AC9): only for rust-extend targets, only when a
  # burst-lane session reports gate_ready=true, and only when the compat
  # knob above hasn't already pinned the cap to 1. Cap = min(
  # BUILD_SAME_TARGET_CAP_BURST (default 4), the box's own reported width).
  # BURST_LANE_SH overridable so a selftest can point at a fake toolchain
  # (same convention extend-gate.sh/lane-claim.sh already use) without a
  # real Hetzner box.
  if [ "$distinct_targets_forced" -ne 1 ] && [ -n "$bi" ]; then
    local build_target_field; build_target_field=$(read_field "$prd" build_target)
    if [ "$build_target_field" = "rust-extend" ]; then
      local burst_bin="${BURST_LANE_SH:-$HERE/burst-lane.sh}"
      if [ -x "$burst_bin" ]; then
        local bstatus gate_ready width cap_burst
        bstatus="$("$burst_bin" status --json 2>/dev/null || true)"
        gate_ready="$(printf '%s' "$bstatus" | jq -r '.gate_ready // empty' 2>/dev/null || true)"
        if [ "$gate_ready" = "true" ]; then
          width="$(printf '%s' "$bstatus" | jq -r '.width // empty' 2>/dev/null || true)"
          case "$width" in ''|*[!0-9]*) width="" ;; esac
          if [ -n "$width" ]; then
            cap_burst="${BUILD_SAME_TARGET_CAP_BURST:-4}"
            case "$cap_burst" in ''|*[!0-9]*|0) cap_burst=4 ;; esac
            if [ "$width" -lt "$cap_burst" ]; then same_target_cap="$width"; else same_target_cap="$cap_burst"; fi
            cap_source="burst"
          fi
        fi
      fi
    fi
  fi

  local same_target_count=0
  if [ -n "$bi" ] && [ -n "$admitted_targets" ]; then
    local t
    local IFS=','
    for t in $admitted_targets; do
      [ "$t" = "$bi" ] && same_target_count=$((same_target_count + 1))
    done
  fi
  # Journaled once per select-guard call (the caller — the tick parent —
  # owns deduping this to "once per target per tick" if it wants a single
  # summary line per requirement 5's own wording; this script only knows
  # about the one candidate it was asked about).
  if [ -n "$bi" ]; then
    echo "select same-target cap=$same_target_cap source=$cap_source target=$bi admitted=$((same_target_count + 1))" >&2
    if [ "$same_target_count" -ge "$same_target_cap" ]; then
      echo "blocked: $slug: same-target: $bi already at cap=$same_target_cap (source=$cap_source, $same_target_count admitted this tick)"
      exit 1
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
