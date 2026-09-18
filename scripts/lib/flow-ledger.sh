#!/usr/bin/env bash
# lib/flow-ledger.sh — the one flow_ledger_append, shared by every
# lifecycle script that records a build-flow stage transition
# (PRD-build-flow-ledger). Source this; never execute it.
#
# The problem this fixes: `ticks_invested` was null on 97.7% of manifest
# entries because the only per-PRD counters were written by a model in a
# Phase 7 patch. This library gives every lifecycle script (lane-claim.sh,
# worktree-extend.sh, gate-launch.sh, extend-gate.sh, archive-commit.sh,
# manifest-set.sh, manifest-reconcile.sh -- the actual first-sight-of-a-
# new-PRD writer; scan-prds.sh itself never touches the manifest, only
# emits JSON, see that script's own header -- mark-needs-classification.sh)
# one call to
# append a fact — `{ts, slug, stage, lane, sha?, detail?}` — to one
# append-only ledger, at the point of action, never re-derived after the
# fact by a model guessing at elapsed time.
#
# Stages (Requirement 1): queued, claimed, first_commit, gate_start,
# gate_verdict (detail carries `verdict=pass|delta-pass|block|infra`),
# landed, archived, blocked, unblocked, needs_classification.
#
# API:
#   flow_ledger_append <slug> <stage> [--lane <lane>] [--sha <sha>] [--detail <text>]
#     Appends one JSON line under `flock` (Technical considerations).
#     NEVER fails the caller (Requirement 2) — a write failure (unwritable
#     ledger, missing jq, lock timeout) is swallowed and journaled once via
#     lib/journal.sh's journal_line, and the function still returns 0.
#
# Env:
#   FLOW_LEDGER_FILE   override the ledger path entirely (selftests).
#                      Default: ${BUILD_STATE_DIR:-<skill-root>/state}/flow-ledger.jsonl
#   FLOW_LEDGER_JQ     override the `jq` binary (selftests).
#   FLOW_LEDGER_LOCK_TIMEOUT  seconds to wait for the append flock (default 2).

_FLOW_LEDGER_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FLOW_LEDGER_LIB_SKILL_DIR="$(cd "$_FLOW_LEDGER_LIB_HERE/../.." && pwd)"

# shellcheck source=journal.sh
source "$_FLOW_LEDGER_LIB_HERE/journal.sh"

flow_ledger_path() {
  printf '%s\n' "${FLOW_LEDGER_FILE:-${BUILD_STATE_DIR:-$_FLOW_LEDGER_LIB_SKILL_DIR/state}/flow-ledger.jsonl}"
}

flow_ledger_append() {
  local slug="${1:-}" stage="${2:-}"
  [ -n "$slug" ] && [ -n "$stage" ] || { echo "flow_ledger_append: slug and stage required" >&2; return 0; }
  shift 2 2>/dev/null || shift $#
  local lane="" sha="" detail=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane) lane="${2:-}"; shift 2 ;;
      --sha) sha="${2:-}"; shift 2 ;;
      --detail) detail="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$lane" ] || lane="$(hostname 2>/dev/null || echo unknown)"

  local jq_bin="${FLOW_LEDGER_JQ:-jq}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local ledger; ledger="$(flow_ledger_path)"
  local timeout="${FLOW_LEDGER_LOCK_TIMEOUT:-2}"

  local line
  line="$("$jq_bin" -n \
    --arg ts "$ts" --arg slug "$slug" --arg stage "$stage" --arg lane "$lane" \
    --arg sha "$sha" --arg detail "$detail" \
    '{ts:$ts, slug:$slug, stage:$stage, lane:$lane}
     + (if $sha != "" then {sha:$sha} else {} end)
     + (if $detail != "" then {detail:$detail} else {} end)' 2>/dev/null)"
  if [ -z "$line" ]; then
    journal_line "flow-ledger append-failed (slug=$slug stage=$stage reason=jq-render)"
    return 0
  fi

  local ledger_dir; ledger_dir="$(dirname "$ledger")"
  if ! mkdir -p "$ledger_dir" 2>/dev/null; then
    journal_line "flow-ledger append-failed (slug=$slug stage=$stage reason=mkdir path=$ledger)"
    return 0
  fi

  if (
      flock -w "$timeout" 200 || exit 1
      printf '%s\n' "$line" >> "$ledger"
    ) 200>>"$ledger.lock" 2>/dev/null
  then
    :
  else
    journal_line "flow-ledger append-failed (slug=$slug stage=$stage reason=write-or-lock path=$ledger)"
  fi
  return 0
}
