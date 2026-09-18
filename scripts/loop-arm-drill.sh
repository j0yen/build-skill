#!/usr/bin/env bash
# loop-arm-drill.sh — operator-run: prove the auth-expired classification
# + alarm pipeline end to end against the REAL claude binary, without
# ever touching real credentials (PRD-buildloop-tick-outcome-liveness
# AC16).
#
# Why: R1-R9 (tick-outcome.json, cause classification, the LIVENESS/LOOP
# lines, the loop-tick-failed alarm) are all provable with a fixture
# coordinator that prints a canned auth-expired line and exits 1
# (tests/tickout_ac1_auth_expired_classified.sh etc) -- but a fixture
# can't prove the REAL claude CLI's real failure text still matches
# lib/tick-cause.sh's regex three years from now if Anthropic changes
# the wording. AC16 exists because the 2026-09-18 incident this whole
# PRD is named for was exactly that: the real binary, not a fixture.
#
# What it does, in order:
#   0. Takes `tick.lock` ITSELF, once, for the whole drill, waiting up to
#      $LOOP_ARM_DRILL_LOCK_WAIT (default 5400s) for a real tick already
#      in flight to finish, then holds it across all three drill ticks
#      and sets TICK_RUN_ASSUME_LOCK=1 so the inner tick-run.sh calls do
#      not try to re-take it. Two separate reasons, both load-bearing
#      (PRD-buildloop-tick-outcome-liveness AC16, added after ten
#      dispatches could not prove AC16 at all):
#        - Without the WAIT, this script was unrunnable from anywhere a
#          real tick might be running — and on a host whose
#          claude-build.timer fires every 5 minutes there is no reliable
#          idle window to hand an operator. Every inner tick-run.sh call
#          simply lost its `flock -n`, recorded `skipped
#          cause=tick-lock-held`, and the drill failed its own
#          `cause != auth-expired` assertion.
#        - Without HOLDING it across all three, a real tick landing
#          between drill ticks 1 and 2 writes its own `ok` record, which
#          resets streak_failed to 0 — so the drill could never reach the
#          streak=3 that fires the alarm AC16 reads as its evidence.
#      This makes mutual exclusion stronger, not weaker: one process holds
#      the lock continuously for the drill's whole span, and a real launch
#      arriving mid-drill takes its ordinary exit-75 path, whose `skipped`
#      record leaves streak_failed untouched by design.
#   1. Creates a throwaway HOME (mktemp -d) and runs THREE consecutive
#      ticks via tick-run.sh, each with the coordinator replaced (`--`)
#      by a real `claude -p` call whose HOME and CLAUDE_CODE_OAUTH_TOKEN
#      are both pointed at that throwaway dir -- there is no
#      credentials.json there and the token is a syntactically-valid but
#      invalid placeholder, so the real binary reaches its own auth
#      check and fails with a real "Failed to authenticate" line. Real
#      production state ($BUILD_STATE_DIR, the real journal) is used for
#      tick-run.sh itself -- only the CHILD's HOME is thrown away. This
#      host's own ~/.claude credentials are never read, written, or
#      touched.
#   2. After each tick, asserts tick-outcome.json has cause=auth-expired.
#   3. After the 3rd, asserts the journal carries `ALARM loop-tick-failed
#      ... cause=auth-expired streak=3`.
#   4. Prints next-step guidance: the next real (unmodified) tick --
#      already due within one $LOOP_TICK_STALE_DEFAULT_INTERVAL_S cycle
#      on any host with claude-build.timer active -- resolves the alarm
#      on its own (`alert-deliver.sh resolve loop-tick-failed
#      build-loop`, R4/AC9); `--resolve-now` runs that one real tick
#      immediately instead of waiting on the timer.
#
# This script is never run BY a tick's own coordinator in-line (same
# posture as loop-arm.sh) and is a no-op with a clear message off the
# build host, to keep a stray invocation elsewhere from spending real API
# calls for no reason. `--detach` is the supported way to start it from
# inside a live tick anyway: it re-launches itself as a transient
# `systemd-run --user` unit (a plain background job would die with the
# tick's own cgroup) which then simply blocks on step 0's lock wait until
# that tick's coordinator exits, and drills in the gap. Nothing about the
# drill itself changes — it still runs outside any tick, under its own
# lock; only who typed the command does.
#
# NOTIFY_CMD is forced to a no-op for the whole drill (alert-deliver.sh's
# own documented override point) unless the caller already exported one:
# a drill is a practice run, not a real incident, and the shipped default
# NOTIFY_CMD (gh issue create, Operator-authorization 2026-09-15) would
# otherwise file a real GitHub issue for it (discovered the hard way
# authoring this script — the fix is here, not a caveat in a comment
# elsewhere). alert-deliver.sh still writes the real ALARM journal line
# and alerts.banner entry regardless of NOTIFY_CMD (both are
# unconditional, "delivery is best-effort" per its own header) — the
# journal evidence AC16 names is unaffected.
#
# Usage: loop-arm-drill.sh [--resolve-now] [--detach] [--no-wait]
#   --resolve-now  after a successful drill, run one real (unmodified)
#                  tick immediately so the alarm resolves without waiting
#                  on claude-build.timer.
#   --detach       re-launch this same command (minus --detach) as a
#                  transient systemd --user unit and return immediately;
#                  the detached copy blocks on the tick.lock wait. Exits 0
#                  once the unit is started, 3 if systemd-run is missing.
#   --no-wait      do not wait for tick.lock (equivalent to
#                  LOOP_ARM_DRILL_LOCK_WAIT=0): fail fast with exit 4 if a
#                  tick is in flight. The pre-2026-09-18 behaviour.
# Env overrides (test-only hooks; production defaults unchanged):
#   LOOP_ARM_DRILL_LOCK_WAIT      seconds to wait for tick.lock (default
#                                 5400 -- comfortably longer than a full
#                                 tick, which runs up to ~90 min). 0 =
#                                 non-blocking.
#   LOOP_ARM_DRILL_CHILD_TIMEOUT  seconds before a drill child is killed
#                                 (default 120). A real `claude -p` with
#                                 an invalid token fails in seconds; this
#                                 only bounds a hang, so that a wedged
#                                 child can never sit on tick.lock.
#   LOOP_ARM_BUILD_HOST   see loop-arm.sh (default redbaron)
#   BUILD_STATE_DIR       see tick-run.sh (default <skill>/state)
#   BUILD_JOURNAL_ROOT    see lib/journal.sh (default ~/brain/journal/build)
#   TICK_RUN              path to tick-run.sh (default <skill>/scripts/tick-run.sh)
#   CLAUDE_BIN            real claude binary the drill child invokes
#                         (default $HOME/.local/bin/claude, resolved from
#                         THIS process's real HOME before the throwaway
#                         HOME is ever set for the child)
#   DRILL_PROMPT          the plain (non-slash-command) prompt given to
#                         the child (default "say hi") -- deliberately
#                         NOT `/build`: an unrecognized slash command is
#                         resolved locally by the CLI before any auth
#                         check runs at all (verified 2026-09-18), which
#                         would misclassify as `other`, not
#                         `auth-expired`. A plain prompt always reaches
#                         the real auth check.
# Exit: 0 all three drill ticks classified auth-expired and the alarm
#         fired (or --detach started the unit) | 1 a drill tick did not
#         classify as auth-expired, or the alarm never appeared | 2 not on
#         the build host (no-op) | 3 tick-run.sh, systemd-run, or the real
#         claude binary not found | 4 tick.lock never came free within
#         LOOP_ARM_DRILL_LOCK_WAIT (no mutation; retry later).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
JOURNAL_DIR="${BUILD_JOURNAL_ROOT:-$HOME/brain/journal/build}"
HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
LOOP_ARM_BUILD_HOST="${LOOP_ARM_BUILD_HOST:-redbaron}"
TICK_RUN="${TICK_RUN:-$HERE/tick-run.sh}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
DRILL_PROMPT="${DRILL_PROMPT:-say hi}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
LOCKFILE="${TICK_LOCK_FILE:-$STATE_DIR/tick.lock}"
HOLDERFILE="${TICK_LOCK_HOLDER_FILE:-$LOCKFILE.holder}"
LOCK_WAIT="${LOOP_ARM_DRILL_LOCK_WAIT:-5400}"
CHILD_TIMEOUT="${LOOP_ARM_DRILL_CHILD_TIMEOUT:-120}"
resolve_now=0
detach=0
for a in "$@"; do
  case "$a" in
    --resolve-now) resolve_now=1 ;;
    --detach) detach=1 ;;
    --no-wait) LOCK_WAIT=0 ;;
    *) echo "loop-arm-drill: unknown argument '$a'" >&2; exit 2 ;;
  esac
done
case "$LOCK_WAIT" in ''|*[!0-9]*) LOCK_WAIT=5400 ;; esac
case "$CHILD_TIMEOUT" in ''|*[!0-9]*) CHILD_TIMEOUT=120 ;; esac

if [ "${HOST,,}" != "${LOOP_ARM_BUILD_HOST,,}" ]; then
  echo "loop-arm-drill: no-op -- this host ($HOST) is not the build host ($LOOP_ARM_BUILD_HOST); the drill only spends real API calls where the real loop actually runs" >&2
  exit 2
fi
[ -x "$TICK_RUN" ] || { echo "loop-arm-drill: $TICK_RUN not found" >&2; exit 3; }
[ -x "$CLAUDE_BIN" ] || { echo "loop-arm-drill: $CLAUDE_BIN not found" >&2; exit 3; }

# --detach: hand the whole run to a transient user unit and return. Done
# BEFORE the lock wait on purpose — the point is not to block the caller
# (typically a live tick's own branch) for however long the current tick
# still has to run.
if [ "$detach" -eq 1 ]; then
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "loop-arm-drill: --detach needs systemd-run on PATH" >&2; exit 3
  fi
  unit="loop-arm-drill-$(date -u +%Y%m%d%H%M%S)"
  args=()
  [ "$resolve_now" -eq 1 ] && args+=(--resolve-now)
  if systemd-run --user --unit="$unit" --collect \
      --setenv=LOOP_ARM_DRILL_LOCK_WAIT="$LOCK_WAIT" \
      --setenv=BUILD_STATE_DIR="$STATE_DIR" \
      -- bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "${args[@]}" >/dev/null 2>&1; then
    echo "loop-arm-drill: detached as $unit (waits up to ${LOCK_WAIT}s for tick.lock, then drills); follow with: journalctl --user -u $unit -f"
    exit 0
  fi
  echo "loop-arm-drill: systemd-run --user failed to start $unit" >&2; exit 3
fi

export NOTIFY_CMD="${NOTIFY_CMD:-true}"

TICK_OUTCOME_FILE="$STATE_DIR/tick-outcome.json"  # lint:gate-red-not-rendered -- synchronous drill diagnostic, printed the instant it's read while the operator watches; not a cached/re-read-later status line
echo "loop-arm-drill: state=$STATE_DIR outcome_file=$TICK_OUTCOME_FILE notify_cmd=$NOTIFY_CMD"

# Step 0 (see header): take tick.lock ONCE for the whole drill.
mkdir -p "$STATE_DIR" 2>/dev/null || true
: >>"$LOCKFILE" 2>/dev/null || true
exec 9>"$LOCKFILE" || { echo "loop-arm-drill: cannot open $LOCKFILE" >&2; exit 3; }
if [ "$LOCK_WAIT" -gt 0 ]; then
  echo "loop-arm-drill: waiting up to ${LOCK_WAIT}s for tick.lock ($LOCKFILE)"
  flock -w "$LOCK_WAIT" 9
else
  flock -n 9
fi
if [ $? -ne 0 ]; then
  echo "loop-arm-drill: tick.lock still held after ${LOCK_WAIT}s -- a tick is in flight; nothing was mutated, retry later" >&2
  exit 4
fi
# We hold it. Own the holder file for the whole drill too (the inner
# tick-run.sh calls deliberately do not touch it under
# TICK_RUN_ASSUME_LOCK), so `tick-run.sh --status` names the real holder.
DRILL_STARTED="$(date -u +%s)"
BOOT_ID="$(cat "${TICK_RUN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null || echo unknown)"
printf '%s %s %s %s\n' "$$" "$BOOT_ID" "$DRILL_STARTED" "loop-arm-drill.sh" > "$HOLDERFILE" 2>/dev/null || true
trap 'rm -f "$HOLDERFILE" 2>/dev/null || true' EXIT
echo "loop-arm-drill: holding tick.lock (pid=$$) for the whole drill"
export TICK_RUN_ASSUME_LOCK=1

run_drill_tick() {
  local n="$1"
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/loop-arm-drill.XXXXXX")"
  echo "loop-arm-drill: tick $n/3 -- throwaway HOME=$t"
  BUILD_STATE_DIR="$STATE_DIR" "$TICK_RUN" -- \
    timeout "$CHILD_TIMEOUT" \
    env -i HOME="$t" PATH="$PATH" \
      CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-drill-invalid-0000000000000000000000000000000000000000" \
      "$CLAUDE_BIN" -p "$DRILL_PROMPT" --model sonnet --dangerously-skip-permissions --output-format text \
    >/tmp/loop-arm-drill-tick"$n".log 2>&1
  local rc=$?
  rm -rf "$t"
  local cause
  cause="$("$JQ" -r '.cause // empty' "$TICK_OUTCOME_FILE" 2>/dev/null)"
  echo "loop-arm-drill: tick $n/3 -- tick-run.sh rc=$rc cause=$cause"
  if [ "$cause" != "auth-expired" ]; then
    echo "loop-arm-drill: FAIL tick $n did not classify as auth-expired (got '$cause') -- see /tmp/loop-arm-drill-tick$n.log" >&2
    return 1
  fi
  return 0
}

for n in 1 2 3; do
  run_drill_tick "$n" || exit 1
done

streak="$("$JQ" -r '.streak_failed // 0' "$TICK_OUTCOME_FILE" 2>/dev/null)"
echo "loop-arm-drill: streak_failed=$streak after 3 drill ticks"

today="$(date -u +%Y-%m-%d)"
alarm_line=""
if [ -f "$JOURNAL_DIR/$today.md" ]; then
  alarm_line="$(grep -E 'ALARM[[:space:]]+loop-tick-failed.*cause=auth-expired' "$JOURNAL_DIR/$today.md" | tail -1)"
fi
if [ -z "$alarm_line" ]; then
  echo "loop-arm-drill: FAIL no 'ALARM loop-tick-failed ... cause=auth-expired' journal line found in $JOURNAL_DIR/$today.md" >&2
  exit 1
fi
echo "loop-arm-drill: ALARM confirmed -- $alarm_line"

if [ "$resolve_now" -eq 1 ]; then
  echo "loop-arm-drill: --resolve-now -- running one real (unmodified) tick to resolve"
  BUILD_STATE_DIR="$STATE_DIR" "$TICK_RUN"
  rc2="$("$JQ" -r '.outcome // empty' "$TICK_OUTCOME_FILE" 2>/dev/null)"
  echo "loop-arm-drill: resolving tick outcome=$rc2"
else
  echo "loop-arm-drill: done -- the next real tick (claude-build.timer, already active on this host) resolves the alarm on its own; re-run with --resolve-now to force it immediately instead of waiting"
fi
exit 0
