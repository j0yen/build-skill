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
# per-commit. Requirement 7's FORMULA lives here: `sub-cap` probes the
# box's MemAvailable/nproc over ssh and prints/journals
# `burst: sub-cap=<n> (avail_gb=<n> nproc=<n>)` (or the no-session local=3
# fallback line). That call is now ALSO wired into selection:
# `lane-claim.sh`'s `target-busy` calls it (via `effective_subcap()`) for
# any build_into path that looks like a rust crate, so a live session's
# box-computed sub-cap governs same-target fan-out there instead of the
# local SAME_LANE_SUBCAP — see lane-claim.sh's header and SKILL.md's
# "Burst-lane PATH" section. The uv/python leg (req 12) is wired: SKILL.md's
# "Burst-lane PATH, python branches" section, `burst-lane-bin/uv`, `up`'s uv
# install on the box, and `run`'s pull-back branching on the routed command
# (uv -> `pull_pybuilder_incremental` for `.pybuilder/`, everything else ->
# `pull_target_incremental` for `target/` as before — a python run has no
# Cargo target-dir to resolve). Requirement 13 (cost ledger "PRDs served"
# attribution) is also wired: `run` appends the caller's
# `BURST_LANE_PRD_SLUG` (or the worktree's own basename, falling back)
# deduped to `state/burst-lane/prds_served`, `down`/`watchdog` read it into
# each `cost.jsonl` row's `prds` array at teardown and reset it for the
# next session, and `cost --today` unions and prints the slugs served
# across today's rows.
#
# PRD-build-gate-on-casper requirement 1 (gate toolchain provisioning) is
# also wired: `up` (both the fresh-create and adoption branches) calls
# `provision_gate_tools()` right after `box_bootstrap`/the sandbox probe —
# it installs autobuilder/jq/gh/mold/cargo-deny/cargo-nextest/uv/claude on
# the box if `command -v` doesn't already find them, rsyncs a read-only
# mirror of build-skill's own scripts/ and rustbuild's scripts/+prompts/,
# and records `gate_ready`/`gate_tools_missing` into session state (see
# `GATE_TOOLS_LIST` near the top). `verify` gained a matching `gate-tools`
# check that fails closed, naming the first missing tool. The remaining
# gate-on-casper requirements (parity, the `gate` subcommand itself,
# credentials, concurrency slots, teardown safety) are NOT yet wired — see
# git log / the PRD's own requirement list for what's landed so far.
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
#       Prints active session id/ip/minutes-alive/ttl/sandbox_ok/concurrent
#       (live run slots held/cap — PRD-build-burst-parallel-runs AC6), or
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
#       Sums state/burst-lane/cost.jsonl rows for today's UTC date and
#       prints the union of PRD slugs those rows' sessions served (req 13).
#   burst-lane.sh cost --by-prd [--today|--session <id>]
#       PRD-build-cost-attribution: table of slug, runs, box-minutes, eur
#       (sorted by eur desc) plus a totals row, sourced from cost.jsonl's
#       `kind:"slug"` rows (see below). No flag aggregates all history;
#       `--today` filters to today's UTC date; `--session <id>` to one
#       session_id (usually a server_id).
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
#   burst-lane.sh reap
#       PRD-build-burst-remote-disk-guard requirement 5: lists $REMOTE_ROOT's
#       immediate children, deletes any whose local worktree is gone (a
#       dirty marker or a held per-worktree lock protects a dir instead),
#       and prints "reaped_dirs=<n> reaped_bytes=<n>". Also called
#       automatically by `down` and `watchdog` before their own
#       keep/delete decision (requirement 6) — a reap trouble is journaled,
#       never fatal.
#   burst-lane.sh route-check [--repo <path>]
#       PRD-build-gate-cargo-route-attest: attests whether a `cargo` call
#       under the CURRENT $PATH would actually reach the burst-lane shim or
#       silently run local. Prints "route: intended=<burst|local>
#       resolved=<path> shim=<path> state=<clean|mismatch|could-not-check>
#       [cause=<c>]", emits the `gate-cargo-route` three-state probe, and —
#       on mismatch — appends a synthetic local/shim-not-first line to
#       $BURST_ROUTE_LOG (if set) so a downstream route-log scan sees the
#       failure even when the shim itself never ran to log it. Called by
#       extend-gate.sh at gate start; see that script's own header.
#
# Cost attribution (PRD-build-cost-attribution, 2026-09-10): every routed
# `run` now also appends a row to state/burst-lane/attribution.jsonl —
# {date, session_id, slug, wall_seconds, sync_s, bytes, worktree} — under
# the same RUN_LOCK `run` already holds. `slug` is $BURST_LANE_PRD_SLUG when
# the caller exported one (PRD-build-gate-cargo-route-attest requirement 6 —
# a gate dispatch sets this to "gate-<repo>" since its main checkout is
# never a <repo>-<slug> worktree attribution_slug_for() could otherwise
# guess from), else attribution_slug_for() (worktree basename convention:
# <repo>-<slug> under build-worktrees, the shared checkout itself ->
# "shared-<repo>", a gate-burst/this-skill's-own AC-fixture path ->
# "selftest", else "unattributed" — never dropped). At teardown (`down`'s
# delete path and
# `watchdog`'s), prorate_attribution() sums those rows (plus any orphaned
# rows left by a crashed prior session — journaled by name, not silently
# folded in) by slug, prorates the session's cost_eur by each slug's share
# of total attributed wall-seconds, and appends `kind:"slug"` rows to
# cost.jsonl beside the existing (unchanged-shape) session-total row.
# `cost --by-prd` reads those rows back into a table. `down` also runs a
# cursor-guarded once-per-day rollup line into the tick journal
# (~/brain/journal/build/<date>.md, NOT this script's own burst-lane.log).
#
# Env overrides (offline testing only — never set in production):
#   BURST_LANE_HCLOUD_BIN, BURST_LANE_SSH_BIN, BURST_LANE_RSYNC_BIN,
#   BURST_LANE_STATE_DIR, BURST_LANE_JOURNAL, BURST_LANE_ENV_FILE,
#   BURST_LANE_NOW, BURST_LANE_PRD_DIR, BURST_LANE_COST_LEDGER,
#   BURST_LANE_REMOTE_ROOT, BURST_LANE_SERVER_NAME, BURST_LANE_ATTR_LEDGER,
#   BURST_LANE_REPOS_DIR, BURST_LANE_TICK_JOURNAL_DIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

STATE_DIR="${BURST_LANE_STATE_DIR:-$SKILL_DIR/state/burst-lane}"
STATE_FILE="$STATE_DIR/session.json"
COST_LEDGER="${BURST_LANE_COST_LEDGER:-$STATE_DIR/cost.jsonl}"
# Requirement 13: which PRD slugs this session served, one per line,
# deduped. Reset on a fresh boot/adopt (alongside runs_served=0), appended
# to (deduped) by every routed `run`, read into the cost-ledger row at
# teardown, then cleared with the rest of the session state.
SERVED_FILE="$STATE_DIR/prds_served"
ENV_FILE="${BURST_LANE_ENV_FILE:-$HOME/.config/wm-burst/.env}"
JOURNAL="${BURST_LANE_JOURNAL:-$HOME/brain/journal/build/burst-lane.log}"
PRD_DIR="${BURST_LANE_PRD_DIR:-$HOME/Documents/PRDs}"
# PRD-build-cost-attribution: per-run attribution ledger (requirement 1),
# the known-repo root used to split a worktree basename into <repo>/<slug>
# (attribution_slug_for below), the once-per-day rollup cursor (requirement
# 4), and the tick journal directory that rollup line lands in — distinct
# from $JOURNAL above, which is this script's own flat log.
ATTR_LEDGER="${BURST_LANE_ATTR_LEDGER:-$STATE_DIR/attribution.jsonl}"
# PRD-build-burst-pull-on-demand: lazy-pull state. DIRTY_DIR holds one
# marker per worktree (keyed like remote_path_for()'s sha1 scheme) recording
# that a completed remote `run` left target/ (or .pybuilder/) ahead of the
# local worktree; PULLSZ_DIR remembers the last ACTUAL pull's byte count per
# worktree (survives marker clears) so a skipped pull's telemetry can still
# print an `estimate: true` bytes_saved figure instead of a bare zero.
DIRTY_DIR="$STATE_DIR/dirty"
PULLSZ_DIR="$STATE_DIR/pull-sizes"
ATTR_REPOS_DIR="${BURST_LANE_REPOS_DIR:-$HOME/wintermute}"
ROLLUP_CURSOR="$STATE_DIR/.rollup-cursor"
TICK_JOURNAL_DIR="${BURST_LANE_TICK_JOURNAL_DIR:-$HOME/brain/journal/build}"
# PRD-build-gate-on-casper requirement 1: gate toolchain provisioning. The
# 8 versioned CLI tools `up` provisions if absent; the two script mirrors
# (build-skill's own scripts/, rustbuild's scripts/+prompts/) are synced
# read-only alongside them but aren't "versioned" the same way. Overridable
# so offline tests never touch the real ~/.cargo/bin or ~/.claude/skills.
GATE_TOOLS_LIST="autobuilder jq gh mold cargo-deny cargo-nextest uv claude"
GATE_TOOLS_STATE_FILE="$STATE_DIR/gate-tools.json"
GATE_TOOLS_BUILD_SCRIPTS_SRC="${BURST_LANE_GATE_BUILD_SCRIPTS:-$HOME/.claude/skills/build/scripts}"
GATE_TOOLS_RUSTBUILD_SCRIPTS_SRC="${BURST_LANE_GATE_RUSTBUILD_SCRIPTS:-$HOME/.claude/skills/rustbuild/scripts}"
GATE_TOOLS_RUSTBUILD_PROMPTS_SRC="${BURST_LANE_GATE_RUSTBUILD_PROMPTS:-$HOME/.claude/skills/rustbuild/prompts}"
GATE_TOOLS_AUTOBUILDER_BIN="${BURST_LANE_AUTOBUILDER_BIN:-$HOME/.cargo/bin/autobuilder}"
# Absolute (no "~") on purpose — the fake rsync fixture only string-strips a
# "user@host:" prefix, it never runs a remote shell to expand a tilde, so a
# literal "~/.cargo/bin" destination would resolve to a relative "~" dir
# under whatever the test's cwd happens to be instead of a scoped path.
# Overridable so the offline selftest can point this at a tmpdir instead of
# the production default (which matches cmd_verify's own hardcoded
# /root/.cargo/bin PATH entry — this whole lane assumes REMOTE_USER=root).
GATE_TOOLS_REMOTE_BIN_DIR="${BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR:-/root/.cargo/bin}"

HCLOUD="${BURST_LANE_HCLOUD_BIN:-hcloud}"
SSH_BIN="${BURST_LANE_SSH_BIN:-ssh}"
RSYNC_BIN="${BURST_LANE_RSYNC_BIN:-rsync}"

# Three-state retrofit (PRD-build-three-state-probes): fail-open sourcing so
# an unshipped/missing library never breaks a burst-lane invocation.
if [ -r "$HERE/probe-result.sh" ]; then
  # shellcheck source=probe-result.sh
  source "$HERE/probe-result.sh"
else
  probe_emit() { :; }
fi

SERVER_NAME="${BURST_LANE_SERVER_NAME:-wm-burst-lane}"
SERVER_TYPE="${BURST_SERVER_TYPE:-ccx53}"
DEFAULT_LOCATION="nbg1"
DEFAULT_SNAPSHOT_ID="427125061"
DEFAULT_TTL_HOURS="6"
HARD_TTL_HOURS="12"
COST_PER_HOUR_EUR="0.47"
REMOTE_ROOT="${BURST_LANE_REMOTE_ROOT:-/root/build}"

die() { echo "burst-lane: $*" >&2; exit "${2:-1}"; }
usage() { echo "usage: burst-lane.sh {up|status|run|sync-back|pull|ensure-fresh|down|watchdog|cost|sub-cap|verify|reap|route-check|parity|gate} ..." >&2; exit 2; }

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
  # BURST_SERVER_TYPE from the env file must win over the pre-source default
  # (SERVER_TYPE is assigned before load_env runs).
  SERVER_TYPE="${BURST_SERVER_TYPE:-$SERVER_TYPE}"
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
        *.*.*)                   printf '  "%s":"%s"' "$k" "$v" ;;
        *)                       printf '  "%s":%s' "$k" "$v" ;;
      esac
    done
    echo
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_clear() { rm -f "$STATE_FILE" "$SERVED_FILE"; }
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
box_bootstrap() {  # $1 = ip — make a snapshot box ready (idempotent, ~1s when already done)
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
    mkdir -p $REMOTE_ROOT
    sysctl -qw kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    command -v bwrap >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq bubblewrap; } >/dev/null 2>&1
    command -v python3 >/dev/null 2>&1 || apt-get install -y -qq python3-minimal python3 >/dev/null 2>&1
    command -v uv >/dev/null 2>&1 || [ -x /root/.local/bin/uv ] || (curl -LsSf https://astral.sh/uv/install.sh | sh) >/dev/null 2>&1
    true" 2>/dev/null || true
}

sandbox_probe() {  # $1 = ip -> echoes true|false
  if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" \
       'bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-pid --die-with-parent python3 -c "print(1)"' >/dev/null 2>&1; then
    echo true
  else
    echo false
  fi
}

# ---- gate toolchain provisioning (PRD-build-gate-on-casper requirement 1) --
# `up` calls provision_gate_tools() after box_bootstrap so a remote gate has
# everywhere it needs before extend-gate.sh ever runs there: autobuilder
# (copied from THIS host's ~/.cargo/bin, not apt/cargo-installed — it has no
# published crate), jq/gh/mold/cargo-deny/cargo-nextest/uv/claude (installed
# on the box if `command -v` doesn't find them), and the build-skill +
# rustbuild script/prompt trees (rsynced read-only — the box runs
# extend-gate.sh against its OWN copy, never writes back into it). The probe
# command is marked with a `# gate-tools-probe` comment line and each
# install command with `# gate-tools-install <tool>` SPECIFICALLY so the
# offline fake-ssh fixture (tests/fixtures/burst-lane-fake/ssh) can
# intercept them deterministically — see that fixture's own header for the
# FAKE_SSH_GATE_TOOLS_MISSING / FAKE_GATE_TOOLS_STATE knobs — instead of a
# real box's bash actually needing to parse a comment (it doesn't; comments
# are just inert there, the real install shell below the marker runs as
# normal).
gate_tools_probe() {  # $1=ip -> stdout: one "tool=version|MISSING" line per tool
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
# gate-tools-probe
for t in $GATE_TOOLS_LIST; do
  if command -v \"\$t\" >/dev/null 2>&1; then
    v=\"\$(\"\$t\" --version 2>/dev/null | head -n1)\"
    printf '%s=%s\n' \"\$t\" \"\${v:-unknown}\"
  else
    printf '%s=MISSING\n' \"\$t\"
  fi
done" 2>/dev/null
}

gate_tools_install_cmd() {  # $1=tool (never "autobuilder" — that's a push, see below) -> stdout: remote command
  local tool="$1"
  case "$tool" in
    jq)
      printf '%s\napt-get update -qq && apt-get install -y -qq jq\n' "# gate-tools-install $tool" ;;
    gh)
      printf '%s\n%s\n' "# gate-tools-install $tool" \
        "(curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && apt-get update -qq && apt-get install -y -qq gh)" ;;
    mold)
      printf '%s\napt-get update -qq && apt-get install -y -qq mold\n' "# gate-tools-install $tool" ;;
    cargo-deny)
      printf '%s\nexport PATH=/root/.cargo/bin:\$PATH; cargo install --locked cargo-deny\n' "# gate-tools-install $tool" ;;
    cargo-nextest)
      printf '%s\nexport PATH=/root/.cargo/bin:\$PATH; cargo install --locked cargo-nextest\n' "# gate-tools-install $tool" ;;
    uv)
      printf '%s\ncurl -LsSf https://astral.sh/uv/install.sh | sh\n' "# gate-tools-install $tool" ;;
    claude)
      printf '%s\ncurl -fsSL https://claude.ai/install.sh | bash\n' "# gate-tools-install $tool" ;;
    *)
      printf '%s\ntrue\n' "# gate-tools-install $tool" ;;
  esac
}

# Read-only mirror of the two script trees a remote extend-gate.sh needs
# (build-skill's own scripts/, rustbuild's scripts/+prompts/) — best-effort,
# never fatal (a missing local source dir is skipped, not an error: some
# hosts running this script don't have rustbuild installed at all).
sync_gate_tools_scripts() {  # $1=ip
  local ip="$1" src dst
  for pair in \
    "$GATE_TOOLS_BUILD_SCRIPTS_SRC:$REMOTE_ROOT/.gate-tools/build-scripts" \
    "$GATE_TOOLS_RUSTBUILD_SCRIPTS_SRC:$REMOTE_ROOT/.gate-tools/rustbuild-scripts" \
    "$GATE_TOOLS_RUSTBUILD_PROMPTS_SRC:$REMOTE_ROOT/.gate-tools/rustbuild-prompts"
  do
    src="${pair%%:*}"; dst="${pair#*:}"
    [ -d "$src" ] || continue
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" "mkdir -p '$dst'" 2>/dev/null || true
    "$RSYNC_BIN" -az --delete -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
      "$src/" "$REMOTE_USER@$ip:$dst/" >/dev/null 2>&1 || true
    # Files only (never -R on the dirs themselves) — a directory stripped of
    # its own write bit can no longer have entries added/removed inside it,
    # which broke both a later re-sync (rsync --delete needs to unlink stale
    # files) and this selftest's own tmpdir cleanup (rm -rf) the first time
    # this shipped with a blanket `chmod -R a-w`.
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" "find '$dst' -type f -exec chmod a-w {} +" 2>/dev/null || true
  done
}

# Sets GATE_READY (true/false) and GATE_TOOLS_MISSING (comma-joined tool
# names, empty when none) on return; writes the full probe result to
# $GATE_TOOLS_STATE_FILE for `verify`'s gate-tools check to read back.
# Never fatal — a total probe failure (ssh unreachable etc.) records every
# tool MISSING rather than crashing `up`.
GATE_READY="false"
GATE_TOOLS_MISSING=""
provision_gate_tools() {  # $1=ip
  local ip="$1" probe_out name ver

  probe_out="$(gate_tools_probe "$ip")"
  while IFS='=' read -r name ver; do
    [ -n "$name" ] || continue
    [ "$ver" = "MISSING" ] || continue
    if [ "$name" = "autobuilder" ]; then
      if [ -f "$GATE_TOOLS_AUTOBUILDER_BIN" ]; then
        "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
          "$(printf '%s\nmkdir -p '"'"'%s'"'"'\n' "# gate-tools-install autobuilder" "$GATE_TOOLS_REMOTE_BIN_DIR")" >/dev/null 2>&1 || true
        "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
          "$GATE_TOOLS_AUTOBUILDER_BIN" "$REMOTE_USER@$ip:$GATE_TOOLS_REMOTE_BIN_DIR/autobuilder" >/dev/null 2>&1 || true
        "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
          "chmod +x '$GATE_TOOLS_REMOTE_BIN_DIR/autobuilder'" 2>/dev/null || true
      fi
    else
      "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" "$(gate_tools_install_cmd "$name")" >/dev/null 2>&1 || true
    fi
  done <<<"$probe_out"

  sync_gate_tools_scripts "$ip"

  local final_out; final_out="$(gate_tools_probe "$ip")"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if [ -n "$final_out" ]; then
    python3 -c '
import json, sys
lines = sys.argv[1].strip().splitlines()
tools, missing = {}, []
for ln in lines:
    if "=" not in ln:
        continue
    k, v = ln.split("=", 1)
    tools[k] = v
    if v == "MISSING":
        missing.append(k)
json.dump({"tools": tools, "missing": missing}, open(sys.argv[2], "w"))
' "$final_out" "$GATE_TOOLS_STATE_FILE"
    GATE_TOOLS_MISSING="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d.get("missing",[])))' "$GATE_TOOLS_STATE_FILE" 2>/dev/null || true)"
  else
    python3 -c '
import json, sys
json.dump({"tools": {}, "missing": sys.argv[1].split()}, open(sys.argv[2], "w"))
' "$GATE_TOOLS_LIST" "$GATE_TOOLS_STATE_FILE"
    GATE_TOOLS_MISSING="$GATE_TOOLS_LIST"
  fi
  if [ -z "$GATE_TOOLS_MISSING" ]; then GATE_READY="true"; else GATE_READY="false"; fi
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
    box_bootstrap "$aip"
    local sbx; sbx="$(sandbox_probe "$aip")"
    provision_gate_tools "$aip"
    : > "$SERVED_FILE"
    state_write "server_id=$aid" "ip=$aip" "server_type=$SERVER_TYPE" \
      "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
      "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
      "teardown_scheduled=false" "teardown_epoch=" \
      "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING"
    journal_line "$(now_iso)  burst-lane  up  adopted  (server_id=$aid ip=$aip sandbox_ok=$sbx gate_ready=$GATE_READY)"
    ( cmd_verify >/dev/null 2>&1 ) || journal_line "$(now_iso)  burst-lane  up  verify-failed-after-adopt  (lane unverified — run falls back local)"
    echo "already-up: $aid $aip (adopted)"
    exit 0
  fi

  local pre_out; pre_out="$(precondition)"; local pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=precondition-failed: $pre_out)"
    echo "fallback: precondition failed - $pre_out"
    exit 3
  fi

  # AC14 (primary-IP billing): deliberately never pass --primary-ipv4 (attach
  # an existing, standalone Primary IP) or --without-ipv4 here. Left at the
  # default, hcloud auto-creates an ephemeral Primary IPv4 that is owned by
  # this server and is deleted automatically when the server is (Hetzner's
  # documented default) — no separate `hcloud primary-ip delete` call is ever
  # needed, and none is ever made (see destroy_verify below), so no orphan
  # Primary IP can outlive teardown. If this ever grows an explicit
  # --primary-ipv4 attach, destroy_verify must gain a matching
  # `hcloud primary-ip delete` in the same step or every subsequent boot
  # leaks a billed IP.
  local create_out create_err; create_err="$(mktemp)"
  if ! create_out="$("$HCLOUD" server create --name "$SERVER_NAME" --type "$SERVER_TYPE" \
        --location "$LOCATION" --image "$SNAPSHOT_ID" --ssh-key "${HCLOUD_SSH_KEY:-default}" -o json 2>"$create_err")"; then
    local emsg; emsg="$(tail -3 "$create_err" 2>/dev/null | tr '\n' ' ')"; rm -f "$create_err"
    journal_line "$(now_iso)  burst-lane  up  fallback  (cause=hcloud-server-create-failed: $emsg)"
    echo "fallback: hcloud server create failed - $emsg"
    exit 3
  fi
  rm -f "$create_err"
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

  box_bootstrap "$ip"
  local sbx; sbx="$(sandbox_probe "$ip")"
  provision_gate_tools "$ip"
  : > "$SERVED_FILE"
  state_write "server_id=$id" "ip=$ip" "server_type=$SERVER_TYPE" \
    "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
    "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
    "teardown_scheduled=false" "teardown_epoch=" \
    "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING"
  journal_line "$(now_iso)  burst-lane  up  booted  (server_id=$id ip=$ip type=$SERVER_TYPE sandbox_ok=$sbx gate_ready=$GATE_READY)"
  ( cmd_verify >/dev/null 2>&1 ) || journal_line "$(now_iso)  burst-lane  up  verify-failed-after-boot  (lane unverified — run falls back local)"
  if [ "$sbx" = false ]; then
    journal_line "$(now_iso)  burst-lane  up  sandbox-unavailable  (server_id=$id — rust selection falls back to local cap for python-kind sandboxed tests this tick)"
  fi
  echo "up: $id $ip"
  exit 0
}

# ---- verify ---------------------------------------------------------------
# End-to-end proof the lane can do real work: rsync roundtrip + remote cargo
# + remote uv + sandbox, all with outcome assertions. Stamps verified=true
# into session state on success; cmd_run refuses to route until it has.
# This exists because every lane component "passed" its fixtures on
# 2026-09-09 while zero real work had ever executed on a box.
cmd_verify() {
  if ! state_active; then
    probe_emit burst-verify could-not-check "no active session to verify" >/dev/null
    echo "verify: no active session"; exit 1
  fi
  local ip; ip="$(state_read ip)"
  local fails=0
  vfail() { echo "verify FAIL: $1"; fails=$((fails+1)); }

  local fx; fx="$(mktemp -d)"; echo ok > "$fx/probe.txt"
  local rpath="$REMOTE_ROOT/.verify-fixture"
  "$RSYNC_BIN" -az --delete --rsync-path="mkdir -p '$rpath' && rsync" \
      -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
      "$fx/" "$REMOTE_USER@$ip:$rpath/" >/dev/null 2>&1 || vfail "rsync roundtrip"
  rm -rf "$fx"

  local rout
  rout="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    'export PATH=/root/.cargo/bin:/root/.local/bin:$PATH; cargo --version && uv --version && python3 -c "print(1)"' 2>/dev/null)"
  printf '%s' "$rout" | grep -q "^cargo " || vfail "remote cargo"
  printf '%s' "$rout" | grep -q "^uv "    || vfail "remote uv"
  printf '%s' "$rout" | grep -q "^1$"     || vfail "remote python3"
  [ "$(sandbox_probe "$ip")" = "true" ]   || vfail "bwrap sandbox"

  # Requirement 1's own verify check: fails closed, naming the first missing
  # tool, rather than a bare "gate-tools FAIL" — an operator staring at the
  # journal should not have to go re-run provisioning by hand to find out
  # which one.
  local gt_ready gt_missing gt_first
  gt_ready="$(state_read gate_ready)"; gt_missing="$(state_read gate_tools_missing)"
  if [ "$gt_ready" = "true" ]; then
    echo "gate-tools ok"
  else
    gt_first="${gt_missing%%,*}"
    vfail "gate-tools (missing: ${gt_first:-unknown})"
  fi

  if [ "$fails" -gt 0 ]; then
    probe_emit burst-verify dirty "$fails check(s) failed — lane stays unverified, all work falls back local" >/dev/null
    journal_line "$(now_iso)  burst-lane  verify  FAILED  ($fails check(s) — lane stays unverified, all work falls back local)"
    exit 1
  fi
  state_write "server_id=$(state_read server_id)" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$(state_read runs_served)" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" \
    "gate_ready=$gt_ready" "gate_tools_missing=$gt_missing" \
    "verified=true"
  probe_emit burst-verify clean "rsync+cargo+uv+python3+sandbox all real" >/dev/null
  journal_line "$(now_iso)  burst-lane  verify  ok  (rsync+cargo+uv+python3+sandbox all real)"
  echo "verify: ok"
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
    probe_emit burst-status clean "no active session" >/dev/null
    if [ "$json" -eq 1 ]; then echo '{"active":false}'; else echo "no active session"; fi
    exit 0
  fi
  # AC4 (PRD-build-three-state-probes): a corrupted session.json is a file
  # that exists but does not mean "no session" and does not mean "a healthy
  # active session" — it means the check itself couldn't run. Treat it as
  # could-not-check, not as either two-state answer, while still emitting
  # `"active":false` so every existing caller's fallback-local string match
  # (e.g. gate-burst.sh's `*'"active":true'*`) is unaffected.
  if [ -n "$JQ" ] && ! "$JQ" -e . "$STATE_FILE" >/dev/null 2>&1; then
    probe_emit burst-status could-not-check "session.json corrupted (unparseable): $STATE_FILE" >/dev/null
    journal_line "$(now_iso)  burst-lane  status  could-not-check  (session.json corrupted at $STATE_FILE — treating as no active session, falling back local)"
    if [ "$json" -eq 1 ]; then echo '{"active":false,"could_not_check":true}'; else echo "could-not-check: session.json corrupted — treating as no active session"; fi
    exit 0
  fi
  local id ip alive ttl sbx conc
  id="$(state_read server_id)"; ip="$(state_read ip)"; alive="$(minutes_alive)"
  ttl="$(state_read ttl_hours)"; sbx="$(state_read sandbox_ok)"
  # PRD-build-burst-parallel-runs AC6: live concurrency, so an operator can
  # see utilization ("3/4") at a glance instead of inferring it from journal
  # `concurrent=` fields scattered across `run` lines.
  conc="$(count_held_slots)"
  probe_emit burst-status dirty "active session $id ip=$ip alive=${alive}m" >/dev/null

  # PRD-build-burst-pull-on-demand requirement 3: dirty worktrees, with age
  # (seconds since marked), so an operator can see the lazy-pull backlog at a
  # glance. Appended only in the ACTIVE-session branch — the "no active
  # session"/"could-not-check" strings above are matched EXACTLY (by name,
  # not substring) by the cargo/uv shims' own status-parse, and must never
  # gain trailing content.
  mkdir -p "$DIRTY_DIR" 2>/dev/null || true
  local dirty_json dirty_lines
  dirty_json="$(python3 -c '
import json, glob, sys, time
now = int(sys.argv[1])
rows = []
for f in sorted(glob.glob(sys.argv[2] + "/*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    ts = d.get("marked_ts", "")
    try:
        marked_epoch = int(time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
    except Exception:
        marked_epoch = now
    d["age_seconds"] = max(0, now - marked_epoch)
    rows.append(d)
print(json.dumps(rows))
' "$(now_epoch)" "$DIRTY_DIR")"
  dirty_lines="$(python3 -c '
import json, sys
for r in json.loads(sys.argv[1]):
    print("dirty: %s age=%ss" % (r.get("worktree", ""), r.get("age_seconds", 0)))
' "$dirty_json")"

  # PRD-build-burst-remote-disk-guard requirement 3: free disk and a
  # three-state ok|low|full read, straight from the same probe sub-cap and
  # run's route-refusal use — so an operator (or lane-claim.sh) never has to
  # ssh in to learn what run's next fallback: disk-low would have said.
  # Fail OPEN on a probe hiccup: free_disk_gb stays JSON null, disk_state
  # stays the default "ok" (never claim "low"/"full" from a reading we
  # don't actually have).
  local free_disk_gb="null" disk_state="ok" disk_probe_status
  if disk_probe_status="$(probe_remote_capacity "$ip" 2>/dev/null)"; then
    local _st_avail _st_nproc st_free
    read -r _st_avail _st_nproc st_free <<<"$disk_probe_status"
    case "$st_free" in
      ''|*[!0-9]*) : ;;
      *)
        free_disk_gb="$st_free"
        local st_floor="${BURST_DISK_FLOOR_GB:-40}"
        if [ "$st_free" -le 0 ]; then disk_state="full"
        elif [ "$st_free" -lt "$st_floor" ]; then disk_state="low"
        else disk_state="ok"
        fi
        ;;
    esac
  fi

  if [ "$json" -eq 1 ]; then
    printf '{"active":true,"server_id":"%s","ip":"%s","minutes_alive":%s,"ttl_hours":"%s","sandbox_ok":"%s","concurrent":"%s","free_disk_gb":%s,"disk_state":"%s","dirty":%s}\n' \
      "$id" "$ip" "$alive" "$ttl" "$sbx" "$conc" "$free_disk_gb" "$disk_state" "$dirty_json"
  else
    echo "active: $id ip=$ip alive=${alive}m ttl=${ttl}h sandbox_ok=$sbx concurrent=$conc disk_state=$disk_state free_disk_gb=$free_disk_gb"
    [ -n "$dirty_lines" ] && printf '%s\n' "$dirty_lines"
  fi
  exit 0
}

# ---- route-check (PRD-build-gate-cargo-route-attest) ------------------------
# Attests whether a `cargo` call made under the CURRENT $PATH — the same
# $PATH a cargo-invoking producer inherits from its caller — would actually
# reach the burst-lane shim (scripts/burst-lane-bin/cargo) or silently fall
# straight through to a real cargo ahead of it on PATH (the exact 2026-09-10
# defect: extend-gate.sh re-prepending $HOME/.cargo/bin ahead of an
# already-armed shim, so 53 autobuilder loops + 34 gate `cargo test` runs
# all landed on RedBaron with casper idle). `intended` mirrors extend-
# gate.sh's own definition: burst iff `status --json` reports an active
# session RIGHT NOW; local otherwise. `resolved` is `command -v cargo`
# under THIS process's own $PATH — the same resolution a real `cargo test`
# call would get. `state` is clean when intended=local (nothing to route)
# or resolved IS the shim; mismatch when intended=burst and resolved is
# something else (the shim is present but shadowed, or entirely absent
# from PATH — same observable symptom either way: the box never sees this
# run); could-not-check when no cargo resolves at all. On mismatch, also
# appends one synthetic route-log line (decision=local cause=shim-not-first)
# to $BURST_ROUTE_LOG when that env var is set, so a caller scanning the
# route log for local-decision causes (extend-gate.sh's own postcondition)
# still sees this failure mode even though the shim itself never ran to log
# anything about itself. Emits the shared three-state probe `gate-cargo-
# route` (dirty for mismatch — the library only knows clean/dirty/could-
# not-check; "mismatch" is this probe's own name for its dirty state, named
# in the printed line and journal below).
cmd_route_check() {
  local repo="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:?route-check: --repo needs a value}"; shift 2 ;;
      *) echo "usage: burst-lane.sh route-check [--repo <path>]" >&2; exit 2 ;;
    esac
  done
  local shim="$HERE/burst-lane-bin/cargo"
  local status_json intended="local"
  status_json="$("$0" status --json 2>/dev/null || true)"
  case "$status_json" in *'"active":true'*) intended="burst" ;; esac

  local resolved resolved_dir shim_dir
  resolved="$(command -v cargo 2>/dev/null || true)"
  resolved_dir=""
  [ -n "$resolved" ] && resolved_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P || true)"
  shim_dir="$(cd "$(dirname "$shim")" 2>/dev/null && pwd -P || true)"

  local state cause=""
  if [ -z "$resolved" ]; then
    state="could-not-check"
  elif [ "$intended" = "burst" ] && [ -n "$shim_dir" ] && [ "$resolved_dir" != "$shim_dir" ]; then
    state="mismatch"; cause="shim-not-first"
  else
    state="clean"
  fi

  if [ "$state" = "mismatch" ] && [ -n "${BURST_ROUTE_LOG:-}" ]; then
    mkdir -p "$(dirname "$BURST_ROUTE_LOG")" 2>/dev/null || true
    (
      flock -w 2 205 2>/dev/null || exit 0
      printf '%s %s - local %s %s\n' "$(now_iso)" "$$" "$cause" "$repo" >&205
    ) 205>>"$BURST_ROUTE_LOG" 2>/dev/null || true
  fi

  case "$state" in
    clean)           probe_emit gate-cargo-route clean "intended=$intended resolved=${resolved:-none}" >/dev/null ;;
    mismatch)        probe_emit gate-cargo-route dirty "route-mismatch intended=$intended resolved=${resolved:-none} shim=$shim cause=$cause" >/dev/null ;;
    could-not-check) probe_emit gate-cargo-route could-not-check "no cargo resolved on \$PATH" >/dev/null ;;
  esac

  printf 'route: intended=%s resolved=%s shim=%s state=%s%s\n' \
    "$intended" "${resolved:-none}" "$shim" "$state" "${cause:+ cause=$cause}"
  exit 0
}

# ---- off-root cargo target-dir (PRD-build-worktree-targets-off-root) --------
# A worktree's own .cargo/config.toml may point `target-dir` at an absolute
# path OUTSIDE the worktree tree (e.g. /mnt/data/jsy/cargo-targets/<slug>) so
# RedBaron's main checkout stays lean. That config file rides along in the
# rsync-up, so remote cargo resolves the same absolute string and writes
# there on the box's own filesystem — never under $remote_path/target — a
# fact `pull_target_incremental` used to not know, so the pull-back for
# every off-root worktree silently found nothing and fell back local
# (mcphost-call-limits-honest, 2026-09-09 19:58Z: "No such file or
# directory" for $remote_path/target on a box that had genuinely built).
# Echoes the absolute override path, or empty for the plain (relative
# $worktree/target) convention.
cargo_target_dir_for() {  # $1=worktree -> stdout: absolute override, or ""
  local cfg="$1/.cargo/config.toml"
  [ -f "$cfg" ] || return 0
  sed -n -E 's/^[[:space:]]*target-dir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n1
}

# ---- shared incremental target/ pull (requirement 10) -----------------------
# A 95-binary test target should not copy whole on every run — both `run`'s
# own pull-back and the standalone `sync-back` subcommand go through this one
# `rsync --delete --stats` path so already-synced bytes on the box (warm from
# a prior run on the same worktree) don't get re-counted or re-copied.
pull_target_incremental() {  # $1=worktree $2=ip -> stdout: bytes transferred; rc 0/1
  local worktree="$1" ip="$2" remote_path stats local_target remote_target override
  remote_path="$(remote_path_for "$worktree")"
  override="$(cargo_target_dir_for "$worktree")"
  # The BOX always builds into $remote_path/target (cmd_run sets no remote
  # CARGO_TARGET_DIR); only the LOCAL side honors the off-root override.
  # Mirroring the override to the remote side (req-10 first cut) pointed the
  # pull at a path that never exists on the box — every override worktree's
  # pull failed rsync-down (2026-09-09 21:03Z).
  remote_target="$remote_path/target"
  if [ -n "$override" ]; then
    local_target="$override"
  else
    local_target="$worktree/target"
  fi
  mkdir -p "$local_target" 2>/dev/null || true
  # --exclude autobuilder: gate receipts/verdicts live at target/autobuilder/
  # LOCALLY ONLY (producers run here; the box only runs cargo) — without this,
  # --delete erased the gate's own evidence on every routed shared-checkout run.
  if ! stats="$("$RSYNC_BIN" -az --delete --stats --exclude autobuilder -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_target/" "$local_target/" 2>&1)"; then
    return 1
  fi
  local bytes; bytes="$(echo "$stats" | grep -oE 'Total transferred file size: [0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')"
  echo "${bytes:-0}"
  return 0
}

# ---- shared incremental .pybuilder/ pull (requirement 12) --------------------
# `pull_target_incremental` only ever pulls `target/` (or its Cargo
# target-dir override) back — a python `run` (routed through the uv shim)
# has no Cargo target-dir at all, so that pull silently found nothing for
# every python run and AC12's ".pybuilder/ receipts appear locally
# afterwards" was unmet even though the routing itself worked. This mirrors
# `pull_target_incremental`'s same incremental rsync --delete --stats
# contract for pybuilder's own `.pybuilder/` receipt directory instead.
pull_pybuilder_incremental() {  # $1=worktree $2=ip -> stdout: bytes transferred; rc 0/1
  local worktree="$1" ip="$2" remote_path stats local_target remote_target
  remote_path="$(remote_path_for "$worktree")"
  local_target="$worktree/.pybuilder"; remote_target="$remote_path/.pybuilder"
  mkdir -p "$local_target" 2>/dev/null || true
  if ! stats="$("$RSYNC_BIN" -az --delete --stats -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_target/" "$local_target/" 2>&1)"; then
    return 1
  fi
  local bytes; bytes="$(echo "$stats" | grep -oE 'Total transferred file size: [0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')"
  echo "${bytes:-0}"
  return 0
}

# ---- cost attribution (PRD-build-cost-attribution, requirement 1) -----------
# Every routed `run` is attributed to the PRD slug whose worktree it served.
# Derivation (first match wins; never drops a run — falls to "unattributed"):
#   1. gate-burst / this skill's own AC-fixture tests (tests/gate_burst_ac*.sh
#      use tmpdirs named gb-ac<N>.XXXXXX; the checked-in fake ssh/rsync/hcloud
#      fixtures live under */gate-burst-fake/ or */burst-lane-fake/) -> "selftest".
#   2. The worktree basename IS one of the known repo roots directly (a gate/
#      extend run against build_into itself — e.g. extend-gate.sh's cargo
#      invocations run in the shared checkout, not a per-PRD worktree) ->
#      "shared-<repo>".
#   3. build-worktrees convention (worktree-extend.sh's `wt_path`, wm-buildtree's
#      equivalent): basename is `<repo>-<slug>` — find the longest known repo
#      name under $ATTR_REPOS_DIR that prefixes the basename and strip it.
#   4. Anything else -> "unattributed" (counted, never dropped).
attribution_slug_for() {  # $1 = worktree path -> stdout: slug
  local wt="$1" base cand rest
  base="$(basename "$wt")"

  case "$wt" in
    */gb-ac*|*/gate-burst-fake*|*/burst-lane-fake*) echo "selftest"; return ;;
  esac

  if [ -n "$base" ] && [ -d "$ATTR_REPOS_DIR/$base" ]; then
    echo "shared-$base"; return
  fi

  if [ -d "$ATTR_REPOS_DIR" ]; then
    for cand in $(ls -1 "$ATTR_REPOS_DIR" 2>/dev/null | awk '{ print length"\t"$0 }' | sort -rn | cut -f2-); do
      case "$base" in
        "$cand"-*)
          rest="${base#"$cand"-}"
          if [ -n "$rest" ]; then echo "$rest"; return; fi
          ;;
      esac
    done
  fi

  echo "unattributed"
}

# Sub-second wallclock — now_epoch()'s integer seconds (and its
# BURST_LANE_NOW test override, needed for hour-boundary teardown math) are
# too coarse to reliably observe a >0 duration around a near-instant fake-ssh
# round trip in the offline selftest (AC1: "wall seconds >0").
now_fractional() { date +%s.%N; }

# Requirement 1 (cont'd): append one NDJSON row to the attribution ledger.
# Called from inside cmd_run, under the RUN_LOCK it already holds for the
# whole rsync+ssh+rsync body — no separate lock needed for the append.
#
# PRD-build-burst-pull-on-demand extends this with two row shapes sharing
# one file (the cost-ledger's own kind:"slug" additive-row precedent):
#   kind="run"  (default, $7 unset/"run"): a completed remote run. $8/$9/$10
#     are pulls_skipped (0/1 — always 1 now that `run` never pulls itself),
#     bytes_saved (estimate from the worktree's last observed pull, or 0 if
#     none has ever happened) and estimate (always "true" when
#     pulls_skipped>0 — this PRD never claims an exact figure for a transfer
#     that didn't happen).
#   kind="pull" ($7="pull"): a lazy pull that DID execute. $11=trigger
#     (local-read|explicit|teardown). wall_seconds is always 0 (no remote
#     exec happened); sync_s/bytes are the pull's own cost.
attribution_record() {  # $1=slug $2=session_id $3=wall_s $4=sync_s $5=bytes $6=worktree [$7=kind $8=pulls_skipped $9=bytes_saved $10=estimate $11=trigger]
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local kind="${7:-run}" pulls_skipped="${8:-0}" bytes_saved="${9:-0}" estimate="${10:-false}" trigger="${11:-}"
  python3 -c '
import json, sys
slug, sid, wall_s, sync_s, nbytes, worktree, date, path, kind, pulls_skipped, bytes_saved, estimate, trigger = sys.argv[1:14]
row = {
    "date": date, "session_id": sid, "slug": slug,
    "wall_seconds": round(float(wall_s), 3), "sync_s": round(float(sync_s), 3),
    "bytes": int(nbytes or 0), "worktree": worktree, "kind": kind,
}
if kind == "pull":
    row["trigger"] = trigger
else:
    row["pulls_skipped"] = int(pulls_skipped or 0)
    row["bytes_saved"] = int(bytes_saved or 0)
    row["estimate"] = (estimate == "true")
with open(path, "a") as fh:
    fh.write(json.dumps(row) + "\n")
' "$1" "$2" "$3" "$4" "$5" "$6" "$(now_iso)" "$ATTR_LEDGER" "$kind" "$pulls_skipped" "$bytes_saved" "$estimate" "$trigger"
}

# ---- run --------------------------------------------------------------------
RUN_LOCK="$STATE_DIR/run.lock"

# PRD-build-burst-parallel-runs: remote dirs are disjoint PER LOCAL PATH, not
# per basename — ~/repos/synthorg and a worktree both named "synthorg" must
# never share (and --delete-shred) one remote dir. Every sync site derives
# the remote path from this one helper.
remote_path_for() {  # $1=worktree -> stdout remote dir
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/%s-%s\n' "$REMOTE_ROOT" "$(basename "$1")" "$wkey"
}
worktree_lock_key() { printf '%s' "$1" | sha1sum | cut -c1-16; }
wt_lock_file() { printf '%s/locks/wt-%s.lock\n' "$STATE_DIR" "$(worktree_lock_key "$1")"; }

# ---- lazy pull: dirty marker (PRD-build-burst-pull-on-demand requirement 1) -
# One marker file per worktree, keyed the same way remote_path_for() keys its
# remote dir — so the marker survives a worktree's own git resets (state
# lives outside the worktree, per the worktree-reset-wipes-state rule) and
# is trivially found again by any later invocation regardless of the
# worktree's own git state.
dirty_marker_file() {  # $1=worktree -> stdout path
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/%s.json\n' "$DIRTY_DIR" "$wkey"
}

mark_dirty() {  # $1=worktree $2=session_id $3=remote_path $4=kind (target|pybuilder)
  mkdir -p "$DIRTY_DIR" 2>/dev/null || true
  python3 -c '
import json, sys
worktree, sid, remote_path, kind, ts, path = sys.argv[1:7]
row = {"worktree": worktree, "session_id": sid, "remote_path": remote_path, "kind": kind, "marked_ts": ts}
with open(path, "w") as fh:
    fh.write(json.dumps(row))
' "$1" "$2" "$3" "$4" "$(now_iso)" "$(dirty_marker_file "$1")"
}

is_dirty() { [ -s "$(dirty_marker_file "$1")" ]; }  # $1=worktree -> rc0 dirty

dirty_field() {  # $1=worktree $2=field -> stdout value; rc1 if no marker/field
  local f; f="$(dirty_marker_file "$1")"
  [ -s "$f" ] || return 1
  python3 -c '
import json, sys
path, key = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
print(d.get(key, ""))
' "$f" "$2"
}

clear_dirty() { rm -f "$(dirty_marker_file "$1")"; }  # $1=worktree

# Last ACTUAL pull's byte count for a worktree — the "last observed pull
# size" the PRD's requirement 1 wants a skipped pull's bytes_saved estimated
# from. Kept in its own file (not the marker) so it survives clear_dirty.
record_pull_size() {  # $1=worktree $2=bytes
  mkdir -p "$PULLSZ_DIR" 2>/dev/null || true
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s\n' "${2:-0}" > "$PULLSZ_DIR/$wkey"
}
last_pull_size() {  # $1=worktree -> stdout bytes (0 if never pulled)
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  cat "$PULLSZ_DIR/$wkey" 2>/dev/null || echo 0
}

# rc0 if the box currently reachable at $1 still has $2 on disk — used both
# to decide whether a lazy pull can proceed and (when it can't) whether that
# marker should go COLD (box/dir provably gone — requirement 4) rather than
# be left dirty forever. A totally unreachable box (ssh itself fails) is
# indistinguishable from "the dir is gone" here, and is treated the same:
# correctness by recompile, never a silent stale read.
remote_dir_exists() {  # $1=ip $2=remote_path -> rc0 exists
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
    "$REMOTE_USER@$1" "[ -d '$2' ]" 2>/dev/null
}

# Shared body for actually executing a lazy pull against one dirty marker.
# Does NOT itself lock — callers hold (or non-blockingly probe) the
# worktree's own flock as their race-safety strategy differs (see cmd_pull,
# cmd_ensure_fresh, sweep_dirty_worktrees below). Three outcomes:
#   pulled: marker cleared, pull size recorded, kind="pull" attribution row
#     appended, journaled — rc0.
#   cold (no active session, or the remote dir provably no longer exists):
#     marker cleared anyway (requirement 4 — never a silent stale read; the
#     next local build just recompiles), journaled, rc0.
#   real failure (box up, dir exists, rsync itself failed): marker LEFT IN
#     PLACE for a later retry, journaled, rc1.
do_marker_pull() {  # $1=worktree $2=trigger(local-read|explicit|teardown) -> rc0 handled, rc1 real failure
  local worktree="$1" trigger="$2" sid remote_path kind
  is_dirty "$worktree" || return 0
  sid="$(dirty_field "$worktree" session_id)"
  remote_path="$(dirty_field "$worktree" remote_path)"
  kind="$(dirty_field "$worktree" kind)"

  if ! state_active; then
    clear_dirty "$worktree"
    journal_line "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid trigger=$trigger cause=no-active-session — local target stale, next local build recompiles)"
    return 0
  fi
  local ip; ip="$(state_read ip)"

  if ! remote_dir_exists "$ip" "$remote_path"; then
    clear_dirty "$worktree"
    journal_line "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid remote_path=$remote_path trigger=$trigger cause=remote-dir-missing — local target stale, next local build recompiles)"
    return 0
  fi

  local t0 t1 bytes prc=0
  t0="$(now_fractional)"
  if [ "$kind" = "pybuilder" ]; then
    bytes="$(pull_pybuilder_incremental "$worktree" "$ip")" || prc=1
  else
    bytes="$(pull_target_incremental "$worktree" "$ip")" || prc=1
  fi
  t1="$(now_fractional)"
  if [ "$prc" -ne 0 ]; then
    journal_line "$(now_iso)  burst-lane  pull  fallback  (cause=rsync-failed worktree=$worktree trigger=$trigger — marker left dirty for retry)"
    return 1
  fi

  record_pull_size "$worktree" "${bytes:-0}"
  clear_dirty "$worktree"
  local sync_s slug
  sync_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  # requirement 7: teardown pulls are lane overhead, not the reading party's
  # own cost — everything else is attributed to whoever's local read
  # triggered it (same derivation a run itself would use for this worktree).
  if [ "$trigger" = "teardown" ]; then slug="teardown"; else slug="$(attribution_slug_for "$worktree")"; fi
  attribution_record "$slug" "$sid" 0 "$sync_s" "${bytes:-0}" "$worktree" pull 0 0 false "$trigger"
  journal_line "$(now_iso)  burst-lane  pull  ok  (worktree=$worktree trigger=$trigger bytes=${bytes:-0} slug=$slug)"
  return 0
}

# PRD-build-burst-parallel-runs AC6: non-blocking peek at how many run slots
# are currently held, for `status` to report `concurrent=<held>/<cap>`. Never
# acquires a slot itself (a peek that took one would lie about capacity to
# any run racing it) — same try-and-release-immediately probe
# acquire_run_slot already uses to count the OTHER held slots once it has
# taken its own.
count_held_slots() {  # -> stdout "<held>/<cap>"
  local cap="${BURST_MAX_CONCURRENT_RUNS:-4}" held=0 j
  mkdir -p "$STATE_DIR/slots" 2>/dev/null || true
  for j in $(seq 1 "$cap"); do
    ( exec 211>"$STATE_DIR/slots/$j.lock"; flock -n 211 ) 2>/dev/null || held=$((held+1))
  done
  printf '%s/%s\n' "$held" "$cap"
}

# Concurrency slots (cargo-budget pattern): different-worktree runs proceed in
# parallel up to BURST_MAX_CONCURRENT_RUNS; a full table waits (journaled after
# 120s), never fails the caller. Acquired on fd 202; released with the process.
# MUST be called directly (never in $(...) — a command substitution is a
# subshell and the flock dies with it, which is exactly the bug the selftest
# caught on first run). Sets SLOT_HELD="held/cap"; holds fd 202 on return.
SLOT_HELD=""
acquire_run_slot() {
  local cap="${BURST_MAX_CONCURRENT_RUNS:-4}" i waited=0
  mkdir -p "$STATE_DIR/slots" 2>/dev/null || true
  while :; do
    for i in $(seq 1 "$cap"); do
      exec 202>"$STATE_DIR/slots/$i.lock"
      if flock -n 202; then
        local held=0 j
        for j in $(seq 1 "$cap"); do
          [ "$j" = "$i" ] && { held=$((held+1)); continue; }
          ( exec 210>"$STATE_DIR/slots/$j.lock"; flock -n 210 ) 2>/dev/null || held=$((held+1))
        done
        SLOT_HELD="$held/$cap"
        return 0
      fi
    done
    sleep 2; waited=$((waited+2))
    if [ "$waited" -eq 120 ]; then
      journal_line "$(now_iso)  burst-lane  run  slot-wait  (worktree=$1 cap=$cap waited=${waited}s)"
    fi
  done
}

cmd_run() {
  local worktree="${1:-}"; shift || true
  while [ "${1:-}" = "--" ]; do shift; done  # guard: doubled -- from stacked wrappers
  [ -n "$worktree" ] && [ $# -ge 1 ] || { echo "usage: burst-lane.sh run <worktree> -- <cargo args...>" >&2; exit 2; }
  [ -d "$worktree" ] || die "no such worktree: $worktree" 2

  # Global lock (201) held ONLY for session ensure/verify — the old
  # whole-run hold serialized the box to width-1 (2026-09-10 5-whys).
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
  if [ "$(state_read verified)" != "true" ]; then
    ( cmd_verify >/dev/null 2>&1 ) || true
    if [ "$(state_read verified)" != "true" ]; then
      journal_line "$(now_iso)  burst-lane  run  lane-unverified  (server_id=$id worktree=$worktree — falling back local)"
      echo "fallback: lane not verified (burst-lane.sh verify) — running locally"
      exit 3
    fi
  fi
  flock -u 201

  acquire_run_slot "$worktree"
  local slot_held="$SLOT_HELD"
  # Same-worktree runs still serialize: two --delete syncs of one remote dir
  # would shred each other. Different worktrees hold different locks.
  mkdir -p "$STATE_DIR/locks" 2>/dev/null || true
  exec 203>"$STATE_DIR/locks/wt-$(worktree_lock_key "$worktree").lock"
  flock 203

  local remote_path; remote_path="$(remote_path_for "$worktree")"

  # PRD-build-burst-remote-disk-guard requirement 3: refuse to route to a
  # box that cannot receive this worktree, checked BEFORE the (now
  # known-likely-to-fail) rsync-up rather than discovered from its failure.
  # Fail OPEN on anything short of a confident "below the floor" reading —
  # a probe failure or malformed third field here must never itself block
  # a run that a real disk-full condition would have blocked anyway (the
  # rsync-up below still catches that case, named per requirement 4).
  local disk_probe_run
  if disk_probe_run="$(probe_remote_capacity "$ip" 2>/dev/null)"; then
    local _run_avail _run_nproc run_free_gb
    read -r _run_avail _run_nproc run_free_gb <<<"$disk_probe_run"
    case "$run_free_gb" in
      ''|*[!0-9]*) : ;;
      *)
        local disk_floor_run="${BURST_DISK_FLOOR_GB:-40}"
        if [ "$run_free_gb" -lt "$disk_floor_run" ]; then
          journal_line "$(now_iso)  burst-lane  run  fallback  (cause=disk-low free_gb=$run_free_gb floor_gb=$disk_floor_run worktree=$worktree)"
          echo "fallback: disk-low (free_gb=$run_free_gb floor_gb=$disk_floor_run)"
          exit 3
        fi
        ;;
    esac
  fi

  # PRD-build-cost-attribution requirement 1: wall-seconds attributed to a
  # slug measure the REMOTE EXEC only; rsync up+down time is tracked
  # separately as sync_s (sizing evidence for the incremental-pull work,
  # not this PRD's own cost-share denominator).
  local t_up_start t_up_end t_remote_end
  t_up_start="$(now_fractional)"

  # PRD-build-burst-remote-disk-guard requirement 4: name the cause instead
  # of making the operator ssh in and run df/cat the log by hand — the rsync
  # exit code and the log's own last non-blank line ride into the journal,
  # and the captured log itself lives under state (survives past $$ exiting,
  # unlike the old /tmp/burst-lane-rsync-up.$$.log a reboot or tmpwatch
  # would also silently reap).
  mkdir -p "$STATE_DIR/logs" 2>/dev/null || true
  local up_log="$STATE_DIR/logs/rsync-up.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$worktree/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line "$(now_iso)  burst-lane  run  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" worktree=$worktree)"
    echo "fallback: rsync to $ip failed rc=$rsync_up_rc (see $up_log)"
    exit 3
  fi
  t_up_end="$(now_fractional)"

  # A caller (the PATH shims) may hand us the LOCAL absolute binary path —
  # meaningless on the box. Route by bare name; the remote PATH below finds it.
  local first="$1"; shift
  case "$first" in */cargo) first=cargo ;; */uv) first=uv ;; esac
  # CARGO_TARGET_DIR pins the remote build into $remote_path/target no matter
  # what .cargo/config.toml the worktree synced up (an off-root target-dir
  # override in that file sent remote builds to a box-local absolute path the
  # pull could never find — 2026-09-09 21:38Z; env beats config in cargo).
  # PRD-build-gate-wall-clock requirement 2: never run a compile against a
  # remote sccache server that does not answer (this box's own version of
  # the 2026-09-10 RedBaron incident — an unmanaged sccache restarting
  # mid-request orphans clients for the whole gate's wall clock). This box
  # is an ephemeral root ssh session with no systemd-user unit to manage,
  # so the equivalent guard is inlined here rather than shelling out to
  # scripts/sccache-assert.sh (which drives a local systemd-user unit that
  # does not exist on this remote): assert once, restart-once on failure
  # via a plain `sccache --stop-server && --start-server` (self-contained,
  # no sudo, no unit), assert again, else refuse before $first ever runs.
  local remote_cmd="cd $remote_path && export PATH=/root/.cargo/bin:/root/.local/bin:\$PATH CARGO_HOME=\${CARGO_HOME:-\$HOME/.cargo} CARGO_TARGET_DIR=$remote_path/target RUSTC_WRAPPER=sccache SCCACHE_DIR=/root/.sccache; timeout 5 sccache --show-stats >/dev/null 2>&1 || { sccache --stop-server >/dev/null 2>&1; sccache --start-server >/dev/null 2>&1; sleep 1; }; timeout 5 sccache --show-stats >/dev/null 2>&1 || { echo 'burst-lane: sccache_unreachable on remote box' >&2; exit 97; }; $first $*"
  local rc=0
  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "$remote_cmd" || rc=$?
  t_remote_end="$(now_fractional)"

  # Remote 127/126 = the command or its interpreter is missing ON THE BOX —
  # an infra failure of this lane, never a result of the caller's tests.
  # Report fallback (exit 3) so shims re-run locally; a missing remote binary
  # must never masquerade as a red test suite (2026-09-09: 14 "routed" runs
  # were all exit=127 and nobody noticed until the journal was read). Remote
  # 97 = the sccache-unreachable guard above refused before $first ran —
  # same fallback treatment, never a compile run against a server that
  # never answered.
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    journal_line "$(now_iso)  burst-lane  run  infra-fail  (server_id=$id worktree=$worktree remote_rc=$rc cmd=$first — falling back local)"
    echo "fallback: remote $first not runnable on box (rc=$rc)"
    exit 3
  fi
  if [ "$rc" -eq 97 ]; then
    journal_line "$(now_iso)  burst-lane  run  sccache-unreachable  (server_id=$id worktree=$worktree cmd=$first — falling back local)"
    echo "fallback: remote sccache did not answer after one restart attempt (rc=97)"
    exit 3
  fi

  # PRD-build-burst-pull-on-demand requirement 1: `run` no longer pulls
  # target/ (or .pybuilder/) back itself — it marks the worktree remote-dirty
  # and returns. The pull happens lazily, at whichever of the three points
  # (explicit `pull`, a local cargo consumer via `ensure-fresh`, or the
  # teardown sweep) actually needs the artifacts next. This is the whole
  # laziness: 19 of 21 pulls in the PRD's own baseline session sat between
  # two remote runs where nothing local ever read the worktree.
  local kind; kind="$([ "$first" = "uv" ] && echo pybuilder || echo target)"
  mark_dirty "$worktree" "$id" "$remote_path" "$kind"

  # Read-modify-write of session state back under the brief global lock.
  flock 201
  local runs; runs="$(state_read runs_served)"; runs=$((runs + 1))
  state_write "server_id=$id" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$runs" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" "verified=$(state_read verified)" \
    "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)"

  # Requirement 13: attribute this run to a PRD slug for the cost ledger.
  # Callers that know their own slug (branch/gate dispatch) should export
  # BURST_LANE_PRD_SLUG; otherwise fall back to the worktree's own basename
  # (worktree-extend.sh's own <repo>-<slug> convention), which is still a
  # useful, human-readable attribution even when not a bare PRD slug.
  local served_id="${BURST_LANE_PRD_SLUG:-$(basename "$worktree")}"
  if [ -n "$served_id" ]; then
    grep -qxF "$served_id" "$SERVED_FILE" 2>/dev/null || echo "$served_id" >> "$SERVED_FILE"
  fi

  # PRD-build-cost-attribution requirement 1: attribute this completed run
  # to a PRD slug in the attribution ledger (independent of, and finer-
  # grained than, requirement 13's prds_served roster above — that roster
  # is a per-session dedup list; this ledger is a per-run cost record).
  # PRD-build-burst-pull-on-demand requirement 5: since the pull itself is
  # now always skipped here, this row always carries pulls_skipped=1 and an
  # ESTIMATED bytes_saved (the worktree's last actually-observed pull size,
  # or 0 the first time anything ever ran against it) — never a claimed
  # exact figure for a transfer that didn't happen. sync_s is now upload-only
  # (no download occurred); "bytes" is 0 for the same reason.
  local wall_s sync_s slug bytes_saved
  wall_s="$(awk -v a="$t_remote_end" -v b="$t_up_end" 'BEGIN{printf "%.3f", a-b}')"
  sync_s="$(awk -v u0="$t_up_start" -v u1="$t_up_end" 'BEGIN{printf "%.3f", u1-u0}')"
  # PRD-build-gate-cargo-route-attest requirement 6: a caller that knows its
  # own cost-attribution slug (the gate dispatch, exporting BURST_LANE_PRD_SLUG
  # exactly as it already does for served_id above) wins over the worktree-
  # basename guess — a gate's main checkout is never a <repo>-<slug>
  # worktree, so attribution_slug_for() alone would always misattribute a
  # gate's own cargo cost as "unattributed" or the bare repo name.
  slug="${BURST_LANE_PRD_SLUG:-$(attribution_slug_for "$worktree")}"
  bytes_saved="$(last_pull_size "$worktree")"
  attribution_record "$slug" "$id" "$wall_s" "$sync_s" 0 "$worktree" run 1 "$bytes_saved" true

  flock -u 201

  journal_line "$(now_iso)  burst-lane  run  routed  (server_id=$id worktree=$worktree runs_served=$runs exit=$rc dirty=1 kind=$kind bytes_saved=$bytes_saved slug=$slug wall_s=$wall_s concurrent=$slot_held)"
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
  # PRD-build-burst-pull-on-demand: sync-back is a real pull — it must not
  # leave a stale dirty marker behind claiming target/ is still ahead.
  record_pull_size "$worktree" "${bytes:-0}"
  clear_dirty "$worktree"
  journal_line "$(now_iso)  burst-lane  sync-back  ok  (worktree=$worktree bytes=$bytes)"
  echo "synced: bytes=$bytes"
  exit 0
}

# ---- pull (PRD-build-burst-pull-on-demand requirement 3, explicit) ----------
# Forces a pull and clears the marker. Requirement 6: refuses (rc4, named
# error, no rsync) rather than blocking if the worktree's lock is currently
# held by a live `run` — an explicit pull racing a live compile must never
# interleave rsync with it.
cmd_pull() {
  local worktree="${1:-}"
  [ -n "$worktree" ] && [ -d "$worktree" ] || { echo "usage: burst-lane.sh pull <worktree>" >&2; exit 2; }
  mkdir -p "$STATE_DIR/locks" 2>/dev/null || true
  exec 205>"$(wt_lock_file "$worktree")"
  if ! flock -n 205; then
    journal_line "$(now_iso)  burst-lane  pull  refused  (worktree=$worktree cause=worktree-busy — a live run holds this worktree's lock)"
    echo "refused: worktree busy (live run in progress)" >&2
    exit 4
  fi
  if ! is_dirty "$worktree"; then
    flock -u 205
    echo "clean: nothing to pull"
    exit 0
  fi
  if do_marker_pull "$worktree" explicit; then
    flock -u 205
    echo "pulled"
    exit 0
  fi
  flock -u 205
  echo "fallback: pull failed"
  exit 3
}

# ---- parity (PRD-build-gate-on-casper requirement 2) ------------------------
# Parses a `cargo test --workspace --no-fail-fast` log (real or fake — the
# offline selftest arms a fake `cargo` on $PATH that emits this exact shape,
# so this parser is exercised authentically rather than against canned JSON)
# into {"<crate>::<source-path>": "ok"|"FAILED", ...}. A "Running [unittests]
# <path> (target/.../deps/<bin>-<16-hex-hash>)" line opens a suite; a
# "Doc-tests <crate>" line opens a doctest pseudo-suite; the next
# "test result: (ok|FAILED)." line closes whichever is currently open.
cargo_test_suites_json() {  # stdin=log -> stdout JSON object
  python3 -c '
import json, re, sys
running_re = re.compile(r"Running\s+(?:unittests\s+)?(\S+)\s+\(target/[^)]*?/deps/([A-Za-z0-9_.\-]+)-[0-9a-f]{16}\)")
doctest_re = re.compile(r"Doc-tests\s+(\S+)")
result_re = re.compile(r"test result:\s*(ok|FAILED)\.")
suites = {}
current = None
for line in sys.stdin:
    m = running_re.search(line)
    if m:
        current = "%s::%s" % (m.group(2), m.group(1))
        continue
    m = doctest_re.search(line)
    if m:
        current = "%s::doctests" % m.group(1)
        continue
    m = result_re.search(line)
    if m and current:
        suites[current] = m.group(1)
        current = None
print(json.dumps(suites))
'
}

cmd_parity() {
  local repo="${1:-}"
  [ -n "$repo" ] && [ -d "$repo" ] || { echo "usage: burst-lane.sh parity <repo>" >&2; exit 2; }

  if ! state_active; then
    local up_out; up_out="$(cmd_up 2>&1)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      echo "$up_out"
      exit 3
    fi
  fi
  local id ip; id="$(state_read server_id)"; ip="$(state_read ip)"

  local head_sha; head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head_sha" ] || { echo "fallback: could not resolve HEAD for $repo"; journal_line "$(now_iso)  burst-lane  parity  fallback  (cause=no-head repo=$repo)"; exit 3; }

  # Serialize against a live `run`/`parity` on the SAME worktree — same lock
  # `run`/`pull` already use, so a parity rsync-up never interleaves with a
  # live compile's own rsync of the same remote dir.
  mkdir -p "$STATE_DIR/locks" 2>/dev/null || true
  exec 206>"$(wt_lock_file "$repo")"
  flock 206

  local remote_path; remote_path="$(remote_path_for "$repo")"
  mkdir -p "$STATE_DIR/logs" 2>/dev/null || true
  local up_log="$STATE_DIR/logs/rsync-parity.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$repo/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    flock -u 206
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line "$(now_iso)  burst-lane  parity  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" repo=$repo)"
    echo "fallback: rsync to $ip failed rc=$rsync_up_rc (see $up_log)"
    exit 3
  fi

  local box_log; box_log="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "cd $remote_path && export PATH=/root/.cargo/bin:/root/.local/bin:\$PATH CARGO_TARGET_DIR=$remote_path/target; cargo test --workspace --no-fail-fast" 2>&1)"
  flock -u 206
  local box_suites; box_suites="$(printf '%s\n' "$box_log" | cargo_test_suites_json)"

  local local_log_file="$repo/target/autobuilder/test-output.txt" local_log
  if [ -f "$local_log_file" ]; then
    local_log="$(cat "$local_log_file")"
  else
    mkdir -p "$(dirname "$local_log_file")" 2>/dev/null || true
    local_log="$(cd "$repo" && cargo test --workspace --no-fail-fast 2>&1)"
    printf '%s\n' "$local_log" > "$local_log_file"
  fi
  local local_suites; local_suites="$(printf '%s\n' "$local_log" | cargo_test_suites_json)"

  mkdir -p "$repo/target/autobuilder/receipts" 2>/dev/null || true
  local parity_file="$repo/target/autobuilder/receipts/box-parity.json"
  local diff_json status_word
  diff_json="$(python3 -c '
import json, sys
box = json.loads(sys.argv[1])
local = json.loads(sys.argv[2])
names = sorted(set(box) | set(local))
suites = {}
diff = []
for n in names:
    b, l = box.get(n), local.get(n)
    suites[n] = {"box": b, "local": l}
    if b != l:
        diff.append(n)
print(json.dumps({"suites": suites, "diff": diff}))
' "$box_suites" "$local_suites")"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
out = {"head_sha": sys.argv[2], "box_host": sys.argv[3], "suites": d["suites"], "diff": d["diff"]}
json.dump(out, open(sys.argv[4], "w"), indent=2)
' "$diff_json" "$head_sha" "$ip" "$parity_file"

  local diff_count; diff_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["diff"]))' "$diff_json")"
  if [ "$diff_count" -eq 0 ]; then status_word="ok"; else status_word="diff"; fi
  journal_line "$(now_iso)  burst-lane  parity  $status_word  (repo=$repo head=$head_sha box=$ip diff=$diff_count)"
  echo "parity: $status_word (diff=$diff_count) — $parity_file"
  exit 0
}

# ---- gate (PRD-build-gate-on-casper requirement 3 — STUB) -------------------
# Only requirement 5's fallback contract is wired so far: refuses to route
# (exit 3, "fallback: parity-diff|parity-unknown") unless `parity` has
# already recorded a clean receipt AT THE REPO'S CURRENT HEAD — the parity
# receipt lives inside the repo itself (target/autobuilder/receipts/
# box-parity.json, written by cmd_parity above), so this check needs no
# separate session-state field: a repo's own receipts tree is already the
# single source of truth extend-gate.sh's other producers read. The actual
# remote invocation (rsync repo up, run extend-gate.sh on the box, rsync
# receipts back, propagate the exit code) is requirement 3 and NOT yet
# implemented — see the PRD's own requirement list.
cmd_gate() {
  local repo="${1:-}"
  [ -n "$repo" ] && [ -d "$repo" ] || { echo "usage: burst-lane.sh gate <repo> --head <sha> [extend-gate args...]" >&2; exit 2; }
  shift || true

  local head_now; head_now="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  local parity_file="$repo/target/autobuilder/receipts/box-parity.json"
  local cause=""
  if [ ! -f "$parity_file" ]; then
    cause="parity-unknown"
  else
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("head_sha") == sys.argv[2] and d.get("diff") == [] else 1)
' "$parity_file" "$head_now" || cause="parity-diff"
  fi
  if [ -n "$cause" ]; then
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=$cause repo=$repo head=$head_now)"
    echo "fallback: $cause"
    exit 3
  fi

  echo "gate: parity clean at head=$head_now — remote invocation not yet implemented (PRD-build-gate-on-casper requirement 3)" >&2
  exit 2
}

# ---- ensure-fresh (PRD-build-burst-pull-on-demand requirement 2) -----------
# The single invariant every local cargo/test consumer must go through
# before touching a worktree: dirty -> pull (blocking on the worktree lock —
# a live run finishing first is the correct wait here, unlike the explicit
# `pull` command's non-blocking refusal), clear marker, then the caller
# proceeds. Clean (or no marker at all) is a fast, lock-free no-op. Called
# from burst-lane-bin/cargo's and cargo-budget-bin/cargo's local-fallback
# paths, and from extend-gate.sh's cargo_budgeted() (the gate harness's own
# choke point for every producer's cargo, including extended-receipts.sh's
# 17). Never blocks the caller on infra trouble — a failed pull here still
# exits 0 so a build-skill invocation never turns "no pull yet" into "no
# build at all"; the caller simply runs against whatever's on disk.
cmd_ensure_fresh() {
  local worktree="${1:-}"
  [ -n "$worktree" ] && [ -d "$worktree" ] || { echo "usage: burst-lane.sh ensure-fresh <worktree>" >&2; exit 2; }
  if ! is_dirty "$worktree"; then
    echo "clean"
    exit 0
  fi
  mkdir -p "$STATE_DIR/locks" 2>/dev/null || true
  exec 204>"$(wt_lock_file "$worktree")"
  flock 204
  if ! is_dirty "$worktree"; then
    flock -u 204
    echo "clean"
    exit 0
  fi
  do_marker_pull "$worktree" local-read
  flock -u 204
  echo "ensured"
  exit 0
}

# ---- teardown sweep (PRD-build-burst-pull-on-demand requirement 4) ---------
# Every dirty marker on disk — not just this session's own — gets one pull
# attempt before a box is destroyed (down's delete path, watchdog's TTL
# teardown). A marker from a session that already died some other way (crash,
# a teardown that skipped the sweep) is exactly what do_marker_pull's "cold"
# path exists for: it finds no active session (or a session whose IP no
# longer serves that remote_path) and clears the marker rather than leaving
# it dirty forever. A worktree whose lock is currently held (a live run
# still in flight right as the box is about to die) is left alone and
# journaled — never aborts the rest of the sweep.
sweep_dirty_worktrees() {  # $1=caller (down|watchdog)
  mkdir -p "$DIRTY_DIR" "$STATE_DIR/locks" 2>/dev/null || true
  local f wt
  for f in "$DIRTY_DIR"/*.json; do
    [ -e "$f" ] || continue
    wt="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("worktree", ""))
except Exception:
    print("")
' "$f" 2>/dev/null)"
    if [ -z "$wt" ]; then
      rm -f "$f"
      continue
    fi
    if ( exec 206>"$(wt_lock_file "$wt")"; flock -n 206 && do_marker_pull "$wt" teardown ); then
      :
    else
      journal_line "$(now_iso)  burst-lane  ${1:-down}  sweep-failed  (worktree=$wt — busy or pull failed; marker left in place, sweep continues)"
    fi
  done
}

# ---- reap (PRD-build-burst-remote-disk-guard requirement 5) -----------------
# A remote build dir dies with its worktree: `reap` lists $REMOTE_ROOT's
# immediate children, decodes each `<basename>-<sha1[0:8]>` (the same
# scheme remote_path_for()/dirty_marker_file() already use — the sha1
# prefix in a dir name and a dirty marker's filename are the SAME key for
# the SAME worktree, so "is this dir dirty" is a direct DIRTY_DIR/<hash>.json
# lookup, never a re-decode) against the local worktree roots this lane
# knows, and deletes any dir with no live local worktree behind it. The
# shared checkout(s) in BURST_REAP_KEEP (default "mcphost" — the
# pre-remote_path_for() legacy layout requirement 7 carries forward) are
# always protected, hashed or not.
REAP_KEEP="${BURST_REAP_KEEP:-mcphost}"

# Local roots a worktree basename is looked up under, per requirement 5:
# worktree-extend.sh's own wt_path convention, the off-root scratch root,
# and the shared-checkout root attribution_slug_for() already trusts
# ($ATTR_REPOS_DIR). A worktree living outside all three is still found —
# reap_plan() below also consults every worktree path a dirty marker or an
# attribution row has ever recorded, so nothing this lane has ever touched
# needs a fourth hardcoded root.
reap_candidate_roots() {
  printf '%s\n' "$HOME/.cache/build-worktrees" "/mnt/data/jsy/tmp" "$ATTR_REPOS_DIR"
}

# $1 = newline-separated "<mtime_epoch>\t<basename>" listing (oldest first)
# on stdin -> stdout one "<basename>\t<action>\t<reason>\t<worktree>" row per
# entry (action: keep|dirty|live|orphan). Pure classification — no ssh, no
# deletion; reap_orphans() below executes the plan.
reap_plan() {
  python3 -c '
import sys, os, re, hashlib, json

keep = set(sys.argv[1].split())
roots = [r for r in sys.argv[2].split("\n") if r]
dirty_dir = sys.argv[3]
attr_ledger = sys.argv[4]

def hash8(p):
    return hashlib.sha1(p.encode()).hexdigest()[:8]

extra_paths = set()
try:
    for fn in os.listdir(dirty_dir):
        if not fn.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(dirty_dir, fn)))
        except Exception:
            continue
        w = d.get("worktree", "")
        if w:
            extra_paths.add(w)
except OSError:
    pass
try:
    with open(attr_ledger) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            w = d.get("worktree", "")
            if w:
                extra_paths.add(w)
except OSError:
    pass

pat = re.compile(r"^(.*)-([0-9a-f]{8})$")
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    parts = raw.split("\t", 1)
    if len(parts) != 2:
        continue
    _mtime, name = parts
    if name in keep:
        print("%s\tkeep\tkeep-listed\t" % name)
        continue
    m = pat.match(name)
    if m:
        base, h = m.group(1), m.group(2)
        marker = os.path.join(dirty_dir, h + ".json")
        if os.path.exists(marker) and os.path.getsize(marker) > 0:
            print("%s\tdirty\tdirty-marker\t" % name)
            continue
        found = None
        for root in roots:
            cand = os.path.join(root, base)
            if hash8(cand) == h:
                found = cand
                break
        if not found:
            for w in extra_paths:
                if os.path.basename(w) == base and hash8(w) == h:
                    found = w
                    break
        if found and os.path.isdir(found):
            print("%s\tlive\tworktree-present\t%s" % (name, found))
        elif found:
            print("%s\torphan\tworktree-gone\t%s" % (name, found))
        else:
            print("%s\torphan\tno-local-match\t" % name)
    else:
        # Legacy un-hashed dir (requirement 7): live iff some known root
        # still has a directory of that exact basename.
        found = None
        for root in roots:
            cand = os.path.join(root, name)
            if os.path.isdir(cand):
                found = cand
                break
        if found:
            print("%s\tlive\tworktree-present\t%s" % (name, found))
        else:
            print("%s\torphan\tlegacy-no-local-match\t" % name)
' "$REAP_KEEP" "$(reap_candidate_roots)" "$DIRTY_DIR" "$ATTR_LEDGER"
}

# Executes reap_plan()'s decisions against the live box: deletes each orphan
# (skipping one whose worktree lock is currently held — a live run in
# flight on a not-yet-dirty-marked worktree, requirement 5's other named
# protection besides the dirty marker itself), journals every ok/skip/fail
# as plain "burst-lane reap <ok|skip|fail>" lines (same shape whether called
# standalone or from down/watchdog below), never aborts on a single failure
# (requirement 6). Always exits 0 to its caller — a reap trouble is
# journaled, never fatal.
reap_orphans() {
  local reaped_dirs=0 reaped_bytes=0
  mkdir -p "$DIRTY_DIR" "$STATE_DIR/locks" 2>/dev/null || true
  if ! state_active; then
    echo "reaped_dirs=0 reaped_bytes=0"
    return 0
  fi
  local ip; ip="$(state_read ip)"
  # -not -name '.*' excludes the lane's own infrastructure dirs (e.g.
  # cmd_verify's .verify-fixture roundtrip probe) — never a worktree
  # remnant, so never orphan-eligible.
  local list_cmd="find '$REMOTE_ROOT' -mindepth 1 -maxdepth 1 -not -name '.*' -printf '%T@\t%f\n' 2>/dev/null"
  local list_out list_rc=0
  list_out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
      "$REMOTE_USER@$ip" "$list_cmd" 2>/dev/null)" || list_rc=$?
  if [ "$list_rc" -ne 0 ]; then
    journal_line "$(now_iso)  burst-lane  reap  fail  (cause=ssh rc=$list_rc)"
    echo "reaped_dirs=0 reaped_bytes=0"
    return 0
  fi
  if [ -z "$list_out" ]; then
    echo "reaped_dirs=0 reaped_bytes=0"
    return 0
  fi

  local plan; plan="$(printf '%s\n' "$list_out" | sort -n | reap_plan)"
  local name action reason wt
  while IFS=$'\t' read -r name action reason wt; do
    [ -n "$name" ] || continue
    case "$action" in
      keep)  journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=keep)" ;;
      dirty) journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=dirty)" ;;
      live)  : ;;  # untouched, no journal noise on every healthy pass
      orphan)
        local busy=0
        if [ -n "$wt" ] && ! ( exec 207>"$(wt_lock_file "$wt")"; flock -n 207 ); then
          busy=1
        fi
        if [ "$busy" -eq 1 ]; then
          journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=busy)"
          continue
        fi
        local bytes
        bytes="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
            "$REMOTE_USER@$ip" "du -sb '$REMOTE_ROOT/$name' 2>/dev/null | cut -f1" 2>/dev/null)"
        bytes="${bytes:-0}"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
             "$REMOTE_USER@$ip" "rm -rf '$REMOTE_ROOT/$name'" 2>/dev/null; then
          reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + bytes))
          journal_line "$(now_iso)  burst-lane  reap  ok  (dir=$name bytes=$bytes reason=$reason)"
        else
          journal_line "$(now_iso)  burst-lane  reap  fail  (dir=$name cause=rm-failed)"
        fi
        ;;
    esac
  done <<<"$plan"

  echo "reaped_dirs=$reaped_dirs reaped_bytes=$reaped_bytes"
  return 0
}

cmd_reap() {
  local out; out="$(reap_orphans)"
  echo "$out"
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
    # Operator (2026-09-09): the box serves python work too (req 12 / BURST_PY)
    # — keep it up while EITHER kind remains, matching the tick wrapper's `up`
    # predicate; a rust-only scan tore the box down under queued python PRDs.
    case "$bt" in rust-cli|rust-lib|rust-extend|python-cli|python-lib|python-agent) ;; *) continue ;; esac
    st="$(grep -m1 -oE '^-[[:space:]]*Status:[[:space:]]*[A-Za-z0-9_-]+' "$f" 2>/dev/null | sed -E 's/^-[[:space:]]*Status:[[:space:]]*//')"
    case "$st" in queued|building|in_progress) return 0 ;; esac
  done
  return 1
}

# ---- teardown (shared by down + watchdog) ------------------------------------
destroy_verify() {  # $1 = server id -> 0 on verified-gone, 1 on still-present after retries
  # AC14: `server delete` alone is the whole teardown — no separate
  # `hcloud primary-ip delete` call, because cmd_up's create never attaches a
  # standalone Primary IP (see the comment there). The ephemeral Primary IPv4
  # Hetzner auto-created with this server is owned by it and goes with it in
  # this same call, so no orphan IP survives to bill after teardown.
  local id="$1" attempt
  for attempt in 1 2 3; do
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    sleep 1
    if ! server_alive "$id"; then return 0; fi
  done
  return 1
}

ledger_append() {  # $1=hours $2=eur $3=session_id (PRD-build-cost-attribution,
                    # additive — old readers keying on hours/eur/prds are
                    # unaffected); reads $SERVED_FILE (requirement 13: PRD
                    # slugs this session served), one row per session
  python3 -c '
import json, sys
date, hours, eur, sid, served_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
prds = []
try:
    with open(served_path) as f:
        prds = [l.strip() for l in f if l.strip()]
except OSError:
    pass
row = {"date": date, "hours": float(hours), "eur": float(eur), "prds": prds}
if sid:
    row["session_id"] = sid
print(json.dumps(row))
' "$(now_iso)" "$1" "$2" "${3:-}" "$SERVED_FILE" >> "$COST_LEDGER"
}

# ---- teardown proration (PRD-build-cost-attribution requirement 2) ----------
# Sums $ATTR_LEDGER's rows by slug (across ALL session_ids currently sitting
# in the file — not just this teardown's own — so a crashed prior session's
# never-prorated rows roll into this teardown rather than being lost; see
# Technical considerations), prorates $3 (eur) across slugs by each slug's
# share of total attributed wall-seconds, and appends one `kind:"slug"` row
# per slug to $COST_LEDGER (additive — the existing session-total row this
# is called beside is untouched). The attribution ledger is cleared after a
# successful prorate (nothing left to double-count next teardown). Prints
# one `ORPHANED:<session_id>` line per OTHER session_id folded in, for the
# caller to journal by name. Exits 3 (nothing written, ledger left alone)
# if the file exists but can't be read — requirement 5 (P2): an unreadable
# attribution file is could-not-check, never silently zero cost.
prorate_attribution() {  # $1=this session_id $2=hours $3=eur $4=caller (down|watchdog)
  [ -s "$ATTR_LEDGER" ] || return 0
  local out rc
  out="$(python3 -c '
import json, sys, collections

sid, eur, date, attr_path, cost_path = sys.argv[1:6]
eur = float(eur)

try:
    with open(attr_path) as fh:
        lines = fh.readlines()
except OSError:
    print("COULD_NOT_CHECK")
    sys.exit(3)

by_slug = collections.OrderedDict()
sessions = set()
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    # PRD-build-burst-pull-on-demand requirement 7: a pull row own sync_s
    # is attributed to whichever slug triggered the read (do_marker_pull
    # already resolved teardown -> the literal slug teardown as a lane-
    # overhead bucket, rather than the reading worktree own PRD) - this is
    # what closes the ledger prior open question (prorate rsync time to
    # slugs, or hold as lane overhead): prorated, to the reader.
    slug = row.get("slug") or "unattributed"
    kind = row.get("kind", "run")
    by_slug.setdefault(slug, {
        "seconds": 0.0, "runs": 0, "pulls_skipped": 0, "bytes_saved": 0,
        "pulls_performed": 0, "bytes_pulled": 0,
    })
    v = by_slug[slug]
    if kind == "pull":
        v["seconds"] += float(row.get("sync_s", 0) or 0)
        v["pulls_performed"] += 1
        v["bytes_pulled"] += int(row.get("bytes", 0) or 0)
    else:
        v["seconds"] += float(row.get("wall_seconds", 0) or 0)
        v["runs"] += 1
        v["pulls_skipped"] += int(row.get("pulls_skipped", 0) or 0)
        v["bytes_saved"] += int(row.get("bytes_saved", 0) or 0)
    sessions.add(row.get("session_id", ""))

total_secs = sum(v["seconds"] for v in by_slug.values())
if total_secs > 0:
    slugs = sorted(by_slug.keys())
    running = 0.0
    out_rows = []
    for i, slug in enumerate(slugs):
        v = by_slug[slug]
        if i == len(slugs) - 1:
            slug_eur = eur - running
        else:
            slug_eur = round(eur * (v["seconds"] / total_secs), 6)
            running += slug_eur
        out_rows.append({
            "date": date, "session_id": sid, "kind": "slug", "slug": slug,
            "seconds": round(v["seconds"], 3), "runs": v["runs"], "eur": slug_eur,
            "pulls_skipped": v["pulls_skipped"], "bytes_saved": v["bytes_saved"],
            "pulls_performed": v["pulls_performed"], "bytes_pulled": v["bytes_pulled"],
        })
    with open(cost_path, "a") as fh:
        for row in out_rows:
            fh.write(json.dumps(row) + "\n")

for s in sessions:
    if s and s != sid:
        print("ORPHANED:" + s)
' "$1" "$3" "$(now_iso)" "$ATTR_LEDGER" "$COST_LEDGER")"
  rc=$?
  if [ "$rc" -eq 3 ] || [ "$out" = "COULD_NOT_CHECK" ]; then
    probe_emit burst-attribution could-not-check "attribution ledger unreadable at teardown ($ATTR_LEDGER)" >/dev/null
    journal_line "$(now_iso)  burst-lane  ${4:-down}  attribution-could-not-check  ($ATTR_LEDGER unreadable — cost NOT attributed to any slug this teardown)"
    return 3
  fi
  : > "$ATTR_LEDGER"
  probe_emit burst-attribution clean "prorated $3 eur across attribution rows for session $1" >/dev/null
  printf '%s\n' "$out"
  return 0
}

# ---- daily rollup (PRD-build-cost-attribution requirement 4) ----------------
# Cursor-guarded so N `down` calls the same UTC day emit exactly one line —
# into the TICK journal ($TICK_JOURNAL_DIR/<date>.md), not this script's own
# $JOURNAL flat log. Reads TODAY's kind:"slug" rows from cost.jsonl (written
# by prorate_attribution above, so this only ever reports slugs that have
# actually torn down at least once today) and picks the top slug by eur.
# A day with no slug rows yet (no teardown has happened today) is a no-op —
# nothing to roll up, cursor not advanced, so the line still lands once a
# teardown does happen later today.
maybe_daily_rollup() {
  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  local last; last="$(cat "$ROLLUP_CURSOR" 2>/dev/null || true)"
  [ "$last" = "$today" ] && return 0
  [ -f "$COST_LEDGER" ] || return 0

  local line
  line="$(python3 -c '
import json, sys, collections

today, path = sys.argv[1], sys.argv[2]
totals = collections.OrderedDict()
pulls_skipped_total = 0
bytes_saved_total = 0
for ln in open(path):
    ln = ln.strip()
    if not ln:
        continue
    try:
        d = json.loads(ln)
    except ValueError:
        continue
    if d.get("kind") != "slug" or not str(d.get("date", "")).startswith(today):
        continue
    s = d.get("slug", "unattributed")
    totals[s] = totals.get(s, 0.0) + float(d.get("eur", 0) or 0)
    # PRD-build-burst-pull-on-demand requirement 5/8: the yield (pulls
    # skipped, GB saved) belongs in the same once-a-day line as the cost —
    # "readable in one place", not a number scattered across journal greps.
    pulls_skipped_total += int(d.get("pulls_skipped", 0) or 0)
    bytes_saved_total += int(d.get("bytes_saved", 0) or 0)

if not totals:
    sys.exit(1)

grand = sum(totals.values())
top_slug, top_eur = max(totals.items(), key=lambda kv: kv[1])
gb_saved = bytes_saved_total / (1024.0 ** 3)
print("burst-cost: %.4f across %d slugs; top %s %.4f; pulls skipped %d, saved ~%.2f GB" %
      (grand, len(totals), top_slug, top_eur, pulls_skipped_total, gb_saved))
' "$today" "$COST_LEDGER")" || return 0

  # PRD-build-burst-remote-disk-guard requirement 8: fold today's reap yield
  # and disk-low fallback count into the same once-a-day line — these live
  # in THIS script's own flat $JOURNAL (reap_orphans/cmd_run's own lines),
  # not the cost ledger the block above reads, so they're pulled from there
  # instead of taught to cost.jsonl.
  local reap_stats reaped_dirs reaped_bytes disk_low reaped_gb
  reap_stats="$(python3 -c '
import re, sys
today, path = sys.argv[1], sys.argv[2]
dirs = 0
total_bytes = 0
low = 0
try:
    with open(path) as fh:
        for ln in fh:
            if not ln.startswith(today):
                continue
            if "burst-lane  reap  ok" in ln:
                dirs += 1
                m = re.search(r"bytes=(\d+)", ln)
                if m:
                    total_bytes += int(m.group(1))
            elif "burst-lane  run  fallback" in ln and "cause=disk-low" in ln:
                low += 1
except OSError:
    pass
print(dirs, total_bytes, low)
' "$today" "$JOURNAL")"
  read -r reaped_dirs reaped_bytes disk_low <<<"$reap_stats"
  reaped_gb="$(awk -v b="${reaped_bytes:-0}" 'BEGIN{printf "%.0f", b/1073741824}')"
  line="$line reaped_dirs=${reaped_dirs:-0} reaped_gb=${reaped_gb:-0} disk_low_fallbacks=${disk_low:-0}"

  mkdir -p "$TICK_JOURNAL_DIR" 2>/dev/null || true
  printf '%s\n' "$line" >> "$TICK_JOURNAL_DIR/$today.md"
  printf '%s\n' "$today" > "$ROLLUP_CURSOR"
}

# ---- down ---------------------------------------------------------------------
cmd_down() {
  local more_work=0
  [ "${1:-}" = "--more-work-queued" ] && more_work=1

  # PRD-build-cost-attribution requirement 4: cursor-guarded, so this is a
  # no-op after the first `down` call of the UTC day — independent of
  # today's keep/scheduled/deleted decision below, since the wrapper may
  # call `down` many times a day but the rollup line must land exactly once.
  maybe_daily_rollup

  if ! state_active; then
    echo "no-active-session"
    exit 0
  fi

  local id boot_epoch; id="$(state_read server_id)"; boot_epoch="$(state_read boot_epoch)"

  # PRD-build-burst-remote-disk-guard requirement 6: reap runs on every
  # `down` call, before the keep/scheduled/deleted decision below — disk
  # hygiene does not wait for a box that is about to die anyway (goal 2:
  # "reaped on the next down or watchdog pass"). Never blocks/aborts the
  # decision that follows; a reap trouble (ssh down, rm error) is only ever
  # journaled by reap_orphans itself.
  reap_orphans >/dev/null 2>&1 || true

  if rust_work_remains || [ "$more_work" -eq 1 ]; then
    if [ "$(state_read teardown_scheduled)" = "true" ]; then
      state_write "server_id=$id" "ip=$(state_read ip)" "server_type=$(state_read server_type)" \
        "boot_ts=$(state_read boot_ts)" "boot_epoch=$boot_epoch" "ttl_hours=$(state_read ttl_hours)" \
        "hard_ttl_hours=$(state_read hard_ttl_hours)" "runs_served=$(state_read runs_served)" \
        "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=false" "teardown_epoch=" "verified=$(state_read verified)" \
        "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)"
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
    # PRD-build-burst-pull-on-demand requirement 4: every still-dirty
    # worktree gets pulled (or goes cold) before the box that would strand
    # its artifacts is destroyed. Never blocks/aborts the teardown itself.
    sweep_dirty_worktrees down
    if destroy_verify "$id"; then
      local hrs; hrs="$(awk -v m="$alive" 'BEGIN{printf "%.4f", m/60.0}')"
      local eur; eur="$(awk -v h="$hrs" -v r="$COST_PER_HOUR_EUR" 'BEGIN{printf "%.4f", h*r}')"
      local served; served="$( [ -f "$SERVED_FILE" ] && paste -sd, "$SERVED_FILE" 2>/dev/null || true)"
      # PRD-build-cost-attribution requirement 2: prorate this session's
      # cost across the slugs that were actually attributed to it (plus any
      # orphaned rows a crashed prior session left behind — named below).
      # Runs BEFORE ledger_append so the session-total row this teardown
      # writes stays the LAST line in cost.jsonl (existing readers of
      # requirement 13's row assume that positionally, e.g. "the row I just
      # wrote is the tail").
      local prorate_out orphan_sid
      prorate_out="$(prorate_attribution "$id" "$hrs" "$eur" down)" || true
      while IFS= read -r orphan_sid; do
        case "$orphan_sid" in
          ORPHANED:*)
            journal_line "$(now_iso)  burst-lane  down  attribution-orphan-included  (session_id=${orphan_sid#ORPHANED:} — crashed prior session's rows folded into this teardown's proration)"
            ;;
        esac
      done <<<"$prorate_out"
      ledger_append "$hrs" "$eur" "$id"
      journal_line "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id minutes=$alive cost_eur=$eur prds=${served:-none})"
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
    "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=true" "teardown_epoch=$window_start" "verified=$(state_read verified)" \
    "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)"
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
  # PRD-build-burst-remote-disk-guard requirement 6: same as `down` — reap
  # runs on every watchdog pass, before the due/not-due decision, never
  # blocking it.
  reap_orphans >/dev/null 2>&1 || true

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
  # PRD-build-burst-pull-on-demand requirement 4: same sweep as `down`'s
  # delete path — the watchdog is a teardown path too and must not strand
  # artifacts either.
  sweep_dirty_worktrees watchdog
  if destroy_verify "$id"; then
    local hrs eur
    hrs="$(awk -v m="$alive" 'BEGIN{printf "%.4f", m/60.0}')"
    eur="$(awk -v h="$hrs" -v r="$COST_PER_HOUR_EUR" 'BEGIN{printf "%.4f", h*r}')"
    local served; served="$( [ -f "$SERVED_FILE" ] && paste -sd, "$SERVED_FILE" 2>/dev/null || true)"
    # See cmd_down's matching comment: prorate BEFORE ledger_append so the
    # session-total row stays the last line in cost.jsonl.
    local prorate_out orphan_sid
    prorate_out="$(prorate_attribution "$id" "$hrs" "$eur" watchdog)" || true
    while IFS= read -r orphan_sid; do
      case "$orphan_sid" in
        ORPHANED:*)
          journal_line "$(now_iso)  burst-lane  watchdog  attribution-orphan-included  (session_id=${orphan_sid#ORPHANED:} — crashed prior session's rows folded into this teardown's proration)"
          ;;
      esac
    done <<<"$prorate_out"
    ledger_append "$hrs" "$eur" "$id"
    journal_line "$(now_iso)  burst-lane  watchdog  teardown  (server_id=$id uptime=${alive}m cost_eur=$eur prds=${served:-none})"
    state_clear
    echo "watchdog teardown: $id (${alive}m)"
    exit 0
  fi
  journal_line "$(now_iso)  burst-lane  watchdog  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
  echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
  exit 1
}

# ---- sub-cap (requirement 7 formula) -----------------------------------------
# Probes the box's available memory, core count, and (PRD-build-burst-
# remote-disk-guard requirement 1) free root disk over ssh in one round
# trip. The `\$2`/`\$(...)` inside the single-quoted remote_cmd are deliberately
# unescaped from THIS script's perspective (single quotes suppress local
# expansion) so they evaluate on the remote shell, matching the pattern
# `run`'s own remote_cmd construction already uses. `$REMOTE_ROOT` is a
# LOCAL var and is deliberately interpolated into the (otherwise
# remote-evaluated) command string — the box always builds into
# `$remote_path/target` under `$REMOTE_ROOT` (cmd_run pins
# CARGO_TARGET_DIR there regardless of any off-root `.cargo/config.toml`
# override — see pull_target_incremental's own comment), so `$REMOTE_ROOT`'s
# filesystem is the one that actually fills up; a second df round trip
# against a worktree's off-root target-dir would probe a path the remote
# box never writes to.
probe_remote_capacity() {  # $1 = ip -> stdout "avail_gb nproc free_disk_gb"; rc 1 on failure
  local ip="$1" out
  local remote_cmd='avail_kb=$(grep MemAvailable /proc/meminfo | awk "{print \$2}"); disk_gb=$(df -BG --output=avail '"$REMOTE_ROOT"' 2>/dev/null | tail -n1 | tr -dc "0-9"); echo $((avail_kb/1024/1024)) $(nproc) ${disk_gb:-}'
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
    probe_emit burst-subcap clean "no session — local cap applies" >/dev/null
    journal_line "$(now_iso)  burst-lane  sub-cap  no-session  (local=3, fallback rules apply)"
    echo "sub-cap=0 local=3 (no session — local cap applies)"
    exit 0
  fi

  # Requirement 6 / AC5: a session whose sandbox check failed at `up` never
  # gets its box-computed width honored here — the tick's rust selection
  # falls back to a local cap of 2 (a lower, more conservative fallback than
  # the no-session cap of 3, since a sandbox-unverified box still might not
  # be safe for the sandboxed suites that share the tick). Printed as
  # `sub-cap=2` (not `local=2`) so effective_subcap's existing `sub-cap=<n>`
  # parse picks it up as the cap directly, with no separate wiring needed.
  if [ "$(state_read sandbox_ok)" = "false" ]; then
    probe_emit burst-subcap dirty "sandbox unavailable — local cap 2 applies this tick" >/dev/null
    journal_line "$(now_iso)  burst-lane  sub-cap  sandbox-unavailable  (server_id=$(state_read server_id) local cap=2 this tick)"
    echo "sub-cap=2 local=0 (sandbox unavailable — falling back to local cap 2 this tick)"
    exit 0
  fi

  local ip; ip="$(state_read ip)"
  local probe
  if ! probe="$(probe_remote_capacity "$ip")"; then
    probe_emit burst-subcap could-not-check "capacity probe failed server_id=$(state_read server_id)" >/dev/null
    journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=probe-failed server_id=$(state_read server_id))"
    echo "fallback: could not probe box capacity"
    exit 3
  fi
  local avail_gb nproc_n free_disk_gb
  read -r avail_gb nproc_n free_disk_gb <<<"$probe"
  case "$avail_gb" in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac
  case "$nproc_n"  in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac
  # PRD-build-burst-remote-disk-guard requirement 1: a probe missing the
  # third (disk) field is the same bad-probe-output fallback as a missing
  # mem/cpu field — never a silently-skipped disk check.
  case "$free_disk_gb" in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac

  local gb_per="${BURST_GB_PER_BRANCH:-6}" cores_per="${BURST_CORES_PER_BRANCH:-4}"
  # PRD-build-burst-remote-disk-guard requirement 2: disk floor folded into
  # the same min() the memory/cpu terms already go through — a box below
  # BURST_DISK_FLOOR_GB (default 40, headroom below which sccache/rustc
  # scratch and the next few branches' pulls have nowhere to land) admits
  # zero more branches, same effective width as a bad/no-session probe.
  local disk_floor="${BURST_DISK_FLOOR_GB:-40}" disk_per="${BURST_GB_DISK_PER_BRANCH:-70}"
  local by_mem=$(( avail_gb / gb_per )) by_cpu=$(( nproc_n / cores_per ))
  local by_disk=$(( (free_disk_gb - disk_floor) / disk_per ))
  [ "$by_disk" -lt 0 ] && by_disk=0
  local subcap=$by_mem bound="mem"
  if [ "$by_cpu" -lt "$subcap" ]; then subcap=$by_cpu; bound="cpu"; fi
  if [ "$by_disk" -lt "$subcap" ]; then subcap=$by_disk; bound="disk"; fi
  if [ "$candidates" -gt 0 ] && [ "$candidates" -lt "$subcap" ]; then subcap=$candidates; bound="candidates"; fi

  local bound_suffix=""
  [ "$bound" = "disk" ] && bound_suffix=" bound=disk"

  probe_emit burst-subcap clean "sub-cap=$subcap (avail_gb=$avail_gb nproc=$nproc_n free_disk_gb=$free_disk_gb)" >/dev/null
  journal_line "$(now_iso)  burst-lane  sub-cap  computed  (burst: sub-cap=$subcap (avail_gb=$avail_gb nproc=$nproc_n free_disk_gb=$free_disk_gb)${bound_suffix} local=0)"
  echo "sub-cap=$subcap local=0 (avail_gb=$avail_gb nproc=$nproc_n free_disk_gb=$free_disk_gb)${bound_suffix}"
  exit 0
}

# ---- cost -------------------------------------------------------------------
cmd_cost() {
  if [ "${1:-}" = "--by-prd" ]; then
    shift
    cmd_cost_by_prd "$@"
    return $?
  fi
  [ "${1:-}" = "--today" ] || { echo "usage: burst-lane.sh cost --today | cost --by-prd [--today|--session <id>]" >&2; exit 2; }
  [ -f "$COST_LEDGER" ] || { echo "hours=0.00 eur=0.00"; exit 0; }
  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  python3 -c '
import json, sys
today, path = sys.argv[1], sys.argv[2]
hours = eur = 0.0
prds = []
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    # Requirement 2/3 (PRD-build-cost-attribution): kind:"slug" rows are the
    # per-slug proration of a session-total row already counted below —
    # summing them here too would double the day total.
    if d.get("kind") == "slug":
        continue
    if d.get("date", "").startswith(today):
        hours += float(d.get("hours", 0))
        eur += float(d.get("eur", 0))
        for p in d.get("prds", []) or []:
            if p not in prds:
                prds.append(p)
prds_str = ",".join(prds) if prds else "none"
print(f"hours={hours:.2f} eur={eur:.2f} prds={prds_str}")
' "$today" "$COST_LEDGER"
}

# ---- cost --by-prd (PRD-build-cost-attribution requirement 3) ---------------
# Table of slug/runs/box-minutes/eur sorted by eur desc, plus a totals row.
# No flag: all history. --today: today's UTC date. --session <id>: one
# session_id. Source is cost.jsonl's kind:"slug" rows (written by
# prorate_attribution at teardown); the totals row is compared against the
# matching session-total row(s) as an in-code conservation check (P3
# success metric: "proration conservation error ... 0.00").
cmd_cost_by_prd() {
  local mode="all" filt=""
  case "${1:-}" in
    --today) mode="today" ;;
    --session)
      mode="session"; filt="${2:-}"
      [ -n "$filt" ] || { echo "usage: burst-lane.sh cost --by-prd --session <id>" >&2; exit 2; }
      ;;
    "") mode="all" ;;
    *) echo "usage: burst-lane.sh cost --by-prd [--today|--session <id>]" >&2; exit 2 ;;
  esac
  [ -f "$COST_LEDGER" ] || { echo "no cost data"; exit 0; }
  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  python3 -c '
import json, sys, collections

mode, filt, today, path = sys.argv[1:5]
slug_totals = collections.OrderedDict()
session_eur_total = 0.0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if mode == "today" and not str(d.get("date", "")).startswith(today):
        continue
    if mode == "session" and d.get("session_id") != filt:
        continue
    if d.get("kind") == "slug":
        s = d.get("slug", "unattributed")
        slug_totals.setdefault(s, {"runs": 0, "seconds": 0.0, "eur": 0.0,
                                    "pulls_skipped": 0, "bytes_saved": 0})
        slug_totals[s]["runs"] += int(d.get("runs", 0) or 0)
        slug_totals[s]["seconds"] += float(d.get("seconds", 0) or 0)
        slug_totals[s]["eur"] += float(d.get("eur", 0) or 0)
        # PRD-build-burst-pull-on-demand requirement 5: the skip yield lands
        # in this same table, not a separate report.
        slug_totals[s]["pulls_skipped"] += int(d.get("pulls_skipped", 0) or 0)
        slug_totals[s]["bytes_saved"] += int(d.get("bytes_saved", 0) or 0)
    else:
        session_eur_total += float(d.get("eur", 0) or 0)

rows = sorted(slug_totals.items(), key=lambda kv: -kv[1]["eur"])
print("{:<28}{:>6}{:>12}{:>10}{:>10}{:>10}".format("slug", "runs", "box-min", "eur", "skipped", "GBsaved"))
grand_eur = grand_min = 0.0
grand_runs = grand_skipped = 0
grand_bytes_saved = 0
for slug, v in rows:
    mins = v["seconds"] / 60.0
    gb = v["bytes_saved"] / (1024.0 ** 3)
    grand_eur += v["eur"]; grand_min += mins; grand_runs += v["runs"]
    grand_skipped += v["pulls_skipped"]; grand_bytes_saved += v["bytes_saved"]
    print("{:<28}{:>6}{:>12.2f}{:>10.4f}{:>10}{:>10.3f}".format(slug, v["runs"], mins, v["eur"], v["pulls_skipped"], gb))
grand_gb = grand_bytes_saved / (1024.0 ** 3)
print("{:<28}{:>6}{:>12.2f}{:>10.4f}{:>10}{:>10.3f}".format("TOTAL", grand_runs, grand_min, grand_eur, grand_skipped, grand_gb))

# Conservation check (in-code, per the success-metrics table): the sum of
# printed slug eur must equal the session-total eur it was prorated from.
if session_eur_total and abs(grand_eur - session_eur_total) > 1e-6:
    print("conservation-error: slug total {:.6f} != session total {:.6f}".format(grand_eur, session_eur_total), file=sys.stderr)
    sys.exit(1)
' "$mode" "$filt" "$today" "$COST_LEDGER"
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    up)        cmd_up "$@" ;;
    status)    cmd_status "$@" ;;
    run)       cmd_run "$@" ;;
    sync-back) cmd_sync_back "$@" ;;
    pull)      cmd_pull "$@" ;;
    ensure-fresh) cmd_ensure_fresh "$@" ;;
    down)      cmd_down "$@" ;;
    watchdog)  cmd_watchdog "$@" ;;
    cost)      cmd_cost "$@" ;;
    sub-cap)   cmd_sub_cap "$@" ;;
    verify)    cmd_verify "$@" ;;
    reap)      cmd_reap "$@" ;;
    route-check) cmd_route_check "$@" ;;
    parity)    cmd_parity "$@" ;;
    gate)      cmd_gate "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
