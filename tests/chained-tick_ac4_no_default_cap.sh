#!/usr/bin/env bash
# chained-tick_ac4_no_default_cap.sh — PRD-build-chained-tick-actions AC4.
#
# Given CHAIN_MAX_STEPS unset, When a 12-step green fixture runs, Then it
# reaches archived in one tick; Given CHAIN_MAX_STEPS=3 pinned on the same
# fixture, When it runs, Then it stops after 3 steps with reason cap.
# (Operator, 2026-09-09: "no chain cap" — unset means unlimited, the other
# stop conditions are the only limits; requirement 4.)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$CG" ] && [ -x "$MS" ] || { echo "ac4: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/chained-tick-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"
SLUG="twelve-step-fixture"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"][sys.argv[2]].get(sys.argv[3]))' "$BUILD_MANIFEST" "$1" "$2"; }
patch() { local f; f="$(mktemp "$T/patch.XXXXXX.json")"; printf '%s' "$1" > "$f"; "$MS" "$SLUG" "$f"; }
reset_manifest() {
  cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "queued", "build_target": "shell", "blockers": [], "chained_steps": 0}}}
JSON
}

# ---- Part 1: CHAIN_MAX_STEPS unset -> a 12-step green fixture reaches
# archived in one dispatch, never stopped by a cap. ------------------------
unset CHAIN_MAX_STEPS
reset_manifest
all_continued=1
for k in $(seq 1 12); do
  if [ "$k" -lt 12 ]; then
    patch "{\"status\":\"in_progress\",\"chained_steps\":$k}"
  else
    patch "{\"status\":\"shipped\",\"chained_steps\":$k}"
  fi
  if [ "$k" -lt 12 ]; then
    out="$("$CG" check "$SLUG" --step-count "$k" --skip-select-guard)"; rc=$?
    if [ "$rc" -ne 0 ]; then all_continued=0; echo "  (step $k) $out" >&2; fi
  fi
done
expect "unset cap: chain-guard said continue after every one of steps 1..11" "[ $all_continued -eq 1 ]"
expect "unset cap: fixture reached shipped in one dispatch (12 steps)"       "[ \"\$(get "$SLUG" status)\" = shipped ]"
expect "unset cap: chained_steps telemetry shows all 12"                    "[ \"\$(get "$SLUG" chained_steps)\" = 12 ]"

out="$("$CG" check "$SLUG" --step-count 12 --skip-select-guard)"; rc=$?
expect "post-archive re-check stops on archive-done, not a cap" \
  "[ $rc -eq 1 ] && grep -q 'archive-done' <<<\"\$out\""

# ---- Part 2: same fixture shape, CHAIN_MAX_STEPS=3 pinned -> stops after
# exactly 3 steps with reason cap. ------------------------------------------
export CHAIN_MAX_STEPS=3
reset_manifest
patch '{"status":"in_progress","chained_steps":1}'
out="$("$CG" check "$SLUG" --step-count 1 --skip-select-guard)"; rc=$?
expect "cap=3: after step 1, continue (1 < 3)" "[ $rc -eq 0 ]"

patch '{"status":"in_progress","chained_steps":2}'
out="$("$CG" check "$SLUG" --step-count 2 --skip-select-guard)"; rc=$?
expect "cap=3: after step 2, continue (2 < 3)" "[ $rc -eq 0 ]"

patch '{"status":"in_progress","chained_steps":3}'
out="$("$CG" check "$SLUG" --step-count 3 --skip-select-guard)"; rc=$?
expect "cap=3: after step 3, stop"        "[ $rc -eq 1 ]"
expect "cap=3: stop reason is cap"        "grep -q ': cap$' <<<\"\$out\""
expect "cap=3: fixture did NOT reach shipped (stopped at 3/12)" \
  "[ \"\$(get "$SLUG" status)\" = in_progress ]"

unset CHAIN_MAX_STEPS
exit $fail
