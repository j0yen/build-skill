#!/usr/bin/env bash
# manifest-write-durability.sh — Stress-test for manifest sidecar durability
#
# Acceptance criterion 1: N=12 concurrent writers each update a distinct
# slug's status; after all exit, all 12 updates are present in manifest.json
# (0 lost writes) across 20 repeated runs.
#
# Acceptance criterion 3: jq -e . state/manifest.json stays valid after
# every concurrent run (no torn/partial writes).
#
# Usage:
#   tests/manifest-write-durability.sh [--writers N] [--runs M] [--verbose]
#
# Exit: 0 = all runs passed, 1 = at least one failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$SKILL_DIR/scripts"
JQ="${JQ:-jq}"

N_WRITERS=12
N_RUNS=20
verbose=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --writers) N_WRITERS="$2" ; shift 2 ;;
    --runs)    N_RUNS="$2"    ; shift 2 ;;
    --verbose) verbose=true   ; shift ;;
    *) echo "unknown arg: $1" >&2 ; exit 2 ;;
  esac
done

# ── scratch environment ───────────────────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d /tmp/mwd-test.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

pass=0
fail=0

run_once() {
  local run_id="$1"
  local state_dir="$TMPDIR_ROOT/run-${run_id}/state"
  local status_dir="$state_dir/status"
  local manifest="$state_dir/manifest.json"
  local lock="$state_dir/manifest.lock"

  mkdir -p "$status_dir"

  # Seed manifest with the slugs we'll update
  local prds_json="["
  for i in $(seq 1 "$N_WRITERS"); do
    local slug="stress-writer-${run_id}-${i}"
    [ "$i" -gt 1 ] && prds_json+=","
    prds_json+="$(printf '{"slug":"%s","status":"queued","ticks_invested":0,"build_auto":true,"build_target":null,"revision":1,"last_action":null,"last_error":null,"output_repo_path":null,"output_repo_url":null,"version_bump":null,"blockers":[]}' "$slug")"
  done
  prds_json+="]"
  printf '{"prds":%s,"generated_at":"test"}' "$prds_json" > "$manifest"

  # Spawn N concurrent sidecar writers
  local pids=()
  for i in $(seq 1 "$N_WRITERS"); do
    local slug="stress-writer-${run_id}-${i}"
    (
      STATE_DIR="$state_dir" \
      JQ="$JQ" \
      SKILL_DIR="$TMPDIR_ROOT/run-${run_id}" \
      bash "$SCRIPTS_DIR/manifest-sidecar.sh" write "$slug" \
        status=shipped \
        last_action="$(date -u +%FT%TZ)" \
        ticks_invested_delta=1 \
        action=stress-test \
        outcome=ok
    ) &
    pids+=($!)
  done

  # Wait for all writers
  local writer_failed=false
  for pid in "${pids[@]}"; do
    wait "$pid" || writer_failed=true
  done
  if $writer_failed; then
    echo "run $run_id: FAIL — at least one writer exited non-zero" >&2
    return 1
  fi

  # Now merge sidecars into manifest
  STATUS_DIR="$status_dir" \
  STATE_DIR="$state_dir" \
  MANIFEST="$manifest" \
  LOCK="$lock" \
  JQ="$JQ" \
    bash "$SCRIPTS_DIR/manifest-merge-sidecars.sh" --dir "$status_dir" --cleanup \
    >/dev/null 2>&1

  # Validate: manifest must be valid JSON
  if ! "$JQ" -e . "$manifest" >/dev/null 2>&1; then
    echo "run $run_id: FAIL — manifest.json is not valid JSON" >&2
    return 1
  fi

  # Validate: all N slugs must have status=shipped
  local lost
  lost=0
  for i in $(seq 1 "$N_WRITERS"); do
    local slug="stress-writer-${run_id}-${i}"
    local got
    got="$("$JQ" -r --arg s "$slug" '.prds[] | select(.slug==$s) | .status' "$manifest" 2>/dev/null || echo "")"
    if [ "$got" != "shipped" ]; then
      lost=$((lost + 1))
      $verbose && echo "run $run_id: MISSING slug=$slug got='$got'" >&2
    fi
  done

  if [ "$lost" -gt 0 ]; then
    echo "run $run_id: FAIL — $lost/$N_WRITERS writes lost" >&2
    return 1
  fi

  $verbose && echo "run $run_id: PASS — all $N_WRITERS writes present"
  return 0
}

echo "manifest-write-durability: N_WRITERS=$N_WRITERS N_RUNS=$N_RUNS"

for r in $(seq 1 "$N_RUNS"); do
  if run_once "$r"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "manifest-write-durability: $pass/$N_RUNS passed, $fail failed"

[ "$fail" -eq 0 ]
