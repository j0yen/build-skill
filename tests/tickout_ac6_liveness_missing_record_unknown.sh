#!/usr/bin/env bash
# tickout_ac6_liveness_missing_record_unknown.sh —
# PRD-buildloop-tick-outcome-liveness AC6.
#
# Given no tick-outcome.json, When loop-liveness.sh runs, Then the
# summary carries last_ok_age=unknown and never the bare
# `LIVENESS ok n=<N>` form.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIVENESS="$HERE/../scripts/loop-liveness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export LOOP_UNITS_FILE="$TMP/loop-units.txt"
export LOOP_LIVENESS_STATE_DIR="$TMP/liveness-state"
export LOOP_LIVENESS_HOST="fixture-host"
printf 'fixture-host unit-a.timer\n' > "$LOOP_UNITS_FILE"
mkdir -p "$LOOP_LIVENESS_STATE_DIR"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo active
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"

# No tick-outcome.json at all -- point at a path that doesn't exist.
export TICK_OUTCOME_FILE="$TMP/no-such-tick-outcome.json"

fail=0
out="$("$LIVENESS" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'last_ok_age=unknown'; then
  echo "ok  AC6: missing record -> last_ok_age=unknown"
else
  echo "FAIL: rc=$rc out=$out (want last_ok_age=unknown)"
  fail=1
fi

if echo "$out" | grep -qxF 'LIVENESS ok n=1'; then
  echo "FAIL: bare 'LIVENESS ok n=1' form still present: $out"
  fail=1
else
  echo "ok  AC6: never the bare LIVENESS ok n=<N> form"
fi

exit "$fail"
