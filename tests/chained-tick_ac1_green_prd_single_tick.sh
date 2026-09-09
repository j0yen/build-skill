#!/usr/bin/env bash
# chained-tick_ac1_green_prd_single_tick.sh — PRD-build-chained-tick-actions AC1.
#
# Given a shell-target fixture PRD that is green end-to-end, When one tick
# dispatches it, Then it reaches archived in that ONE tick with one manifest
# transition committed per step (inspectable in the fixture manifest's audit
# trail).
#
# This exercises the mechanical half of the contract (chain-guard.sh's
# precondition re-check + manifest-set.sh's per-step commit), driving a
# fixture PRD through the same step sequence SKILL.md's Phase 4 describes
# for a shell target (implement -> install/wire -> archive), calling
# chain-guard.sh between every pair of steps exactly as a chaining branch
# agent would, and using the per-step journal lines (requirement 6's
# `chain: <slug> step <k> <action> -> <result>` format) as the audit trail.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$CG" ] && [ -x "$MS" ] || { echo "ac1: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/chained-tick-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"
SLUG="green-fixture"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

mkdir -p "$T/build-queue"
cat > "$T/build-queue/PRD-$SLUG.md" <<EOF
# PRD: $SLUG
- Status: queued
- build_target: shell
- publish: none
EOF

cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "queued", "build_target": "shell", "blockers": []}}}
JSON

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"][sys.argv[2]].get(sys.argv[3]))' "$BUILD_MANIFEST" "$1" "$2"; }

patch() { # <step-json>
  local f; f="$(mktemp "$T/patch.XXXXXX.json")"
  printf '%s' "$1" > "$f"
  "$MS" "$SLUG" "$f"
}

step_and_log() { # <k> <action> <patch-json>
  local k="$1" action="$2" patch_json="$3"
  patch "$patch_json"
  printf 'chain: %s step %s %s -> committed\n' "$SLUG" "$k" "$action" >> "$JOURNAL"
}

# Step 1: implement (unconditional — the tick's normal Phase-4 dispatch,
# no chain-guard re-check needed ahead of the FIRST action).
step_and_log 1 implement '{"status":"in_progress","last_action":"2026-09-09T00:00:01Z","chained_steps":1}'

out="$("$CG" check "$SLUG" --step-count 1 --prd-dir "$T")"; rc=$?
expect "after step 1, chain-guard says continue" "[ $rc -eq 0 ]"
expect "reason is preconditions-hold" "grep -q 'preconditions-hold' <<<\"\$out\""

# Step 2: install/wire.
step_and_log 2 install-wire '{"status":"in_progress","last_action":"2026-09-09T00:00:02Z","chained_steps":2}'

out="$("$CG" check "$SLUG" --step-count 2 --prd-dir "$T")"; rc=$?
expect "after step 2, chain-guard says continue" "[ $rc -eq 0 ]"

# Step 3: archive (publish: none, so archive is the final step).
step_and_log 3 archive '{"status":"shipped","last_action":"2026-09-09T00:00:03Z","chained_steps":3}'

out="$("$CG" check "$SLUG" --step-count 3 --prd-dir "$T")"; rc=$?
expect "after step 3 (archived), chain-guard says stop"  "[ $rc -eq 1 ]"
expect "stop reason is archive-done"                     "grep -q 'archive-done' <<<\"\$out\""

expect "manifest final status is shipped" "[ \"\$(get "$SLUG" status)\" = shipped ]"
expect "chained_steps telemetry reflects 3 steps" "[ \"\$(get "$SLUG" chained_steps)\" = 3 ]"

expect "journal has exactly 3 chain step lines" \
  "[ \"\$(grep -c '^chain: green-fixture step ' "$JOURNAL")\" -eq 3 ]"
expect "journal step lines are in order 1,2,3" \
  "[ \"\$(grep -o 'step [0-9]*' "$JOURNAL" | awk '{print \$2}' | tr '\n' ',')\" = '1,2,3,' ]"
expect "no state/intent orphans left behind" \
  "[ -z \"\$(ls -A "$BUILD_STATE_DIR/intent" 2>/dev/null)\" ]"

exit $fail
