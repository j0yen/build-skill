#!/usr/bin/env bash
# chained-tick_ac3_lock_contention.sh — PRD-build-chained-tick-actions AC3.
#
# Given a fixture with the integrate flock held elsewhere, When the chain
# reaches the integrate step, Then it stops within 60 s with stop reason
# lock-contended and the claim survives for next-tick resume.
#
# Uses --lock-wait well under 60s so the selftest itself stays fast; the
# mechanism is the SAME flock-with-timeout probe SKILL.md's contract wires
# in at the default 60s bound for a live dispatch (requirement 1: "integrate
# flock acquirable without waiting past 60 s"; requirement 3: "not acquired
# within 60 s").

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$CG" ] && [ -x "$MS" ] || { echo "ac3: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/chained-tick-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"
SLUG="lockcontend-fixture"
LOCK="$T/repo.git/autobuilder-integrate.lock"
mkdir -p "$(dirname "$LOCK")"
touch "$LOCK"

cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "in_progress", "build_target": "rust-extend", "blockers": [], "chained_steps": 1}}}
JSON

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"][sys.argv[2]].get(sys.argv[3]))' "$BUILD_MANIFEST" "$1" "$2"; }

# Another lane/branch holds the integrate lock for the whole probe window.
( flock "$LOCK" -c "sleep 3" ) &
HOLDER_PID=$!
sleep 0.3   # let the holder actually acquire before we probe

t0=$(date +%s)
out="$("$CG" check "$SLUG" --step-count 1 --skip-select-guard --integrate-lock "$LOCK" --lock-wait 2)"
rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))

expect "chain-guard reports stop"                 "[ $rc -eq 1 ]"
expect "stop reason is lock-contended"            "grep -q 'lock-contended' <<<\"\$out\""
expect "the probe stopped within its bound (<=2s + slack)" "[ $elapsed -le 5 ]"

wait "$HOLDER_PID" 2>/dev/null || true

# "the claim survives for next-tick resume" — chain-guard is read-only: the
# manifest entry (this branch's own live claim/state) is untouched by a
# stopped probe, exactly as it would be if the tick simply ended after its
# last successful step.
expect "manifest status untouched (still in_progress)" "[ \"\$(get "$SLUG" status)\" = in_progress ]"
expect "manifest chained_steps untouched by the probe"  "[ \"\$(get "$SLUG" chained_steps)\" = 1 ]"

# Once the lock frees up, the SAME probe succeeds — proving this was a
# transient contention stop, not a permanent block.
out2="$("$CG" check "$SLUG" --step-count 1 --skip-select-guard --integrate-lock "$LOCK" --lock-wait 2)"
rc2=$?
expect "lock free -> chain-guard now says continue" "[ $rc2 -eq 0 ]"

exit $fail
