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
#   BUILD_TICK_ARGS   forwarded into the default coordinator's /build arg
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
JOURNAL="${TICK_RUN_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
BOOT_ID_FILE="${TICK_RUN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
boot_id() { cat "$BOOT_ID_FILE" 2>/dev/null || echo unknown; }

journal() {
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  printf '%s  %s\n' "$(now_iso)" "$1" >> "$JOURNAL"
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
    return 0
  fi
  if read_holder; then
    local age=$(( $(now_epoch) - ${H_STARTED:-0} ))
    echo "tick-lock-held (pid=$H_PID age=${age}s cmd=$H_CMD)"
  else
    echo "tick-lock-held (holder file missing/unreadable)"
  fi
  return 0
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
    coord_cmd=("$CLAUDE_BIN" -p "/build${BUILD_TICK_ARGS:+ $BUILD_TICK_ARGS}" --model sonnet --dangerously-skip-permissions --output-format text)
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

  printf '%s %s %s %s\n' "$$" "$(boot_id)" "$(now_epoch)" "${coord_cmd[*]}" > "$HOLDERFILE"

  # Print-mode ceiling (Technical considerations): a manual path that
  # forgets this loses its branches to the default wait ceiling (the
  # 08:32Z batch did exactly that). Set it here, once, for every entry
  # path through this script — never override a caller's own value.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"

  # exec, not a subshell call: the coordinator's pid becomes THIS
  # process's pid (matching $HOLDERFILE above) and fd 9's flock rides
  # along for its whole life. If exec itself fails (e.g. missing
  # binary), bash's default (non-interactive, execfail unset) behavior
  # is to exit this process immediately with the exec failure's exit
  # code — which also closes fd 9 and releases the flock, exactly as
  # AC7 requires, with no special-case code needed here.
  exec "${coord_cmd[@]}"
}

main "$@"
