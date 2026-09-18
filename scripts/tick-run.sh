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
#   TICK_OUTCOME_FILE tick-outcome.json path (default $BUILD_STATE_DIR/
#                     tick-outcome.json) — PRD-buildloop-tick-outcome-
#                     liveness R1: written on every exit path (ok, failed
#                     w/ classified cause, or skipped w/ tick-lock-held),
#                     atomically (temp+rename). See scripts/lib/tick-
#                     cause.sh for the cause classifier.
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
# shellcheck source=lib/tick-cause.sh
source "$SKILL_DIR/scripts/lib/tick-cause.sh"
JOURNAL="${TICK_RUN_JOURNAL:-$(journal_root)/$(date -u +%F).md}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
BOOT_ID_FILE="${TICK_RUN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
LANE="${TICK_RUN_LANE:-$(hostname)}"
RECONCILE_PY="${TICK_RECONCILE_PY:-$SKILL_DIR/scripts/tick-reconcile.py}"
SELECT_TICK_STATE_DIR="${SELECT_TICK_STATE_DIR:-$STATE_DIR/select-tick}"
# PRD-buildloop-tick-outcome-liveness R1: the one outcome record a tick
# ever writes, whatever happened to its child.
TICK_OUTCOME_FILE="${TICK_OUTCOME_FILE:-$STATE_DIR/tick-outcome.json}"  # lint:gate-red-not-rendered -- writer, not a renderer; loop-liveness.sh/handoff-header.sh/gates-banner.sh render age from the record this writes
# PRD-buildloop-tick-outcome-liveness R8: append-only history of every
# record write_tick_outcome makes, one compact line per tick, rotated at
# 30 days -- day-ledger.sh's own source for ticks_failed/causes/
# longest_failed_streak (tick-outcome.json above is only ever the LATEST
# record; day-ledger.sh needs the whole day's sequence).
TICK_OUTCOMES_JSONL="${TICK_OUTCOMES_JSONL:-$STATE_DIR/tick-outcomes.jsonl}"
TICK_OUTCOMES_ROTATE_DAYS="${TICK_OUTCOMES_ROTATE_DAYS:-30}"
# Alarm hourly gate (requirement 4): never more than one alarm per hour per
# lane. State is separate from select-tick.sh's own admitted/skipped
# persistence so a read of one never races a write of the other.
ALARM_LAST_FILE="${TICK_RUN_ALARM_LAST_FILE:-$SELECT_TICK_STATE_DIR/alarm-last-$LANE.json}"
STREAK_FILE="${TICK_RUN_STREAK_FILE:-$SELECT_TICK_STATE_DIR/streak-$LANE.json}"
ALERT_DELIVER="${TICK_RUN_ALERT_DELIVER:-$SKILL_DIR/scripts/alert-deliver.sh}"
# PRD-buildloop-tick-outcome-liveness R5: the one knob, same override
# convention as GATE_RED_WINDOW_H.
LOOP_TICK_FAIL_ALARM_STREAK="${LOOP_TICK_FAIL_ALARM_STREAK:-3}"
# "Delivered for the CURRENT failure episode" -- deliberately NOT
# alert-deliver.sh's own per-UTC-day marker (scripts/lib/alert-marker.sh):
# that marker would either suppress a same-day resolve after a same-day
# delivery, or suppress a brand-new episode's first alarm later the same
# day. This sentinel is created on delivery and removed on resolve.
TICK_ALARM_MARKER="${TICK_ALARM_MARKER:-$STATE_DIR/tick-outcome-alarm-delivered}"

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

# write_tick_outcome <rc> <outcome> <cause> <evidence> — PRD-buildloop-
# tick-outcome-liveness R1. Writes $TICK_OUTCOME_FILE atomically (via
# atomic_write_json, temp+rename — AC3: no partial JSON ever observable).
# outcome is ok|failed|skipped. Reads the previous record (if any) to:
#   - bump the running "n" counter,
#   - carry `last_ok_ts` forward on anything but ok (AC1),
#   - compute `streak_failed`: 0 on ok, prev+1 on failed, unchanged on
#     skipped (a lock-contended tick is not evidence the loop is broken —
#     it neither breaks nor resolves an existing failure streak).
write_tick_outcome() {
  local rc="$1" outcome="$2" cause="$3" evidence="$4"
  local ts; ts="$(now_iso)"
  local prev_n=0 prev_streak=0 prev_last_ok=""
  if [ -x "$JQ" ] && [ -r "$TICK_OUTCOME_FILE" ]; then
    prev_n="$("$JQ" -r '.n // 0' "$TICK_OUTCOME_FILE" 2>/dev/null)"
    prev_streak="$("$JQ" -r '.streak_failed // 0' "$TICK_OUTCOME_FILE" 2>/dev/null)"
    prev_last_ok="$("$JQ" -r '.last_ok_ts // empty' "$TICK_OUTCOME_FILE" 2>/dev/null)"
  fi
  case "$prev_n" in ''|*[!0-9]*) prev_n=0 ;; esac
  case "$prev_streak" in ''|*[!0-9]*) prev_streak=0 ;; esac

  local n=$((prev_n + 1))
  local streak_failed last_ok_ts
  case "$outcome" in
    ok)
      streak_failed=0
      last_ok_ts="$ts"
      ;;
    failed)
      streak_failed=$((prev_streak + 1))
      last_ok_ts="$prev_last_ok"
      ;;
    *)
      streak_failed="$prev_streak"
      last_ok_ts="$prev_last_ok"
      ;;
  esac

  local json
  if [ -x "$JQ" ]; then
    json="$("$JQ" -n \
      --arg ts "$ts" --argjson n "$n" --argjson rc "$rc" --arg outcome "$outcome" \
      --arg cause "$cause" --arg evidence "$evidence" --argjson streak_failed "$streak_failed" \
      --arg last_ok_ts "$last_ok_ts" --arg lane "$LANE" \
      '{ts:$ts, n:$n, rc:$rc, outcome:$outcome,
        cause: (if $cause == "" then null else $cause end),
        evidence: (if $evidence == "" then null else $evidence end),
        streak_failed:$streak_failed,
        last_ok_ts: (if $last_ok_ts == "" then null else $last_ok_ts end),
        lane:$lane}')" || return 0
  else
    # jq missing (should never happen in production -- every other
    # atomic_write_json caller in this script already requires it): a
    # best-effort record beats no record at all.
    local esc_evidence="${evidence//\"/\\\"}"
    json="$(printf '{"ts":"%s","n":%d,"rc":%d,"outcome":"%s","cause":"%s","evidence":"%s","streak_failed":%d,"last_ok_ts":"%s","lane":"%s"}' \
      "$ts" "$n" "$rc" "$outcome" "$cause" "$esc_evidence" "$streak_failed" "$last_ok_ts" "$LANE")"
  fi
  atomic_write_json "$TICK_OUTCOME_FILE" "$json"
  append_tick_outcomes_jsonl "$json"
}

# append_tick_outcomes_jsonl <json> — R8: one compact line per tick,
# appended to $TICK_OUTCOMES_JSONL, then rotated (drop lines whose `.ts`
# is older than $TICK_OUTCOMES_ROTATE_DAYS days) via temp+rename so a
# concurrent reader (day-ledger.sh) never observes a half-rewritten file.
# Best-effort throughout (jq missing, or a JSON build failure above,
# means this silently does nothing) -- the append-only history is a
# reporting aid, never load-bearing for the record write_tick_outcome
# itself already committed.
append_tick_outcomes_jsonl() {
  local json="$1"
  [ -x "$JQ" ] || return 0
  local line
  line="$(printf '%s' "$json" | "$JQ" -c '.' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  mkdir -p "$(dirname "$TICK_OUTCOMES_JSONL")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$TICK_OUTCOMES_JSONL" 2>/dev/null || return 0

  local days="$TICK_OUTCOMES_ROTATE_DAYS"
  case "$days" in ''|*[!0-9]*) days=30 ;; esac
  local cutoff=$(( $(now_epoch) - days * 86400 ))
  local tmp
  tmp="$(mktemp "$(dirname "$TICK_OUTCOMES_JSONL")/.tmp.XXXXXX" 2>/dev/null)" || return 0
  if "$JQ" -c --argjson cutoff "$cutoff" \
       'select((.ts // "") as $t | $t != "" and (($t | fromdateiso8601) >= $cutoff))' \
       "$TICK_OUTCOMES_JSONL" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$TICK_OUTCOMES_JSONL" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# maybe_deliver_loop_tick_failed <cause> <streak_failed> <last_ok_ts>
# <evidence> — PRD-buildloop-tick-outcome-liveness R4/R5. Fires
# `alert-deliver.sh loop-tick-failed` exactly AT $LOOP_TICK_FAIL_ALARM_STREAK
# (default 3, plain call), and again at 2x/4x that threshold (6/12 by
# default, `--comment` re-delivery — AC10); silent everywhere else,
# including every streak `cause=quota-saturated` (AC8 — that branch
# already has its own alarm and must never be double-paged). Journals its
# own `ALARM  loop-tick-failed  ...` line (alert-deliver.sh itself only
# journals notify/notify-send, never an ALARM line — same convention as
# gate-red-tick.sh's `ALARM  gate-red-persistent  ...`).
maybe_deliver_loop_tick_failed() {
  local cause="$1" streak="$2" last_ok_ts="$3" evidence="$4"
  [ "$cause" != "quota-saturated" ] || return 0
  local base="$LOOP_TICK_FAIL_ALARM_STREAK"
  case "$base" in ''|*[!0-9]*) base=3 ;; esac
  local comment_flag=()
  if [ "$streak" -eq "$base" ] 2>/dev/null; then
    :
  elif [ "$streak" -eq $((base * 2)) ] 2>/dev/null || [ "$streak" -eq $((base * 4)) ] 2>/dev/null; then
    comment_flag=(--comment)
  else
    return 0
  fi

  journal "ALARM  loop-tick-failed  cause=$cause streak=$streak last_ok=${last_ok_ts:-unknown}"

  local ev
  ev="$(mktemp 2>/dev/null)" || return 0
  printf 'cause=%s streak=%s last_ok=%s\n%s\n' "$cause" "$streak" "${last_ok_ts:-unknown}" "$evidence" > "$ev"
  if [ -x "$ALERT_DELIVER" ]; then
    "$ALERT_DELIVER" loop-tick-failed build-loop "$ev" --value "$streak" "${comment_flag[@]}" >/dev/null 2>&1 || true
  fi
  rm -f "$ev" 2>/dev/null
  mkdir -p "$(dirname "$TICK_ALARM_MARKER")" 2>/dev/null || true
  : > "$TICK_ALARM_MARKER" 2>/dev/null || true
}

# maybe_resolve_loop_tick_failed — called on an `ok` outcome. Resolves
# exactly once per delivered episode (AC9), gated on our own sentinel
# (not alert-deliver.sh's per-UTC-day marker, which must not suppress a
# same-day resolve).
maybe_resolve_loop_tick_failed() {
  [ -f "$TICK_ALARM_MARKER" ] || return 0
  if [ -x "$ALERT_DELIVER" ]; then
    "$ALERT_DELIVER" resolve loop-tick-failed build-loop >/dev/null 2>&1 || true
  fi
  rm -f "$TICK_ALARM_MARKER" 2>/dev/null || true
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
    write_tick_outcome 75 skipped tick-lock-held "$msg"
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
  #
  # PRD-buildloop-tick-outcome-liveness R1/R2: the child's merged
  # stdout/stderr is teed to a private capture file so tick-cause.sh can
  # classify a failure after the fact, while still streaming through to
  # this script's own stdout unchanged (a caller like
  # claude-build-tick.sh's own `| tee -a "$LOG"` sees byte-identical
  # output to before this PRD — merging stdout/stderr here changes
  # nothing observable, since that caller already merges them with its
  # own `2>&1`). PIPESTATUS[0], not pipefail's $?, is the child's real
  # exit code (matches claude-build-tick.sh's own convention) — this is
  # what makes AC3's rc=143 (child SIGTERM'd) land in the record: the
  # foreground pipeline still returns 128+signum for a killed child.
  local capture_file rc
  capture_file="$(mktemp "${TMPDIR:-/tmp}/tick-run-capture.XXXXXX" 2>/dev/null)" || capture_file=""
  if [ -n "$capture_file" ]; then
    # `9>&-` on BOTH pipeline stages, not just coord_cmd: `tee` is its own
    # forked process and, unless closed here too, inherits fd 9 wide open
    # from this shell exactly like coord_cmd would without its own
    # `9>&-` — an orphaned `tee` (its stdin held open by an orphaned
    # grandchild coord_cmd spawned, the same AC6 shape noted above) would
    # then keep the flock held after this wrapper and its coordinator are
    # both gone, reintroducing the exact bug that comment describes.
    "${coord_cmd[@]}" 9>&- 2>&1 | tee "$capture_file" 9>&-
    rc=${PIPESTATUS[0]}
  else
    "${coord_cmd[@]}" 9>&-
    rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    write_tick_outcome "$rc" ok "" ""
    maybe_resolve_loop_tick_failed
  else
    local cause="other" evidence=""
    if [ -n "$capture_file" ]; then
      IFS=$'\t' read -r cause evidence < <(tick_cause_classify "$capture_file")
    fi
    write_tick_outcome "$rc" failed "$cause" "$evidence"
    # Re-read the record just written for its authoritative streak_failed/
    # last_ok_ts rather than re-deriving them here (write_tick_outcome
    # already did the prev-record RMW; one source of truth).
    local streak_failed=0 last_ok_ts=""
    if [ -x "$JQ" ] && [ -r "$TICK_OUTCOME_FILE" ]; then
      streak_failed="$("$JQ" -r '.streak_failed // 0' "$TICK_OUTCOME_FILE" 2>/dev/null)"
      last_ok_ts="$("$JQ" -r '.last_ok_ts // empty' "$TICK_OUTCOME_FILE" 2>/dev/null)"
    fi
    case "$streak_failed" in ''|*[!0-9]*) streak_failed=0 ;; esac
    maybe_deliver_loop_tick_failed "$cause" "$streak_failed" "$last_ok_ts" "$evidence"
  fi
  [ -n "$capture_file" ] && rm -f "$capture_file" 2>/dev/null

  reconcile "$rc"

  exit "$rc"
}

main "$@"
