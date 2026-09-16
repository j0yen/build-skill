#!/usr/bin/env bash
# lib/gate-patience.sh — PRD-build-gate-patience-from-queue-depth: derives
# how long a gate should wait for a contended producer lock from the ACTUAL
# queue in front of it, instead of a fixed constant. Sourced by
# extend-gate.sh and chain-guard.sh so both compute (and journal) the exact
# same number for the same crate at the same moment — a caller re-deriving
# its own formula is exactly how two callers would disagree about what
# "patience" means for one crate.
#
# Grounding (this PRD's own header): a gate waited 90s x 3 for a lock held
# 1541s by a full cold-cache gate, with 8 branches admitted on one crate —
# every waiter's patience was a constant chosen for one branch per crate,
# never re-derived as per-crate admission grew. Requirement 1:
#   patience_s = max(floor, depth * wall_est)
# where `depth` is the number of OTHER live claims on this build_into
# (lane-claim.sh's own liveness/staleness verdict, never a bare grep of
# Lane: lines — a claim whose coordinator is confirmed gone must not count
# toward how long a sibling waits) and `wall_est` is the median `wall=<s>`
# of the last three `gate <crate> ...` journal lines for this crate,
# falling back to 600s when fewer than one such line exists.
#
# Functions (no side effects beyond stdout/exit code; callers own the
# journal write):
#   gate_patience_depth <build_into> [<exclude_prd_path>] [<prd_dir>]
#       Prints an integer >= 0: live (non-stale) claims on <build_into>,
#       excluding <exclude_prd_path> (the caller's own claim, if any) and
#       excluding <build_into> itself as a claim target when unset.
#   gate_patience_wall_est <journal_file> <crate>
#       Prints an integer: median `wall=<s>` of the last three
#       `gate  <crate>  ...` lines found in <journal_file> (chronological
#       order assumed, as every journal in this codebase is append-only).
#       Prints 600 (the documented fallback) when <journal_file> is
#       missing/empty or no matching line exists.
#   gate_patience_compute <build_into> <crate> <floor> <journal_file> \
#                          [<exclude_prd_path>] [<prd_dir>]
#       Sets GATE_PATIENCE_DEPTH, GATE_PATIENCE_WALL_EST, GATE_PATIENCE_S
#       in the caller's shell (no subshell) and returns 0. Never fails —
#       a missing lane-claim.sh/jq/journal degrades to depth=0/wall_est=600
#       (so patience floors at <floor>) rather than blocking the gate this
#       lib exists to unblock.
#   gate_patience_journal_line <crate> <depth> <wall_est> <patience>
#       Prints (does not write) the exact requirement-1 journal text:
#       "gate  patience  (crate=<name> depth=<n> wall_est=<s> patience=<s>)"
#   gate_patience_contended_line <slug> <crate> <holder_pid> <holder_slug> \
#                                 <holder_age_s> <waited_s>
#       Prints the requirement-2 contended journal text.
#
# Overridable for tests/gatepat_selftest.sh (never touching production
# defaults): GATE_PATIENCE_LANE_CLAIM points at a fake lane-claim.sh so a
# fixture can fabricate claims without a real PRD clone.
set -uo pipefail

GATE_PATIENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_PATIENCE_LANE_CLAIM="${GATE_PATIENCE_LANE_CLAIM:-$GATE_PATIENCE_LIB_DIR/../lane-claim.sh}"
GATE_PATIENCE_JQ="${GATE_PATIENCE_JQ:-jq}"

# Reads the build_into: value out of a PRD file's frontmatter, same three
# forms (bullet/bare/bold) every other reader in this repo accepts —
# duplicated rather than sourced from lane-claim.sh because that script's
# read_build_into() is a private helper, not a published contract, and this
# lib must not assume lane-claim.sh's internals never change shape under it.
_gate_patience_read_build_into() {
  head -n 80 "$1" 2>/dev/null | grep -E '^(- *build_into:|build_into:|\*\*build_into:\*\*)' | head -n1 \
    | sed -E 's/^(- *build_into:|build_into:|\*\*build_into:\*\*)[[:space:]]*//' \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]+$//'
}

_gate_patience_realpath() {
  # readlink -f isn't on every minimal box; fall back to cd+pwd for a path
  # whose dirname exists (true for any PRD file this lib is ever handed).
  if command -v readlink >/dev/null 2>&1 && readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"
    return
  fi
  local d b
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || { printf '%s\n' "$1"; return; }
  b="$(basename "$1")"
  printf '%s/%s\n' "$d" "$b"
}

gate_patience_depth() {
  local build_into="$1" exclude_prd="${2:-}" prd_dir="${3:-$HOME/Documents/PRDs}"
  [ -n "$build_into" ] || { echo 0; return 0; }
  [ -x "$GATE_PATIENCE_LANE_CLAIM" ] || { echo 0; return 0; }
  command -v "$GATE_PATIENCE_JQ" >/dev/null 2>&1 || { echo 0; return 0; }

  local build_into_real; build_into_real="$(_gate_patience_realpath "$build_into")"
  local excl_real=""
  [ -n "$exclude_prd" ] && [ -f "$exclude_prd" ] && excl_real="$(_gate_patience_realpath "$exclude_prd")"

  local json
  json="$("$GATE_PATIENCE_LANE_CLAIM" --json --prd-dir "$prd_dir" 2>/dev/null)" || { echo 0; return 0; }
  [ -n "$json" ] || { echo 0; return 0; }

  local f real bi depth=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    real="$(_gate_patience_realpath "$f")"
    [ -n "$excl_real" ] && [ "$real" = "$excl_real" ] && continue
    bi="$(_gate_patience_read_build_into "$f")"
    [ -n "$bi" ] || continue
    [ "$(_gate_patience_realpath "$bi" 2>/dev/null)" = "$build_into_real" ] || [ "$bi" = "$build_into" ] || continue
    depth=$((depth + 1))
  done < <(printf '%s' "$json" | "$GATE_PATIENCE_JQ" -r '.claims[]? | select(.state != "stale") | .prd' 2>/dev/null)

  echo "$depth"
}

gate_patience_wall_est() {
  local journal_file="$1" crate="$2"
  local fallback=600
  [ -n "$journal_file" ] && [ -f "$journal_file" ] || { echo "$fallback"; return 0; }
  [ -n "$crate" ] || { echo "$fallback"; return 0; }

  # Last three `gate  <crate>  ...  wall=<n>s ...` lines, in file order
  # (journals are append-only chronological) -- `tail -n3` after grep keeps
  # only the most recent three regardless of how many exist.
  local vals
  vals="$(grep -E "  gate  ${crate//./\\.}  " "$journal_file" 2>/dev/null \
    | grep -oE 'wall=[0-9]+s?' | tail -n3 | grep -oE '[0-9]+')"
  [ -n "$vals" ] || { echo "$fallback"; return 0; }

  local sorted n
  sorted="$(printf '%s\n' "$vals" | sort -n)"
  n="$(printf '%s\n' "$sorted" | wc -l)"
  if [ "$((n % 2))" -eq 1 ]; then
    printf '%s\n' "$sorted" | sed -n "$(( (n + 1) / 2 ))p"
  else
    local a b
    a="$(printf '%s\n' "$sorted" | sed -n "$((n / 2))p")"
    b="$(printf '%s\n' "$sorted" | sed -n "$((n / 2 + 1))p")"
    echo $(( (a + b) / 2 ))
  fi
}

# gate_patience_compute <build_into> <crate> <floor> <journal_file> [<exclude_prd>] [<prd_dir>]
# Sets GATE_PATIENCE_DEPTH / GATE_PATIENCE_WALL_EST / GATE_PATIENCE_S in the
# CALLING shell (this function must be invoked, never subshelled/piped, for
# the assignments to be visible — same convention as bash's own `read`).
gate_patience_compute() {
  local build_into="$1" crate="$2" floor="$3" journal_file="$4"
  local exclude_prd="${5:-}" prd_dir="${6:-$HOME/Documents/PRDs}"

  GATE_PATIENCE_DEPTH="$(gate_patience_depth "$build_into" "$exclude_prd" "$prd_dir")"
  GATE_PATIENCE_WALL_EST="$(gate_patience_wall_est "$journal_file" "$crate")"

  local raw=$(( GATE_PATIENCE_DEPTH * GATE_PATIENCE_WALL_EST ))
  if [ "$raw" -gt "$floor" ] 2>/dev/null; then
    GATE_PATIENCE_S="$raw"
  else
    GATE_PATIENCE_S="$floor"
  fi
  return 0
}

gate_patience_journal_line() {
  local crate="$1" depth="$2" wall_est="$3" patience="$4"
  printf '%s  gate  patience  (crate=%s depth=%s wall_est=%s patience=%s)' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$crate" "$depth" "$wall_est" "$patience"
}

gate_patience_contended_line() {
  local slug="$1" crate="$2" holder_pid="$3" holder_slug="$4" holder_age_s="$5" waited_s="$6"
  printf '%s  gate  %s  contended  (crate=%s holder_pid=%s holder_slug=%s holder_age_s=%s waited_s=%s)' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$crate" "$holder_pid" "$holder_slug" "$holder_age_s" "$waited_s"
}
