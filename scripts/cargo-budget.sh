#!/usr/bin/env bash
# cargo-budget.sh — host-wide cargo concurrency budget (PRD-build-cargo-
# concurrency-budget). RedBaron OOMed for ~6 minutes at 06:08Z 2026-09-09
# (load average 21,466) while the same-target sub-cap was only 3: a gate's
# `cargo test --workspace` and several worktree branches each assumed they
# owned the whole 16-thread/30GB box. Nothing counted what a branch or a
# gate unleashes underneath the sub-cap. This script is the shared budget:
# a small counting semaphore (N host-wide slots via flock), a per-run
# thread/job cap sized to the slot count, and a memory (and, on RedBaron,
# a load) floor checked before a slot is taken.
#
# Subcommands:
#   cargo-budget.sh run -- <cmd...>
#       Waits for a slot (see gates below), then execs <cmd...> with
#       CARGO_BUILD_JOBS/RUST_TEST_THREADS set (unless the caller already
#       set them), samples /proc/loadavg every 5s while <cmd...> runs, and
#       appends one row to state/cargo-budget/ledger.jsonl (now including
#       a sccache_server:{pid,started_at} field — PRD-build-gate-wall-
#       clock requirement 5). Exits with <cmd...>'s own exit code, 3 if
#       the combined wait exceeded CARGO_BUDGET_WAIT_MAX before a
#       slot/gate cleared, or 4 if the managed sccache server did not
#       answer even after one restart attempt (sccache_unreachable —
#       <cmd...> never runs; no ledger row is written for a refused run).
#   cargo-budget.sh summary [--since <epoch>] [--no-cursor]
#       Prints `cargo-budget: peak_load=<n> min_avail_gb=<n> waits=<n>
#       max_wait_s=<n>` aggregated from ledger rows at or after <epoch>.
#       With no --since, uses (and advances) a persistent cursor file so
#       repeated calls (one per tick) each cover only their own window —
#       this is what Phase 7's tick-summary step calls.
#   cargo-budget.sh last [n]
#       Prints the last n (default 5) ledger rows, one per line,
#       human-readable. Used by lane-status.sh report.
#
# Gates, checked in this order before a slot is taken (cheapest-to-fail
# first, so a starved box never even queues on the slot semaphore):
#   1. MemAvailable (from /proc/meminfo, or $CARGO_BUDGET_MEMINFO for
#      tests) >= CARGO_BUDGET_MIN_AVAIL_GB (default 6), rechecked every
#      10s.
#   2. On RedBaron only (hostname match, or $CARGO_BUDGET_HOSTNAME for
#      tests): 1-minute loadavg (from /proc/loadavg, or
#      $CARGO_BUDGET_LOADAVG for tests) <= CARGO_BUDGET_MAX_LOAD (default
#      64), rechecked every 10s.
#   3. A free slot among CARGO_BUDGET_SLOTS (default 2), via flock on
#      state/cargo-budget/slot-N.lock, rechecked every 1s.
# All three share ONE overall wait ceiling, CARGO_BUDGET_WAIT_MAX (default
# 1200s), measured from the first gate check. A `cargo-budget wait
# <mem|load|slot>` line is journaled the moment a wait begins and every
# 60s thereafter while it continues.
#
# Env overrides (production defaults in parens):
#   CARGO_BUDGET_SLOTS (2)  CARGO_BUDGET_WAIT_MAX (1200)
#   CARGO_BUDGET_MIN_AVAIL_GB (6)  CARGO_BUDGET_TEST_THREADS (4)
#   CARGO_BUDGET_MAX_LOAD (64)
#   CARGO_BUDGET_WEDGE (unset=off) — opt a `run` call into gate-wedge.sh's
#     per-step wall-clock budget + CPU-delta wedge probe (PRD-build-gate-
#     wall-clock requirement 3). Off by default: see the note at the
#     `"$@"` call site below for why (output buffering).
#   GATE_WEDGE_SH (<skill-dir>/scripts/gate-wedge.sh)
#   CARGO_BUDGET_STEP_NAME (cargo-budget) — step name on wedge receipts
#   CARGO_BUDGET_SCCACHE_ASSERT (auto) — auto/1/on/0/off; see the
#     sccache-assert.sh call site below (PRD-build-gate-wall-clock
#     requirement 2/5: never compile against an unreachable sccache
#     server; every ledger row's exit_code 4 means this refused the run).
#   SCCACHE_ASSERT_SH (<skill-dir>/scripts/sccache-assert.sh)
# Test-only hooks (never set these in production use):
#   CARGO_BUDGET_STATE_DIR  CARGO_BUDGET_JOURNAL  CARGO_BUDGET_MEMINFO
#   CARGO_BUDGET_LOADAVG  CARGO_BUDGET_HOSTNAME  CARGO_BUDGET_NPROC
#
# SAFETY: this script deliberately never launches or throttles anything by
# itself beyond the gates above — see cargo-budget-selftest.sh for proof,
# which uses `sleep`-based fake commands, never a real cargo build,
# precisely so validating this fix cannot recreate the incident it fixes.
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CARGO_BUDGET_STATE_DIR:-$SKILL_DIR/state/cargo-budget}"
LEDGER="$STATE_DIR/ledger.jsonl"
CURSOR_FILE="$STATE_DIR/.summary-cursor"

die() { echo "cargo-budget: $1" >&2; exit "${2:-2}"; }
usage() { echo "usage: cargo-budget.sh {run -- <cmd...>|summary [--since <epoch>]|last [n]}" >&2; exit 2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

journal() {
  local jf="${CARGO_BUDGET_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
  mkdir -p "$(dirname "$jf")" 2>/dev/null || true
  printf '%s  cargo-budget  %s\n' "$(now_iso)" "$1" >> "$jf"
}

mem_avail_gb() {
  local f="${1:-/proc/meminfo}"
  awk '/^MemAvailable:/ { printf "%.3f", $2/1024/1024; found=1 } END { if (!found) print "999" }' "$f" 2>/dev/null \
    || echo "999"
}

load_1m() {
  local f="${1:-/proc/loadavg}"
  awk '{ print $1; found=1 } END { if (!found) print "0" }' "$f" 2>/dev/null || echo "0"
}

is_redbaron() {
  local h="${1:-}"
  [ "$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')" = "redbaron" ]
}

ge_float() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 >= b+0) }'; }
gt_float() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 > b+0) }'; }
max_float() { awk -v a="$1" -v b="$2" 'BEGIN{ print (a+0>b+0)?a+0:b+0 }'; }

nproc_count() { echo "${CARGO_BUDGET_NPROC:-$(nproc 2>/dev/null || echo 4)}"; }

cmd_run() {
  [ "${1:-}" = "--" ] || usage
  shift
  [ $# -ge 1 ] || usage

  local slots="${CARGO_BUDGET_SLOTS:-2}"
  local wait_max="${CARGO_BUDGET_WAIT_MAX:-1200}"
  local min_avail_gb="${CARGO_BUDGET_MIN_AVAIL_GB:-6}"
  local test_threads="${CARGO_BUDGET_TEST_THREADS:-4}"
  local max_load="${CARGO_BUDGET_MAX_LOAD:-64}"
  local meminfo_file="${CARGO_BUDGET_MEMINFO:-/proc/meminfo}"
  local loadavg_file="${CARGO_BUDGET_LOADAVG:-/proc/loadavg}"
  local hostname_val="${CARGO_BUDGET_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

  mkdir -p "$STATE_DIR"
  local wait_start_epoch; wait_start_epoch=$(now_epoch)
  local last_journal_epoch=$wait_start_epoch
  local avail_gb="0"

  # --- gates 1+2: memory floor, then (RedBaron only) load ceiling --------
  local reason=""
  while :; do
    avail_gb="$(mem_avail_gb "$meminfo_file")"
    if ! ge_float "$avail_gb" "$min_avail_gb"; then
      reason="mem"
    elif is_redbaron "$hostname_val" && gt_float "$(load_1m "$loadavg_file")" "$max_load"; then
      reason="load"
    else
      reason=""
    fi
    [ -z "$reason" ] && break

    local now; now=$(now_epoch)
    local elapsed=$(( now - wait_start_epoch ))
    if [ "$elapsed" -ge "$wait_max" ]; then
      journal "wait $reason timeout after ${elapsed}s avail_gb=$avail_gb cmd=[$*]"
      die "wait ceiling (${wait_max}s) exceeded waiting on '$reason' gate for: $*" 3
    fi
    if [ "$now" = "$last_journal_epoch" ] || [ $(( now - last_journal_epoch )) -ge 60 ]; then
      journal "wait $reason avail_gb=$avail_gb elapsed=${elapsed}s cmd=[$*]"
      last_journal_epoch=$now
    fi
    sleep 10
  done

  # --- gate 3: slot semaphore ---------------------------------------------
  local slot_index=-1
  local slot_fd=-1
  local slot_last_journal=$(now_epoch)
  local slot_journal_started=0
  while :; do
    local i
    for i in $(seq 0 $((slots - 1))); do
      local lf="$STATE_DIR/slot-$i.lock"
      : >>"$lf" 2>/dev/null
      local fd
      exec {fd}>"$lf"
      if flock -n "$fd"; then
        slot_index=$i
        slot_fd=$fd
        break 2
      fi
      exec {fd}>&-
    done

    local now; now=$(now_epoch)
    local elapsed=$(( now - wait_start_epoch ))
    if [ "$elapsed" -ge "$wait_max" ]; then
      journal "wait slot timeout after ${elapsed}s slots=$slots cmd=[$*]"
      die "wait ceiling (${wait_max}s) exceeded waiting for a slot (of $slots) for: $*" 3
    fi
    if [ "$slot_journal_started" -eq 0 ] || [ $(( now - slot_last_journal )) -ge 60 ]; then
      journal "wait slot avail_slots=0/$slots elapsed=${elapsed}s cmd=[$*]"
      slot_last_journal=$now
      slot_journal_started=1
    fi
    sleep 1
  done

  local total_wait_s=$(( $(now_epoch) - wait_start_epoch ))

  # --- computed caps (unless the caller already set them) -----------------
  local jobs=$(( $(nproc_count) / slots ))
  [ "$jobs" -lt 2 ] && jobs=2
  : "${CARGO_BUILD_JOBS:=$jobs}"
  : "${RUST_TEST_THREADS:=$test_threads}"
  export CARGO_BUILD_JOBS RUST_TEST_THREADS

  # --- peak-load sampler (every 5s, for the lifetime of the child) --------
  local peak_file; peak_file="$(mktemp "${TMPDIR:-/tmp}/cargo-budget-peak.XXXXXX")"
  echo "0" > "$peak_file"
  (
    while :; do
      cur_peak="$(cat "$peak_file" 2>/dev/null || echo 0)"
      la="$(load_1m "$loadavg_file")"
      max_float "$la" "$cur_peak" > "$peak_file.tmp" 2>/dev/null && mv -f "$peak_file.tmp" "$peak_file"
      sleep 5
    done
  ) &
  local sampler_pid=$!
  disown "$sampler_pid" 2>/dev/null || true

  # PRD-build-gate-wall-clock requirement 2/5: assert the managed sccache
  # server answers BEFORE this budgeted command ever compiles — the
  # actual local-RedBaron path the 2026-09-10 incident hit (RUSTC_WRAPPER
  # is set fleet-wide via ~/.cargo/config.toml, not by any single script,
  # so this shared cargo-invoking choke point is the right place, not a
  # per-script edit). Only runs when sccache is actually on $PATH — a box
  # with no sccache configured is unaffected (never a hard dependency).
  # Read-only in the common case (show-stats succeeds — the assert never
  # touches the server unless it is provably unreachable, so this is safe
  # to run unconditionally against a server other concurrent callers may
  # be using right now); only escalates to a restart when genuinely
  # unreachable, which is exactly this PRD's fix, not a new risk. Fails
  # the run closed (rc 4, before "$@" ever executes) on sccache_unreachable
  # — never compiles against a server we could not prove was up.
  # $CARGO_BUDGET_SCCACHE_ASSERT: auto (default) | 1/on (force even
  # without sccache on PATH, for tests) | 0/off (force-disable).
  local sccache_assert_bin="${SCCACHE_ASSERT_SH:-$SKILL_DIR/scripts/sccache-assert.sh}"
  local sccache_pid="unknown" sccache_started_at="unknown"
  local assert_mode="${CARGO_BUDGET_SCCACHE_ASSERT:-auto}"
  local should_assert=0
  case "$assert_mode" in
    1|on)  should_assert=1 ;;
    0|off) should_assert=0 ;;
    *)     command -v sccache >/dev/null 2>&1 && should_assert=1 ;;
  esac
  if [ "$should_assert" -eq 1 ] && [ -x "$sccache_assert_bin" ]; then
    local assert_out
    if assert_out="$("$sccache_assert_bin" 2>&1)"; then
      sccache_pid="$(printf '%s\n' "$assert_out" | sed -n 's/.*pid=\([^ ]*\).*/\1/p' | head -1)"
      sccache_started_at="$(printf '%s\n' "$assert_out" | sed -n 's/.*started_at=\([^ ]*\).*/\1/p' | head -1)"
      [ -n "$sccache_pid" ] || sccache_pid="unknown"
      [ -n "$sccache_started_at" ] || sccache_started_at="unknown"
    else
      # NOTE: a bare `exec ... 2>/dev/null` redirection applies to the
      # CURRENT SHELL PERMANENTLY (there is no command word for the
      # redirection to be scoped to) — `2>/dev/null` here would silently
      # blackhole every later stderr write for the rest of this process,
      # including die()'s own message a few lines down. Close the fd
      # unguarded; closing an already-valid bash-allocated fd does not
      # error in the cases this branch runs in.
      exec {slot_fd}>&- || true
      kill "$sampler_pid" 2>/dev/null || true
      wait "$sampler_pid" 2>/dev/null || true
      rm -f "$peak_file" "$peak_file.tmp" 2>/dev/null || true
      journal "sccache_unreachable cmd=[$*]"
      die "$assert_out (refusing to run: $*)" 4
    fi
  fi

  local run_start_iso; run_start_iso="$(now_iso)"
  # PRD-build-gate-wall-clock requirement 3: opt-in per-step wall-clock
  # budget + CPU-delta wedge probe (see gate-wedge.sh's own header — this
  # is the 2026-09-10 incident's fix: a hung cargo/sccache client tree at
  # zero CPU for 60+ minutes with nothing noticing). OFF by default
  # ($CARGO_BUDGET_WEDGE unset) because gate-wedge.sh buffers <cmd...>'s
  # stdout/stderr until it exits (needed to re-emit it after a false-start
  # retry without interleaving two attempts' output) — a real behavior
  # change for anything tailing a live build log, so this does not flip on
  # for every existing cargo-budget.sh caller in production yet. Set
  # CARGO_BUDGET_WEDGE=1 to opt a caller in today; $GATE_WEDGE_SH and
  # $CARGO_BUDGET_STEP_NAME are forwarded overrides (see that script's
  # header for the budget/probe timing envs it reads directly).
  local wedge_bin="${GATE_WEDGE_SH:-$SKILL_DIR/scripts/gate-wedge.sh}"
  if [ -n "${CARGO_BUDGET_WEDGE:-}" ] && [ -x "$wedge_bin" ]; then
    "$wedge_bin" run --step "${CARGO_BUDGET_STEP_NAME:-cargo-budget}" -- "$@"
  else
    "$@"
  fi
  local rc=$?
  local run_end_iso; run_end_iso="$(now_iso)"

  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  local peak_load; peak_load="$(cat "$peak_file" 2>/dev/null || echo 0)"
  rm -f "$peak_file" "$peak_file.tmp" 2>/dev/null || true

  # release the slot
  exec {slot_fd}>&- 2>/dev/null || true

  # --- ledger row (one flock-serialized append per run) -------------------
  local row
  row="$(jq -nc \
    --arg ts_start "$run_start_iso" \
    --arg ts_end "$run_end_iso" \
    --argjson wait_s "$total_wait_s" \
    --argjson peak_load "$peak_load" \
    --argjson slot "$slot_index" \
    --argjson pid "$$" \
    --arg cmd "$*" \
    --argjson exit_code "$rc" \
    --argjson mem_avail_gb_start "$avail_gb" \
    --arg sccache_pid "$sccache_pid" \
    --arg sccache_started_at "$sccache_started_at" \
    '{ts_start:$ts_start, ts_end:$ts_end, wait_s:$wait_s, peak_load:$peak_load, slot:$slot, pid:$pid, cmd:$cmd, exit_code:$exit_code, mem_avail_gb_start:$mem_avail_gb_start, sccache_server:{pid:$sccache_pid, started_at:$sccache_started_at}}')"
  {
    exec {lfd}>>"$LEDGER.lock"
    flock -x "$lfd"
    printf '%s\n' "$row" >> "$LEDGER"
    exec {lfd}>&-
  }

  exit "$rc"
}

cmd_summary() {
  local since="" use_cursor=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="$2"; use_cursor=0; shift 2 ;;
      --no-cursor) use_cursor=0; shift ;;
      *) shift ;;
    esac
  done
  mkdir -p "$STATE_DIR"
  [ -f "$LEDGER" ] || : > "$LEDGER"

  if [ -z "$since" ] && [ "$use_cursor" -eq 1 ]; then
    since="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
  fi
  since="${since:-0}"

  local stats
  stats="$(jq -sc --argjson since "$since" '
    map(select(((.ts_end // .ts_start) | fromdateiso8601) >= $since)) as $r |
    {
      peak_load:   (([$r[].peak_load]   + [0]) | max),
      min_avail_gb: (if ($r|length) > 0 then ([$r[].mem_avail_gb_start] | min) else 0 end),
      waits:       ([$r[] | select(.wait_s > 0)] | length),
      max_wait_s:  (([$r[].wait_s] + [0]) | max)
    }' "$LEDGER" 2>/dev/null || echo '{"peak_load":0,"min_avail_gb":0,"waits":0,"max_wait_s":0}')"

  if [ "$use_cursor" -eq 1 ]; then now_epoch > "$CURSOR_FILE"; fi

  local peak_load min_avail waits max_wait
  peak_load="$(jq -r '.peak_load' <<<"$stats")"
  min_avail="$(jq -r '.min_avail_gb' <<<"$stats")"
  waits="$(jq -r '.waits' <<<"$stats")"
  max_wait="$(jq -r '.max_wait_s' <<<"$stats")"
  printf 'cargo-budget: peak_load=%s min_avail_gb=%s waits=%s max_wait_s=%s\n' \
    "$peak_load" "$min_avail" "$waits" "$max_wait"
}

cmd_last() {
  local n="${1:-5}"
  mkdir -p "$STATE_DIR"
  if [ ! -f "$LEDGER" ]; then
    echo "(no cargo-budget ledger yet)"
    return 0
  fi
  tail -n "$n" "$LEDGER" | while IFS= read -r row; do
    jq -r '"\(.ts_start)  wait_s=\(.wait_s) peak_load=\(.peak_load) mem_avail_gb_start=\(.mem_avail_gb_start) exit=\(.exit_code) cmd=\(.cmd)"' <<<"$row" 2>/dev/null
  done
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    run) cmd_run "$@" ;;
    summary) cmd_summary "$@" ;;
    last) cmd_last "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
