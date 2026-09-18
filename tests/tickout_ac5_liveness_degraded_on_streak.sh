#!/usr/bin/env bash
# tickout_ac5_liveness_degraded_on_streak.sh —
# PRD-buildloop-tick-outcome-liveness AC5.
#
# Given two consecutive failed records, When loop-liveness.sh runs, Then
# its summary line is `LIVENESS degraded cause=<cause> streak=2
# last_ok_age=<s>` and its exit code is 0; given streak_failed=1 it is
# `LIVENESS ok ... streak_failed=1`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIVENESS="$HERE/../scripts/loop-liveness.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export LOOP_UNITS_FILE="$TMP/loop-units.txt"
export LOOP_LIVENESS_STATE_DIR="$TMP/liveness-state"
export LOOP_LIVENESS_HOST="fixture-host"
printf 'fixture-host unit-a.timer\n' > "$LOOP_UNITS_FILE"
mkdir -p "$LOOP_LIVENESS_STATE_DIR"

# Fake systemctl: always active, so bad=0 and the ok/degraded branch runs.
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo active
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"

export TICK_OUTCOME_FILE="$TMP/tick-outcome.json"

fail=0

# --- streak_failed=2, cause=auth-expired: degraded --------------------
"$JQ" -n '{ts:"2026-09-18T04:00:00Z",n:5,rc:1,outcome:"failed",cause:"auth-expired",evidence:"x",streak_failed:2,last_ok_ts:"2026-09-18T03:00:00Z",lane:"redbaron"}' > "$TICK_OUTCOME_FILE"
out="$("$LIVENESS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^LIVENESS degraded cause=auth-expired streak=2 last_ok_age=[0-9]+$'; then
  echo "ok  AC5: streak_failed=2 -> LIVENESS degraded, exit 0"
else
  echo "FAIL: streak=2 case: rc=$rc out=$out"
  fail=1
fi

# --- streak_failed=1: still ok, with the field visible ------------------
"$JQ" -n '{ts:"2026-09-18T04:00:00Z",n:5,rc:1,outcome:"failed",cause:"other",evidence:"x",streak_failed:1,last_ok_ts:"2026-09-18T03:00:00Z",lane:"redbaron"}' > "$TICK_OUTCOME_FILE"
out2="$("$LIVENESS" 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ] && echo "$out2" | grep -qE '^LIVENESS ok n=1 last_ok_age=[0-9]+ streak_failed=1$'; then
  echo "ok  AC5: streak_failed=1 -> LIVENESS ok ... streak_failed=1"
else
  echo "FAIL: streak=1 case: rc=$rc2 out=$out2"
  fail=1
fi

exit "$fail"
