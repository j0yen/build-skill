#!/usr/bin/env bash
# chain-guard.sh — mechanical precondition + stop-condition check for
# in-tick chained-step continuation (PRD-build-chained-tick-actions).
#
# Operator authorization (Joe, 2026-09-09, verbatim): "does it have to be
# one action per PRD for tick? Can we expand thsis?" -> "no chain cap".
# Requirement 1 lets a branch agent, after committing a step's manifest
# transition, re-check the SAME preconditions the tick parent would use
# to select this PRD again, and — if they hold — perform the next step in
# the same dispatch instead of waiting for the next tick. This script is
# that re-check, made mechanical rather than left to branch-agent prose:
# SKILL.md's Phase 4 "In-tick chaining" section calls it once per prospective
# step. It does not perform the step itself and does not write the manifest;
# it only answers "may the SAME PRD's NEXT step run now, in this dispatch?".
#
# Usage:
#   chain-guard.sh check <slug> [options]
#
# Options:
#   --step-count N         Steps already chained THIS dispatch for this slug
#                           (default 0 — i.e. this call is for step 1's
#                           follow-up, the 2nd step overall).
#   --max-steps N           Explicit cap, overrides $CHAIN_MAX_STEPS. Requirement 4:
#                           an UNSET cap (no flag, no env var) means unlimited —
#                           the stop conditions below are the only limits.
#   --reflect-candidate     This PRD is this tick's ONE designated Phase-6
#                           reflect candidate (requirement 5 — the ≤1/tick
#                           invariant stands; never chained past its one action).
#   --integrate-lock PATH   Path to the target repo's
#                           .git/autobuilder-integrate.lock — probed before an
#                           integrate/gate step so a chain never waits past the
#                           bound past this call's own budget.
#   --lock-wait N           Seconds to wait for --integrate-lock (default 60,
#                           matching requirement 1's "60 s" and requirement 3's
#                           "not acquired within 60 s"). Selftests may pass a
#                           smaller value to keep runs fast; the SKILL.md
#                           contract for a live dispatch is the 60s default.
#   --lane NAME             Forwarded to select-guard.sh (default: hostname).
#   --prd-dir DIR           Forwarded to select-guard.sh (default: ~/Documents/PRDs).
#   --skip-select-guard     Skip the select-guard.sh re-check (used by
#                           selftests that only want to exercise the
#                           manifest-state / cap / lock checks in isolation).
#
# Reads the manifest via $BUILD_MANIFEST (default:
# <skill-dir>/state/manifest.json), same convention as manifest-set.sh, so
# tests can sandbox it with BUILD_STATE_DIR/BUILD_MANIFEST exactly as
# tests/manifest-set.sh already does.
#
# Exit 0 + "continue: <slug>: <reason>"   the next step may run now.
# Exit 1 + "stop: <slug>: <reason>"       chaining stops; <reason> is one of:
#   excluded-kernel-extend | excluded-reflect-candidate | archive-done |
#   blockers | needs-user | cap | lock-contended | target-busy: <detail> |
#   no-manifest-entry
# Exit 4                                   usage / IO error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
SELECT_GUARD="$HERE/select-guard.sh"

die() { echo "chain-guard: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: chain-guard.sh check <slug> [options]" >&2; exit 4; }

# Read one field of prds.<slug> from the manifest as a bare string.
# "status"/"build_target" -> the scalar (empty if null/absent).
# "blockers" -> "0" (empty array/absent) or "N" (array length).
manifest_field() {
  local slug="$1" field="$2"
  MANIFEST="$MANIFEST" python3 - "$slug" "$field" <<'PY'
import json, os, sys
slug, field = sys.argv[1], sys.argv[2]
path = os.environ["MANIFEST"]
try:
    with open(path) as f:
        m = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print("__NO_ENTRY__")
    raise SystemExit(0)
prds = m.get("prds", {})
if isinstance(prds, list):
    entry = next((p for p in prds if isinstance(p, dict) and p.get("slug") == slug), None)
else:
    entry = prds.get(slug)
if not isinstance(entry, dict):
    print("__NO_ENTRY__")
    raise SystemExit(0)
if field == "blockers":
    b = entry.get("blockers") or []
    print(len(b) if isinstance(b, list) else 0)
else:
    v = entry.get(field)
    print("" if v is None else v)
PY
}

cmd_check() {
  local slug="${1:-}"; shift || true
  [ -n "$slug" ] || usage

  local step_count=0 max_steps="${CHAIN_MAX_STEPS:-}" reflect_candidate=0
  local integrate_lock="" lock_wait=60 lane="$(hostname)" prd_dir="$HOME/Documents/PRDs"
  local skip_select_guard=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --step-count) step_count="${2:-0}"; shift 2 ;;
      --max-steps) max_steps="${2:-}"; shift 2 ;;
      --reflect-candidate) reflect_candidate=1; shift ;;
      --integrate-lock) integrate_lock="${2:-}"; shift 2 ;;
      --lock-wait) lock_wait="${2:-60}"; shift 2 ;;
      --lane) lane="${2:-}"; shift 2 ;;
      --prd-dir) prd_dir="${2:-}"; shift 2 ;;
      --skip-select-guard) skip_select_guard=1; shift ;;
      *) die "unknown option: $1" 4 ;;
    esac
  done

  # Requirement 5 — kernel-extend and the tick's one reflect candidate never
  # chain, checked BEFORE anything else so no other precondition can
  # override this exclusion.
  local build_target; build_target="$(manifest_field "$slug" build_target)"
  if [ "$build_target" = "kernel-extend" ]; then
    echo "stop: $slug: excluded-kernel-extend"
    return 1
  fi
  if [ "$reflect_candidate" -eq 1 ]; then
    echo "stop: $slug: excluded-reflect-candidate"
    return 1
  fi

  local status; status="$(manifest_field "$slug" status)"
  if [ "$status" = "__NO_ENTRY__" ]; then
    echo "stop: $slug: no-manifest-entry"
    return 1
  fi
  if [ "$status" = "shipped" ]; then
    echo "stop: $slug: archive-done"
    return 1
  fi

  local blockers_n; blockers_n="$(manifest_field "$slug" blockers)"
  if [ "${blockers_n:-0}" -gt 0 ] 2>/dev/null; then
    echo "stop: $slug: blockers"
    return 1
  fi

  if [ "$status" = "needs_classification" ] || [ "$status" = "needs_user" ] || [ "$status" = "needs-user" ]; then
    echo "stop: $slug: needs-user"
    return 1
  fi

  # Requirement 4 — cap ONLY applies when explicitly set (env or --max-steps).
  if [ -n "$max_steps" ]; then
    if [ "$step_count" -ge "$max_steps" ] 2>/dev/null; then
      echo "stop: $slug: cap"
      return 1
    fi
  fi

  # Requirement 1 / 3 — integrate lock acquirable without waiting past the
  # bound (default 60s). A successful probe releases the lock immediately;
  # the real integrate/gate step re-acquires it for its own actual work.
  if [ -n "$integrate_lock" ]; then
    mkdir -p "$(dirname "$integrate_lock")" 2>/dev/null || true
    if ! flock -w "$lock_wait" "$integrate_lock" -c true 2>/dev/null; then
      echo "stop: $slug: lock-contended"
      return 1
    fi
  fi

  # Requirement 1 — re-check sub-cap/cargo-budget/burst-route exactly as
  # the tick parent's dispatch-boundary guard would (SKILL.md's
  # select-guard.sh call site).
  if [ "$skip_select_guard" -eq 0 ] && [ -x "$SELECT_GUARD" ]; then
    local sg_out sg_rc
    sg_out="$("$SELECT_GUARD" "$slug" "$lane" "$prd_dir" 2>&1)"
    sg_rc=$?
    if [ "$sg_rc" -ne 0 ]; then
      echo "stop: $slug: target-busy: ${sg_out#blocked: $slug: }"
      return 1
    fi
  fi

  echo "continue: $slug: preconditions-hold"
  return 0
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    check) cmd_check "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
