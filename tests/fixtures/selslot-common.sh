#!/usr/bin/env bash
# selslot-common.sh — shared scratch-fixture harness for the
# tests/selslot_ac*.sh files (PRD-build-select-guard-depends-before-slot).
#
# Mirrors scripts/select-guard-selftest.sh's own convention exactly (bare
# git origin, clone, synthetic PRD files under build-queue/, an empty
# built-prds/ so every named Depends-on starts out unmet) — never touches
# the real ~/Documents/PRDs clone, never a real host or network call
# (AC10). $SG always runs with BUILD_DISTINCT_TARGETS=1/
# BUILD_SAME_TARGET_CAP=1 forced regardless of the caller's own ambient
# environment (a live /build tick's shell commonly exports
# BUILD_DISTINCT_TARGETS=0 for its own orchestration — without forcing it
# here, these fixtures would flake under exactly the environment they're
# meant to run in).
#
# Sourced by each tests/selslot_ac*.sh file. Callers must call
# selslot_setup first; the EXIT trap it installs cleans up.
set -uo pipefail

SELSLOT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SG="$SELSLOT_HERE/../scripts/select-guard.sh"
DG="$SELSLOT_HERE/../scripts/lib/depends-gate.sh"

selslot_setup() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/selslot-ac.XXXXXX")
  trap 'rm -rf "$ROOT"' EXIT
  git init -q --bare "$ROOT/origin.git"
  git clone -q "$ROOT/origin.git" "$ROOT/clone"
  mkdir -p "$ROOT/clone/build-queue" "$ROOT/clone/built-prds"
  JOURNAL_DIR="$ROOT/journal"
  mkdir -p "$JOURNAL_DIR"
  export JOURNAL_DIR
  SELECT_GUARD_JOURNAL="$ROOT/select-guard-journal.md"
  : > "$SELECT_GUARD_JOURNAL"
  export SELECT_GUARD_JOURNAL
}

selslot_write_prd() {
  # selslot_write_prd <slug> <build_into> [depends_on_filename]
  local slug="$1" bi="$2" dep="${3:-}"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: queued"
    echo "- build_target: shell"
    echo "- build_into: $bi"
    echo "- build_priority: high"
    [ -n "$dep" ] && echo "- Depends-on: $dep"
  } > "$ROOT/clone/build-queue/PRD-$slug.md"
}

selslot_commit() {
  git -C "$ROOT/clone" add -A
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "selslot fixture"
  local branch
  branch=$(git -C "$ROOT/clone" symbolic-ref --short HEAD)
  git -C "$ROOT/clone" push -q origin "$branch"
}

selslot_guard() {
  # selslot_guard <slug> [branch-count] [admitted-targets]
  local slug="$1" bc="${2:-0}" at="${3:-}"
  BUILD_DISTINCT_TARGETS=1 BUILD_SAME_TARGET_CAP=1 "$SG" "$slug" carbon "$ROOT/clone" "$bc" "$at"
}
