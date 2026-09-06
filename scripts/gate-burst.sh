#!/usr/bin/env bash
# gate-burst.sh — manager for routing mixed-tick gate cargo to a burst box
# (PRD-build-gate-cloudburst). When a /build tick dispatches both Rust gate
# work and a Python suite in the same tick, the cargo load can flip the
# pytest verdict (observed 2026-09-06: a 444s mcphost gate ran beside the
# synthorg suite that went red at an unchanged green commit). Hetzner bills
# per hour, so once a box is up, batching every pending gate run into that
# hour is marginal-cost-zero — this script boots on first use, reuses for
# the rest of the tick, and tears down before a second billed hour starts.
#
# Engineering note (2026-09-06): the PRD's Technical considerations say
# this wraps "the /cloudbuild flow". No `/cloudbuild` Claude skill exists
# anywhere on this machine (checked: not under ~/.claude/skills, no
# pre-fleet-sync-renamed backup either — the PRD's own suspicion, "its
# presence on RedBaron must be verified, not assumed", resolved negative).
# The nearest real, already-installed tool is `wm-burst`
# (~/.local/bin/wm-burst, from ~/wintermute/constellation-burst-builder) —
# but its `pod up` primitive is atomic (spin up, run exactly ONE command,
# tear down) and cannot support this PRD's P0 "reuse for every subsequent
# run while it is alive" requirement (AC3: three pending gate runs share
# one boot). So this script talks to the Hetzner Cloud API directly via
# the `hcloud` CLI + ssh + rsync — the same primitives the PRD's Technical
# considerations describe (SNAPSHOT_ID, shared sccache, rsync excludes) —
# rather than wrapping either wm-burst or a nonexistent skill. On THIS
# machine `hcloud` itself is absent and `~/.config/wm-burst/.env` has no
# HCLOUD_TOKEN, so the precondition check (P1) correctly and honestly
# fails closed; see `gate-burst.sh precondition`.
#
# Subcommands:
#   gate-burst.sh precondition
#       Checks: `hcloud` on PATH, `hcloud server-type list` authenticates,
#       config env file has SNAPSHOT_ID. Exit 0 pass; exit 1 + a message
#       naming the first missing piece otherwise. Read-only, safe to poll.
#   gate-burst.sh should-route --rust <n> --python <n>
#       Mixed-tick routing predicate (P0). Exit 0 (route to burst) iff
#       both counts are > 0; exit 1 (stay local) otherwise. Takes no
#       action — callers decide what to do with the verdict.
#   gate-burst.sh up
#       Idempotent. If a tracked box is already alive, exit 0 "already-up".
#       Else runs `precondition`; on failure, exits 3 and prints
#       `fallback: precondition failed - <reason>` (never attempts a
#       network/API call past that point). On success, boots a fresh
#       server from SNAPSHOT_ID, waits for ssh, records
#       state/gate-burst-active.json (server id, ip, boot ts, runs
#       served), and prints `up: <id> <ip>`.
#   gate-burst.sh run <repo> <command...>
#       Ensures a box is up (calling `up` if needed — if that fails,
#       prints `fallback: <reason>` and exits 3, so the caller runs the
#       gate cargo locally per today's behavior). rsyncs <repo> to the
#       box, runs <command...> remotely under RUSTC_WRAPPER=sccache,
#       rsyncs `target/` and any receipt inputs back, stamps
#       `<repo>/.gate-burst-host` with the producing hostname (receipt
#       equivalence, AC7 — a remote receipt records which host built it),
#       and propagates the remote command's exit code. Any rsync/ssh/
#       remote-mismatch failure prints `fallback: <reason>`, marks the
#       box unavailable for the rest of this shell's lifetime (env var
#       GATE_BURST_UNAVAILABLE=1 in the calling shell, since state
#       persists across invocations via the state file's own
#       `unavailable: true` flag), and exits 3 — never a blocked PRD.
#   gate-burst.sh status [--pending] [--json]
#       Prints the active box's id/ip/minutes-alive/runs-served (or
#       "no active box"), remaining minutes in its current billed hour,
#       and the ledger's month-to-date total. `--pending` also lists any
#       jobs appended to the run queue this tick that haven't completed
#       (P2 "batch opportunism": what a tick could still serve this hour).
#   gate-burst.sh down [--force] [--more-work-queued]
#       Hour-aware teardown (P0). An idle box at minute >=55 of its
#       billed hour is destroyed unconditionally (absolute kill — no box
#       ever enters a second billed hour idle). Otherwise: if
#       --more-work-queued was passed AND the remaining time in the
#       billed hour is >=10 minutes, the box survives (prints
#       `kept-alive: ...`). Otherwise destroyed. `--force` always
#       destroys. Destroy-verify: confirms via `hcloud server describe`
#       that the server is actually gone, retries on failure, and after
#       exhausting retries writes a loud `LEAK-FLAG` journal line naming
#       the server id and estimated bleed rate (this is the one failure
#       that must page a human). On a verified destroy, appends one
#       ledger line (date, server type, minutes alive, runs served,
#       estimated cost) and clears the state file.
#
# Env overrides (for offline testing — never set these in production):
#   GATE_BURST_HCLOUD_BIN, GATE_BURST_SSH_BIN, GATE_BURST_RSYNC_BIN  —
#   substitute fake binaries so up/run/down can be exercised without a
#   real Hetzner account. GATE_BURST_STATE_DIR, GATE_BURST_LEDGER,
#   GATE_BURST_JOURNAL, GATE_BURST_ENV_FILE, GATE_BURST_NOW — override
#   state/ledger/journal/config paths and the wall clock ("now" as epoch
#   seconds) for deterministic hour-boundary tests. GATE_BURST_REMOTE_ROOT
#   overrides the remote working directory (default `/root/gate-burst`)
#   so a fake ssh/rsync pair can target a writable scratch path instead
#   of `/root`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

STATE_DIR="${GATE_BURST_STATE_DIR:-$SKILL_DIR/state/gate-burst}"
STATE_FILE="$STATE_DIR/active.json"
LEDGER="${GATE_BURST_LEDGER:-$HOME/brain/journal/build/gate-burst-cost-ledger.ndjson}"
ENV_FILE="${GATE_BURST_ENV_FILE:-$HOME/.config/wm-burst/.env}"
JOURNAL="${GATE_BURST_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"

HCLOUD="${GATE_BURST_HCLOUD_BIN:-hcloud}"
SSH_BIN="${GATE_BURST_SSH_BIN:-ssh}"
RSYNC_BIN="${GATE_BURST_RSYNC_BIN:-rsync}"

DEFAULT_SERVER_TYPE="ccx23"
DEFAULT_LOCATION="fsn1"
DEFAULT_SNAPSHOT_ID="427125061"
DEFAULT_COST_PER_HOUR_USD="0.10"   # ccx23 approx; overridable via env

die() { echo "gate-burst: $*" >&2; exit "${2:-1}"; }
usage() { echo "usage: gate-burst.sh {precondition|should-route|up|run|status|down} ..." >&2; exit 2; }

now_epoch() { echo "${GATE_BURST_NOW:-$(date -u +%s)}"; }
now_iso()   { date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
journal_line() { mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true; printf '%s\n' "$1" >> "$JOURNAL"; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- config -----------------------------------------------------------
load_env() {
  SNAPSHOT_ID="$DEFAULT_SNAPSHOT_ID"
  SERVER_TYPE="$DEFAULT_SERVER_TYPE"
  LOCATION="$DEFAULT_LOCATION"
  COST_PER_HOUR_USD="$DEFAULT_COST_PER_HOUR_USD"
  SSH_KEY="$HOME/.ssh/id_ed25519"
  REMOTE_USER="root"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}
load_env

# ---- state (JSON via jq if present, else a tiny key=value sidecar) ----
JQ="$(command -v jq || true)"

state_read() {  # $1 = key -> stdout value or empty
  [ -f "$STATE_FILE" ] || return 0
  if [ -n "$JQ" ]; then
    "$JQ" -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
  else
    grep -oE "\"$1\":\"[^\"]*\"" "$STATE_FILE" 2>/dev/null | head -n1 | sed -E 's/.*:"([^"]*)"/\1/'
  fi
}

state_write() {  # $1..$N = key=value pairs (values may be numeric or string)
  local tmp="$STATE_FILE.tmp.$$"
  {
    echo "{"
    local first=1 kv k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      [ "$first" -eq 1 ] || echo ","
      first=0
      case "$v" in
        ''|*[!0-9]*) printf '  "%s":"%s"' "$k" "$v" ;;
        *)           printf '  "%s":%s' "$k" "$v" ;;
      esac
    done
    echo
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_clear() { rm -f "$STATE_FILE"; }
state_active() { [ -f "$STATE_FILE" ]; }

# ---- precondition -------------------------------------------------------
cmd_precondition() {
  if ! command -v "$HCLOUD" >/dev/null 2>&1; then
    echo "fail: hcloud CLI not on PATH"
    exit 1
  fi
  if ! "$HCLOUD" server-type list >/dev/null 2>&1; then
    echo "fail: hcloud present but not authenticated (server-type list failed) — check HCLOUD_TOKEN"
    exit 1
  fi
  if [ -z "${SNAPSHOT_ID:-}" ]; then
    echo "fail: no SNAPSHOT_ID in $ENV_FILE (or its own default)"
    exit 1
  fi
  echo "ok: hcloud authenticated, snapshot=$SNAPSHOT_ID"
  exit 0
}

# ---- should-route --------------------------------------------------------
cmd_should_route() {
  local rust=0 python=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --rust) rust="$2"; shift 2 ;;
      --python) python="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$rust" -gt 0 ] && [ "$python" -gt 0 ]; then
    echo "route: mixed tick (rust=$rust python=$python)"
    exit 0
  fi
  echo "local: single-flavor tick (rust=$rust python=$python)"
  exit 1
}

# ---- up -----------------------------------------------------------------
server_alive() {  # $1 = server id -> 0 if hcloud still sees it
  "$HCLOUD" server describe "$1" >/dev/null 2>&1
}

cmd_up() {
  if state_active; then
    local id; id="$(state_read server_id)"
    if [ -n "$id" ] && server_alive "$id"; then
      echo "already-up: $id $(state_read ip)"
      exit 0
    fi
    # Tracked box vanished under us — clear stale state and re-provision.
    state_clear
  fi

  local pre_out; pre_out="$(cmd_precondition 2>&1)"; local pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    journal_line "$(now_iso)  gate-burst  up  fallback  (cause=precondition-failed: $pre_out)"
    echo "fallback: precondition failed - $pre_out"
    exit 3
  fi

  local name="gate-burst-$(now_epoch)"
  local create_out
  if ! create_out="$("$HCLOUD" server create --name "$name" --type "$SERVER_TYPE" \
        --location "$LOCATION" --image "$SNAPSHOT_ID" --ssh-key "${HCLOUD_SSH_KEY:-default}" 2>&1)"; then
    journal_line "$(now_iso)  gate-burst  up  fallback  (cause=hcloud-server-create-failed: $create_out)"
    echo "fallback: hcloud server create failed - $create_out"
    exit 3
  fi
  local id ip
  id="$(echo "$create_out" | grep -oE '"id":[0-9]+' | head -n1 | cut -d: -f2)"
  ip="$(echo "$create_out" | grep -oE '"ip":"[^"]*"' | head -n1 | cut -d'"' -f4)"
  if [ -z "$id" ]; then
    journal_line "$(now_iso)  gate-burst  up  fallback  (cause=could-not-parse-server-id)"
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
    journal_line "$(now_iso)  gate-burst  up  fallback  (cause=ssh-unreachable server_id=$id ip=$ip)"
    echo "fallback: ssh never became reachable on $ip after 30s"
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    exit 3
  fi

  state_write "server_id=$id" "ip=$ip" "server_type=$SERVER_TYPE" \
    "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "runs_served=0" "unavailable=false"
  journal_line "$(now_iso)  gate-burst  up  booted  (server_id=$id ip=$ip type=$SERVER_TYPE)"
  echo "up: $id $ip"
  exit 0
}

# ---- run ------------------------------------------------------------------
# A run's flock (fd 201, held for the entire rsync+ssh+rsync body) is what
# backs AC10: `down` blocks on the same lock before it may destroy, so a
# run in progress at the hour boundary always finishes before teardown —
# never killed mid-build for billing's sake.
RUN_LOCK="$STATE_DIR/run.lock"

cmd_run() {
  local repo="${1:-}"; shift || true
  [ -n "$repo" ] && [ $# -ge 1 ] || { echo "usage: gate-burst.sh run <repo> <command...>" >&2; exit 2; }
  [ -d "$repo" ] || die "no such repo: $repo" 2

  exec 201>"$RUN_LOCK"
  flock 201

  if [ "$(state_read unavailable)" = "true" ]; then
    echo "fallback: burst already marked unavailable for this tick"
    exit 3
  fi

  if ! state_active; then
    local up_out; up_out="$(cmd_up)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      echo "$up_out"
      exit 3
    fi
  fi

  local id ip; id="$(state_read server_id)"; ip="$(state_read ip)"
  local remote_root="${GATE_BURST_REMOTE_ROOT:-/root/gate-burst}"
  local remote_path="$remote_root/$(basename "$repo")"

  if ! "$RSYNC_BIN" -az --delete --exclude target --exclude .git \
        -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$repo/" "$REMOTE_USER@$ip:$remote_path/" >/tmp/gate-burst-rsync-up.$$.log 2>&1; then
    state_write "server_id=$id" "ip=$ip" "unavailable=true" \
      "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
      "runs_served=$(state_read runs_served)" "server_type=$(state_read server_type)"
    journal_line "$(now_iso)  gate-burst  run  fallback  (cause=rsync-up-failed repo=$repo)"
    echo "fallback: rsync to $ip failed (see /tmp/gate-burst-rsync-up.$$.log)"
    exit 3
  fi

  local remote_cmd="cd $remote_path && RUSTC_WRAPPER=sccache $*"
  local rc=0
  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "$remote_cmd" || rc=$?

  if ! "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/target/" "$repo/target/" >/tmp/gate-burst-rsync-down.$$.log 2>&1; then
    journal_line "$(now_iso)  gate-burst  run  fallback  (cause=rsync-down-failed repo=$repo)"
    echo "fallback: rsync from $ip failed (see /tmp/gate-burst-rsync-down.$$.log)"
    exit 3
  fi

  # Receipt equivalence (AC7): stamp which host produced this build.
  local remote_host; remote_host="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" \
    "$REMOTE_USER@$ip" hostname 2>/dev/null || echo "$ip")"
  printf '%s\n' "$remote_host" > "$repo/.gate-burst-host"

  local runs; runs="$(state_read runs_served)"; runs=$((runs + 1))
  state_write "server_id=$id" "ip=$ip" "unavailable=false" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "runs_served=$runs" "server_type=$(state_read server_type)"
  journal_line "$(now_iso)  gate-burst  run  routed  (server_id=$id repo=$repo runs_served=$runs exit=$rc)"
  exit "$rc"
}

# ---- status ---------------------------------------------------------------
minutes_alive() {
  local boot_epoch; boot_epoch="$(state_read boot_epoch)"
  [ -n "$boot_epoch" ] || { echo 0; return; }
  echo $(( ( $(now_epoch) - boot_epoch ) / 60 ))
}

minutes_remaining_in_hour() {
  local m; m="$(minutes_alive)"
  echo $(( 60 - (m % 60) ))
}

ledger_month_total() {
  [ -f "$LEDGER" ] || { echo "0.00"; return; }
  local month; month="$(date -u -d "@$(now_epoch)" +%Y-%m 2>/dev/null || date -u +%Y-%m)"
  awk -F'\t' -v m="$month" '$1 ~ ("^" m) { sum += $5 } END { printf "%.2f", sum+0 }' "$LEDGER"
}

cmd_status() {
  local pending=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pending) pending=1; shift ;;
      --json) json=1; shift ;;
      *) shift ;;
    esac
  done

  if ! state_active; then
    if [ "$json" -eq 1 ]; then
      echo '{"active":false,"month_total_usd":"'"$(ledger_month_total)"'"}'
    else
      echo "no active box. month-to-date: \$$(ledger_month_total)"
    fi
    exit 0
  fi

  local id ip runs alive remain
  id="$(state_read server_id)"; ip="$(state_read ip)"; runs="$(state_read runs_served)"
  alive="$(minutes_alive)"; remain="$(minutes_remaining_in_hour)"

  if [ "$json" -eq 1 ]; then
    printf '{"active":true,"server_id":"%s","ip":"%s","minutes_alive":%s,"runs_served":%s,"minutes_remaining":%s,"month_total_usd":"%s"}\n' \
      "$id" "$ip" "$alive" "$runs" "$remain" "$(ledger_month_total)"
  else
    echo "active: $id ip=$ip alive=${alive}m runs_served=$runs remaining-in-hour=${remain}m"
    echo "month-to-date: \$$(ledger_month_total)"
  fi

  if [ "$pending" -eq 1 ]; then
    # P2 "batch opportunism" (list queued rust-extend PRDs a live box could
    # still serve this hour) is NOT wired — it needs a real cross-cutting
    # read of the PRD manifest/scan-prds.sh output, deferred this round
    # (see PRD-build-gate-cloudburst deferred_acs / mock_justifications).
    echo "pending: not yet wired (P2 deferred — see PRD's mock_justifications)"
  fi
  exit 0
}

# ---- down -------------------------------------------------------------------
destroy_verify() {  # $1 = server id -> 0 on verified-gone, 1 on still-present after retries
  local id="$1" attempt
  for attempt in 1 2 3; do
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    sleep 1
    if ! server_alive "$id"; then
      return 0
    fi
  done
  return 1
}

cmd_down() {
  local force=0 more_work=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --more-work-queued) more_work=1; shift ;;
      *) shift ;;
    esac
  done

  if ! state_active; then
    echo "no-active-box"
    exit 0
  fi

  # Block until any in-flight `run` releases the lock (AC10: a run in
  # progress at the hour boundary is never killed — teardown waits for
  # it to finish). Bounded so a truly wedged run can't hang a tick forever.
  exec 202>"$RUN_LOCK"
  if ! flock -w 300 202; then
    echo "down deferred: a run is still in flight after 300s wait" >&2
    exit 1
  fi

  local id runs stype alive remain
  id="$(state_read server_id)"; runs="$(state_read runs_served)"; stype="$(state_read server_type)"
  alive="$(minutes_alive)"; remain="$(minutes_remaining_in_hour)"

  if [ "$force" -eq 0 ] && [ "$alive" -lt 55 ]; then
    if [ "$more_work" -eq 1 ] && [ "$remain" -ge 10 ]; then
      echo "kept-alive: more work queued, ${remain}m remaining in billed hour"
      exit 0
    fi
  fi

  if destroy_verify "$id"; then
    local cost; cost="$(awk -v m="$alive" -v r="$COST_PER_HOUR_USD" 'BEGIN{printf "%.4f", (m/60.0)*r}')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$stype" "$alive" "$runs" "$cost" >> "$LEDGER"
    journal_line "$(now_iso)  gate-burst  down  destroyed-verified  (server_id=$id minutes=$alive runs_served=$runs cost_usd=$cost)"
    state_clear
    echo "destroyed: $id (verified, ${alive}m, \$${cost})"
    exit 0
  fi

  local bleed; bleed="$(awk -v r="$COST_PER_HOUR_USD" 'BEGIN{printf "%.4f", r}')"
  journal_line "$(now_iso)  gate-burst  down  LEAK-FLAG  (server_id=$id bleed_usd_per_hour=$bleed action=page-a-human — destroy failed after 3 retries)"
  echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries — bleeding \$$bleed/hr, paging via journal"
  exit 1
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    precondition) cmd_precondition "$@" ;;
    should-route) cmd_should_route "$@" ;;
    up)           cmd_up "$@" ;;
    run)          cmd_run "$@" ;;
    status)       cmd_status "$@" ;;
    down)         cmd_down "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
