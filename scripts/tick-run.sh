#!/usr/bin/env bash
# tick-run.sh — lock-holding entrypoint for a /build tick
# (PRD-build-tick-lock-held).
#
# Problem this fixes: Phase 0 said "acquire tick.lock with flock -n; if
# held, exit", but that flock lived inside one short-lived Bash tool call
# issued by the coordinator (an LLM) and was released the instant that
# call returned — so the lock never actually protected anything past the
# first few milliseconds of a tick. On 2026-09-15 an automatic tick and a
# hand-launched manual batch ran concurrently on RedBaron for hours because
# of exactly this: `flock -n tick.lock true` succeeded mid-tick.
#
# Fix: tie the lock's lifetime to the coordinator PROCESS, not to a tool
# call. This script opens state/tick.lock on a fixed fd (9), flock -n's
# it, writes who holds it to state/tick.lock.holder, then `exec`s the
# coordinator command with that fd still open — bash does not close
# fds across `exec` by default, so the flock (which lives on the open
# file description, not the fd number) survives for exactly as long as
# the coordinator process tree does. A second tick-run.sh, no matter how
# it was launched (timer or manual systemd-run), inherits nothing from
# the first and genuinely fails to acquire the same flock.
#
# Usage:
#   tick-run.sh                    run the default coordinator
#                                   (claude -p "/build${BUILD_TICK_ARGS:+ $BUILD_TICK_ARGS}")
#   tick-run.sh -- <cmd...>        run <cmd...> as the coordinator instead
#                                   (selftests use this to substitute a fixture)
#   tick-run.sh --status           print the current holder (pid/age/cmdline)
#                                   or `free`; never takes the lock
#   tick-run.sh --check-held       Phase-0 verification subcommand: exits 0
#                                   and prints `held-by-ancestor` when
#                                   state/tick.lock is genuinely held (by
#                                   construction, only this script's own
#                                   holder can ever hold it — see SKILL.md
#                                   Phase 0); exits 1 and prints `not-held`
#                                   otherwise. Never acquires the lock
#                                   itself — the coordinator VERIFIES, it
#                                   never `flock`s itself (requirement 3).
#
# Env:
#   BUILD_STATE_DIR   state dir (default <skill-dir>/state)
#   TICK_LOCK_FILE    lock path (default $BUILD_STATE_DIR/tick.lock)
#   TICK_LOCK_HOLDER_FILE  holder path (default $TICK_LOCK_FILE.holder)
#   TICK_RUN_JOURNAL  daily journal (default ~/brain/journal/build/<date>.md)
#   TICK_RUN_BOOT_ID_FILE  boot id source (default /proc/sys/kernel/random/boot_id;
#                     tests override this to a fixture file)
#   CLAUDE_BIN        coordinator binary (default ~/.local/bin/claude)
#   BUILD_TICK_ARGS   forwarded into the default coordinator's /build arg,
#                     UNLESS it starts with "run <slugs>" (space- or
#                     comma-separated) -- PRD-build-select-tick-run-pin:
#                     that form is derived into SELECT_TICK_PIN (exported,
#                     comma-joined) instead, and the coordinator's own
#                     /build arg gets no slug list at all. select-tick.sh
#                     reads SELECT_TICK_PIN as its --pin default, so the
#                     coordinator's one Phase 2 call is already pinned
#                     without ever seeing the slugs itself.
#
# Exit: 0 coordinator ran and exited 0 | <n> the coordinator's own exit
#       code (this script `exec`s it, so its exit code IS this script's) |
#       75 tick-lock-held (a second launch found the lock genuinely held) |
#       2 usage error
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
LOCKFILE="${TICK_LOCK_FILE:-$STATE_DIR/tick.lock}"
HOLDERFILE="${TICK_LOCK_HOLDER_FILE:-$LOCKFILE.holder}"
# shellcheck source=lib/journal.sh
source "$SKILL_DIR/scripts/lib/journal.sh"
JOURNAL="${TICK_RUN_JOURNAL:-$(journal_root)/$(date -u +%F).md}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
BOOT_ID_FILE="${TICK_RUN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
LANE="${TICK_RUN_LANE:-$(hostname)}"
RECONCILE_PY="${TICK_RECONCILE_PY:-$SKILL_DIR/scripts/tick-reconcile.py}"
SELECT_TICK_STATE_DIR="${SELECT_TICK_STATE_DIR:-$STATE_DIR/select-tick}"
# Alarm hourly gate (requirement 4): never more than one alarm per hour per
# lane. State is separate from select-tick.sh's own admitted/skipped
# persistence so a read of one never races a write of the other.
ALARM_LAST_FILE="${TICK_RUN_ALARM_LAST_FILE:-$SELECT_TICK_STATE_DIR/alarm-last-$LANE.json}"
STREAK_FILE="${TICK_RUN_STREAK_FILE:-$SELECT_TICK_STATE_DIR/streak-$LANE.json}"
ALERT_DELIVER="${TICK_RUN_ALERT_DELIVER:-$SKILL_DIR/scripts/alert-deliver.sh}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
boot_id() { cat "$BOOT_ID_FILE" 2>/dev/null || echo unknown; }

# PRD-build-journal-single-writer requirement 1: routed through the one
# journal_line instead of a private printf >>. TICK_RUN_JOURNAL is now a
# legacy alias journal_line itself understands (scripts/lib/journal.sh),
# so this still honors the same override every existing ticklock_* /
# pin_ac* selftest sets.
journal() {
  journal_line --file "$JOURNAL" "$(printf '%s  %s' "$(now_iso)" "$1")"
}

usage() { echo "usage: tick-run.sh [--status|--check-held] [-- <cmd...>]" >&2; exit 2; }

# read_holder <var-prefix> — sets <prefix>_pid/_bid/_started/_cmd from
# $HOLDERFILE ("pid boot-id started_epoch cmdline"); cmdline absorbs the
# rest of the line (may itself contain spaces).
read_holder() {
  H_PID=""; H_BID=""; H_STARTED=""; H_CMD=""
  [ -r "$HOLDERFILE" ] || return 1
  IFS=' ' read -r H_PID H_BID H_STARTED H_CMD < "$HOLDERFILE" || return 1
  [ -n "$H_PID" ] || return 1
  return 0
}

# probe_lock -> 0 (free right now) | 1 (held right now). Opens its OWN fd
# on $LOCKFILE (never the fixed fd 9 the real acquire path uses) so a
# --status/--check-held call never contends with, or accidentally
# releases, an fd this process might otherwise hold.
probe_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  : >>"$LOCKFILE" 2>/dev/null || true
  local pfd
  exec {pfd}>"$LOCKFILE" || return 1
  if flock -n "$pfd"; then
    exec {pfd}>&-
    return 0
  fi
  exec {pfd}>&-
  return 1
}

cmd_status() {
  if probe_lock; then
    echo "free"
  elif read_holder; then
    local age=$(( $(now_epoch) - ${H_STARTED:-0} ))
    echo "tick-lock-held (pid=$H_PID age=${age}s cmd=$H_CMD)"
  else
    echo "tick-lock-held (holder file missing/unreadable)"
  fi
  print_last_reconcile
  return 0
}

# print_last_reconcile — requirement 7 (P1): the last tick's
# admitted/dispatched/missing, from the persisted reconciliation row, as a
# plain `admitted=<n> dispatched=<m> missing=<csv>` line. Silent no-op if
# no reconciliation has ever been persisted (fresh install / no tick yet).
print_last_reconcile() {
  local f="$SELECT_TICK_STATE_DIR/last.reconcile.json"
  [ -x "$JQ" ] || return 0
  [ -r "$f" ] || return 0
  local admitted dispatched missing
  admitted="$("$JQ" -r '.admitted // 0' "$f" 2>/dev/null)" || return 0
  dispatched="$("$JQ" -r '.dispatched // 0' "$f" 2>/dev/null)" || return 0
  missing="$("$JQ" -r '(.missing // []) | join(",")' "$f" 2>/dev/null)" || return 0
  echo "admitted=$admitted dispatched=$dispatched missing=$missing"
}

# Phase-0 verification (requirement 3): the coordinator never flocks
# itself. By construction only this script's own successful acquire path
# ever holds state/tick.lock, so a failed probe here IS "held by my
# ancestor" — no other process can legitimately be the holder.
cmd_check_held() {
  if probe_lock; then
    echo "not-held"
    return 1
  fi
  echo "held-by-ancestor"
  return 0
}

# atomic_write_json <path> <json-text> — temp-then-rename, matching
# select-tick.sh's own persistence convention.
atomic_write_json() {
  local path="$1" json="$2"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  local tmp
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

# maybe_alarm <admitted> <dispatched> <missing-csv> — requirement 4.
# Tracks a per-lane consecutive-under-dispatch streak in $STREAK_FILE
# (keyed by tick-id so a --status read or a second reconcile of the SAME
# tick never double-counts); fires the alarm (journal line + the same
# notifier path repo-health alarms use) only when the streak reaches 2 AND
# the per-lane hourly gate ($ALARM_LAST_FILE) allows it.
maybe_alarm() {
  local under_dispatched="$1" admitted="$2" dispatched="$3" missing_csv="$4"
  local prev_streak=0 prev_under=false prev_tick=""
  if [ -x "$JQ" ] && [ -r "$STREAK_FILE" ]; then
    prev_streak="$("$JQ" -r '.streak // 0' "$STREAK_FILE" 2>/dev/null)"
    prev_under="$("$JQ" -r '.under_dispatched // false' "$STREAK_FILE" 2>/dev/null)"
    prev_tick="$("$JQ" -r '.tick_id // ""' "$STREAK_FILE" 2>/dev/null)"
    case "$prev_streak" in ''|*[!0-9]*) prev_streak=0 ;; esac
  fi
  [ "$prev_tick" = "$TICK_ID" ] && return 0

  local new_streak=0
  if [ "$under_dispatched" = true ]; then
    if [ "$prev_under" = "true" ]; then
      new_streak=$((prev_streak + 1))
    else
      new_streak=1
    fi
  fi

  atomic_write_json "$STREAK_FILE" "$("$JQ" -n --arg tick_id "$TICK_ID" --argjson under "$under_dispatched" --argjson streak "$new_streak" \
    '{tick_id:$tick_id, under_dispatched:$under, streak:$streak}')" 2>/dev/null || true

  [ "$under_dispatched" = true ] && [ "$new_streak" -ge 2 ] || return 0

  local now last_epoch=0
  now="$(now_epoch)"
  if [ -r "$ALARM_LAST_FILE" ] && [ -x "$JQ" ]; then
    last_epoch="$("$JQ" -r '.epoch // 0' "$ALARM_LAST_FILE" 2>/dev/null)"
    case "$last_epoch" in ''|*[!0-9]*) last_epoch=0 ;; esac
  fi
  if [ "$last_epoch" -gt 0 ] && [ $(( now - last_epoch )) -lt 3600 ]; then
    return 0
  fi

  journal "$LANE  alarm  under-dispatched twice (admitted=$admitted dispatched=$dispatched missing=$missing_csv)  (class=under-dispatch lane=$LANE)"

  local evidence
  evidence="$(mktemp 2>/dev/null)" || evidence=""
  if [ -n "$evidence" ]; then
    printf 'under-dispatched twice admitted=%s dispatched=%s missing=%s\n' "$admitted" "$dispatched" "$missing_csv" > "$evidence"
    if [ -x "$ALERT_DELIVER" ]; then
      "$ALERT_DELIVER" under-dispatch "$LANE" "$evidence" --value "$((admitted - dispatched))" --comment >/dev/null 2>&1 || true
    fi
    rm -f "$evidence" 2>/dev/null
  fi

  atomic_write_json "$ALARM_LAST_FILE" "$("$JQ" -n --argjson epoch "$now" '{epoch:$epoch}')" 2>/dev/null || true
}

# reconcile <rc> — requirement 3 (+4, +6's persistence half). Called once,
# after the coordinator child has exited by any means. Reads this tick's
# admitted[] from state/select-tick/<TICK_ID>.json (written by select-tick.sh
# during the child's run); if that file was never written, there is nothing
# to reconcile against and this is a silent no-op — not every tick-run.sh
# invocation goes through a real select-tick.sh call (selftests substitute
# fixtures for narrower ACs).
reconcile() {
  local rc="$1"
  [ -x "$JQ" ] || return 0
  local admitted_file="$SELECT_TICK_STATE_DIR/${TICK_ID}.json"
  [ -r "$admitted_file" ] || return 0

  local admitted_json
  admitted_json="$("$JQ" -c '{admitted: (.admitted // [])}' "$admitted_file" 2>/dev/null)" || return 0
  local admitted_n
  admitted_n="$("$JQ" -r '.admitted | length' <<<"$admitted_json" 2>/dev/null)"
  [ -n "$admitted_n" ] || return 0
  if [ "$admitted_n" -eq 0 ]; then
    return 0
  fi

  local today_journal
  today_journal="$(journal_root)/$(date -u +%F).md"
  local -a journal_files=("$JOURNAL")
  [ "$today_journal" != "$JOURNAL" ] && journal_files+=("$today_journal")

  [ -r "$RECONCILE_PY" ] || return 0
  local recon
  recon="$(printf '%s' "$admitted_json" | python3 "$RECONCILE_PY" "$TICK_STARTED_EPOCH" "$STATE_DIR" "${journal_files[@]}" 2>/dev/null)" || return 0
  [ -n "$recon" ] || return 0

  local dispatched_n missing_csv coordinator_cause
  dispatched_n="$("$JQ" -r '.dispatched_slugs | length' <<<"$recon" 2>/dev/null)"
  missing_csv="$("$JQ" -r '.missing_slugs | join(",")' <<<"$recon" 2>/dev/null)"
  coordinator_cause="$("$JQ" -r '.coordinator_cause // empty' <<<"$recon" 2>/dev/null)"
  [ -n "$dispatched_n" ] || return 0

  local under_dispatched=false cause=""
  if [ "$dispatched_n" -lt "$admitted_n" ]; then
    under_dispatched=true
    if [ -n "$coordinator_cause" ]; then
      cause="$coordinator_cause"
      journal "select-tick  under-dispatched-detail  (missing=$missing_csv)"
    elif [ "$rc" -gt 128 ]; then
      local sig
      sig="$(kill -l "$((rc - 128))" 2>/dev/null || echo "$((rc - 128))")"
      cause="coordinator-killed-$sig"
      journal "select-tick  under-dispatched  (admitted=$admitted_n dispatched=$dispatched_n missing=$missing_csv cause=$cause lane=$LANE)"
    else
      cause="unknown"
      journal "select-tick  under-dispatched  (admitted=$admitted_n dispatched=$dispatched_n missing=$missing_csv cause=$cause lane=$LANE)"
    fi
  fi

  atomic_write_json "$SELECT_TICK_STATE_DIR/${TICK_ID}.reconcile.json" "$("$JQ" -n \
    --arg tick_id "$TICK_ID" --argjson admitted "$admitted_n" --argjson dispatched "$dispatched_n" \
    --argjson missing "$("$JQ" -c '.missing_slugs' <<<"$recon")" --arg cause "$cause" --argjson under "$under_dispatched" \
    '{tick_id:$tick_id, admitted:$admitted, dispatched:$dispatched, missing:$missing, cause:$cause, under_dispatched:$under}')"
  if [ -f "$SELECT_TICK_STATE_DIR/${TICK_ID}.reconcile.json" ]; then
    local tmplink="$SELECT_TICK_STATE_DIR/.last.reconcile.json.tmp.$$"
    ln -sfn "$(basename "${TICK_ID}.reconcile.json")" "$tmplink" 2>/dev/null \
      && mv -Tf "$tmplink" "$SELECT_TICK_STATE_DIR/last.reconcile.json" 2>/dev/null
  fi

  maybe_alarm "$under_dispatched" "$admitted_n" "$dispatched_n" "$missing_csv"
}

main() {
  case "${1:-}" in
    --status) cmd_status; exit $? ;;
    --check-held) cmd_check_held; exit $? ;;
    -h|--help) usage ;;
  esac

  local coord_cmd=()
  if [ "${1:-}" = "--" ]; then
    shift
    coord_cmd=("$@")
  elif [ $# -gt 0 ]; then
    usage
  else
    # PRD-build-select-tick-run-pin requirement 2: `BUILD_TICK_ARGS="run
    # <slugs>"` is a pin consumed by select-tick.sh, not slug text handed
    # to the coordinator's own /build prompt -- the 2026-09-15 07:11Z/
    # 22:23:55Z incidents this PRD is grounded in both trace back to the
    # coordinator (an LLM) improvising on that text instead. Derive the
    # pin here, export it so select-tick.sh's own default (SELECT_TICK_PIN)
    # picks it up the moment the coordinator makes its one Phase 2 call,
    # and strip the slug list from the /build arg entirely. Any other
    # BUILD_TICK_ARGS value (e.g. "status") passes through unchanged.
    local build_args="${BUILD_TICK_ARGS:-}"
    local pin_arg=""
    case "$build_args" in
      run\ *)
        local raw="${build_args#run }"
        local -a _slugs=()
        IFS=', ' read -r -a _slugs <<<"$raw"
        local _s
        for _s in "${_slugs[@]}"; do
          [ -n "$_s" ] || continue
          pin_arg="${pin_arg:+$pin_arg,}$_s"
        done
        build_args=""
        ;;
    esac
    if [ -n "$pin_arg" ]; then
      export SELECT_TICK_PIN="$pin_arg"
    fi
    coord_cmd=("$CLAUDE_BIN" -p "/build${build_args:+ $build_args}" --model sonnet --dangerously-skip-permissions --output-format text)
  fi

  mkdir -p "$STATE_DIR"
  : >>"$LOCKFILE"

  # Fixed fd 9 (documented above): opened here, held across the `exec`
  # below so the flock's lifetime is the coordinator process tree's
  # lifetime, not this line's. The coordinator's own `flock -n` probe on
  # the same path (Phase 0 verification) is expected to fail — that's
  # the point.
  exec 9>"$LOCKFILE"

  if ! flock -n 9; then
    local age
    if read_holder; then
      age=$(( $(now_epoch) - ${H_STARTED:-0} ))
    else
      H_PID="unknown"; H_CMD="unknown"; age=0
    fi
    local msg="tick-lock-held (pid=$H_PID age=${age}s cmd=$H_CMD)"
    echo "$msg" >&2
    journal "build-tick  skip  $msg"
    exit 75
  fi

  # We now hold the flock on fd 9. requirement 4 (stale holder): the
  # kernel already released any PRIOR holder's lock the instant that
  # holder's process died — flock -n succeeding above proves that, not
  # this check. This check only decides whether to JOURNAL a reclaim (the
  # holder file named a now-dead pid from this same boot).
  if read_holder && [ "$H_BID" = "$(boot_id)" ] && ! kill -0 "$H_PID" 2>/dev/null; then
    journal "tick-lock  reclaimed  (stale_pid=$H_PID)"
  fi

  TICK_STARTED_EPOCH="$(now_epoch)"
  TICK_ID="${TICK_STARTED_EPOCH}-$$"
  printf '%s %s %s %s\n' "$$" "$(boot_id)" "$TICK_STARTED_EPOCH" "${coord_cmd[*]}" > "$HOLDERFILE"

  # requirement 1's tick-id handoff: select-tick.sh (run by the coordinator
  # below) reads these to persist state/select-tick/<TICK_ID>.json under the
  # SAME id this process will reconcile against below — no re-derivation
  # from the holder file needed on either side, though select-tick.sh falls
  # back to reading the holder file itself if these are ever absent.
  export SELECT_TICK_TICK_ID="$TICK_ID"
  export SELECT_TICK_TICK_STARTED="$TICK_STARTED_EPOCH"

  # requirement 6 (holder hygiene): armed only now, AFTER this process has
  # actually written ITS OWN holder file above — never before, or the
  # early tick-lock-held return path (which belongs to a DIFFERENT,
  # already-running holder) would delete that other holder's file out from
  # under it. Fires on every exit from here on: normal, `exit "$rc"` below,
  # or this process itself being signaled. Releases fd 9's flock as a side
  # effect of process exit either way.
  trap 'rm -f "$HOLDERFILE" 2>/dev/null || true' EXIT

  # Print-mode ceiling (Technical considerations): a manual path that
  # forgets this loses its branches to the default wait ceiling (the
  # 08:32Z batch did exactly that). Set it here, once, for every entry
  # path through this script — never override a caller's own value.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"

  # requirement 2: a plain foreground command, not `exec` — this process
  # stays alive as the coordinator's parent for its whole life (fd 9's
  # flock is THIS process's, held here regardless of the child), regains
  # control the instant the child exits by ANY means (normal exit, or
  # killed by signal — bash reports 128+signum as $? for a foreground
  # child killed by a signal, which is all requirement 3's
  # coordinator-killed-<sig> cause needs), and only then runs the
  # reconciliation requirement 3 describes. A missing coord_cmd binary
  # behaves exactly as AC7 wants: "command not found" is non-zero and does
  # not exit this script (no -e), so the trap above still fires and the
  # lock still releases.
  #
  # `9>&-` closes fd 9 for the child (and everything it forks) rather
  # than letting it inherit an open copy: a fixed-number `exec 9>file`
  # redirect is NOT close-on-exec by default, so without this a
  # grandchild the coordinator spawns (observed with AC6's fixture: a
  # `sleep` the fake coordinator backgrounds) survives the coordinator
  # itself being killed, as an orphan, STILL holding fd 9's open file
  # description — flock is scoped to the open file description, not the
  # process, so that orphan alone kept the lock held for the rest of its
  # sleep even after this wrapper had already exited and removed the
  # holder file. Closing it here means only this wrapper's own fd 9 can
  # ever hold the lock, exactly as the holder file already claims.
  "${coord_cmd[@]}" 9>&-
  local rc=$?

  reconcile "$rc"

  exit "$rc"
}

main "$@"
