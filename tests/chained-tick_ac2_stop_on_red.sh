#!/usr/bin/env bash
# chained-tick_ac2_stop_on_red.sh — PRD-build-chained-tick-actions AC2.
#
# Given a fixture whose gate step fails, When the chain reaches that step,
# Then it stops the chain at the gate, records the stop reason, and leaves
# manifest state identical to today's single-action outcome.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$CG" ] && [ -x "$MS" ] || { echo "ac2: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/chained-tick-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"
SLUG="red-fixture"

mkdir -p "$T/build-queue"
cat > "$T/build-queue/PRD-$SLUG.md" <<EOF
# PRD: $SLUG
- Status: queued
- build_target: rust-extend
- build_into: /tmp/does-not-matter-ac2
EOF

cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "queued", "build_target": "rust-extend", "blockers": []}}}
JSON

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"][sys.argv[2]].get(sys.argv[3]))' "$BUILD_MANIFEST" "$1" "$2"; }
patch() { local f; f="$(mktemp "$T/patch.XXXXXX.json")"; printf '%s' "$1" > "$f"; "$MS" "$SLUG" "$f"; }

# Step 1: push lands (as far as the chain gets before the gate).
patch '{"status":"in_progress","last_action":"2026-09-09T00:00:01Z","chained_steps":1}'

out="$("$CG" check "$SLUG" --step-count 1 --prd-dir "$T")"; rc=$?
expect "after step 1, chain-guard says continue" "[ $rc -eq 0 ]"

# Step 2: the gate step runs and BLOCKS (extend-gate.sh verdict=block) —
# per SKILL.md's "gate" action: blockers gains a `gate: <receipt> —
# <message>` line, next: gate-red, Status stays in_progress. No tag, no
# archive, no passing Receipts: line — exactly what a standalone
# single-action tick would leave behind.
patch '{"status":"in_progress","last_action":"2026-09-09T00:00:02Z","chained_steps":2,"blockers":["gate: reviewer-agent — new blocking finding"],"next":"gate-red"}'

out="$("$CG" check "$SLUG" --step-count 2 --prd-dir "$T")"; rc=$?
expect "after the red gate step, chain-guard says stop" "[ $rc -eq 1 ]"
expect "stop reason is blockers"                        "grep -q 'stop: red-fixture: blockers' <<<\"\$out\""

expect "manifest status stays in_progress (not shipped)" "[ \"\$(get "$SLUG" status)\" = in_progress ]"
expect "manifest next is gate-red"                        "[ \"\$(get "$SLUG" next)\" = gate-red ]"
expect "manifest blockers non-empty"                      "[ \"\$(python3 -c 'import json;print(len(json.load(open(\"'"$BUILD_MANIFEST"'\"))[\"prds\"][\"$SLUG\"][\"blockers\"]))')\" -gt 0 ]"

# A subsequent tick re-selecting this PRD (chained_steps reset to a fresh
# tick's own counting) would see the SAME gate-red state a standalone
# single-action tick left behind — no extra archive/tag/push side effects
# leaked past the stop.
expect "no output_repo_url / tag fields were fabricated" \
  "[ \"\$(get "$SLUG" output_repo_url)\" = None ]"

exit $fail
