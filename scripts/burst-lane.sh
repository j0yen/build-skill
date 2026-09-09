#!/usr/bin/env bash
# burst-lane.sh — session-lifecycle manager for the Hetzner CCX53 burst lane
# (PRD-build-burst-lane-ccx53). Ports the session-mode half of the retired
# `/mnt/data/jsy/tmp/cloudbuild-retired/cloudbuild.sh` (session-start/
# session-end/watchdog) onto the single-box, hour-aware teardown discipline
# `gate-burst.sh` already proved for PRD-build-gate-cloudburst — but where
# gate-burst.sh tears an idle box down inside the same tick, this lane stays
# up across PRDs and ticks (operator, 2026-09-09 07:58Z) and only schedules
# deletion once no rust work remains anywhere in build-queue/, at the last
# two minutes of the current billed hour.
#
# THIS PASS implements requirement 1 (session lifecycle: up/status/run/
# sync-back/down/watchdog), the requirement-6 sandbox probe on `up`, and
# requirement 10 (the target/ pull-back `run` does on exit is now the same
# incremental `rsync --delete --stats` path `sync-back` uses, with bytes
# transferred recorded on both commands' journal lines). Requirements 4
# (worktree-extend.sh PATH prepend) and 5 (gate-burst.sh should-route/run)
# landed in later ticks — see git log, this header is not kept current
# per-commit. Requirement 7's FORMULA now lives here too: `sub-cap` probes
# the box's MemAvailable/nproc over ssh and prints/journals
# `burst: sub-cap=<n> (avail_gb=<n> nproc=<n>)` (or the no-session local=3
# fallback line) — but wiring that call INTO SKILL.md's selection rule and
# lane-claim.sh's SAME_LANE_SUBCAP (so a live session actually drops the
# local rust cap to 0 and admits up to sub-cap branches) is still a later
# tick's step. NOT yet wired: that selection-side integration, the
# uv/python leg (req 12), and the cost ledger's "PRDs served" attribution
# (req 13, beyond the hours/eur it already tracks) — each is its own
# well-defined next step for a later tick.
#
# Subcommands:
#   burst-lane.sh up
#       Idempotent (AC1): a live tracked session -> "already-up: <id> <ip>",
#       no create call. A server named wm-burst-lane already on Hetzner but
#       with no local session.json -> adopted, no create call. Otherwise
#       checks precondition (hcloud on PATH + authenticated + SNAPSHOT_ID
#       set), creates exactly one ccx53 named wm-burst-lane, waits for ssh,
#       writes state/burst-lane/session.json, runs one sandboxed
#       `python3 -c print(1)` over ssh and records sandbox_ok (AC5).
#   burst-lane.sh status [--json]
#       Prints active session id/ip/minutes-alive/ttl/sandbox_ok, or
#       "no active session".
#   burst-lane.sh run <worktree> -- <cargo args...>
#       Ensures a session is up (booting one if needed), rsyncs <worktree>
#       to the box (excluding target/ and .git/), runs the command remotely
#       under RUSTC_WRAPPER=sccache, rsyncs target/ back, returns the
#       remote command's exit code. Any infra failure prints
#       "fallback: <reason>" and exits 3 (never blocks the caller).
#   burst-lane.sh sync-back <worktree>
#       Standalone incremental (rsync --delete) pull of target/ from the
#       box back to <worktree>, journaling bytes transferred.
#   burst-lane.sh down [--more-work-queued]
#       Never calls poweroff/shutdown/stop (AC14) — a stopped server bills
#       the same as a running one. Scans build-queue/ for any rust-target
#       PRD queued/building/in_progress; if any remain (or
#       --more-work-queued is passed), decision=keep and any scheduled
#       teardown is cancelled. Otherwise decision=scheduled until the last
#       two minutes of the current billed hour, then decision=deleted
#       (delete verified, primary IP goes with it, cost journaled).
#   burst-lane.sh watchdog
#       Safety-net TTL check (default 6h, session.json's own ttl_hours) —
#       independent of the down/rust-work logic above. Deletes and
#       journals a "watchdog teardown" line with uptime if the session has
#       outlived its TTL.
#   burst-lane.sh cost --today
#       Sums state/burst-lane/cost.jsonl rows for today's UTC date.
#   burst-lane.sh sub-cap [--candidates <n>]
#       Requirement 7's formula. No session -> prints "sub-cap=0 local=3
#       (no session — local cap applies)" and journals a no-session line.
#       Session up -> probes the box's MemAvailable_gb and nproc over ssh,
#       computes min(floor(avail_gb/BURST_GB_PER_BRANCH),
#       floor(nproc/BURST_CORES_PER_BRANCH)[, candidates]) (defaults 6 GB
#       and 4 cores per branch), prints "sub-cap=<n> local=0
#       (avail_gb=<n> nproc=<n>)" and journals
#       "burst: sub-cap=<n> (avail_gb=<n> nproc=<n>)" (AC7). A failed probe
#       exits 3 with "fallback: ...", never blocking the caller.
#
# Env overrides (offline testing only — never set in production):
#   BURST_LANE_HCLOUD_BIN, BURST_LANE_SSH_BIN, BURST_LANE_RSYNC_BIN,
#   BURST_LANE_STATE_DIR, BURST_LANE_JOURNAL, BURST_LANE_ENV_FILE,
#   BURST_LANE_NOW, BURST_LANE_PRD_DIR, BURST_LANE_COST_LEDGER,
#   BURST_LANE_REMOTE_ROOT, BURST_LANE_SERVER_NAME
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

STATE_DIR="${BURST_LANE_STATE_DIR:-$SKILL_DIR/state/burst-lane}"
STATE_FILE="$STATE_DIR/session.json"
COST_LEDGER="${BURST_LANE_COST_LEDGER:-$STATE_DIR/cost.jsonl}"
ENV_FILE="${BURST_LANE_ENV_FILE:-$HOME/.config/wm-burst/.env}"
JOURNAL="${BURST_LANE_JOURNAL:-$HOME/brain/journal/build/burst-lane.log}"
PRD_DIR="${BURST_LANE_PRD_DIR:-$HOME/Documents/PRDs}"

HCLOUD="${BURST_LANE_HCLOUD_BIN:-hcloud}"
SSH_BIN="${BURST_LANE_SSH_BIN:-ssh}"
RSYNC_BIN="${BURST_LANE_RSYNC_BIN:-rsync}"

SERVER_NAME="${BURST_LANE_SERVER_NAME:-wm-burst-lane}"
SERVER_TYPE="ccx53"
DEFAULT_LOCATION="nbg1"
DEFAULT_SNAPSHOT_ID="427125061"
DEFAULT_TTL_HOURS="6"
HARD_TTL_HOURS="12"
COST_PER_HOUR_EUR="0.47"
REMOTE_ROOT="${BURST_LANE_REMOTE_ROOT:-/root/build}"

die() { echo "burst-lane: $*" >&2; exit "${2:-1}"; }
usage() { echo "usage: burst-lane.sh {up|status|run|sync-back|down|watchdog|cost|sub-cap} ..." >&2; exit 2; }

now_epoch() { echo "${BURST_LANE_NOW:-$(date -u +%s)}"; }
now_iso()   { date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
journal_line() { mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true; printf '%s\n' "$1" >> "$JOURNAL"; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- config -------------------------------------------------------------
load_env() {
  SNAPSHOT_ID="$DEFAULT_SNAPSHOT_ID"
  LOCATION="$DEFAULT_LOCATION"
  SSH_KEY="$HOME/.ssh/id_ed25519"
  REMOTE_USER="root"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  SNAPSHOT_ID="${SNAPSHOT_ID:-$DEFAULT_SNAPSHOT_ID}"
  LOCATION="${BUILDER_LOC:-$LOCATION}"
}
load_env

# ---- state (flat JSON, jq if present else grep fallback — matches
# gate-burst.sh's convention so both scripts are readable the same way) ---
JQ="$(command -v jq || true)"

state_read() {  # $1 = key -> stdout value or empty
  [ -f "$STATE_FILE" ] || return 0
  if [ -n "$JQ" ]; then
    "$JQ" -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
  else
    grep -oE "\"$1\":\"?[^,\"}]*\"?" "$STATE_FILE" 2>/dev/null | head -n1 | sed -E 's/^[^:]*:"?([^",}]*)"?$/\1/'
  fi
}

state_write() {  # $1..$N = key=value pairs
  local tmp="$STATE_FILE.tmp.$$"
  {
    echo "{"
    local first=1 kv k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      [ "$first" -eq 1 ] || echo ","
      first=0
      case "$v" in
        true|false|''|*[!0-9.]*) printf '  "%s":"%s"' "$k" "$v" ;;
        *)                       printf '  "%s":%s' "$k" "$v" ;;
      esac
    done
    echo
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_clear() { rm -f "$STATE_FILE"; }
state_active() { [ -f "$STATE_FILE" ]; }

# ---- hcloud helpers -------------------------------------------------------
server_alive() {  # $1 = server id -> 0 if hcloud still sees it
  "$HCLOUD" server describe "$1" -o json >/dev/null 2>&1
}

# find_by_name <name> -> prints "id ip" on stdout, rc 0 if found else rc 1
find_by_name() {
  local out
  out="$("$HCLOUD" server describe "$1" -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d = d.get("server", d)
print(d.get("id",""), d.get("public_net",{}).get("ipv4",{}).get("ip",""))
' <<<"$out" 2>/dev/null
}

precondition() {  # stdout = message; rc 0 pass, 1 fail
  if ! command -v "$HCLOUD" >/dev/null 2>&1; then
    echo "fail: hcloud CLI not on PATH"; return 1
  fi
  if ! "$HCLOUD" server-type list >/dev/null 2>&1; then
    echo "fail: hcloud present but not authenticated (server-type list failed) — check HCLOUD_TOKEN"; return 1
  fi
  if [ -z "${SNAPSHOT_ID:-}" ]; then
    echo "fail: no SNAPSHOT_ID in $ENV_FILE (or its own default)"; return 1
  fi
  echo "ok: hcloud authenticated, snapshot=$SNAPSHOT_ID"; return 0
}

# ---- up -------------------------------------------------------------------
sandbox_probe() {  # $1 = ip -> echoes true|false
  if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" \
       'bwrap --unshare-user --unshare-pid --die-with-parent python3 -c "print(1)"' >/dev/null 2>&1; then
    echo true
  else
    echo false
  fi
}

cmd_up() {
  if state_active; then
    local id; id="$(state_read server_id)"
    if [ -n "$id" ] && server_alive "$id"; then
      echo "already-up: $id $(state_read ip)"
      exit 0
    fi
    # Tracked box vanished under us — clear stale state and re-check by name.
    state_clear
  fi

  # Adoption path: a session.json can be lost (crash, disk wipe) while the
  # server itself is still alive and billing — never double-create.
  local adopt; adopt="$(find_by_name "$SERVER_NAME" 2>/dev/null || true)"
  if [ -n "$adopt" ]; then
    local aid aip; aid="${adopt%% *}"; aip="${adopt##* }"
    local sbx; sbx="$(sandbox_probe "$aip")"
    state_write "server_id=$aid" "ip=$aip" "server_type=$SERVER_TYPE" \
      "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
      "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
      "teardown_scheduled=false" "teardown_epoch="
    journal_line "$(now_iso)  burst-lane  up  adopted  (server_id=$aid ip=$aip sandbox_ok=$sbx)"
    echo "already-up: $aid $aip (adopted)"
    exit 0
  fi

  local pre_out; pre_out="$(precondition)"; local pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=precondition-failed: $pre_out)"
    echo "fallback: precondition failed - $pre_out"
    exit 3
  fi

  local create_out
  if ! create_out="$("$HCLOUD" server create --name "$SERVER_NAME" --type "$SERVER_TYPE" \
        --location "$LOCATION" --image "$SNAPSHOT_ID" --ssh-key "${HCLOUD_SSH_KEY:-default}" -o json 2>&1)"; then
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=hcloud-server-create-failed: $create_out)"
    echo "fallback: hcloud server create failed - $create_out"
    exit 3
  fi
  local id ip
  read -r id ip <<<"$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d = d.get("server", d)
print(d.get("id",""), d.get("public_net",{}).get("ipv4",{}).get("ip",""))
' <<<"$create_out" 2>/dev/null)"
  if [ -z "${id:-}" ]; then
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=could-not-parse-server-id)"
    echo "fallback: could not parse server id from hcloud output"
    exit 3
  fi

  # Wait for ssh (bounded — never hang a tick forever).
  local tries=0
  while [ "$tries" -lt 30 ]; do
    if "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
         -i "$SSH_KEY" "$REMOTE_USER@$ip" true >/dev/null 2>&1; then
      break
    fi
    tries=$((tries + 1)); sleep 1
  done
  if [ "$tries" -ge 30 ]; then
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=ssh-unreachable server_id=$id ip=$ip)"
    echo "fallback: ssh never became reachable on $ip after 30s"
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    exit 3
  fi

  local sbx; sbx="$(sandbox_probe "$ip")"
  state_write "server_id=$id" "ip=$ip" "server_type=$SERVER_TYPE" \
    "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
    "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
    "teardown_scheduled=false" "teardown_epoch="
  journal_line "$(now_iso)  burst-lane  up  booted  (server_id=$id ip=$ip type=$SERVER_TYPE sandbox_ok=$sbx)"
  if [ "$sbx" = false ]; then
    journal_line "$(now_iso)  burst-lane  up  sandbox-unavailable  (server_id=$id — rust selection falls back to local cap for python-kind sandboxed tests this tick)"
  fi
  echo "up: $id $ip"
  exit 0
}

# ---- status -----------------------------------------------------------------
minutes_alive() {
  local boot_epoch; boot_epoch="$(state_read boot_epoch)"
  [ -n "$boot_epoch" ] || { echo 0; return; }
  echo $(( ( $(now_epoch) - boot_epoch ) / 60 ))
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  if ! state_active; then
    if [ "$json" -eq 1 ]; then echo '{"active":false}'; else echo "no active session"; fi
    exit 0
  fi
  local id ip alive ttl sbx
  id="$(state_read server_id)"; ip="$(state_read ip)"; alive="$(minutes_alive)"
  ttl="$(state_read ttl_hours)"; sbx="$(state_read sandbox_ok)"
  if [ "$json" -eq 1 ]; then
    printf '{"active":true,"server_id":"%s","ip":"%s","minutes_alive":%s,"ttl_hours":"%s","sandbox_ok":"%s"}\n' \
      "$id" "$ip" "$alive" "$ttl" "$sbx"
  else
    echo "active: $id ip=$ip alive=${alive}m ttl=${ttl}h sandbox_ok=$sbx"
  fi
  exit 0
}

# ---- shared incremental target/ pull (requirement 10) -----------------------
# A 95-binary test target should not copy whole on every run — both `run`'s
# own pull-back and the standalone `sync-back` subcommand go through this one
# `rsync --delete --stats` path so already-synced bytes on the box (warm from
# a prior run on the same worktree) don't get re-counted or re-copied.
pull_target_incremental() {  # $1=worktree $2=ip -> stdout: bytes transferred; rc 0/1
  local worktree="$1" ip="$2" remote_path stats
  remote_path="$REMOTE_ROOT/$(basename "$worktree")"
  if ! stats="$("$RSYNC_BIN" -az --delete --stats -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/target/" "$worktree/target/" 2>&1)"; then
    return 1
  fi
  local bytes; bytes="$(echo "$stats" | grep -oE 'Total transferred file size: [0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')"
  echo "${bytes:-0}"
  return 0
}

# ---- run --------------------------------------------------------------------
RUN_LOCK="$STATE_DIR/run.lock"

cmd_run() {
  local worktree="${1:-}"; shift || true
  [ "${1:-}" = "--" ] && shift
  [ -n "$worktree" ] && [ $# -ge 1 ] || { echo "usage: burst-lane.sh run <worktree> -- <cargo args...>" >&2; exit 2; }
  [ -d "$worktree" ] || die "no such worktree: $worktree" 2

  exec 201>"$RUN_LOCK"
  flock 201

  if ! state_active; then
    local up_out; up_out="$(cmd_up 2>&1)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      echo "$up_out"
      exit 3
    fi
  fi

  local id ip; id="$(state_read server_id)"; ip="$(state_read ip)"
  local remote_path="$REMOTE_ROOT/$(basename "$worktree")"

  if ! "$RSYNC_BIN" -az --delete --exclude target --exclude .git \
        -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$worktree/" "$REMOTE_USER@$ip:$remote_path/" >/tmp/burst-lane-rsync-up.$$.log 2>&1; then
    journal_line "$(now_iso)  burst-lane  run  fallback  (cause=rsync-up-failed worktree=$worktree)"
    echo "fallback: rsync to $ip failed (see /tmp/burst-lane-rsync-up.$$.log)"
    exit 3
  fi

  local remote_cmd="cd $remote_path && export CARGO_HOME=\${CARGO_HOME:-\$HOME/.cargo} RUSTC_WRAPPER=sccache SCCACHE_DIR=/root/.sccache; $*"
  local rc=0
  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "$remote_cmd" || rc=$?

  local bytes
  if ! bytes="$(pull_target_incremental "$worktree" "$ip")"; then
    journal_line "$(now_iso)  burst-lane  run  fallback  (cause=rsync-down-failed worktree=$worktree)"
    echo "fallback: rsync from $ip failed"
    exit 3
  fi

  local runs; runs="$(state_read runs_served)"; runs=$((runs + 1))
  state_write "server_id=$id" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$runs" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)"
  journal_line "$(now_iso)  burst-lane  run  routed  (server_id=$id worktree=$worktree runs_served=$runs exit=$rc bytes=$bytes)"
  exit "$rc"
}

# ---- sync-back ----------------------------------------------------------------
cmd_sync_back() {
  local worktree="${1:-}"
  [ -n "$worktree" ] && [ -d "$worktree" ] || { echo "usage: burst-lane.sh sync-back <worktree>" >&2; exit 2; }
  if ! state_active; then
    echo "fallback: no active session"
    exit 3
  fi
  local ip; ip="$(state_read ip)"
  local bytes
  if ! bytes="$(pull_target_incremental "$worktree" "$ip")"; then
    journal_line "$(now_iso)  burst-lane  sync-back  fallback  (cause=rsync-failed worktree=$worktree)"
    echo "fallback: rsync from $ip failed"
    exit 3
  fi
  journal_line "$(now_iso)  burst-lane  sync-back  ok  (worktree=$worktree bytes=$bytes)"
  echo "synced: bytes=$bytes"
  exit 0
}

# ---- rust-work-remains (drives down's keep/schedule/delete decision) --------
rust_work_remains() {
  local dir="$PRD_DIR/build-queue"
  [ -d "$dir" ] || return 1
  local f bt st
  for f in "$dir"/PRD-*.md; do
    [ -f "$f" ] || continue
    bt="$(grep -m1 -oE '^-[[:space:]]*build_target:[[:space:]]*[A-Za-z0-9_-]+' "$f" 2>/dev/null | sed -E 's/^-[[:space:]]*build_target:[[:space:]]*//')"
    case "$bt" in rust-cli|rust-lib|rust-extend) ;; *) continue ;; esac
    st="$(grep -m1 -oE '^-[[:space:]]*Status:[[:space:]]*[A-Za-z0-9_-]+' "$f" 2>/dev/null | sed -E 's/^-[[:space:]]*Status:[[:space:]]*//')"
    case "$st" in queued|building|in_progress) return 0 ;; esac
  done
  return 1
}

# ---- teardown (shared by down + watchdog) ------------------------------------
destroy_verify() {  # $1 = server id -> 0 on verified-gone, 1 on still-present after retries
  local id="$1" attempt
  for attempt in 1 2 3; do
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    sleep 1
    if ! server_alive "$id"; then return 0; fi
  done
  return 1
}

ledger_append() {  # $1=hours $2=eur
  printf '{"date":"%s","hours":%s,"eur":%s}\n' "$(now_iso)" "$1" "$2" >> "$COST_LEDGER"
}

# ---- down ---------------------------------------------------------------------
cmd_down() {
  local more_work=0
  [ "${1:-}" = "--more-work-queued" ] && more_work=1

  if ! state_active; then
    echo "no-active-session"
    exit 0
  fi

  local id boot_epoch; id="$(state_read server_id)"; boot_epoch="$(state_read boot_epoch)"

  if rust_work_remains || [ "$more_work" -eq 1 ]; then
    if [ "$(state_read teardown_scheduled)" = "true" ]; then
      state_write "server_id=$id" "ip=$(state_read ip)" "server_type=$(state_read server_type)" \
        "boot_ts=$(state_read boot_ts)" "boot_epoch=$boot_epoch" "ttl_hours=$(state_read ttl_hours)" \
        "hard_ttl_hours=$(state_read hard_ttl_hours)" "runs_served=$(state_read runs_served)" \
        "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=false" "teardown_epoch="
      journal_line "$(now_iso)  burst-lane  down  decision=keep  (server_id=$id cause=rust-work-arrived, schedule cancelled)"
    else
      journal_line "$(now_iso)  burst-lane  down  decision=keep  (server_id=$id)"
    fi
    echo "decision=keep"
    exit 0
  fi

  # No rust work remains anywhere in build-queue/. Schedule deletion for the
  # last two minutes of the current billed hour (counted from boot_epoch);
  # only actually delete once inside that window.
  local now hour_secs into_hour hour_start hour_end window_start
  now="$(now_epoch)"
  hour_secs=3600
  into_hour=$(( (now - boot_epoch) % hour_secs ))
  hour_start=$(( now - into_hour ))
  hour_end=$(( hour_start + hour_secs ))
  window_start=$(( hour_end - 120 ))

  if [ "$now" -ge "$window_start" ]; then
    local alive; alive="$(minutes_alive)"
    if destroy_verify "$id"; then
      local hrs; hrs="$(awk -v m="$alive" 'BEGIN{printf "%.4f", m/60.0}')"
      local eur; eur="$(awk -v h="$hrs" -v r="$COST_PER_HOUR_EUR" 'BEGIN{printf "%.4f", h*r}')"
      ledger_append "$hrs" "$eur"
      journal_line "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id minutes=$alive cost_eur=$eur)"
      state_clear
      echo "decision=deleted"
      exit 0
    fi
    journal_line "$(now_iso)  burst-lane  down  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
    echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
    exit 1
  fi

  state_write "server_id=$id" "ip=$(state_read ip)" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$boot_epoch" "ttl_hours=$(state_read ttl_hours)" \
    "hard_ttl_hours=$(state_read hard_ttl_hours)" "runs_served=$(state_read runs_served)" \
    "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=true" "teardown_epoch=$window_start"
  journal_line "$(now_iso)  burst-lane  down  decision=scheduled  (server_id=$id teardown_at=$(date -u -d "@$window_start" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$window_start"))"
  echo "decision=scheduled"
  exit 0
}

# ---- watchdog -------------------------------------------------------------------
# Safety-net TTL check, independent of down's rust-work logic — the backstop
# against a forgotten box. Intended to be invoked periodically (a systemd
# timer wiring it up is a follow-on step, not done in this pass).
cmd_watchdog() {
  if ! state_active; then
    echo "no-active-session"
    exit 0
  fi
  local id boot_epoch ttl_hours now age ttl_secs
  id="$(state_read server_id)"; boot_epoch="$(state_read boot_epoch)"
  ttl_hours="$(state_read ttl_hours)"; ttl_hours="${ttl_hours:-$DEFAULT_TTL_HOURS}"
  now="$(now_epoch)"; age=$(( now - boot_epoch ))
  ttl_secs=$(( ttl_hours * 3600 ))

  # Also honor a scheduled teardown whose window has arrived even if TTL
  # hasn't (down normally handles this, but a tick that never calls down
  # again after scheduling should not leak past its own window).
  local scheduled teardown_epoch
  scheduled="$(state_read teardown_scheduled)"; teardown_epoch="$(state_read teardown_epoch)"
  local due=0
  [ "$age" -ge "$ttl_secs" ] && due=1
  if [ "$scheduled" = "true" ] && [ -n "$teardown_epoch" ] && [ "$now" -ge "$teardown_epoch" ]; then due=1; fi

  if [ "$due" -eq 0 ]; then
    echo "ok: age=${age}s < ttl=${ttl_secs}s"
    exit 0
  fi

  local alive; alive="$(minutes_alive)"
  if destroy_verify "$id"; then
    local hrs eur
    hrs="$(awk -v m="$alive" 'BEGIN{printf "%.4f", m/60.0}')"
    eur="$(awk -v h="$hrs" -v r="$COST_PER_HOUR_EUR" 'BEGIN{printf "%.4f", h*r}')"
    ledger_append "$hrs" "$eur"
    journal_line "$(now_iso)  burst-lane  watchdog  teardown  (server_id=$id uptime=${alive}m cost_eur=$eur)"
    state_clear
    echo "watchdog teardown: $id (${alive}m)"
    exit 0
  fi
  journal_line "$(now_iso)  burst-lane  watchdog  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
  echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
  exit 1
}

# ---- sub-cap (requirement 7 formula) -----------------------------------------
# Probes the box's available memory and core count over ssh in one round
# trip. The `\$2`/`\$(...)` inside the single-quoted remote_cmd are deliberately
# unescaped from THIS script's perspective (single quotes suppress local
# expansion) so they evaluate on the remote shell, matching the pattern
# `run`'s own remote_cmd construction already uses.
probe_remote_capacity() {  # $1 = ip -> stdout "avail_gb nproc"; rc 1 on failure
  local ip="$1" out
  local remote_cmd='avail_kb=$(grep MemAvailable /proc/meminfo | awk "{print \$2}"); echo $((avail_kb/1024/1024)) $(nproc)'
  out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
        "$REMOTE_USER@$ip" "$remote_cmd" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  echo "$out"
}

cmd_sub_cap() {
  local candidates=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --candidates) candidates="${2:-0}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! state_active; then
    journal_line "$(now_iso)  burst-lane  sub-cap  no-session  (local=3, fallback rules apply)"
    echo "sub-cap=0 local=3 (no session — local cap applies)"
    exit 0
  fi

  local ip; ip="$(state_read ip)"
  local probe
  if ! probe="$(probe_remote_capacity "$ip")"; then
    journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=probe-failed server_id=$(state_read server_id))"
    echo "fallback: could not probe box capacity"
    exit 3
  fi
  local avail_gb nproc_n
  read -r avail_gb nproc_n <<<"$probe"
  case "$avail_gb" in ''|*[!0-9]*) journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac
  case "$nproc_n"  in ''|*[!0-9]*) journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac

  local gb_per="${BURST_GB_PER_BRANCH:-6}" cores_per="${BURST_CORES_PER_BRANCH:-4}"
  local by_mem=$(( avail_gb / gb_per )) by_cpu=$(( nproc_n / cores_per ))
  local subcap=$by_mem
  [ "$by_cpu" -lt "$subcap" ] && subcap=$by_cpu
  if [ "$candidates" -gt 0 ] && [ "$candidates" -lt "$subcap" ]; then subcap=$candidates; fi

  journal_line "$(now_iso)  burst-lane  sub-cap  computed  (burst: sub-cap=$subcap (avail_gb=$avail_gb nproc=$nproc_n) local=0)"
  echo "sub-cap=$subcap local=0 (avail_gb=$avail_gb nproc=$nproc_n)"
  exit 0
}

# ---- cost -------------------------------------------------------------------
cmd_cost() {
  [ "${1:-}" = "--today" ] || { echo "usage: burst-lane.sh cost --today" >&2; exit 2; }
  [ -f "$COST_LEDGER" ] || { echo "hours=0.00 eur=0.00"; exit 0; }
  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  python3 -c '
import json, sys
today, path = sys.argv[1], sys.argv[2]
hours = eur = 0.0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("date", "").startswith(today):
        hours += float(d.get("hours", 0))
        eur += float(d.get("eur", 0))
print(f"hours={hours:.2f} eur={eur:.2f}")
' "$today" "$COST_LEDGER"
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    up)        cmd_up "$@" ;;
    status)    cmd_status "$@" ;;
    run)       cmd_run "$@" ;;
    sync-back) cmd_sync_back "$@" ;;
    down)      cmd_down "$@" ;;
    watchdog)  cmd_watchdog "$@" ;;
    cost)      cmd_cost "$@" ;;
    sub-cap)   cmd_sub_cap "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
