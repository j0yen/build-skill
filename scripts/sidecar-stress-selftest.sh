#!/usr/bin/env bash
# sidecar-stress-selftest.sh — AC1 stress harness for build-manifest-write-durability
#
# Proves the sidecar + parent-merge mechanism (manifest-sidecar.sh +
# manifest-merge-sidecars.sh) loses ZERO writes under N-way concurrent
# branch contention — the race class that, pre-sidecar, dropped 2/9
# branches in the 2026-05-30 tick.
#
# What it does (per the PRD acceptance):
#   AC1: spawn N concurrent writers, each updating a DISTINCT slug's status;
#        after merge, all N updates are present (0 lost writes); repeat R times.
#   AC3: jq -e . manifest.json stays valid after every run (no torn writes).
#   AC4: after --cleanup, no sidecar files remain (no cruft).
#
# Usage:
#   sidecar-stress-selftest.sh [N] [R]
#     N  concurrent writers per run (default 12)
#     R  number of repeated runs   (default 20)
#
# Runs entirely in a throwaway temp STATE_DIR via the scripts' env overrides;
# the live state/manifest.json is never touched.
#
# Exit 0 = all runs clean. Exit 1 = a lost write / torn manifest / cruft.

set -uo pipefail

N="${1:-12}"
R="${2:-20}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDECAR="$SCRIPT_DIR/manifest-sidecar.sh"
MERGE="$SCRIPT_DIR/manifest-merge-sidecars.sh"

for f in "$SIDECAR" "$MERGE"; do
  [ -x "$f" ] || { echo "FAIL: missing/non-exec $f" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-stress.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export STATE_DIR="$WORK/state"
export STATUS_DIR="$STATE_DIR/status"
export MANIFEST="$STATE_DIR/manifest.json"
export LOCK="$STATE_DIR/manifest.lock"
mkdir -p "$STATUS_DIR"

fail=0

# Build a fresh manifest with N distinct slugs all at status=queued.
seed_manifest() {
  jq -n --argjson n "$N" '
    {prds: [range(0;$n) | {
      slug: ("stress-slug-" + (. | tostring | ("00"+.)[-2:])),
      path: null,
      status: "queued",
      build_auto: true,
      build_target: "shell",
      revision: 1,
      last_action: "1970-01-01T00:00:00Z",
      ticks_invested: 0,
      blockers: []
    }]}' > "$MANIFEST"
}

slug_for() { printf 'stress-slug-%02d' "$1"; }

run_once() {
  local run_idx="$1"
  seed_manifest

  # Fan out N concurrent writers, each a DISTINCT slug -> status=shipped.
  local pids=()
  local i
  for ((i=0; i<N; i++)); do
    local s; s="$(slug_for "$i")"
    STATE_DIR="$STATE_DIR" STATUS_DIR="$STATUS_DIR" \
      "$SIDECAR" write "$s" \
        status=shipped \
        last_action="2026-01-01T00:00:0${run_idx}Z" \
        ticks_invested_delta=1 \
        action=stress outcome="run-$run_idx" \
      >/dev/null 2>&1 &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done

  # Parent serial merge + cleanup.
  if ! "$MERGE" --cleanup >/dev/null 2>&1; then
    echo "FAIL run $run_idx: merge exited non-zero" >&2
    return 1
  fi

  # AC3: manifest still valid JSON.
  if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    echo "FAIL run $run_idx: manifest.json is torn/invalid" >&2
    return 1
  fi

  # AC1: every slug must now read status=shipped (0 lost writes).
  local got
  got="$(jq -r '[.prds[] | select(.status=="shipped")] | length' "$MANIFEST")"
  if [ "$got" -ne "$N" ]; then
    echo "FAIL run $run_idx: expected $N shipped, got $got (lost $((N-got)) write(s))" >&2
    jq -r '.prds[] | select(.status!="shipped") | "  lost: \(.slug) status=\(.status)"' "$MANIFEST" >&2
    return 1
  fi

  # AC4: no sidecar cruft left behind after cleanup.
  local leftover
  leftover="$(find "$STATUS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
  if [ "$leftover" -ne 0 ]; then
    echo "FAIL run $run_idx: $leftover sidecar file(s) left after --cleanup" >&2
    return 1
  fi

  return 0
}

echo "sidecar-stress-selftest: N=$N writers x R=$R runs"
for ((r=0; r<R; r++)); do
  if ! run_once "$r"; then
    fail=1
    break
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: $R runs x $N concurrent writers — 0 lost writes, manifest valid every run, no cruft."
  exit 0
else
  echo "FAILED stress selftest." >&2
  exit 1
fi
