#!/usr/bin/env bash
# tests/canary_ac_r7_timer_declared_and_armable.sh —
# PRD-build-burst-gate-canary-invariant R7 (user story 4, AC6/AC12/AC13's
# "when the daily unit runs" premise).
#
# systemd/claude-burst-canary.{service,timer} shipped with this PRD, but
# until 2026-09-18 no host declared the timer in scripts/loop-units.txt —
# loop-arm.sh is the only sanctioned arming step and it arms exactly the
# declared set, so the unit was never enabled, never verified by
# loop-liveness.sh, and R7's whole cadence could not fire on any host.
# A daily gate that is never armed is the same vacuous-mechanism shape
# this PRD exists to close, so the declaration itself gets a test.
#
# Checks, in order:
#   1. both unit files exist and the .timer binds the .service
#   2. the service's ExecStart really is burst-lane.sh canary-daily, and
#      that script exists and is executable
#   3. the build host declares claude-burst-canary.timer in loop-units.txt
#      (the input loop-arm.sh arms from and loop-liveness.sh verifies)
#   4. loop-liveness.sh, given a fake `systemctl` that reports the timer
#      inactive, actually WARNs and names it — the declaration produces an
#      alarm surface rather than a line nothing reads
#   5. behavioral cost guard: `burst-lane.sh canary-daily` against an empty
#      isolated state dir skips with cause=no-active-session and exit 0, so
#      the hourly wakeup spends nothing when no box is live
#
# Pure fixture: fake systemctl, isolated BURST_LANE_STATE_DIR/journal — no
# box, no hcloud, no network, no real systemd call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd "$HERE/.." && pwd -P)"
UNITS_FILE="$SKILL/scripts/loop-units.txt"
SVC="$SKILL/systemd/claude-burst-canary.service"
TMR="$SKILL/systemd/claude-burst-canary.timer"
BL="$SKILL/scripts/burst-lane.sh"
LIVENESS="$SKILL/scripts/loop-liveness.sh"
# The host loop-units.txt declares the buildloop set for; kept in sync with
# loop-arm.sh's own LOOP_ARM_BUILD_HOST default rather than hostname, so
# this test asserts the same thing on every node it runs on.
BUILD_HOST="${LOOP_ARM_BUILD_HOST:-redbaron}"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-r7-timer.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

echo "=== R7.1: unit files exist and the timer binds the service ==="
expect "R7: systemd/claude-burst-canary.service exists" "[ -f '$SVC' ]"
expect "R7: systemd/claude-burst-canary.timer exists" "[ -f '$TMR' ]"
expect "R7: timer's Unit= names claude-burst-canary.service" \
  "grep -qE '^Unit=claude-burst-canary\.service' '$TMR'"
expect "R7: timer is installed into timers.target" \
  "grep -qE '^WantedBy=timers\.target' '$TMR'"

echo "=== R7.2: ExecStart is the real canary-daily entry point ==="
exec_line="$(grep -E '^ExecStart=' "$SVC" | head -1 | sed 's/^ExecStart=//')"
exec_bin="${exec_line%% *}"
expect "R7: ExecStart calls burst-lane.sh canary-daily" \
  "printf '%s' \"\$exec_line\" | grep -qE 'burst-lane\.sh +canary-daily'"
expect "R7: ExecStart's script exists and is executable" "[ -x \"\$exec_bin\" ]"
expect "R7: burst-lane.sh dispatches the canary-daily verb" \
  "grep -qE 'canary-daily\) *cmd_canary_daily' '$BL'"

echo "=== R7.3: the build host declares the timer in loop-units.txt ==="
expect "R7: loop-units.txt exists" "[ -f '$UNITS_FILE' ]"
expect "R7: $BUILD_HOST declares claude-burst-canary.timer" \
  "grep -viE '^[[:space:]]*#' '$UNITS_FILE' | grep -qiE '^[[:space:]]*$BUILD_HOST[[:space:]]+claude-burst-canary\.timer[[:space:]]*\$'"

echo "=== R7.4: an inactive declared timer actually WARNs in loop-liveness ==="
FAKEBIN="$ROOT/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# is-active: every unit active EXCEPT claude-burst-canary.timer.
for a in "$@"; do
  case "$a" in
    claude-burst-canary.timer) echo inactive; exit 3 ;;
  esac
done
echo active
EOF
chmod +x "$FAKEBIN/systemctl"
live_out="$(PATH="$FAKEBIN:$PATH" LOOP_UNITS_FILE="$UNITS_FILE" \
  LOOP_LIVENESS_HOST="$BUILD_HOST" LOOP_LIVENESS_STATE_DIR="$ROOT/lstate" \
  "$LIVENESS" 2>&1)"; live_rc=$?
expect "R7: loop-liveness exits non-zero when the canary timer is inactive" "[ $live_rc -ne 0 ]"
expect "R7: loop-liveness names claude-burst-canary.timer in its WARN" \
  "printf '%s' \"\$live_out\" | grep -qF 'claude-burst-canary.timer'"

echo "=== R7.5: hourly wakeup with no live box is a free no-op ==="
STATE="$ROOT/burst-state"; mkdir -p "$STATE"
JOURNAL="$ROOT/journal.log"; : > "$JOURNAL"
# R17 knob files get isolated copies too: the timer runs canary-daily as the
# user, so a future code path that wrote BUILD_BURST_ENABLED on the way to
# the skip would edit the operator's REAL ~/.config/wm-burst/.env from a
# test run. Both the isolated knob files and (when present) the production
# one are checked for byte-identity after the call.
FAKE_ENV="$ROOT/wm-burst.env"; printf 'BUILD_BURST_ENABLED=0\n' > "$FAKE_ENV"
FAKE_DROPIN="$ROOT/dropin/burst.conf"; mkdir -p "$(dirname "$FAKE_DROPIN")"
PROD_ENV="$HOME/.config/wm-burst/.env"
prod_before=""; [ -f "$PROD_ENV" ] && prod_before="$(md5sum "$PROD_ENV" | cut -d' ' -f1)"
env_before="$(md5sum "$FAKE_ENV" | cut -d' ' -f1)"
daily_out="$(BURST_LANE_STATE_DIR="$STATE" BURST_LANE_JOURNAL="$JOURNAL" \
  BUILD_JOURNAL_ROOT="$ROOT/journal-root" HCLOUD_TOKEN="" \
  BURST_LANE_ENV_FILE="$FAKE_ENV" BURST_LANE_SYSTEMD_DROPIN="$FAKE_DROPIN" \
  "$BL" canary-daily 2>&1)"; daily_rc=$?
env_after="$(md5sum "$FAKE_ENV" | cut -d' ' -f1)"
prod_after=""; [ -f "$PROD_ENV" ] && prod_after="$(md5sum "$PROD_ENV" | cut -d' ' -f1)"
expect "R7: canary-daily exits 0 with no active box" "[ $daily_rc -eq 0 ]"
expect "R7: canary-daily says skipped cause=no-active-session" \
  "printf '%s' \"\$daily_out\" | grep -qF 'canary-daily skipped (cause=no-active-session)'"
expect "R7: the skip is journaled" \
  "grep -qF 'canary-daily  skipped  (cause=no-active-session)' '$JOURNAL'"
expect "R7: no canary.json was written anywhere under the isolated state dir" \
  "! find '$STATE' -name canary.json -print -quit | grep -q ."
expect "R7: the skip wrote no BUILD_BURST_ENABLED knob (R17: only enable/disable may)" \
  "[ \"\$env_before\" = \"\$env_after\" ]"
expect "R7: the skip wrote no systemd drop-in" "[ ! -e '$FAKE_DROPIN' ]"
expect "R7: the operator's real wm-burst/.env is byte-identical after the run" \
  "[ \"\$prod_before\" = \"\$prod_after\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac_r7_timer_declared_and_armable: ALL PASS"
  exit 0
fi
echo "canary_ac_r7_timer_declared_and_armable: assertion(s) FAILED" >&2
exit 1
