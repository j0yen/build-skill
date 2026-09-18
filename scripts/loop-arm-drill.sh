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
# This script never runs from a tick itself (same posture as
# loop-arm.sh) and is a no-op with a clear message off the build host,
# to keep a stray invocation elsewhere from spending real API calls for
# no reason.
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
# Usage: loop-arm-drill.sh [--resolve-now]
# Env overrides (test-only hooks; production defaults unchanged):
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
#         fired | 1 a drill tick did not classify as auth-expired, or the
#         alarm never appeared | 2 not on the build host (no-op) | 3
#         tick-run.sh or the real claude binary not found.
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
resolve_now=0
[ "${1:-}" = "--resolve-now" ] && resolve_now=1

if [ "${HOST,,}" != "${LOOP_ARM_BUILD_HOST,,}" ]; then
  echo "loop-arm-drill: no-op -- this host ($HOST) is not the build host ($LOOP_ARM_BUILD_HOST); the drill only spends real API calls where the real loop actually runs" >&2
  exit 2
fi
[ -x "$TICK_RUN" ] || { echo "loop-arm-drill: $TICK_RUN not found" >&2; exit 3; }
[ -x "$CLAUDE_BIN" ] || { echo "loop-arm-drill: $CLAUDE_BIN not found" >&2; exit 3; }

export NOTIFY_CMD="${NOTIFY_CMD:-true}"

TICK_OUTCOME_FILE="$STATE_DIR/tick-outcome.json"
echo "loop-arm-drill: state=$STATE_DIR outcome_file=$TICK_OUTCOME_FILE notify_cmd=$NOTIFY_CMD"

run_drill_tick() {
  local n="$1"
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/loop-arm-drill.XXXXXX")"
  echo "loop-arm-drill: tick $n/3 -- throwaway HOME=$t"
  BUILD_STATE_DIR="$STATE_DIR" "$TICK_RUN" -- \
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
