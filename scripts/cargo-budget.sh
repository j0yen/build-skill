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
# PRD-build-cargo-budget-per-invocation (2026-09-13): a slot is held only
# while a cargo process tree is alive and busy — see requirements below.
# The 2026-09-13 incident: a gate's `autobuilder loop` producer held a slot
# for 3 600s at peak_load=0.83 (no compiler running for most of that hold)
# while 20 other cargo invocations timed out waiting on the 2 slots this
# budgets. The fix moves the slot to where the compute is: producers
# (extend-gate.sh's `autobuilder loop` / `extended-receipts.sh`) now run
# UNSLOTTED with this script's cargo-budget-bin shim on PATH, so every real
# cargo call the producer spawns takes its OWN slot for exactly its own
# duration (requirement 1, wired in extend-gate.sh, not here).
#
# Subcommands:
#   cargo-budget.sh run -- <cmd...>
#       Waits for a slot (see gates below), then execs <cmd...> with
#       CARGO_BUILD_JOBS/RUST_TEST_THREADS set (unless the caller already
#       set them), samples /proc/loadavg every 5s while <cmd...> runs, and
#       appends one row to state/cargo-budget/ledger.jsonl. Exits with
#       <cmd...>'s own exit code, 3 if the combined wait exceeded
#       CARGO_BUDGET_WAIT_MAX before a slot/gate cleared, or 4 if the
#       managed sccache server did not answer even after one restart
#       attempt (sccache_unreachable — <cmd...> never runs; no ledger row
#       is written for a refused run).
#
#       Nested reuse (requirement 2): if this process's environment
#       already carries CARGO_BUDGET_HELD_SLOT/CARGO_BUDGET_HOLDER_PID from
#       an ancestor `run` that (a) is still alive, (b) is a real ancestor
#       of this process, AND (c) still actually holds that slot's flock
#       (checked against /proc/locks — an idle-released or since-expired
#       hold does NOT count), this `run` executes <cmd...> immediately on
#       that slot without acquiring a second one, journals `nested reuse
#       slot=<n> holder=<pid> cmd=[...]`, and writes a ledger row with
#       `nested:true wait_s:0`. Otherwise it acquires a slot normally
#       (`nested:false`) — including when the env is stale (holder pid
#       dead, or the slot was idle-released out from under it).
#
#       Idle-hold release (requirement 4): once a slot is actually held,
#       a monitor loop samples every 5s. If the hold has lasted at least
#       CARGO_BUDGET_IDLE_HOLD_S (default 300) AND the held process tree's
#       average CPU over the hold is under CARGO_BUDGET_IDLE_CPU_PCT
#       (default 5) percent of one core AND no descendant is named `cargo`
#       or `rustc`, the slot's lock fd is closed (the command keeps
#       running) and the journal gets `idle-release slot=<n> held_s=<s>
#       cpu_pct=<p> cmd=[...]`. If the command later shells to cargo
#       through cargo-budget-bin, that nested `run` finds the slot no
#       longer actually flocked (see nested-reuse condition (c) above) and
#       acquires fresh, normally.
#
#       Child fd hygiene (requirement 3): the slot lock fd is closed in
#       <cmd...>'s own process (a redirection on the backgrounded command,
#       not `exec` in this shell) so no descendant, sampler, or
#       backgrounded grandchild of <cmd...> can keep the flock alive after
#       this script's own copy of the fd is closed.
#   cargo-budget.sh status
#       Prints one line: each slot's holder pid (or `free`), held seconds,
#       and summed process-tree CPU seconds (requirement 8).
#   cargo-budget.sh summary [--since <epoch>] [--no-cursor]
#       Prints `cargo-budget: peak_load=<n> min_avail_gb=<n> waits=<n>
#       max_wait_s=<n> holds=<n> idle_slot_s=<n> nested=<n> timeouts=<n>`
#       aggregated from ledger rows (and the timeouts log) at or after
#       <epoch>. With no --since, uses (and advances) a persistent cursor
#       file so repeated calls (one per tick) each cover only their own
#       window — this is what Phase 7's tick-summary step calls.
#   cargo-budget.sh last [n]
#       Prints the last n (default 5) ledger rows, one per line,
#       human-readable. Used by lane-status.sh report.
#
# Gates, checked in this order before a slot is taken (cheapest-to-fail
# first, so a starved box never even queues on the slot semaphore) — never
# checked at all for a nested-reuse run (requirement 2 above):
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
# 60s thereafter while it continues; while waiting on the slot gate
# specifically, a `wait slot holders=[...]` diagnostic line (requirement 5
# — who holds each slot right now, and for how long) is additionally
# journaled every 300s, and a slot-wait timeout's `die()` message always
# includes the same holders=[...] list.
#
# Env overrides (production defaults in parens):
#   CARGO_BUDGET_SLOTS (2)  CARGO_BUDGET_WAIT_MAX (1200)
#   CARGO_BUDGET_MIN_AVAIL_GB (6)  CARGO_BUDGET_TEST_THREADS (4)
#   CARGO_BUDGET_MAX_LOAD (64)
#   CARGO_BUDGET_IDLE_HOLD_S (300)  CARGO_BUDGET_IDLE_CPU_PCT (5)
#   CARGO_BUDGET_PARENT_STEP (unset) — name of the unslotted producer step
#     that spawned this cargo call (e.g. `autobuilder-loop`,
#     `extended-receipts`); recorded verbatim as the ledger row's
#     `parent_step`, `null` when unset. Set by extend-gate.sh's per-
#     producer PATH/env prefix, never by this script.
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
TIMEOUTS_LOG="$STATE_DIR/timeouts.jsonl"

die() { echo "cargo-budget: $1" >&2; exit "${2:-2}"; }
usage() { echo "usage: cargo-budget.sh {run -- <cmd...>|record-unslotted -- <cmd...>|record-routed -- <cmd...>|status|summary [--since <epoch>]|last [n]}" >&2; exit 2; }

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

# --- process-tree helpers (requirements 2/3/4/5/8) --------------------------
# All read the real `ps`/`/proc` — never faked in tests (see PRD's Technical
# considerations: fixtures here are real live sleep/fake-cargo processes,
# never a synthetic /proc tree), so these are exercised against genuine
# process trees by cargo-budget-selftest.sh's slotinv block.

# is_ancestor_pid <candidate-ancestor-pid> <start-pid> -> rc0 if the
# candidate is <start-pid> itself or appears walking <start-pid>'s ppid
# chain up to pid 1.
is_ancestor_pid() {
  local anc="$1" start="$2"
  ps -eo pid=,ppid= 2>/dev/null | awk -v anc="$anc" -v start="$start" '
    { ppid[$1] = $2 }
    END {
      p = start
      for (i = 0; i < 100000; i++) {
        if (p == anc) { print "yes"; exit }
        if (!(p in ppid) || ppid[p] == "" || p == "1") exit
        p = ppid[p]
      }
    }' | grep -q yes
}

# slot_lock_holder_pid <slot-index> -> pid currently holding that slot's
# flock (via /proc/locks matched on the lock file's inode), or "" if free.
# DESIGN NOTE (requirement 5's own "/proc/locks against the slot files'
# inodes" wording): /proc/locks was tried first and rejected. On this
# fleet's kernel, a FLOCK-class lock's pid field is the pid of whatever
# process CALLED flock(2) — here, the short-lived external `flock -n "$fd"`
# subprocess this script forks per acquisition attempt — not the long-lived
# shell that keeps the fd (and therefore the lock) open afterward.
# Empirically confirmed: that subprocess is already reaped and gone (`ps -p
# <pid>` → no such process) within a second of acquisition, while the lock
# itself correctly persists for the whole hold via the shell's own fd. So a
# holders=[...] line built from /proc/locks alone would almost always name
# a pid that is already dead by the time anyone reads it — useless for
# "diagnosable from the journal alone" (Goals). Instead, each slot's real
# holder is tracked in its own side file (requirement 5/8's actual
# information need), written at acquisition and removed at release
# (normal completion OR idle-release) — see the `slot-N.holder` writes in
# cmd_run. /proc/locks is still what makes the semaphore itself correct
# (unchanged); it is just not the source of holder identity here.
slot_holder_file() { echo "$STATE_DIR/slot-$1.holder"; }

# slot_holder_pid <slot-index> -> live holder pid from the side file, or ""
# (also "" — self-healing — if the recorded pid is no longer alive, e.g.
# the holder crashed without going through the normal release path).
slot_holder_pid() {
  local idx="$1" hf; hf="$(slot_holder_file "$idx")"
  [ -f "$hf" ] || { echo ""; return; }
  local pid; pid="$(jq -r '.pid // empty' "$hf" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid" || echo ""
}

slot_holder_field() {  # $1=idx $2=jq-field -> value or ""
  local idx="$1" hf; hf="$(slot_holder_file "$idx")"
  [ -f "$hf" ] || { echo ""; return; }
  jq -r --arg f "$2" '.[$f] // empty' "$hf" 2>/dev/null
}

slot_holder_write() {  # $1=idx $2=pid $3=started_epoch $4=cmd
  local idx="$1"
  jq -nc --argjson pid "$2" --argjson started "$3" --arg cmd "$4" \
    '{pid:$pid, started_epoch:$started, cmd:$cmd}' > "$(slot_holder_file "$idx")" 2>/dev/null || true
}

slot_holder_clear() { rm -f "$(slot_holder_file "$1")" 2>/dev/null || true; }

# tree_cpu_s <root-pid> -> summed cputimes (seconds, integer) over
# <root-pid> and every live descendant.
tree_cpu_s() {
  local root="$1"
  ps -eo pid=,ppid=,cputimes= 2>/dev/null | awk -v root="$root" '
    { ppid[$1] = $2; cpu[$1] = $3 + 0 }
    function mark(p) { if (p in seen) return; seen[p] = 1; total += cpu[p] }
    END {
      if (!(root in cpu)) { print 0; exit }
      mark(root)
      changed = 1
      while (changed) {
        changed = 0
        for (p in ppid) {
          if (!(p in seen) && (ppid[p] in seen)) { mark(p); changed = 1 }
        }
      }
      printf "%d", total
    }'
}

# tree_has_cargo_or_rustc <root-pid> -> rc0 if <root-pid> or any live
# descendant's comm is `cargo` or `rustc`.
tree_has_cargo_or_rustc() {
  local root="$1"
  ps -eo pid=,ppid=,comm= 2>/dev/null | awk -v root="$root" '
    { ppid[$1] = $2; comm[$1] = $3 }
    function mark(p) { if (p in seen) return; seen[p] = 1 }
    END {
      if (!(root in comm)) exit 1
      mark(root)
      changed = 1
      while (changed) {
        changed = 0
        for (p in ppid) {
          if (!(p in seen) && (ppid[p] in seen)) { mark(p); changed = 1 }
        }
      }
      for (p in seen) if (comm[p] == "cargo" || comm[p] == "rustc") { print "yes"; exit }
    }' | grep -q yes
}

# proc_etime_s <pid> -> seconds since <pid> started, or "" if not found.
proc_etime_s() {
  ps -o etimes= -p "$1" 2>/dev/null | tr -d ' '
}

# slot_holders_desc <slots> -> "holders=[slot0:<pid>:<held_s>s:<cmd head>, ...]"
# read from each slot's holder side file (see the design note above); a
# free slot (no holder file, or its pid no longer alive) reads "slotN:free".
slot_holders_desc() {
  local slots="$1" i pid cmd started held_s out=""
  for i in $(seq 0 $((slots - 1))); do
    pid="$(slot_holder_pid "$i")"
    if [ -n "$pid" ]; then
      cmd="$(slot_holder_field "$i" cmd | cut -c1-60)"
      [ -n "$cmd" ] || cmd="?"
      started="$(slot_holder_field "$i" started_epoch)"
      if [ -n "$started" ]; then
        held_s=$(( $(now_epoch) - started ))
      else
        held_s="?"
      fi
      out="${out}${out:+, }slot${i}:${pid}:${held_s}s:${cmd}"
    else
      out="${out}${out:+, }slot${i}:free"
    fi
  done
  printf 'holders=[%s]' "$out"
}

# write_ledger_row — one flock-serialized append, shared by the nested-reuse
# and normal-acquisition paths.
#
# $16 (slotted): "true" for every pre-existing call site (a real budget
# slot was held, or nested-reused, for this cargo invocation). "false" is
# used only by cmd_record_unslotted (PRD-build-burst-gate-canary-invariant
# R15 attestation gap, 2026-09-18): a cargo call the shim passed straight
# through without ever acquiring a slot (cargo check/metadata, a
# `+toolchain` probe, ...) still gets exactly one ledger row so
# extend-gate.sh's R15 producer-attestation check can see it, with
# slotted:false marking that no budget/wait accounting applies to it.
#
# $18 (route_cause): defaults empty, like $17 (route) did when it was
# added in bf960c4. Set from CARGO_BUDGET_ROUTE_CAUSE (cargo-budget-
# bin/cargo exports it from cargo_route_current()'s CARGO_ROUTE_CAUSE —
# see scripts/lib/cargo-route.sh) on the record-routed path and the
# slotted (cmd_run) path, so a ledger row that says route:"local" also
# says WHY (not-configured, lane-unarmed, status-probe-failed,
# no-active-session, no-server-id) instead of just the bare word.
write_ledger_row() {
  local ts_start="$1" ts_end="$2" wait_s="$3" peak_load="$4" slot="$5" pid="$6" \
        cmd="$7" exit_code="$8" mem_avail_gb_start="$9" sccache_pid="${10}" \
        sccache_started_at="${11}" parent_step="${12}" nested="${13}" \
        tree_cpu_s_val="${14}" idle_released="${15}" slotted="${16:-true}" \
        route="${17:-local}" route_cause="${18:-}"
  mkdir -p "$STATE_DIR"
  local parent_step_json
  if [ -n "$parent_step" ]; then
    parent_step_json="$(jq -nc --arg v "$parent_step" '$v')"
  else
    parent_step_json="null"
  fi
  local row
  row="$(jq -nc \
    --arg ts_start "$ts_start" \
    --arg ts_end "$ts_end" \
    --argjson wait_s "$wait_s" \
    --argjson peak_load "$peak_load" \
    --argjson slot "$slot" \
    --argjson pid "$pid" \
    --arg cmd "$cmd" \
    --argjson exit_code "$exit_code" \
    --argjson mem_avail_gb_start "$mem_avail_gb_start" \
    --arg sccache_pid "$sccache_pid" \
    --arg sccache_started_at "$sccache_started_at" \
    --argjson parent_step "$parent_step_json" \
    --argjson nested "$nested" \
    --argjson tree_cpu_s "$tree_cpu_s_val" \
    --argjson idle_released "$idle_released" \
    --argjson slotted "$slotted" \
    --arg route "$route" \
    --arg route_cause "$route_cause" \
    '{ts_start:$ts_start, ts_end:$ts_end, wait_s:$wait_s, peak_load:$peak_load, slot:$slot, pid:$pid, cmd:$cmd, exit_code:$exit_code, mem_avail_gb_start:$mem_avail_gb_start, sccache_server:{pid:$sccache_pid, started_at:$sccache_started_at}, parent_step:$parent_step, nested:$nested, tree_cpu_s:$tree_cpu_s, idle_released:$idle_released, slotted:$slotted, route:$route, route_cause:$route_cause}')"
  {
    exec {lfd}>>"$LEDGER.lock"
    flock -x "$lfd"
    printf '%s\n' "$row" >> "$LEDGER"
    exec {lfd}>&-
  }
}

# cmd_record_unslotted — PRD-build-burst-gate-canary-invariant R15
# attestation gap fix (2026-09-18): cargo-budget-bin/cargo calls this
# instead of exec'ing straight to the real cargo whenever it decides an
# invocation doesn't need a budget slot (check, metadata, a `+toolchain`
# probe, ...). Writes one ledger row with slotted:false (ts_start==ts_end,
# exit_code null since we exec away and never see it) tagged with
# whatever CARGO_BUDGET_PARENT_STEP the caller set, then execs the real
# command — no gating, no waiting, no behavior change for the cargo call
# itself. This is what makes msrv-verify's `cargo +<msrv> check` (never
# routed — check is cheap/no-compile by design) and any other passthrough
# producer call visible to R15's ledger scan.
cmd_record_unslotted() {
  [ "${1:-}" = "--" ] || usage
  shift
  [ $# -ge 1 ] || usage
  local parent_step="${CARGO_BUDGET_PARENT_STEP:-}"
  local ts; ts="$(now_iso)"
  local meminfo_file="${CARGO_BUDGET_MEMINFO:-/proc/meminfo}"
  write_ledger_row "$ts" "$ts" 0 0 -1 "$$" "$*" null \
    "$(mem_avail_gb "$meminfo_file")" unknown unknown "$parent_step" false 0 false false local
  exec "$@"
}

# cmd_record_routed — PRD-build-cargo-budget-routed-no-slot: cargo-budget-
# bin/cargo calls this instead of cmd_run's slot-acquiring `run --` path
# whenever it has already determined (via cargo_route_current(), the SAME
# predicate burst-lane-bin/cargo's own routing `if` uses) that this
# invocation is actually about to be routed to the burst box. A routed
# call burns zero local CPU/slot time — holding a local budget slot for
# its whole REMOTE wall-clock duration is exactly the bug this fixes (see
# the shim's own header for the incident). Writes one ledger row with
# slotted:false, route:"burst" (ts_start==ts_end, exit_code null since we
# exec away and never see it) tagged with whatever CARGO_BUDGET_PARENT_STEP
# the caller set, then execs the real command (or the next shim in the
# chain) — no gating, no waiting, no slot.
cmd_record_routed() {
  [ "${1:-}" = "--" ] || usage
  shift
  [ $# -ge 1 ] || usage
  local parent_step="${CARGO_BUDGET_PARENT_STEP:-}"
  local route_cause="${CARGO_BUDGET_ROUTE_CAUSE:-}"
  local ts; ts="$(now_iso)"
  local meminfo_file="${CARGO_BUDGET_MEMINFO:-/proc/meminfo}"
  write_ledger_row "$ts" "$ts" 0 0 -1 "$$" "$*" null \
    "$(mem_avail_gb "$meminfo_file")" unknown unknown "$parent_step" false 0 false false burst "$route_cause"
  exec "$@"
}

record_timeout() {  # $1=reason $2=cmd
  mkdir -p "$STATE_DIR"
  local row; row="$(jq -nc --arg ts "$(now_iso)" --arg reason "$1" --arg cmd "$2" '{ts:$ts, reason:$reason, cmd:$cmd}')"
  {
    exec {tfd}>>"$TIMEOUTS_LOG.lock"
    flock -x "$tfd"
    printf '%s\n' "$row" >> "$TIMEOUTS_LOG"
    exec {tfd}>&-
  }
}

cmd_run() {
  [ "${1:-}" = "--" ] || usage
  shift
  [ $# -ge 1 ] || usage

  local slots="${CARGO_BUDGET_SLOTS:-2}"
  local wait_max="${CARGO_BUDGET_WAIT_MAX:-1200}"
  local min_avail_gb="${CARGO_BUDGET_MIN_AVAIL_GB:-6}"
  local test_threads="${CARGO_BUDGET_TEST_THREADS:-4}"
  local max_load="${CARGO_BUDGET_MAX_LOAD:-64}"
  local idle_hold_s="${CARGO_BUDGET_IDLE_HOLD_S:-300}"
  local idle_cpu_pct="${CARGO_BUDGET_IDLE_CPU_PCT:-5}"
  local meminfo_file="${CARGO_BUDGET_MEMINFO:-/proc/meminfo}"
  local loadavg_file="${CARGO_BUDGET_LOADAVG:-/proc/loadavg}"
  local hostname_val="${CARGO_BUDGET_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
  local parent_step="${CARGO_BUDGET_PARENT_STEP:-}"
  local route_cause="${CARGO_BUDGET_ROUTE_CAUSE:-}"

  mkdir -p "$STATE_DIR"

  # --- requirement 2/3: nested reuse — checked BEFORE any gate, so a
  # producer's own already-slotted cargo call never waits on gates its
  # ancestor already cleared. Condition (c) — the slot is still actually
  # flocked by that holder pid right now, per /proc/locks — is what makes
  # this correctly fall through to normal acquisition once the ancestor's
  # hold has been idle-released (requirement 4) out from under it.
  if [ -n "${CARGO_BUDGET_HELD_SLOT:-}" ] && [ -n "${CARGO_BUDGET_HOLDER_PID:-}" ] \
     && kill -0 "$CARGO_BUDGET_HOLDER_PID" 2>/dev/null \
     && is_ancestor_pid "$CARGO_BUDGET_HOLDER_PID" "$$" \
     && [ "$(slot_holder_pid "$CARGO_BUDGET_HELD_SLOT")" = "$CARGO_BUDGET_HOLDER_PID" ]; then
    journal "nested reuse slot=$CARGO_BUDGET_HELD_SLOT holder=$CARGO_BUDGET_HOLDER_PID cmd=[$*]"
    local n_start n_end n_rc
    n_start="$(now_iso)"
    "$@"
    n_rc=$?
    n_end="$(now_iso)"
    write_ledger_row "$n_start" "$n_end" 0 0 "$CARGO_BUDGET_HELD_SLOT" "$$" "$*" "$n_rc" \
      "$(mem_avail_gb "$meminfo_file")" unknown unknown "$parent_step" true 0 false true local "$route_cause"
    exit "$n_rc"
  fi

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
      record_timeout "$reason" "$*"
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
  local holders_last_journal=$(now_epoch)
  local holders_journal_started=0
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
      local holders; holders="$(slot_holders_desc "$slots")"
      journal "wait slot timeout after ${elapsed}s slots=$slots $holders cmd=[$*]"
      record_timeout slot "$*"
      die "wait ceiling (${wait_max}s) exceeded waiting for a slot (of $slots) for: $* $holders" 3
    fi
    if [ "$slot_journal_started" -eq 0 ] || [ $(( now - slot_last_journal )) -ge 60 ]; then
      journal "wait slot avail_slots=0/$slots elapsed=${elapsed}s cmd=[$*]"
      slot_last_journal=$now
      slot_journal_started=1
    fi
    if [ "$holders_journal_started" -eq 0 ] || [ $(( now - holders_last_journal )) -ge 300 ]; then
      journal "wait slot $(slot_holders_desc "$slots") elapsed=${elapsed}s cmd=[$*]"
      holders_last_journal=$now
      holders_journal_started=1
    fi
    sleep 1
  done

  local total_wait_s=$(( $(now_epoch) - wait_start_epoch ))
  local hold_start_epoch; hold_start_epoch=$(now_epoch)

  # --- computed caps (unless the caller already set them) -----------------
  local jobs=$(( $(nproc_count) / slots ))
  [ "$jobs" -lt 2 ] && jobs=2
  : "${CARGO_BUILD_JOBS:=$jobs}"
  : "${RUST_TEST_THREADS:=$test_threads}"
  export CARGO_BUILD_JOBS RUST_TEST_THREADS

  # requirement 2: tag this hold so a nested `run` underneath "$@" can find
  # and reuse it (see the nested-reuse check at the top of this function).
  export CARGO_BUDGET_HELD_SLOT="$slot_index"
  export CARGO_BUDGET_HOLDER_PID="$$"
  # requirement 5/8: record who's actually holding this slot (see the
  # design note above slot_holder_file — /proc/locks alone can't answer
  # this for a flock(1)-per-attempt idiom). Cleared at every release point
  # below (idle-release and normal completion).
  slot_holder_write "$slot_index" "$$" "$hold_start_epoch" "$*"

  # PRD-build-gate-wall-clock requirement 2/5: assert the managed sccache
  # server answers BEFORE this budgeted command ever compiles — see header.
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
      # CURRENT SHELL PERMANENTLY — see the historical note this replaced;
      # close the fd unguarded instead.
      exec {slot_fd}>&- || true
      journal "sccache_unreachable cmd=[$*]"
      die "$assert_out (refusing to run: $*)" 4
    fi
  fi

  local run_start_iso; run_start_iso="$(now_iso)"
  # PRD-build-gate-wall-clock requirement 3: opt-in per-step wall-clock
  # budget + CPU-delta wedge probe. OFF by default ($CARGO_BUDGET_WEDGE
  # unset) because gate-wedge.sh buffers <cmd...>'s stdout/stderr until it
  # exits — see the header for why this does not flip on for every
  # existing caller in production yet.
  local wedge_bin="${GATE_WEDGE_SH:-$SKILL_DIR/scripts/gate-wedge.sh}"

  # requirement 3 (child fd hygiene): the `{slot_fd}>&-` redirection below
  # applies only to the backgrounded command's own forked process — it
  # closes THAT process's copy of the slot lock fd before it (or any
  # descendant/sampler/backgrounded grandchild it spawns) can inherit and
  # keep the flock's open file description alive past this script's own
  # `exec {slot_fd}>&-` a few lines down. It does NOT affect this shell's
  # own copy (a redirection on a simple external command never does).
  if [ -n "${CARGO_BUDGET_WEDGE:-}" ] && [ -x "$wedge_bin" ]; then
    "$wedge_bin" run --step "${CARGO_BUDGET_STEP_NAME:-cargo-budget}" -- "$@" {slot_fd}>&- &
  else
    "$@" {slot_fd}>&- &
  fi
  local cmd_pid=$!

  # --- monitor loop: peak-load sampling + idle-hold release (requirement 4)
  # Polls at a fine ~0.2s grain (so a near-instant command isn't held up
  # waiting on a coarse sampling tick) but only does the 5s-cadence
  # sampling/idle work every ~25th tick — this replaces the old detached
  # peak-load-only subshell sampler, because idle-release (below) must
  # close THIS shell's own copy of the slot fd, which a forked subshell
  # cannot do on the parent's behalf (see requirement 3's note: closing a
  # copy of an fd never releases the flock while another copy, here the
  # parent's, stays open).
  local peak_load="0"
  local idle_released=false
  local last_tree_cpu_s=0
  local _tick=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 0.2
    kill -0 "$cmd_pid" 2>/dev/null || break
    _tick=$((_tick + 1))
    [ $((_tick % 25)) -eq 0 ] || continue
    local la; la="$(load_1m "$loadavg_file")"
    peak_load="$(max_float "$la" "$peak_load")"
    last_tree_cpu_s="$(tree_cpu_s "$cmd_pid")"
    if [ "$idle_released" = false ]; then
      local held_s=$(( $(now_epoch) - hold_start_epoch ))
      if [ "$held_s" -ge "$idle_hold_s" ]; then
        local cpu_pct
        cpu_pct="$(awk -v t="$last_tree_cpu_s" -v s="$held_s" 'BEGIN{ if (s<=0) s=1; printf "%.2f", (t/s)*100 }')"
        if ! gt_float "$cpu_pct" "$idle_cpu_pct" && ! tree_has_cargo_or_rustc "$cmd_pid"; then
          exec {slot_fd}>&- 2>/dev/null || true
          slot_holder_clear "$slot_index"
          idle_released=true
          journal "idle-release slot=$slot_index held_s=${held_s} cpu_pct=${cpu_pct} cmd=[$*]"
        fi
      fi
    fi
  done
  wait "$cmd_pid"
  local rc=$?
  local run_end_iso; run_end_iso="$(now_iso)"

  # release the slot (no-op — already closed — when idle-released above)
  exec {slot_fd}>&- 2>/dev/null || true
  slot_holder_clear "$slot_index"

  local idle_released_json; [ "$idle_released" = true ] && idle_released_json=true || idle_released_json=false
  write_ledger_row "$run_start_iso" "$run_end_iso" "$total_wait_s" "$peak_load" "$slot_index" "$$" "$*" \
    "$rc" "$avail_gb" "$sccache_pid" "$sccache_started_at" "$parent_step" false "$last_tree_cpu_s" "$idle_released_json" true local "$route_cause"

  exit "$rc"
}

cmd_status() {
  local slots="${CARGO_BUDGET_SLOTS:-2}"
  mkdir -p "$STATE_DIR"
  local out="cargo-budget status:" i pid held_s cpu_s started
  for i in $(seq 0 $((slots - 1))); do
    pid="$(slot_holder_pid "$i")"
    if [ -n "$pid" ]; then
      started="$(slot_holder_field "$i" started_epoch)"
      if [ -n "$started" ]; then held_s=$(( $(now_epoch) - started )); else held_s="$(proc_etime_s "$pid")"; fi
      [ -n "$held_s" ] || held_s=0
      cpu_s="$(tree_cpu_s "$pid")"
      out="$out slot${i}=pid:${pid},held_s:${held_s},tree_cpu_s:${cpu_s}"
    else
      out="$out slot${i}=free"
    fi
  done
  printf '%s\n' "$out"
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
  [ -f "$TIMEOUTS_LOG" ] || : > "$TIMEOUTS_LOG"

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
      max_wait_s:  (([$r[].wait_s] + [0]) | max),
      holds:       ([$r[] | select(.nested != true)] | length),
      nested:      ([$r[] | select(.nested == true)] | length),
      idle_slot_s: ([$r[] | select(.idle_released == true) |
                      (((.ts_end | fromdateiso8601) - (.ts_start | fromdateiso8601)))] | add // 0)
    }' "$LEDGER" 2>/dev/null || echo '{"peak_load":0,"min_avail_gb":0,"waits":0,"max_wait_s":0,"holds":0,"nested":0,"idle_slot_s":0}')"

  local timeouts
  timeouts="$(jq -sc --argjson since "$since" 'map(select((.ts | fromdateiso8601) >= $since)) | length' "$TIMEOUTS_LOG" 2>/dev/null || echo 0)"

  if [ "$use_cursor" -eq 1 ]; then now_epoch > "$CURSOR_FILE"; fi

  local peak_load min_avail waits max_wait holds nested idle_slot_s
  peak_load="$(jq -r '.peak_load' <<<"$stats")"
  min_avail="$(jq -r '.min_avail_gb' <<<"$stats")"
  waits="$(jq -r '.waits' <<<"$stats")"
  max_wait="$(jq -r '.max_wait_s' <<<"$stats")"
  holds="$(jq -r '.holds' <<<"$stats")"
  nested="$(jq -r '.nested' <<<"$stats")"
  idle_slot_s="$(jq -r '.idle_slot_s' <<<"$stats")"
  printf 'cargo-budget: peak_load=%s min_avail_gb=%s waits=%s max_wait_s=%s holds=%s idle_slot_s=%s nested=%s timeouts=%s\n' \
    "$peak_load" "$min_avail" "$waits" "$max_wait" "$holds" "$idle_slot_s" "$nested" "$timeouts"
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
    record-unslotted) cmd_record_unslotted "$@" ;;
    record-routed) cmd_record_routed "$@" ;;
    status) cmd_status "$@" ;;
    summary) cmd_summary "$@" ;;
    last) cmd_last "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
