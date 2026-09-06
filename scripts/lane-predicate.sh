#!/usr/bin/env bash
# lane-predicate.sh — Phase 2 lane-aware selection predicate (PRD-build-
# second-lane-carbon P0 "Lane predicate" + "Target-repo exclusivity").
#
# Two /build lanes share one PRD clone: RedBaron (unrestricted — the
# filter below is an optimization on carbon, never a partition that
# strands work) and carbon (cargo-free only). The lane is taken from
# hostname by default so the tick scripts need no fork or env drop-in
# (Technical considerations: "must take the lane predicate from hostname
# or an env drop-in rather than a fork of the script").
#
# Subcommands:
#   lane-predicate.sh select <prd-path> [lane-name] [prd-dir]
#       Exit 0 + "ok: <reason>"   if this lane may select the PRD this tick.
#       Exit 1 + "skip: <reason>" if it must not (cargo-bound on carbon, or
#                                  another lane holds a live claim on the
#                                  same build_into).
#       Exit 4                    usage / missing file.
#   lane-predicate.sh reachable [repo-path]
#       Exit 0 + "reachable"      origin answers `git ls-remote`.
#       Exit 1 + "unreachable"    it does not — caller must idle rather
#                                  than build unclaimed (AC7).
#       repo-path defaults to ~/Documents/PRDs.
#
# RedBaron is always unrestricted by build_target (it may still build
# cargo-free PRDs) but is NOT exempt from target-repo exclusivity — two
# lanes never mutate one build_into concurrently regardless of which
# lane is "the" cargo lane.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_CLAIM="$HERE/lane-claim.sh"

# build_target values PRD-build-second-lane-carbon P0 declares cargo-free.
CARGO_FREE_TARGETS="python-cli python-lib python-agent shell hooks config notebook"

die() { echo "lane-predicate: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: lane-predicate.sh {select|reachable} ..." >&2; exit 4; }

read_field() {
  # $1 = file, $2 = key (e.g. build_target)
  local f="$1" key="$2"
  head -n 80 "$f" \
    | grep -E "^(- *${key}:|${key}:|\*\*${key}:\*\*)" | head -n1 \
    | sed -E "s/^(- *${key}:|${key}:|\*\*${key}:\*\*)[[:space:]]*//" \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]+$//'
}

is_cargo_free() {
  local t="$1" x
  for x in $CARGO_FREE_TARGETS; do [ "$x" = "$t" ] && return 0; done
  return 1
}

cmd_select() {
  local prd="$1" lane="${2:-$(hostname)}" prd_dir="${3:-$HOME/Documents/PRDs}"
  [ -f "$prd" ] || die "no such file: $prd" 4

  local bt; bt=$(read_field "$prd" build_target)
  if [ "${lane,,}" != "redbaron" ] && ! is_cargo_free "$bt"; then
    echo "skip: cargo-bound build_target=${bt:-<none>} (lane $lane restricted to cargo-free)"
    exit 1
  fi

  # Target-repo exclusivity applies to every lane, not just carbon.
  local bi; bi=$(read_field "$prd" build_into)
  if [ -n "$bi" ] && [ -x "$LANE_CLAIM" ]; then
    local busy_out
    if ! busy_out=$("$LANE_CLAIM" target-busy "$bi" --exclude-prd "$prd" --prd-dir "$prd_dir" 2>&1); then
      echo "skip: $busy_out"
      exit 1
    fi
  fi

  echo "ok: lane=$lane build_target=${bt:-<none>}"
  exit 0
}

cmd_reachable() {
  local root="${1:-$HOME/Documents/PRDs}"
  # Deliberately no --exit-code: that flag makes ls-remote exit 2 for a
  # remote with zero matching refs, which is indistinguishable from a
  # genuinely unreachable one — an empty-but-reachable remote must still
  # report "reachable" here. Plain ls-remote exits 0 iff it could talk to
  # the remote at all, regardless of what (if anything) it found.
  if git -C "$root" ls-remote origin >/dev/null 2>&1; then
    echo "reachable"
    exit 0
  fi
  echo "unreachable"
  exit 1
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    select)    [ $# -ge 1 ] || usage; cmd_select "$@" ;;
    reachable) cmd_reachable "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
