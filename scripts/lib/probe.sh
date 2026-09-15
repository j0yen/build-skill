#!/usr/bin/env bash
# scripts/lib/probe.sh — one probe contract for every command in the build
# lane whose failure decides a route, a verdict, or a teardown
# (PRD-build-fail-loud-evidence-kept).
#
# Before this, "run a probe" was per-site taste: stderr thrown at
# /dev/null, the result variable defaulted to empty on failure, and the
# caller continued on that empty value as if the probe had answered
# (Grounding: eight sites doing exactly this shape — a route probe that
# printed its mismatch to stdout nobody kept, a backgrounded parity child
# whose death nobody saw, a `verify-failed` line naming no cause). This
# gives every site the same contract: stderr is always kept on disk, a
# failure is always one journal line naming the rc / last stderr line /
# log path, and the caller always gets rc back to branch on explicitly —
# it never swallows it.
#
# Source this; never execute it.
#
# API:
#   probe_run <name> [--quiet-ok] -- <cmd...>
#     Runs <cmd...>. stdout passes through byte-identical (several callers
#     parse it, e.g. `status --json`) — only stderr is captured. stderr is
#     tee'd to state/logs/probe/<name>.<epoch>.log (both kept on disk and
#     still visible on the real stderr). On success (rc 0) the log is
#     removed unless PROBE_KEEP_OK=1, and nothing is journaled. On
#     failure, one line is journaled via journal_line:
#       <ts>  <caller>  probe  failed  (name=<name> rc=<n> err="<last stderr line>" log=<path>)
#     --quiet-ok: for a probe whose non-zero rc is itself an expected,
#     routine outcome for THIS caller (not a defect) — the log is still
#     kept and rc is still returned for the caller to branch on, but the
#     `probe failed` line is not journaled (the caller's own branch is
#     expected to journal its OWN decision instead, e.g. `route unknown`).
#     Returns the command's own rc either way.
#
#   probe_bg <name> [--close-fds <fd[,fd...]>] -- <cmd...>
#     Runs <cmd...> detached via setsid so the caller returns immediately
#     (the parity-scheduler shape: a backgrounded child whose exit code
#     must still reach the journal even though the parent already
#     returned). stderr is captured to the same state/logs/probe/ log.
#     --close-fds N,M,... closes those file descriptors in the detached
#     child before it runs — preserves burst-lane.sh's own convention of
#     dropping locks (220/221/201/203) a backgrounded grandchild must not
#     inherit. A small reaper (itself backgrounded, so probe_bg itself
#     never blocks) waits on the child and journals:
#       <ts>  <caller>  probe  bg-exit  (name=<name> rc=<n>)
#     plus the same `probe failed` line as probe_run on a non-zero rc
#     (log kept in that case; removed on rc 0). Always returns 0
#     immediately — the caller's own rc is unaffected by the backgrounded
#     child's eventual outcome, by design (fire-and-forget).
#
# <caller> is the immediate caller's script basename
# ($(basename "${BASH_SOURCE[1]}")) — the same convention journal.sh's own
# documentation uses for its callers.
#
# state/logs/probe/ retention (requirement 3): probe_prune_logs() removes
# anything older than PROBE_LOG_MAX_AGE_DAYS (default 7), then trims
# oldest-first until the directory is under PROBE_LOG_MAX_BYTES (default
# 200 MB), journaling one summary line per call:
#   <ts>  probe  prune  (removed=<n> dir=<path>)
# Callers wire this into their own existing reap cadence (see
# lane-status.sh's tick summary and burst-lane.sh's reap functions) —
# probe.sh does not run it on a timer of its own.

_PROBE_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=journal.sh
source "$_PROBE_LIB_HERE/journal.sh"

_probe_skill_dir() {
  ( cd "$_PROBE_LIB_HERE/../.." && pwd -P )
}

# PROBE_LOG_DIR wins outright; otherwise derives off STATE_DIR (the
# generic override scripts/lib/isolation.sh already redirects under test —
# requirement: this library isolates the same way every other build-skill
# writer does, with no bespoke env name of its own to remember) so a
# selftest run under run-selftests.sh isolates probe logs for free.
_probe_log_dir() {
  printf '%s\n' "${PROBE_LOG_DIR:-${STATE_DIR:-$(_probe_skill_dir)/state}/logs/probe}"
}

# _probe_journal <text> — routes a probe.sh-authored line to whichever
# journal the CALLING script itself already writes to, so `probe failed`
# lines land next to that script's own decision lines instead of a
# different default file. Checks the handful of journal-target globals
# the three in-scope callers actually declare, in the order a given
# process can plausibly have more than one set (burst-lane.sh's JOURNAL,
# extend-gate.sh's lowercase journal, then the three legacy per-script
# override env names journal.sh itself already documents) — falls back to
# journal_line's own default root when none is set, which is also the
# unoverridden default every one of these callers themselves resolves to.
_probe_journal() {
  local text="$1"
  local target="${JOURNAL:-${journal:-${EXTEND_GATE_JOURNAL:-${SELECT_GUARD_JOURNAL:-${BURST_LANE_JOURNAL:-}}}}}"
  if [ -n "$target" ]; then
    journal_line --file "$target" "$text"
  else
    journal_line "$text"
  fi
}

# probe_run <name> [--quiet-ok] -- <cmd...>
probe_run() {
  local name="$1"; shift
  local quiet_ok=false
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --quiet-ok) quiet_ok=true; shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift

  local caller; caller="$(basename "${BASH_SOURCE[1]:-$0}")"
  local log_dir; log_dir="$(_probe_log_dir)"
  mkdir -p "$log_dir" 2>/dev/null || true
  local log="$log_dir/${name}.$(date -u +%s).log"

  # Classic stdout/stderr swap: fd3 saves the real stdout, stderr is
  # routed into the pipe (tee), stdout is restored onto fd3 before the
  # command runs — stdout stays byte-identical to a caller reading it via
  # command substitution, while stderr alone goes through tee (kept on
  # disk AND still visible on the real stderr). Synchronous (a pipeline,
  # not a backgrounded process substitution), so PIPESTATUS is reliable
  # and there is no race reading the log file afterward.
  local rc
  exec 3>&1
  "$@" 2>&1 1>&3 3>&- | tee "$log" >&2
  rc="${PIPESTATUS[0]}"
  exec 3>&-

  if [ "$rc" -eq 0 ]; then
    [ "${PROBE_KEEP_OK:-0}" = "1" ] || rm -f "$log" 2>/dev/null
    return 0
  fi

  if ! $quiet_ok; then
    local err_line
    err_line="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n1 | cut -c1-160)"
    _probe_journal "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $caller  probe  failed  (name=$name rc=$rc err=\"$err_line\" log=$log)"
  fi
  return "$rc"
}

# probe_bg <name> [--close-fds <fd[,fd...]>] -- <cmd...>
probe_bg() {
  local name="$1"; shift
  local close_fds=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --close-fds) close_fds="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift

  local caller; caller="$(basename "${BASH_SOURCE[1]:-$0}")"
  local log_dir; log_dir="$(_probe_log_dir)"
  mkdir -p "$log_dir" 2>/dev/null || true
  local log="$log_dir/${name}.$(date -u +%s).log"

  local close_expr=""
  if [ -n "$close_fds" ]; then
    local fd
    IFS=',' read -ra _probe_close_fd_list <<<"$close_fds"
    for fd in "${_probe_close_fd_list[@]}"; do
      [ -n "$fd" ] && close_expr="$close_expr $fd>&-"
    done
  fi

  (
    # Drop the caller's locks in THIS subshell before setsid ever forks,
    # so the detached grandchild below never inherits them (the "backgrounded
    # parity child kept a flock alive" defect this preserves the fix for).
    if [ -n "$close_expr" ]; then
      eval "exec $close_expr" 2>/dev/null || true
    fi
    setsid "$@" >/dev/null 2>"$log" &
    child_pid=$!
    wait "$child_pid"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$log" 2>/dev/null || true
    else
      err_line="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n1 | cut -c1-160)"
      _probe_journal "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $caller  probe  failed  (name=$name rc=$rc err=\"$err_line\" log=$log)"
    fi
    _probe_journal "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $caller  probe  bg-exit  (name=$name rc=$rc)"
  ) &
  disown
  return 0
}

# probe_prune_logs — requirement 3: prune state/logs/probe/ by age then by
# total size, journaling exactly one summary line per call regardless of
# whether anything was removed (a zero-removed line still proves the prune
# ran, rather than reading as silently never wired up).
probe_prune_logs() {
  local log_dir; log_dir="$(_probe_log_dir)"
  [ -d "$log_dir" ] || { journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  probe  prune  (removed=0 dir=$log_dir)"; return 0; }

  local max_age_days="${PROBE_LOG_MAX_AGE_DAYS:-7}"
  local max_bytes="${PROBE_LOG_MAX_BYTES:-209715200}"
  local removed=0 f

  while IFS= read -r -d '' f; do
    rm -f "$f" 2>/dev/null && removed=$((removed + 1))
  done < <(find "$log_dir" -type f -mtime "+${max_age_days}" -print0 2>/dev/null)

  local total_bytes
  total_bytes="$(du -sb "$log_dir" 2>/dev/null | awk '{print $1}')"
  total_bytes="${total_bytes:-0}"
  if [ "$total_bytes" -gt "$max_bytes" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      rm -f "$f" 2>/dev/null && removed=$((removed + 1))
      total_bytes="$(du -sb "$log_dir" 2>/dev/null | awk '{print $1}')"
      total_bytes="${total_bytes:-0}"
      [ "$total_bytes" -le "$max_bytes" ] && break
    done < <(find "$log_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
  fi

  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  probe  prune  (removed=$removed dir=$log_dir)"
  return 0
}
