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
#                                       BUILD_MAX_BRANCHES cap, same-target,
#                                       or "gated: depends-on: <names>",
#                                       PRD-build-select-guard-depends-
#                                       before-slot, evaluated before every
#                                       other check below) exactly as
#                                       lane-predicate.sh reported it (or,
#                                       for the cap/same-target/depends-on
#                                       checks, this script's own). A
#                                       depends-on gate never touches
#                                       admitted-targets state — nothing it
#                                       blocks ever consumes a slot.
# Exit 4                               usage error / PRD file not found.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_PREDICATE="$HERE/lane-predicate.sh"
# shellcheck source=lib/depends-gate.sh
source "$HERE/lib/depends-gate.sh"
# shellcheck source=lib/probe.sh
source "$HERE/lib/probe.sh"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

die() { echo "select-guard: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: select-guard.sh <slug> [lane-name] [prd-dir] [branch-count] [admitted-targets]" >&2; exit 4; }

# select_guard_journal_line — PRD-build-gate-before-land requirement 7:
# durable record of a same-target admit/block decision, so a post-tick
# digest (scripts/serialization-digest.sh) can compute `waits=<n>` from
# the shared journal alone, the same way it reads extend-gate.sh's and
# worktree-extend.sh's own journal lines for the gate/land counters.
# PRD-build-journal-single-writer requirement 1: routed through the one
# journal_line (scripts/lib/journal.sh) instead of a private printf >>
# writer — journal_line already honors SELECT_GUARD_JOURNAL as a legacy
# alias (same override this function always accepted) and BUILD_TEST=1 /
# BUILD_JOURNAL_ROOT for isolation, plus its own production fixture-shaped
# refusal. The isolation-guard.sh pre-check below is kept as a second,
# independent belt-and-suspenders layer against a resolved live path.
select_guard_journal_line() {
  local slug="$1" outcome="$2" detail="$3"
  local journal_probe="${SELECT_GUARD_JOURNAL:-$(journal_root)/$(date -u +%Y-%m-%d).md}"
  if [ -r "$HERE/isolation-guard.sh" ]; then
    # shellcheck source=isolation-guard.sh
    source "$HERE/isolation-guard.sh"
    isolation_guard_path "$journal_probe" "select-guard.sh"
  fi
  journal_line "$(printf '%s  select  %s  %s  (%s)' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$outcome" "$detail")" || true
}

# select_guard_journal_gated — PRD-build-select-guard-depends-before-slot
# requirement 4: a candidate refused by a skip-class gate (Depends-on today
# — one that means the PRD cannot run this tick regardless of slots, as
# opposed to the cap/same-target checks below which are about slot
# availability) is journaled as one exact-format line so a status sweep can
# grep for it without replaying the tick. Deliberately NOT timestamp-
# prefixed like select_guard_journal_line above — this line's format is a
# literal contract (requirement 4's AC asserts it with string equality).
# Same override/isolation-guard.sh convention as select_guard_journal_line.
select_guard_journal_gated() {
  local slug="$1" reason="$2"
  local journal_probe="${SELECT_GUARD_JOURNAL:-$(journal_root)/$(date -u +%Y-%m-%d).md}"
  if [ -r "$HERE/isolation-guard.sh" ]; then
    # shellcheck source=isolation-guard.sh
    source "$HERE/isolation-guard.sh"
    isolation_guard_path "$journal_probe" "select-guard.sh"
  fi
  journal_line "$(printf 'select: %s gated (%s) slot-not-consumed' "$slug" "$reason")" || true
}

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

  # Depends-on gate (PRD-build-select-guard-depends-before-slot requirement
  # 1), evaluated before EVERY slot-pre-reservation check below (cap,
  # same-target) — an unmet dependency is cheaper to check and more common
  # in the failure record (2026-09-14 ticks 6/7) than the cap ever binding.
  # Shared with anything standing in for the coordinator's own Depends-on
  # check via scripts/lib/depends-gate.sh's depends_gate_unmet(), sourced
  # above — one definition, so this call and the coordinator's can never
  # disagree about what "unmet" means. On unmet, this returns WITHOUT
  # touching admitted_targets/same_target_count logic at all: the whole
  # point is that a gated candidate never spends the slot a runnable
  # same-target sibling needs.
  local built_prds_dir="$prd_dir/built-prds"
  local unmet unmet_rc
  unmet=$(depends_gate_unmet "$prd" "$built_prds_dir"); unmet_rc=$?
  if [ "$unmet_rc" -ne 0 ]; then
    local unmet_csv; unmet_csv=$(printf '%s' "$unmet" | tr '\n' ',' | sed 's/,$//')
    select_guard_journal_gated "$slug" depends-on
    echo "blocked: $slug: gated: depends-on: $unmet_csv"
    exit 1
  fi

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
        # PRD-build-fail-loud-evidence-kept AC3/requirement 2: probe_run
        # keeps this probe's stderr (was /dev/null) and journals rc/err/log
        # on failure. Before this, a failed status probe left bstatus empty,
        # gate_ready empty, and the cap silently stayed "local" with no line
        # at all — the caller could not tell "no burst session" from "could
        # not ask". A failed probe now journals its own explicit
        # `cap local (cause=probe-failed)` decision.
        if bstatus="$(probe_run burst-status -- "$burst_bin" status --json)"; then
          gate_ready="$(printf '%s' "$bstatus" | jq -r '.gate_ready // empty' 2>/dev/null || true)"
        else
          gate_ready=""
          select_guard_journal_line "$slug" cap-local "cause=probe-failed"
        fi
        if [ "$gate_ready" = "true" ]; then
          width="$(printf '%s' "$bstatus" | jq -r '.width // .run_slots.cap // empty' 2>/dev/null || true)"
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
      # PRD-build-gate-before-land requirement 7 (P1): a same-target-cap
      # block is a "wait" for the tick's `serialization:` summary line
      # (scripts/serialization-digest.sh) — the only place that number can
      # come from, since select-guard.sh's stderr above is per-invocation,
      # not durable. Written to the SAME shared journal every other build
      # script uses, same isolation-guard.sh default-deny convention.
      select_guard_journal_line "$slug" same-target-blocked "target=$bi cap=$same_target_cap source=$cap_source admitted_this_tick=$same_target_count"
      echo "blocked: $slug: same-target: $bi already at cap=$same_target_cap (source=$cap_source, $same_target_count admitted this tick)"
      exit 1
    fi
    select_guard_journal_line "$slug" same-target-admit "target=$bi cap=$same_target_cap source=$cap_source admitted_this_tick=$((same_target_count + 1))"
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
