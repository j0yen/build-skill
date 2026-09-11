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
# PRD-build-burst-unprivileged-user: mcphost refuses to run as real uid 0
# (`refuse_to_serve_as_root`, src/sandbox.rs) — every remote step used to run
# as root, which made root an invalid test identity the instant a remote
# gate started exercising mcphost's own integration suite. `$REMOTE_USER`
# now defaults to `build` (an unprivileged account `up`/`provision` create
# on the box, uid stable across boots, home mode 700); `$REMOTE_ROOT`,
# `$GATE_TOOLS_REMOTE_BIN_DIR`, and `$GATE_CRED_REMOTE_PATH` all resolve
# under that user's own `$REMOTE_HOME` (`/home/build` by default) instead of
# `/root`. Root now runs exactly three things (requirement 3's allow-list):
# the apparmor sysctl, the two apt-based package installs (bwrap, python3,
# and gate-tools' own jq/gh/mold), and user creation/migration — bundled one
# ssh call each, tagged `# user-create` — everything else (rsync, cargo,
# uv, claude, extend-gate.sh, the credential push) runs as `build@`.
# Toolchain decision (requirement 2): rather than a second, slower per-user
# rustup+toolchain install, `build` shares root's ALREADY-WARM
# `/root/.rustup` (read+execute, granted once at user-creation time via
# `chmod o+x /root` + `chmod -R o+rX /root/.cargo /root/.rustup` — the one
# necessary crack in root's home) via `RUSTUP_HOME=/root/.rustup
# CARGO_HOME=/root/.cargo` exported on every remote cargo invocation; new
# cargo-installed gate tools (cargo-deny, cargo-nextest) still land under
# `$REMOTE_HOME/.local` via `cargo install --root`, never written into
# root's shared tree, so no cargo/rsync call ever needs to be root. sccache
# gets its own per-user cache (`$REMOTE_HOME/.cache/sccache`) rather than
# sharing root's — a cold first-run cache is a perf cost, not a permissions
# problem. `BURST_LANE_REMOTE_USER=root` remains a full rollback (matching
# `REMOTE_ROOT=/root/build` and friends exactly, byte-for-byte the pre-PRD
# behavior) — see `create_remote_user()`'s early return and the
# `REMOTE_HOME`/default-path block right after `load_env`. `provision`
# additionally migrates a LIVE root-only session onto `build` in place (no
# reboot): `migrate_remote_user()` runs the same user-creation call, then
# `cp -a`s each still-dirty worktree's remote tree from the old root-owned
# path into the new one (root-only, bucketed with user creation — it is
# the only user who can read the old tree), marking a worktree cold instead
# of blocking migration if that copy fails.
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
#
# Test isolation (PRD-build-burst-selftest-isolation): BURST_LANE_TEST=1
# marks a test run — every override above is then REQUIRED, not optional;
# any one of STATE_DIR/JOURNAL/COST_LEDGER/ATTR_LEDGER/hcloud/ssh/rsync that
# still resolves to a live path/binary fails closed (exit 9) instead of
# silently touching production. See isolation-guard.sh.
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
# PRD-build-burst-parity-cadence requirement 2: parity's own load-deferral
# wait bound — distinct from cargo-budget.sh's CARGO_BUDGET_WAIT_MAX, which
# only gates the LOCAL cargo invocation. This gates the WHOLE parity attempt
# (box AND local) before either side does any work at all. Shares
# CARGO_BUDGET_MAX_LOAD/CARGO_BUDGET_LOADAVG/CARGO_BUDGET_HOSTNAME's names
# with cargo-budget.sh's own gate (see cargo-budget.sh's header) so one
# fixture/env override drives both layers identically in tests.
PARITY_LOAD_WAIT_S="${PARITY_LOAD_WAIT_S:-900}"
PARITY_LOAD_POLL_S="${PARITY_LOAD_POLL_S:-10}"
# PRD-build-burst-parity-cadence requirement 3: repos `up` schedules one
# session parity proof for (once per session, not once per HEAD), space-
# separated basenames resolved under $ATTR_REPOS_DIR — the same known-repo
# root cost-attribution already uses.
BURST_PARITY_REPOS="${BURST_PARITY_REPOS:-mcphost}"
CARGO_BUDGET_SH="${BURST_LANE_CARGO_BUDGET_SH:-$SKILL_DIR/scripts/cargo-budget.sh}"
# PRD-build-gate-on-casper requirement 1: gate toolchain provisioning. The
# 8 versioned CLI tools `up` provisions if absent; the two script mirrors
# (build-skill's own scripts/, rustbuild's scripts/+prompts/) are synced
# read-only alongside them but aren't "versioned" the same way. Overridable
# so offline tests never touch the real ~/.cargo/bin or ~/.claude/skills.
GATE_TOOLS_LIST="autobuilder jq gh mold cargo-deny cargo-nextest uv claude"
GATE_TOOLS_STATE_FILE="$STATE_DIR/gate-tools.json"
# PRD-build-burst-gate-tools-toolchain requirement 1: cargo-based installs
# pin BOTH the toolchain and the crate version in one table, because the
# box's default toolchain (rustc 1.85 as of 2026-09-11) is too old for
# current cargo-deny/cargo-nextest releases — `cargo install --locked
# cargo-deny` under 1.85 refuses with "cargo-deny 0.18.3 supports rustc
# 1.85.0" (a version *floor*, not a match), and unpinned-latest
# cargo-nextest 0.9.144 needs rustc 1.91, newer than even the 1.88 the box
# already carries. `cargo +<newest-installed-toolchain> install` picks up
# 1.88 without a snapshot rebuild; bump this table (not the install case
# below) when the box's toolchain or these crates move.
GATE_TOOLS_CARGO_DENY_VERSION="${BURST_LANE_GATE_TOOLS_CARGO_DENY_VERSION:-0.20.2}"
GATE_TOOLS_CARGO_NEXTEST_VERSION="${BURST_LANE_GATE_TOOLS_CARGO_NEXTEST_VERSION:-0.9.114}"
GATE_TOOLS_BUILD_SCRIPTS_SRC="${BURST_LANE_GATE_BUILD_SCRIPTS:-$HOME/.claude/skills/build/scripts}"
GATE_TOOLS_RUSTBUILD_SCRIPTS_SRC="${BURST_LANE_GATE_RUSTBUILD_SCRIPTS:-$HOME/.claude/skills/rustbuild/scripts}"
GATE_TOOLS_RUSTBUILD_PROMPTS_SRC="${BURST_LANE_GATE_RUSTBUILD_PROMPTS:-$HOME/.claude/skills/rustbuild/prompts}"
GATE_TOOLS_AUTOBUILDER_BIN="${BURST_LANE_AUTOBUILDER_BIN:-$HOME/.cargo/bin/autobuilder}"
# GATE_TOOLS_REMOTE_BIN_DIR/GATE_CRED_REMOTE_PATH/REMOTE_ROOT are computed
# further down, right after load_env resolves $REMOTE_USER (PRD-build-burst-
# unprivileged-user requirement 1) — their defaults key off which user's
# home they land in, so they can't be pinned until $REMOTE_USER is known.
# PRD-build-gate-on-casper requirement 4: reviewer credential placement.
GATE_CRED_SRC="${BURST_CLAUDE_CRED_SRC:-$HOME/.claude/.credentials.json}"

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

# PRD-build-burst-selftest-isolation: default-deny under BURST_LANE_TEST=1.
# Every path/binary below is checked AFTER override resolution but BEFORE
# the first mkdir/write (the mkdir just below this block), so a refusal has
# zero side effect (Requirement 2, AC1). Fail-open sourcing matches the
# probe-result convention above — a missing library never breaks a real
# (sentinel-off) invocation, it only means an offline test loses its guard.
if [ -r "$HERE/isolation-guard.sh" ]; then
  # shellcheck source=isolation-guard.sh
  source "$HERE/isolation-guard.sh"
else
  isolation_guard_path() { :; }
  isolation_guard_bin() { :; }
fi
isolation_guard_path "$STATE_DIR" "burst-lane.sh"
isolation_guard_path "$JOURNAL" "burst-lane.sh"
isolation_guard_path "$COST_LEDGER" "burst-lane.sh"
isolation_guard_path "$ATTR_LEDGER" "burst-lane.sh"
isolation_guard_bin "$(command -v "$HCLOUD" 2>/dev/null)" "burst-lane.sh(hcloud)"
isolation_guard_bin "$(command -v "$SSH_BIN" 2>/dev/null)" "burst-lane.sh(ssh)"
isolation_guard_bin "$(command -v "$RSYNC_BIN" 2>/dev/null)" "burst-lane.sh(rsync)"

SERVER_NAME="${BURST_LANE_SERVER_NAME:-wm-burst-lane}"
SERVER_TYPE="${BURST_SERVER_TYPE:-ccx53}"
DEFAULT_LOCATION="nbg1"
DEFAULT_SNAPSHOT_ID="427125061"
DEFAULT_TTL_HOURS="6"
HARD_TTL_HOURS="12"
COST_PER_HOUR_EUR="0.47"

# ---- persistent volume (PRD-build-burst-persistent-volume) -----------------
# BURST_VOLUME_NAME empty is the documented rollback: root-disk behavior,
# byte-for-byte, no hcloud volume call ever made. Kept as plain vars (not
# load_env-sourced) so an operator can flip the rollback with a bare env
# export, same as every other BURST_* knob here.
BURST_VOLUME_NAME="${BURST_VOLUME_NAME-wm-burst-build}"
BURST_VOLUME_GB="${BURST_VOLUME_GB:-500}"
BURST_SCCACHE_GB="${BURST_SCCACHE_GB:-40}"
BURST_VOLUME_EUR_PER_GB_MONTH="${BURST_VOLUME_EUR_PER_GB_MONTH:-0.0476}"
# Requirement 9: the pull-BACK destination guard — RedBaron's own local disk,
# not the box's. Default 60 (same floor family as BURST_DISK_FLOOR_GB's own
# 40, sized a bit higher since a single gate pull has been observed as large
# as 87 GB — see the 2026-09-11 08:55Z 0-bytes-free incident in the PRD).
BURST_LOCAL_DISK_FLOOR_GB="${BURST_LOCAL_DISK_FLOOR_GB:-60}"
# Persistent across sessions (NOT cleared by state_clear/`down`'s delete —
# the volume, and the fact that its last detach failed, outlive the box that
# was attached to it). volume_state_write's own key=value convention mirrors
# state_write's.
VOLUME_STATE_FILE="$STATE_DIR/volume.json"

die() { echo "burst-lane: $*" >&2; exit "${2:-1}"; }
usage() { echo "usage: burst-lane.sh {up|status|run|sync-back|pull|ensure-fresh|down|watchdog|cost|sub-cap|verify|provision|reap|box-isolation-check|route-check|parity|gate} ..." >&2; exit 2; }

now_epoch() { echo "${BURST_LANE_NOW:-$(date -u +%s)}"; }
now_iso()   { date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
journal_line() { mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true; printf '%s\n' "$1" >> "$JOURNAL"; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- config -------------------------------------------------------------
load_env() {
  SNAPSHOT_ID="$DEFAULT_SNAPSHOT_ID"
  LOCATION="$DEFAULT_LOCATION"
  SSH_KEY="$HOME/.ssh/id_ed25519"
  # PRD-build-burst-unprivileged-user requirement 1: unprivileged by default.
  # BURST_LANE_REMOTE_USER=root (the selftest fixture's override point, and
  # an operator's documented rollback — see the header note) is the only way
  # back to the old all-root behavior; an env-file REMOTE_USER= line (none
  # ship today) can still override it, same as every other load_env var.
  REMOTE_USER="${BURST_LANE_REMOTE_USER:-build}"
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

# PRD-build-burst-unprivileged-user requirement 2: where root's ALREADY-WARM
# toolchain actually lives — always real root's home in production, but
# overridable so the offline selftest can point RUSTUP_HOME/CARGO_HOME at
# THIS machine's own real, working toolchain (its normal default location
# anyway) instead of a real /root no test-runner here can read. Never used
# for anything but read+execute lookups (see create_remote_user's chmod
# grant, and every RUSTUP_HOME=/CARGO_HOME= export below) — nothing ever
# writes through these two vars; a gate tool's `cargo install` always
# targets $GATE_TOOLS_REMOTE_BIN_DIR's own writable tree via `--root`.
ROOT_RUSTUP_HOME="${BURST_LANE_ROOT_RUSTUP_HOME:-/root/.rustup}"
ROOT_CARGO_HOME="${BURST_LANE_ROOT_CARGO_HOME:-/root/.cargo}"

# PRD-build-burst-parity-robust requirement 1: the CARGO_TARGET_*_RUNNER env
# var name for the box's host triple — the `cargo test` fallback path (used
# only when cargo-nextest is absent on a side) wraps every test binary in
# `stdbuf -o0` through this, since `--test-threads=1` alone does not fix
# stdout/stderr inter-stream reordering by itself (see Technical
# considerations). Overridable for a box whose triple differs.
CARGO_TEST_RUNNER_TARGET_ENV="${BURST_LANE_CARGO_TEST_RUNNER_TARGET_ENV:-CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER}"

# ---- remote paths (PRD-build-burst-unprivileged-user requirement 1) -------
# Computed only now that $REMOTE_USER is resolved. root keeps its historical
# /root-rooted defaults exactly (the documented rollback restores today's
# behavior byte-for-byte); build resolves everything under its own home.
# GATE_TOOLS_REMOTE_BIN_DIR differs in KIND, not just path, between the two:
# root's cargo-installed gate tools land in its own (already writable)
# CARGO_HOME/bin; build's land under $REMOTE_HOME/.local/bin via `cargo
# install --root` (see gate_tools_install_cmd) because build's CARGO_HOME is
# root's shared, READ-ONLY toolchain (requirement 2) — it cannot receive a
# `cargo install`'s own writes.
if [ "$REMOTE_USER" = "root" ]; then
  REMOTE_HOME="/root"
  GATE_TOOLS_REMOTE_BIN_DIR_DEFAULT="$ROOT_CARGO_HOME/bin"
else
  # Absolute (no "~") — the fake rsync fixture only string-strips a
  # "user@host:" prefix, it never runs a remote shell to expand a tilde.
  REMOTE_HOME="${BURST_LANE_REMOTE_HOME:-/home/$REMOTE_USER}"
  GATE_TOOLS_REMOTE_BIN_DIR_DEFAULT="$REMOTE_HOME/.local/bin"
fi
REMOTE_ROOT="${BURST_LANE_REMOTE_ROOT:-$REMOTE_HOME/build}"
# PRD-build-burst-persistent-volume requirement 3: sccache moves onto the
# same tree the volume mounts at $REMOTE_ROOT (byte-identical path whether or
# not a volume is actually attached this session — see "up"'s volume_ensure,
# which mounts AT $REMOTE_ROOT rather than renaming it). Previously
# $REMOTE_HOME/.cache/sccache (build) or /root/.sccache (root); still
# overridable via BURST_LANE_REMOTE_SCCACHE_DIR for either rollback.
REMOTE_SCCACHE_DIR_DEFAULT="$REMOTE_ROOT/.sccache"
# PRD-build-burst-parity-robust requirement 4: the FIXED historical root a
# pre-unprivileged-user (or rolled-back) session always used, independent of
# whatever $REMOTE_ROOT resolves to today — this is where `reap` looks for
# migration residue the direct verified-copy-then-remove step in
# migrate_remote_user() didn't (or couldn't) clear. Equal to $REMOTE_ROOT
# itself under the REMOTE_USER=root rollback, in which case the old-root scan
# is a deliberate no-op (nothing "old" to distinguish).
OLD_ROOT_REMOTE_ROOT="${BURST_LANE_OLD_ROOT_REMOTE_ROOT:-/root/build}"
GATE_TOOLS_REMOTE_BIN_DIR="${BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR:-$GATE_TOOLS_REMOTE_BIN_DIR_DEFAULT}"
# PRD-build-gate-on-casper requirement 4 / PRD-build-burst-unprivileged-user
# requirement 5: reviewer credential placement, now under $REMOTE_HOME.
GATE_CRED_REMOTE_PATH="${BURST_LANE_GATE_CRED_REMOTE_PATH:-$REMOTE_HOME/.claude/.credentials.json}"
REMOTE_SCCACHE_DIR="${BURST_LANE_REMOTE_SCCACHE_DIR:-$REMOTE_SCCACHE_DIR_DEFAULT}"

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

# ---- persistent-volume state (PRD-build-burst-persistent-volume) ----------
# Deliberately a SEPARATE file from $STATE_FILE: the volume (and a failed-
# detach's dirty flag) outlive the session/server that state_clear wipes at
# every successful teardown. volume_mounted reflects only the most recent
# `up`'s outcome (harmless if stale — every reader of it also checks
# state_active first); volume_dirty is the one field that must survive
# across a full session boundary (requirement 2).
volume_state_read() {  # $1 = key -> stdout value or empty
  [ -f "$VOLUME_STATE_FILE" ] || return 0
  if [ -n "$JQ" ]; then
    "$JQ" -r --arg k "$1" '.[$k] // empty' "$VOLUME_STATE_FILE" 2>/dev/null
  else
    grep -oE "\"$1\":\"?[^,\"}]*\"?" "$VOLUME_STATE_FILE" 2>/dev/null | head -n1 | sed -E 's/^[^:]*:"?([^",}]*)"?$/\1/'
  fi
}

volume_state_write() {  # $1..$N = key=value pairs, merged onto whatever's
                         # already in the file (a partial call — e.g. just
                         # "volume_dirty=true" — never clobbers volume_id).
  local tmp="$VOLUME_STATE_FILE.tmp.$$"
  local -A merged
  local k
  for k in volume_id volume_mounted volume_dirty volume_size_gb volume_used_pct; do
    merged["$k"]="$(volume_state_read "$k")"
  done
  local kv v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    merged["$k"]="$v"
  done
  {
    echo "{"
    local first=1
    for k in "${!merged[@]}"; do
      v="${merged[$k]}"
      [ -n "$v" ] || continue
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
  mv -f "$tmp" "$VOLUME_STATE_FILE"
}

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
# ---- unprivileged remote user (PRD-build-burst-unprivileged-user --------
# requirement 1) -------------------------------------------------------------
# Idempotent: creates $REMOTE_USER if absent, installs this lane's own ssh
# public key into its authorized_keys (mode 700 home, 600 authorized_keys),
# and grants it read+execute — never write — into root's already-warm
# rustup/cargo toolchain (requirement 2's chosen approach: sharing root's
# installs is cheaper than a second per-user rustup install, and this is
# what the PRD's own Technical Considerations names as the "cheaper path").
# `o+x` on /root itself is the one necessary crack in its 700 default —
# without directory traversal the read+execute grant on .cargo/.rustup below
# is unreachable by anyone but root. Bundled into ONE root ssh call (tagged
# `# user-create`) alongside the useradd itself, matching requirement 3's
# "root only for ... user creation" allow-list. A no-op for the
# BURST_LANE_REMOTE_USER=root rollback — skipping the call entirely means
# root's own `up` is byte-for-byte what it was before this PRD.
create_remote_user() {  # $1=ip
  local ip="$1"
  [ "$REMOTE_USER" = "root" ] && return 0
  local toolchain_parent; toolchain_parent="$(dirname "$ROOT_CARGO_HOME")"
  local setup="
# user-create
id -u $REMOTE_USER >/dev/null 2>&1 || useradd -m -d $REMOTE_HOME -s /bin/bash $REMOTE_USER
mkdir -p $REMOTE_HOME/.ssh $REMOTE_ROOT
chmod o+x $toolchain_parent 2>/dev/null || true
chmod -R o+rX $ROOT_CARGO_HOME $ROOT_RUSTUP_HOME 2>/dev/null || true
chmod 700 $REMOTE_HOME $REMOTE_HOME/.ssh
chown -R $REMOTE_USER:$REMOTE_USER $REMOTE_HOME $REMOTE_ROOT"
  if [ -f "${SSH_KEY}.pub" ]; then
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "$setup
[ -f $REMOTE_HOME/.ssh/.burst-lane-key-installed ] || { cat >> $REMOTE_HOME/.ssh/authorized_keys && chown $REMOTE_USER:$REMOTE_USER $REMOTE_HOME/.ssh/authorized_keys && touch $REMOTE_HOME/.ssh/.burst-lane-key-installed; }
chmod 600 $REMOTE_HOME/.ssh/authorized_keys 2>/dev/null || true
true" < "${SSH_KEY}.pub" 2>/dev/null || true
  else
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "$setup
true" 2>/dev/null || true
  fi
}

box_bootstrap() {  # $1 = ip — make a snapshot box ready (idempotent, ~1s when already done)
  # Requirement 3: root only for the apparmor sysctl and apt-based installs.
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$1" "
    sysctl -qw kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    command -v bwrap >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq bubblewrap; } >/dev/null 2>&1
    command -v python3 >/dev/null 2>&1 || apt-get install -y -qq python3-minimal python3 >/dev/null 2>&1
    true" 2>/dev/null || true
  create_remote_user "$1"
  # Everything else — requirement 3's "everything else uses build@$ip" —
  # including uv, which has no business running as root just to land a
  # binary in a user's own $HOME/.local/bin.
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
    mkdir -p $REMOTE_ROOT
    command -v uv >/dev/null 2>&1 || [ -x $REMOTE_HOME/.local/bin/uv ] || (curl -LsSf https://astral.sh/uv/install.sh | sh) >/dev/null 2>&1
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

# ---- persistent volume (PRD-build-burst-persistent-volume) ----------------
# `up` calls volume_ensure() right after box_bootstrap (both the adoption and
# fresh-create branches — see cmd_up) so $REMOTE_ROOT is a mounted, durable
# tree before provision_gate_tools/place_gate_credential ever write into it.
# Fails OPEN on every hcloud/ssh error along the way (create-failed, attach-
# failed, mount-failed): the box boots and runs on the ephemeral root disk
# exactly as it did before this PRD, with volume_mounted=false recorded so
# `status`/`cost` never claim a durability this session doesn't have.
find_volume() {  # -> stdout "id size_gb server_id device" (server_id empty
                  # if unattached); rc1 if BURST_VOLUME_NAME is unset/empty
                  # (the documented rollback) or hcloud reports no such volume
  [ -n "$BURST_VOLUME_NAME" ] || return 1
  local out; out="$("$HCLOUD" volume describe "$BURST_VOLUME_NAME" -o json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  # PRD-build-burst-persistent-volume: pipe-delimited, NOT space-delimited —
  # server_id is routinely empty (an unattached volume), and `read`'s
  # default IFS word-splitting collapses consecutive whitespace, silently
  # dropping an empty middle field and shifting linux_device into server_id's
  # slot (caught in offline testing: a fresh, never-attached volume read
  # back as "busy, attached to /dev/disk/by-id/...").
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d = d.get("volume", d)
sid = d.get("server")
print("%s|%s|%s|%s" % (d.get("id",""), d.get("size",""), sid if sid is not None else "", d.get("linux_device","")))
' <<<"$out" 2>/dev/null
}

volume_ensure() {  # $1=ip $2=server_id
  local ip="$1" sid="$2"
  if [ -z "$BURST_VOLUME_NAME" ]; then
    volume_state_write "volume_mounted=false"
    return 0
  fi

  local vid vsize vserver vdevice
  local found; found="$(find_volume)"
  if [ -n "$found" ]; then
    IFS='|' read -r vid vsize vserver vdevice <<<"$found"
  else
    local create_out
    if ! create_out="$("$HCLOUD" volume create --name "$BURST_VOLUME_NAME" --size "$BURST_VOLUME_GB" --location "$LOCATION" -o json 2>&1)"; then
      journal_line "$(now_iso)  burst-lane  up  volume-create-failed  (name=$BURST_VOLUME_NAME err=\"$(tr '\n' ' ' <<<"$create_out")\" — booting on root disk)"
      volume_state_write "volume_mounted=false"
      return 0
    fi
    IFS='|' read -r vid vsize vserver vdevice <<<"$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d = d.get("volume", d)
sid = d.get("server")
print("%s|%s|%s|%s" % (d.get("id",""), d.get("size",""), sid if sid is not None else "", d.get("linux_device","")))
' <<<"$create_out" 2>/dev/null)"
    if [ -z "$vid" ]; then
      journal_line "$(now_iso)  burst-lane  up  volume-create-failed  (name=$BURST_VOLUME_NAME cause=could-not-parse-id — booting on root disk)"
      volume_state_write "volume_mounted=false"
      return 0
    fi
    journal_line "$(now_iso)  burst-lane  up  volume  created  (id=$vid name=$BURST_VOLUME_NAME size=${vsize}G)"
  fi

  # Requirement 6: single-attach safety. Hetzner volumes attach to one
  # server at a time; a volume some OTHER live server holds is never
  # attached here — this box boots without it (root disk) rather than
  # racing/stealing it.
  if [ -n "$vserver" ] && [ "$vserver" != "$sid" ]; then
    journal_line "$(now_iso)  burst-lane  up  volume  busy  (attached_to=$vserver id=$vid)"
    volume_state_write "volume_id=$vid" "volume_mounted=false"
    return 0
  fi

  if [ -z "$vserver" ]; then
    if ! "$HCLOUD" volume attach --server "$sid" "$vid" >/dev/null 2>&1; then
      journal_line "$(now_iso)  burst-lane  up  volume-attach-failed  (id=$vid server_id=$sid — booting on root disk)"
      volume_state_write "volume_id=$vid" "volume_mounted=false"
      return 0
    fi
  fi

  # Requirement 2 (teardown-order counterpart): a volume left dirty by a
  # prior detach failure gets an fsck before this mount, exactly once.
  if [ "$(volume_state_read volume_dirty)" = "true" ]; then
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
      "fsck -y '$vdevice' >/dev/null 2>&1; true # volume-fsck" >/dev/null 2>&1 || true
    journal_line "$(now_iso)  burst-lane  up  volume  fsck  (id=$vid device=$vdevice cause=prior-detach-failed)"
  fi

  # Requirement 1: format only when the volume has no filesystem (a label
  # check on the box itself, not an hcloud-API property) — one combined root
  # ssh round trip, mirroring box_bootstrap's own style. Mounts AT
  # $REMOTE_ROOT (never renames it) so every existing remote_path_for()/
  # dirty-marker path is unaffected by whether a volume happens to be there.
  local mount_out mount_rc=0
  mount_out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "
# volume-mount
label=\$(blkid -s LABEL -o value '$vdevice' 2>/dev/null)
if [ -z \"\$label\" ]; then mkfs.ext4 -L $BURST_VOLUME_NAME '$vdevice' >/dev/null 2>&1 && echo FORMATTED; fi
mkdir -p '$REMOTE_ROOT'
mount '$vdevice' '$REMOTE_ROOT' 2>/dev/null || true
chown -R $REMOTE_USER:$REMOTE_USER '$REMOTE_ROOT'
echo MOUNTED
" 2>/dev/null)" || mount_rc=$?
  if [ "$mount_rc" -ne 0 ] || ! grep -q MOUNTED <<<"$mount_out"; then
    journal_line "$(now_iso)  burst-lane  up  volume-mount-failed  (id=$vid device=$vdevice — booting on root disk)"
    volume_state_write "volume_id=$vid" "volume_mounted=false"
    return 0
  fi

  local dfout used_gb size_gb pct
  dfout="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "df -BG --output=used,size,pcent '$REMOTE_ROOT' 2>/dev/null | tail -n1 # volume-df" 2>/dev/null)"
  used_gb="$(awk '{print $1}' <<<"$dfout" | tr -dc '0-9')"
  size_gb="$(awk '{print $2}' <<<"$dfout" | tr -dc '0-9')"
  pct="$(awk '{print $3}' <<<"$dfout" | tr -dc '0-9')"
  size_gb="${size_gb:-$vsize}"

  volume_state_write "volume_id=$vid" "volume_mounted=true" "volume_dirty=false" \
    "volume_size_gb=${size_gb:-$BURST_VOLUME_GB}" "volume_used_pct=${pct:-0}"
  journal_line "$(now_iso)  burst-lane  up  volume  attached  (id=$vid size=${size_gb:-$BURST_VOLUME_GB}G used=${pct:-0}%)"
}

# ---- persistent volume teardown (requirement 2) ----------------------------
# Called from BOTH cmd_down's delete path and cmd_watchdog's teardown path,
# right before destroy_verify(id) — sync, unmount, detach, verify detached.
# Hetzner detaches a volume automatically on `server delete` regardless, so a
# detach failure here NEVER blocks the server delete that follows it (fail
# open on the teardown, same doctrine as volume_ensure on the way up) — it
# only marks volume_dirty=true so the NEXT up's mount runs fsck first.
volume_teardown() {  # $1=ip $2=caller(down|watchdog)
  local ip="$1" caller="$2"
  [ "$(volume_state_read volume_mounted)" = "true" ] || return 0
  local vid; vid="$(volume_state_read volume_id)"
  [ -n "$vid" ] || return 0

  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "sync # volume-sync" >/dev/null 2>&1 || true
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
    "umount '$REMOTE_ROOT' 2>/dev/null; true # volume-umount" >/dev/null 2>&1 || true

  if ! "$HCLOUD" volume detach "$vid" >/dev/null 2>&1; then
    journal_line "$(now_iso)  burst-lane  $caller  volume  detach-failed  (id=$vid)"
    volume_state_write "volume_dirty=true" "volume_mounted=false"
    return 0
  fi
  # Verify detached (requirement 2's "verify the volume reports detached") —
  # a describe that still shows a server attached is the same detach-failed
  # outcome as the hcloud call itself erroring, never silently trusted.
  local check; check="$(find_volume 2>/dev/null)"
  local _cid _csize cserver _cdev
  IFS='|' read -r _cid _csize cserver _cdev <<<"${check:-}"
  if [ -n "$cserver" ]; then
    journal_line "$(now_iso)  burst-lane  $caller  volume  detach-failed  (id=$vid cause=still-attached server=$cserver)"
    volume_state_write "volume_dirty=true" "volume_mounted=false"
    return 0
  fi
  volume_state_write "volume_mounted=false" "volume_dirty=false"
  journal_line "$(now_iso)  burst-lane  $caller  volume  detached  (id=$vid)"
}

# `status --json`/`status` want a LIVE reading (not whatever volume_ensure
# last stored at `up` time) — AC6 exercises this by pointing the fake ssh's
# `# volume-df` case at a specific used-pct and expecting THIS call to see
# it. Falls back to the last-stored size/pct (never ssh-unreachable => no
# answer at all) if the live probe fails.
volume_status_probe() {  # $1=ip -> stdout "id size_gb used_pct"; empty if no volume tracked
  [ "$(volume_state_read volume_mounted)" = "true" ] || return 0
  local vid; vid="$(volume_state_read volume_id)"
  [ -n "$vid" ] || return 0
  local dfout size_gb pct
  dfout="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" \
    "df -BG --output=used,size,pcent '$REMOTE_ROOT' 2>/dev/null | tail -n1 # volume-df" 2>/dev/null)"
  size_gb="$(awk '{print $2}' <<<"$dfout" | tr -dc '0-9')"
  pct="$(awk '{print $3}' <<<"$dfout" | tr -dc '0-9')"
  size_gb="${size_gb:-$(volume_state_read volume_size_gb)}"
  pct="${pct:-$(volume_state_read volume_used_pct)}"
  printf '%s %s %s\n' "$vid" "${size_gb:-0}" "${pct:-0}"
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
  # PRD-build-burst-unprivileged-user requirement 2: probing needs no root —
  # reading a tool's own --version never writes anything — so this runs as
  # $REMOTE_USER like everything but the requirement-3 allow-list.
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
# gate-tools-probe
# PRD-build-burst-gate-tools-scope requirement 1: a non-login ssh shell's
# PATH lacks the cargo-installed tools/uv/claude dirs, so a correctly-
# installed tool read back MISSING without this export — the exact box
# 165449166 failure mode. PRD-build-burst-unprivileged-user: build's own
# \$GATE_TOOLS_REMOTE_BIN_DIR comes first — that is where cargo-deny/
# cargo-nextest/uv/claude/autobuilder actually land for build (requirement
# 2) — root's shared /root/.cargo/bin:/root/.local/bin stays as a fallback
# (a no-op second listing for the REMOTE_USER=root rollback, since
# GATE_TOOLS_REMOTE_BIN_DIR already equals /root/.cargo/bin there).
export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin
for t in $GATE_TOOLS_LIST; do
  if command -v \"\$t\" >/dev/null 2>&1; then
    v=\"\$(\"\$t\" --version 2>/dev/null | head -n1)\"
    printf '%s=%s\n' \"\$t\" \"\${v:-unknown}\"
  else
    printf '%s=MISSING\n' \"\$t\"
  fi
done" 2>/dev/null
}

# Newest installed toolchain per `rustup toolchain list` (requirement 1) —
# a shared snippet the cargo-deny/cargo-nextest cases below both splice in,
# so there is exactly one place that decides how "newest" is picked. Falls
# back to a bare `cargo install` (no `+toolchain`) when rustup isn't found
# or lists nothing parseable, matching the pre-fix behavior rather than
# hard-failing on a box that manages its toolchain differently.
_gate_tools_cargo_toolchain_pick='tc="$(rustup toolchain list 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | sort -V | tail -n1)"'

gate_tools_install_cmd() {  # $1=tool (never "autobuilder" — that's a push, see below) -> stdout: remote command
  local tool="$1"
  # PRD-build-burst-unprivileged-user requirement 2/3: this whole call now
  # runs as build (never root — see provision_gate_tools' per-tool routing),
  # so `cargo install` must never write into root's shared, READ-ONLY
  # CARGO_HOME — `--root` redirects the installed binary+metadata into
  # build's own tree instead (its parent dir, since `--root X` installs
  # into `X/bin`). For the REMOTE_USER=root rollback this resolves to
  # `--root /root/.cargo`, i.e. cargo's own default — a no-op flag, not a
  # behavior change.
  local install_root; install_root="$(dirname "$GATE_TOOLS_REMOTE_BIN_DIR")"
  case "$tool" in
    jq)
      # apt-get update already ran once for this provision (see the
      # apt-update snippet provision_gate_tools sends before this loop,
      # requirement 3) — no need to repeat it per apt tool.
      printf '%s\napt-get install -y -qq jq\n' "# gate-tools-install $tool" ;;
    gh)
      # Adds its own apt source right before installing, so its second
      # `apt-get update -qq` here is necessary (the shared pre-update ran
      # before this source existed), not a duplicate of requirement 3.
      printf '%s\n%s\n' "# gate-tools-install $tool" \
        "(curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && apt-get update -qq && apt-get install -y -qq gh)" ;;
    mold)
      printf '%s\napt-get install -y -qq mold\n' "# gate-tools-install $tool" ;;
    cargo-deny)
      # NOTE: the format string below is single-quoted bash source, not a
      # double-quoted string — printf's builtin does NOT strip a backslash
      # before an unrecognized escape like \$, so a literal $PATH/$tc here
      # (no backslash) is what actually reaches the remote/eval side as
      # "$PATH"/"$tc" for real expansion there; a backslash-escaped form
      # was tried once and shipped PATH containing the four literal
      # characters "$PATH" instead of this host's real search path —
      # harmless for `cargo` itself (found via the /root/.cargo/bin prefix
      # regardless) but it silently broke `rustup`/grep/sort/tail lookups.
      # RUSTUP_HOME/CARGO_HOME (requirement 2) point `cargo`/`rustup` — both
      # only ever readable, never written, here — at root's shared toolchain
      # regardless of who's running this; `--root` (see above) is what
      # keeps the actual `install` write off of it.
      printf '%s\nexport PATH=$PATH:%s/bin RUSTUP_HOME=%s CARGO_HOME=%s; %s; if [ -n "$tc" ]; then cargo +"$tc" install --locked --root %s cargo-deny@%s; else cargo install --locked --root %s cargo-deny@%s; fi\n' \
        "# gate-tools-install $tool" "$ROOT_CARGO_HOME" "$ROOT_RUSTUP_HOME" "$ROOT_CARGO_HOME" "$_gate_tools_cargo_toolchain_pick" "$install_root" "$GATE_TOOLS_CARGO_DENY_VERSION" "$install_root" "$GATE_TOOLS_CARGO_DENY_VERSION" ;;
    cargo-nextest)
      printf '%s\nexport PATH=$PATH:%s/bin RUSTUP_HOME=%s CARGO_HOME=%s; %s; if [ -n "$tc" ]; then cargo +"$tc" install --locked --root %s cargo-nextest@%s; else cargo install --locked --root %s cargo-nextest@%s; fi\n' \
        "# gate-tools-install $tool" "$ROOT_CARGO_HOME" "$ROOT_RUSTUP_HOME" "$ROOT_CARGO_HOME" "$_gate_tools_cargo_toolchain_pick" "$install_root" "$GATE_TOOLS_CARGO_NEXTEST_VERSION" "$install_root" "$GATE_TOOLS_CARGO_NEXTEST_VERSION" ;;
    uv)
      printf '%s\ncurl -LsSf https://astral.sh/uv/install.sh | sh\n' "# gate-tools-install $tool" ;;
    claude)
      printf '%s\ncurl -fsSL https://claude.ai/install.sh | bash\n' "# gate-tools-install $tool" ;;
    *)
      printf '%s\ntrue\n' "# gate-tools-install $tool" ;;
  esac
}

# apt-based tools this box knows how to install — used to decide whether a
# provision needs the shared `apt-get update -qq` at all (requirement 3).
gate_tools_is_apt() { case "$1" in jq|gh|mold) return 0 ;; *) return 1 ;; esac; }

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
  mkdir -p "$STATE_DIR/logs" 2>/dev/null || true

  probe_out="$(gate_tools_probe "$ip")"

  # requirement 3: apt-get update runs at most ONCE per provision, before
  # the first apt-based install, and gets its own journal record either
  # way — "ran=false" (no apt tool was missing) reads as deliberately
  # skipped, not silently forgotten, the same ambiguity requirement 2
  # exists to kill for individual tool installs.
  local need_apt_update=0
  while IFS='=' read -r name ver; do
    [ -n "$name" ] && [ "$ver" = "MISSING" ] && gate_tools_is_apt "$name" && need_apt_update=1
  done <<<"$probe_out"
  if [ "$need_apt_update" = "1" ]; then
    local apt_log="$STATE_DIR/logs/gate-tools-apt-update.$$.log" apt_rc=0
    # Requirement 3: apt-get is root's job, never build's — hardcoded root@,
    # not $REMOTE_USER@, regardless of which user the rest of this function
    # routes to.
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
      "$(printf '%s\napt-get update -qq\n' "# gate-tools-apt-update")" >"$apt_log" 2>&1 || apt_rc=$?
    journal_line "$(now_iso)  burst-lane  gate-tools  apt-update  (ran=true rc=$apt_rc)"
    rm -f "$apt_log" 2>/dev/null || true
  else
    journal_line "$(now_iso)  burst-lane  gate-tools  apt-update  (ran=false)"
  fi

  while IFS='=' read -r name ver; do
    [ -n "$name" ] || continue
    [ "$ver" = "MISSING" ] || continue
    local start_ts rc secs err_log last_err
    start_ts="$(now_epoch)"
    err_log="$STATE_DIR/logs/gate-tools-install.$$-$name.log"
    rc=0
    if [ "$name" = "autobuilder" ]; then
      if [ -f "$GATE_TOOLS_AUTOBUILDER_BIN" ]; then
        "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
          "$(printf '%s\nmkdir -p '"'"'%s'"'"'\n' "# gate-tools-install autobuilder" "$GATE_TOOLS_REMOTE_BIN_DIR")" >/dev/null 2>&1 || true
        "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
          "$GATE_TOOLS_AUTOBUILDER_BIN" "$REMOTE_USER@$ip:$GATE_TOOLS_REMOTE_BIN_DIR/autobuilder" >"$err_log" 2>&1 || rc=$?
        "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
          "chmod +x '$GATE_TOOLS_REMOTE_BIN_DIR/autobuilder'" 2>/dev/null || true
      else
        rc=1
        printf 'local autobuilder binary not found at %s\n' "$GATE_TOOLS_AUTOBUILDER_BIN" >"$err_log"
      fi
    else
      # Requirement 3: apt-based tools (jq, gh, mold) install as root — the
      # only allow-listed reason to leave $REMOTE_USER here — everything
      # else (cargo-deny, cargo-nextest, uv, claude) installs as build.
      local install_user="$REMOTE_USER"
      gate_tools_is_apt "$name" && install_user="root"
      "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$install_user@$ip" "$(gate_tools_install_cmd "$name")" >"$err_log" 2>&1 || rc=$?
    fi
    secs="$(( $(now_epoch) - start_ts ))"
    journal_line "$(now_iso)  burst-lane  gate-tools  install  (tool=$name rc=$rc secs=$secs)"
    if [ "$rc" != "0" ]; then
      last_err="$(grep -v '^[[:space:]]*$' "$err_log" 2>/dev/null | tail -n1)"
      journal_line "$(now_iso)  burst-lane  gate-tools  install-failed  (tool=$name rc=$rc err=\"$last_err\")"
    fi
    rm -f "$err_log" 2>/dev/null || true
  done <<<"$probe_out"

  sync_gate_tools_scripts "$ip"

  # PRD-build-burst-gate-tools-scope requirement 1: autobuilder is the one
  # tool this box can never install from a package repo — the copy from
  # RedBaron IS the install. A remote version differing from this host's
  # own `autobuilder --version` means the copy is stale (or was hand-fixed
  # to a different build), so gate routing must not trust it even though
  # `command -v` finds it. Computed here (once, after the reinstall/probe
  # round trip above) rather than in `verify`, so `provision` gets the same
  # check without duplicating it.
  local local_ab_version=""
  if [ -x "$GATE_TOOLS_AUTOBUILDER_BIN" ]; then
    local_ab_version="$("$GATE_TOOLS_AUTOBUILDER_BIN" --version 2>/dev/null | head -n1)"
  fi

  local final_out; final_out="$(gate_tools_probe "$ip")"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local drift_json=""
  if [ -n "$final_out" ]; then
    drift_json="$(python3 -c '
import json, sys
lines = sys.argv[1].strip().splitlines()
local_ab_version = sys.argv[3]
tools, missing = {}, []
for ln in lines:
    if "=" not in ln:
        continue
    k, v = ln.split("=", 1)
    tools[k] = v
    if v == "MISSING":
        missing.append(k)
drift = {}
ab_remote = tools.get("autobuilder")
if ab_remote and ab_remote != "MISSING" and local_ab_version:
    if ab_remote.strip() != local_ab_version.strip():
        drift = {"local": local_ab_version.strip(), "remote": ab_remote.strip()}
        if "autobuilder" not in missing:
            missing.append("autobuilder")
out = {"tools": tools, "missing": missing, "gate_tool_versions": tools}
if drift:
    out["version_drift"] = {"autobuilder": drift}
json.dump(out, open(sys.argv[2], "w"))
print(json.dumps(drift))
' "$final_out" "$GATE_TOOLS_STATE_FILE" "$local_ab_version")"
    GATE_TOOLS_MISSING="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d.get("missing",[])))' "$GATE_TOOLS_STATE_FILE" 2>/dev/null || true)"
  else
    python3 -c '
import json, sys
json.dump({"tools": {}, "missing": sys.argv[1].split(), "gate_tool_versions": {}}, open(sys.argv[2], "w"))
' "$GATE_TOOLS_LIST" "$GATE_TOOLS_STATE_FILE"
    GATE_TOOLS_MISSING="$GATE_TOOLS_LIST"
  fi
  if [ -n "$drift_json" ] && [ "$drift_json" != "{}" ]; then
    local dl dr
    dl="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("local",""))' "$drift_json" 2>/dev/null || true)"
    dr="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("remote",""))' "$drift_json" 2>/dev/null || true)"
    journal_line "$(now_iso)  burst-lane  gate-tools  version-drift  (tool=autobuilder local=\"$dl\" remote=\"$dr\")"
  fi
  if [ -z "$GATE_TOOLS_MISSING" ]; then GATE_READY="true"; else GATE_READY="false"; fi
}

# ---- reviewer credential placement/shred (PRD-build-gate-on-casper --------
# requirement 4) -------------------------------------------------------------
# Opt-in (BURST_GATE_REVIEWER=1 — the snapshot and every other box never
# see this file otherwise): `up` pushes the operator's Claude OAuth
# credential file to the box at $GATE_CRED_REMOTE_PATH, mode 0600, and
# journals ONLY that it did so — never the file's own content or even its
# byte count, which could leak a token length. `down`/`watchdog` call
# shred_gate_credential unconditionally (cheap, idempotent — `shred -u` on
# a path that was never placed just fails silently and journals nothing);
# the journal line is gated on the shred call's own exit code, so
# "cred  shredded" only ever appears when a real file was actually
# destroyed, with no separate "was it placed" state to keep in sync.
place_gate_credential() {  # $1=ip
  [ "${BURST_GATE_REVIEWER:-0}" = "1" ] || return 0
  local ip="$1"
  if [ ! -f "$GATE_CRED_SRC" ]; then
    journal_line "$(now_iso)  burst-lane  up  cred-absent  (BURST_GATE_REVIEWER=1 but no credential file at $GATE_CRED_SRC — reviewer will not run)"
    return 0
  fi
  "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "mkdir -p '$(dirname "$GATE_CRED_REMOTE_PATH")'" >/dev/null 2>&1 || true
  if "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
       "$GATE_CRED_SRC" "$REMOTE_USER@$ip:$GATE_CRED_REMOTE_PATH" >/dev/null 2>&1; then
    "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "chmod 600 '$GATE_CRED_REMOTE_PATH'" >/dev/null 2>&1 || true
    journal_line "$(now_iso)  burst-lane  up  cred  placed  (host=$ip)"
  else
    journal_line "$(now_iso)  burst-lane  up  cred-place-failed  (host=$ip — rsync push failed, reviewer will not run)"
  fi
}

shred_gate_credential() {  # $1=ip $2=caller(down|watchdog)
  local ip="${1:-}" caller="${2:-down}"
  [ -n "$ip" ] || return 0
  if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
       "shred -u -f '$GATE_CRED_REMOTE_PATH'" >/dev/null 2>&1; then
    journal_line "$(now_iso)  burst-lane  $caller  cred  shredded  (host=$ip)"
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
    box_bootstrap "$aip"
    volume_ensure "$aip" "$aid"
    local sbx; sbx="$(sandbox_probe "$aip")"
    provision_gate_tools "$aip"
    place_gate_credential "$aip"
    : > "$SERVED_FILE"
    state_write "server_id=$aid" "ip=$aip" "server_type=$SERVER_TYPE" \
      "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
      "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
      "teardown_scheduled=false" "teardown_epoch=" "remote_user=$REMOTE_USER" \
      "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING"
    journal_line "$(now_iso)  burst-lane  up  adopted  (server_id=$aid ip=$aip sandbox_ok=$sbx gate_ready=$GATE_READY)"
    ( cmd_verify >/dev/null 2>&1 ) || journal_line "$(now_iso)  burst-lane  up  verify-failed-after-adopt  (lane unverified — run falls back local)"
    schedule_session_parity "$aid"
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

  # Wait for ssh (bounded — never hang a tick forever). Hardcoded root@, not
  # $REMOTE_USER@ — on a truly fresh snapshot boot $REMOTE_USER (build) does
  # not exist yet, only root does; box_bootstrap below is what creates it.
  local tries=0
  while [ "$tries" -lt 30 ]; do
    if "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
         -i "$SSH_KEY" "root@$ip" true >/dev/null 2>&1; then
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
  volume_ensure "$ip" "$id"
  local sbx; sbx="$(sandbox_probe "$ip")"
  provision_gate_tools "$ip"
  place_gate_credential "$ip"
  : > "$SERVED_FILE"
  state_write "server_id=$id" "ip=$ip" "server_type=$SERVER_TYPE" \
    "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
    "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
    "teardown_scheduled=false" "teardown_epoch=" "remote_user=$REMOTE_USER" \
    "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING"
  journal_line "$(now_iso)  burst-lane  up  booted  (server_id=$id ip=$ip type=$SERVER_TYPE sandbox_ok=$sbx gate_ready=$GATE_READY remote_user=$REMOTE_USER)"
  ( cmd_verify >/dev/null 2>&1 ) || journal_line "$(now_iso)  burst-lane  up  verify-failed-after-boot  (lane unverified — run falls back local)"
  if [ "$sbx" = false ]; then
    journal_line "$(now_iso)  burst-lane  up  sandbox-unavailable  (server_id=$id — rust selection falls back to local cap for python-kind sandboxed tests this tick)"
  fi
  schedule_session_parity "$id"
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
      "$fx/" "$REMOTE_USER@$ip:$rpath/" >/dev/null 2>&1 || vfail "rsync roundtrip (user=$REMOTE_USER)"
  rm -rf "$fx"

  # PRD-build-burst-unprivileged-user requirement 2/4: cargo/uv/python3 all
  # probed as $REMOTE_USER — RUSTUP_HOME/CARGO_HOME point at root's shared,
  # read-only toolchain (requirement 2) regardless of who's asking, so this
  # is a no-op for the REMOTE_USER=root rollback.
  local rout
  rout="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$ROOT_CARGO_HOME; cargo --version && uv --version && python3 -c \"print(1)\"" 2>/dev/null)"
  printf '%s' "$rout" | grep -q "^cargo " || vfail "remote cargo (user=$REMOTE_USER)"
  printf '%s' "$rout" | grep -q "^uv "    || vfail "remote uv (user=$REMOTE_USER)"
  printf '%s' "$rout" | grep -q "^1$"     || vfail "remote python3 (user=$REMOTE_USER)"
  # Requirement 4: the sandbox probe (and the mcphost python-kind suites
  # `run` routes the same way) executes as $REMOTE_USER — a probe failure
  # names the user so an operator isn't left guessing which identity's
  # bwrap access is broken.
  [ "$(sandbox_probe "$ip")" = "true" ]   || vfail "bwrap sandbox (user=$REMOTE_USER)"

  # PRD-build-burst-persistent-volume requirement 3: confirm $REMOTE_USER can
  # actually see (and, via mkdir -p, write into) the sccache dir — real
  # regardless of whether a volume is attached this session (a rollback
  # session still has $REMOTE_ROOT on the root disk, same path).
  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "mkdir -p '$REMOTE_SCCACHE_DIR' && [ -d '$REMOTE_SCCACHE_DIR' ]" >/dev/null 2>&1 \
    || vfail "sccache dir ($REMOTE_SCCACHE_DIR)"

  # Requirement 1's own verify check: fails closed, naming the first missing
  # tool, rather than a bare "gate-tools FAIL" — an operator staring at the
  # journal should not have to go re-run provisioning by hand to find out
  # which one.
  #
  # PRD-build-burst-gate-tools-scope requirement 2: gate-tools is scoped OFF
  # the lane's own `$fails` counter — a missing/version-drifted gate tool
  # must never block `verified=true` for ordinary cargo/uv/python runs, only
  # `gate` routing (checked separately by cmd_gate against gate_ready). This
  # is the exact box-165449166 defect: one gate-only tool took the whole
  # lane down for 95 minutes.
  local gt_ready gt_missing gt_first
  gt_ready="$(state_read gate_ready)"; gt_missing="$(state_read gate_tools_missing)"
  if [ "$gt_ready" = "true" ]; then
    echo "gate-tools ok"
  else
    gt_first="${gt_missing%%,*}"
    echo "verify FAIL: gate-tools (missing: ${gt_first:-unknown})"
    journal_line "$(now_iso)  burst-lane  verify  gate-tools-missing  (missing=${gt_missing:-unknown})"
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
    "remote_user=$(state_read remote_user)" \
    "gate_ready=$gt_ready" "gate_tools_missing=$gt_missing" \
    "verified=true"
  probe_emit burst-verify clean "rsync+cargo+uv+python3+sandbox all real" >/dev/null
  journal_line "$(now_iso)  burst-lane  verify  ok  (rsync+cargo+uv+python3+sandbox all real)"
  echo "verify: ok"
  exit 0
}

# ---- migrate a live session onto the unprivileged user (PRD-build-burst- --
# unprivileged-user requirement 6) ------------------------------------------
# `provision` on a session that booted before this PRD shipped (or is
# running the BURST_LANE_REMOTE_USER=root rollback and is switching back) is
# still root-only; this brings it up to $REMOTE_USER without a reboot: the
# same create_remote_user() call `up` uses, then a remote-side `cp -a` (as
# root — the only user who can read the OLD root-owned tree — bucketed with
# user creation for the same "root only for provisioning" reason) of every
# still-dirty worktree's remote dir from the old tree into the new one, so a
# following `run` does not silently start from an empty $REMOTE_ROOT. A
# worktree whose copy fails goes cold (marker cleared) rather than blocking
# migration — the next run/pull just re-syncs it fresh, exactly like a
# worktree's first-ever run would.
# `du -sb`+`find | wc -l` of a remote path, as root (the only identity that
# can read both the old root-owned tree and, post-migration, the new
# build-owned one) — a single ssh round trip returning "bytes\tcount",
# "0\t0" for a path that doesn't exist. PRD-build-burst-parity-robust
# requirement 4's verified-copy check.
remote_dir_stats() {  # $1=ip $2=path -> stdout "bytes\tcount"
  local ip="$1" path="$2" out
  out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
    "if [ -d '$path' ]; then b=\$(du -sb '$path' 2>/dev/null | cut -f1); c=\$(find '$path' 2>/dev/null | wc -l); printf '%s\t%s\n' \"\${b:-0}\" \"\${c:-0}\"; else printf '0\t0\n'; fi" 2>/dev/null)"
  [ -n "$out" ] && printf '%s\n' "$out" || printf '0\t0\n'
}

migrate_remote_user() {  # $1=ip $2=prior_user
  local ip="$1" prior_user="$2"
  create_remote_user "$ip"

  local prior_home; [ "$prior_user" = "root" ] && prior_home="/root" || prior_home="/home/$prior_user"

  mkdir -p "$DIRTY_DIR" 2>/dev/null || true
  local f wt old_remote_path new_remote_path kind
  for f in "$DIRTY_DIR"/*.json; do
    [ -e "$f" ] || continue
    wt="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("worktree", ""))
except Exception:
    print("")
' "$f" 2>/dev/null)"
    [ -n "$wt" ] || continue
    old_remote_path="$(dirty_field "$wt" remote_path)"
    [ -n "$old_remote_path" ] || old_remote_path="$prior_home/build/$(basename "$wt")-$(printf '%s' "$wt" | sha1sum | cut -c1-8)"
    new_remote_path="$(remote_path_for "$wt")"
    if [ "$old_remote_path" = "$new_remote_path" ]; then
      continue  # BURST_LANE_REMOTE_ROOT is pinned identically either way
    fi
    kind="$(dirty_field "$wt" kind)"; kind="${kind:-target}"
    # chown is best-effort and never gates migrated-vs-cold on its own — the
    # copy having landed is what matters for correctness (a later `run`
    # re-syncs the worktree as build anyway, fixing ownership as a side
    # effect even if this chown failed); only mkdir+cp's own exit code
    # decides migrated vs cold, preserved past the chown via `exit $rc`.
    if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
         "mkdir -p '$new_remote_path' && cp -a '$old_remote_path/.' '$new_remote_path/' 2>/dev/null; rc=\$?; chown -R '$REMOTE_USER:$REMOTE_USER' '$new_remote_path' 2>/dev/null || true; exit \$rc" >/dev/null 2>&1; then
      mark_dirty "$wt" "$(state_read server_id)" "$new_remote_path" "$kind"
      journal_line "$(now_iso)  burst-lane  provision  migrated  (worktree=$wt from=$old_remote_path to=$new_remote_path)"

      # PRD-build-burst-parity-robust requirement 4: the copy landing is not
      # enough on its own to delete the source — verify size AND file count
      # match before removing it, so a partial/corrupt copy never loses data;
      # a mismatch keeps the old directory around (residue over data loss)
      # and says why, rather than silently leaving it forever unexplained.
      local old_stats new_stats old_bytes old_count new_bytes new_count
      old_stats="$(remote_dir_stats "$ip" "$old_remote_path")"
      new_stats="$(remote_dir_stats "$ip" "$new_remote_path")"
      old_bytes="$(cut -f1 <<<"$old_stats")"; old_count="$(cut -f2 <<<"$old_stats")"
      new_bytes="$(cut -f1 <<<"$new_stats")"; new_count="$(cut -f2 <<<"$new_stats")"
      if [ "$old_bytes" = "$new_bytes" ] && [ "$old_count" = "$new_count" ]; then
        if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
             "rm -rf '$old_remote_path'" >/dev/null 2>&1; then
          journal_line "$(now_iso)  burst-lane  provision  migrated-removed  (from=$old_remote_path)"
        else
          journal_line "$(now_iso)  burst-lane  provision  migrate-keep  (cause=remove-failed from=$old_remote_path)"
        fi
      else
        journal_line "$(now_iso)  burst-lane  provision  migrate-keep  (cause=copy-mismatch from=$old_remote_path old_bytes=$old_bytes new_bytes=$new_bytes old_count=$old_count new_count=$new_count)"
      fi
    else
      clear_dirty "$wt"
      journal_line "$(now_iso)  burst-lane  provision  migrate-cold  (worktree=$wt cause=copy-failed old=$old_remote_path new=$new_remote_path)"
    fi
  done
  journal_line "$(now_iso)  burst-lane  provision  user-migrated  (server_id=$(state_read server_id) from=$prior_user to=$REMOTE_USER)"
}

# ---- provision --------------------------------------------------------------
# PRD-build-burst-gate-tools-scope requirement 4: retry every missing gate
# tool's install on the LIVE box and re-run the gate-tools check, without a
# reboot — an operator who fixed whatever blocked an install (a flaky apt
# mirror, a since-corrected autobuilder build on RedBaron) shouldn't have to
# tear a healthy, verified box down and burn another `up` cycle just to pick
# up gate readiness.
cmd_provision() {
  if ! state_active; then
    echo "provision: no active session"; exit 1
  fi
  local ip; ip="$(state_read ip)"

  # PRD-build-burst-unprivileged-user requirement 6: migrate a root-only
  # session in place. A session with no remote_user field at all predates
  # this PRD and reads as "root" — this lane's pre-ship-only identity.
  local prior_user; prior_user="$(state_read remote_user)"; prior_user="${prior_user:-root}"
  if [ "$prior_user" != "$REMOTE_USER" ]; then
    migrate_remote_user "$ip" "$prior_user"
  fi

  provision_gate_tools "$ip"
  state_write "server_id=$(state_read server_id)" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$(state_read runs_served)" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" \
    "verified=$(state_read verified)" "remote_user=$REMOTE_USER" \
    "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING"
  journal_line "$(now_iso)  burst-lane  provision  done  (server_id=$(state_read server_id) gate_ready=$GATE_READY gate_tools_missing=${GATE_TOOLS_MISSING:-none} remote_user=$REMOTE_USER)"
  echo "provision: gate_ready=$GATE_READY missing=${GATE_TOOLS_MISSING:-}"
  [ "$GATE_READY" = "true" ] && exit 0
  exit 1
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

  # PRD-build-gate-on-casper requirement 6/8: currently-running remote
  # gates, straight from the same gate-inflight markers cmd_gate writes and
  # gate_wait_for_inflight() reads — so `status --json` (and a tick
  # deciding whether to dispatch another gate) never has to ssh in or
  # reverse-engineer it from the journal.
  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  local gates_json
  gates_json="$(python3 -c '
import json, glob, sys
now = int(sys.argv[1])
rows = []
for f in sorted(glob.glob(sys.argv[2] + "/*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    d["age_seconds"] = max(0, now - d.get("started_epoch", now))
    rows.append(d)
print(json.dumps(rows))
' "$(now_epoch)" "$GATE_INFLIGHT_DIR")"

  # Requirement 8's own text-mode ask: "status lists running remote gates
  # with repo, HEAD, age, and slot" — one line per gate, HEAD shortened to
  # 12 chars (readable, still unambiguous) the same way `git log --oneline`
  # would.
  local gate_lines
  gate_lines="$(python3 -c '
import json, sys
for r in json.loads(sys.argv[1]):
    head = (r.get("head_sha") or "")[:12]
    print("gate: %s head=%s age=%ss slot=%s" % (r.get("repo", ""), head or "?", r.get("age_seconds", 0), r.get("slot") or "?"))
' "$gates_json")"

  # PRD-build-burst-persistent-volume requirement 4/AC6: volume.{id,size_gb,
  # used_pct} — a live read (volume_status_probe), not last-boot's cached
  # figure, so an operator's `status` and the disk-guard's own numbers never
  # disagree about which filesystem is being described.
  local vol_json="null" vol_line=""
  local vol_probe; vol_probe="$(volume_status_probe "$ip" 2>/dev/null)"
  if [ -n "$vol_probe" ]; then
    local vp_id vp_size vp_pct
    read -r vp_id vp_size vp_pct <<<"$vol_probe"
    vol_json="{\"id\":\"$vp_id\",\"size_gb\":${vp_size:-0},\"used_pct\":${vp_pct:-0}}"
    vol_line=" volume=attached ${vp_pct:-0}%"
  fi

  # PRD-build-burst-persistent-volume requirement 9: RedBaron's own free
  # disk (the pull-back DESTINATION `do_marker_pull`'s local-disk guard
  # checks against) — surfaced here so an operator sees it beside the box's
  # own free_disk_gb rather than having to ssh into neither host to find it.
  local redbaron_free_gb; redbaron_free_gb="$(local_disk_free_gb "$STATE_DIR")"
  case "$redbaron_free_gb" in ''|*[!0-9]*) redbaron_free_gb="null" ;; esac

  # PRD-build-burst-parity-cadence requirement 5: this session's parity
  # state per configured repo (BURST_PARITY_REPOS), straight from each
  # repo's own box-parity.json — best-effort, a repo with no receipt yet is
  # simply absent from the array rather than a fabricated placeholder.
  local parity_json
  parity_json="$(python3 -c '
import json, sys
root, repos = sys.argv[1], sys.argv[2].split()
out = []
for name in repos:
    f = "%s/%s/target/autobuilder/receipts/box-parity.json" % (root, name)
    try:
        d = json.load(open(f))
    except Exception:
        continue
    out.append({
        "repo": name,
        "session_id": d.get("session_id"),
        "head_sha": d.get("head_sha"),
        "diff": d.get("diff", []),
        "host_sensitive": d.get("host_sensitive", []),
    })
print(json.dumps(out))
' "$ATTR_REPOS_DIR" "$BURST_PARITY_REPOS")"

  if [ "$json" -eq 1 ]; then
    printf '{"active":true,"server_id":"%s","ip":"%s","minutes_alive":%s,"ttl_hours":"%s","sandbox_ok":"%s","concurrent":"%s","free_disk_gb":%s,"disk_state":"%s","dirty":%s,"gates":%s,"gate_ready":"%s","gate_tools_missing":"%s","volume":%s,"redbaron_free_gb":%s,"parity":%s}\n' \
      "$id" "$ip" "$alive" "$ttl" "$sbx" "$conc" "$free_disk_gb" "$disk_state" "$dirty_json" "$gates_json" "$(state_read gate_ready)" "$(state_read gate_tools_missing)" "$vol_json" "$redbaron_free_gb" "$parity_json"
  else
    local gate_count; gate_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$gates_json")"
    # PRD-build-burst-gate-tools-scope requirement 3: an operator (or
    # lane-claim.sh) reading text-mode status must see gate readiness at a
    # glance, independent of whether the lane itself is verified for
    # ordinary runs.
    # NOTE: redbaron_free_gb is intentionally JSON-only (not appended here)
    # — an existing gatetools AC4 case anchors on "missing=$(state_read
    # gate_tools_missing)" being the last token on this line whenever no
    # volume line follows; text-mode operators already get free_disk_gb
    # (the box) and volume=attached (the volume) on this same line.
    echo "active: $id ip=$ip alive=${alive}m ttl=${ttl}h sandbox_ok=$sbx concurrent=$conc disk_state=$disk_state free_disk_gb=$free_disk_gb gates:${gate_count} gate_ready=$(state_read gate_ready) missing=$(state_read gate_tools_missing)${vol_line}"
    [ -n "$dirty_lines" ] && printf '%s\n' "$dirty_lines"
    [ -n "$gate_lines" ] && printf '%s\n' "$gate_lines"
    local parity_lines; parity_lines="$(python3 -c '
import json, sys
for r in json.loads(sys.argv[1]):
    head = (r.get("head_sha") or "")[:12]
    print("parity: %s session=%s head=%s diff=%d host_sensitive=%d" % (
        r.get("repo", ""), r.get("session_id") or "?", head or "?",
        len(r.get("diff") or []), len(r.get("host_sensitive") or [])))
' "$parity_json")"
    [ -n "$parity_lines" ] && printf '%s\n' "$parity_lines"
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
attribution_record() {  # $1=slug $2=session_id $3=wall_s $4=sync_s $5=bytes $6=worktree [$7=kind $8=pulls_skipped $9=bytes_saved $10=estimate $11=trigger $12=warm]
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local kind="${7:-run}" pulls_skipped="${8:-0}" bytes_saved="${9:-0}" estimate="${10:-false}" trigger="${11:-}" warm="${12:-}"
  python3 -c '
import json, sys
slug, sid, wall_s, sync_s, nbytes, worktree, date, path, kind, pulls_skipped, bytes_saved, estimate, trigger, warm = sys.argv[1:15]
row = {
    "date": date, "session_id": sid, "slug": slug,
    "wall_seconds": round(float(wall_s), 3), "sync_s": round(float(sync_s), 3),
    "bytes": int(nbytes or 0), "worktree": worktree, "kind": kind,
}
if kind == "pull":
    row["trigger"] = trigger
elif kind == "gate":
    # PRD-build-gate-on-casper requirement 9: a completed remote gate run
    # attributes as its own row (slug=gate-<repo>, per PRD-build-gate-
    # cargo-route-attest convention for a gate dispatch) rather than the
    # pulls_skipped/bytes_saved/estimate fields a plain cargo run carries
    # -- those describe lazy target pull-back, not a gate.
    row["remote"] = True
else:
    row["pulls_skipped"] = int(pulls_skipped or 0)
    row["bytes_saved"] = int(bytes_saved or 0)
    row["estimate"] = (estimate == "true")
    # PRD-build-burst-persistent-volume requirement 5: warm=true|false, only
    # meaningful for a plain run row (a pull/gate row has no "did the target
    # dir already exist before this action" question of its own).
    if warm != "":
        row["warm"] = (warm == "true")
with open(path, "a") as fh:
    fh.write(json.dumps(row) + "\n")
' "$1" "$2" "$3" "$4" "$5" "$6" "$(now_iso)" "$ATTR_LEDGER" "$kind" "$pulls_skipped" "$bytes_saved" "$estimate" "$trigger" "$warm"
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

# PRD-build-burst-persistent-volume requirement 9: RedBaron's own free disk
# (the pull DESTINATION, never the box's — a wholly separate filesystem from
# every other free-space read in this script). BURST_LANE_LOCAL_FREE_GB is
# the offline-test seam (mirrors every other BURST_LANE_NOW-style override
# here) — a real `df` never runs under it, same doctrine as the box-side
# probes' own FAKE_SSH_* knobs.
local_disk_free_gb() {  # $1=path -> stdout free GB, or empty on an unreadable probe
  if [ -n "${BURST_LANE_LOCAL_FREE_GB:-}" ]; then
    echo "$BURST_LANE_LOCAL_FREE_GB"
    return 0
  fi
  df -BG --output=avail "$1" 2>/dev/null | tail -n1 | tr -dc '0-9'
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

  # PRD-build-burst-persistent-volume requirement 9: the pull-back
  # DESTINATION guard, checked before every other reason to give up or
  # proceed below — a low-disk RedBaron root must DEFER (marker stays
  # dirty, retried whenever this worktree is next read/pulled/swept) rather
  # than being reclassified "cold" (which permanently drops the artifact)
  # or attempted and left to fail mid-transfer, one gate pull after another,
  # the way four straight 87/49/87/19 GB pulls actually took RedBaron's
  # root to 0 bytes free on 2026-09-11. need_gb is the larger of the
  # configured floor and this worktree's own last-observed pull size (the
  # best evidence of what THIS pull is about to cost) — fails OPEN (proceeds)
  # on an unreadable probe, never blocking a pull the real disk has room for.
  local pull_free_gb; pull_free_gb="$(local_disk_free_gb "$worktree")"
  case "$pull_free_gb" in
    ''|*[!0-9]*) : ;;
    *)
      local pull_last_bytes pull_last_gb pull_need_gb
      pull_last_bytes="$(last_pull_size "$worktree")"
      pull_last_gb="$(awk -v b="${pull_last_bytes:-0}" 'BEGIN{printf "%.0f", b/1073741824}')"
      pull_need_gb="$BURST_LOCAL_DISK_FLOOR_GB"
      [ "${pull_last_gb:-0}" -gt "$pull_need_gb" ] 2>/dev/null && pull_need_gb="$pull_last_gb"
      if [ "$pull_free_gb" -lt "$pull_need_gb" ]; then
        journal_line "$(now_iso)  burst-lane  pull  deferred  (worktree=$worktree trigger=$trigger cause=local-disk free_gb=$pull_free_gb need_gb=$pull_need_gb)"
        return 0
      fi
      ;;
  esac

  if ! state_active; then
    clear_dirty "$worktree"
    journal_line "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid trigger=$trigger cause=no-active-session — local target stale, next local build recompiles)"
    return 0
  fi
  local ip; ip="$(state_read ip)"

  # PRD-build-burst-persistent-volume requirement 8: a marker's remote_path
  # is only ever valid under the CURRENT $REMOTE_ROOT — a root move (a
  # volume mount, the 2026-09-11 user migration, a future rollback) leaves
  # old markers naming a path under a root that no longer applies, and an
  # ssh round trip against it is not reliable evidence either way (a stale
  # /root/build/... path can exist-but-be-unreadable under the new
  # unprivileged user, producing a false "exists" or a permission-flavored
  # ssh failure that `run`'s rsync then retries as rsync-failed instead of
  # recognizing as cold — the 2026-09-11 wintermute-brain-wmd-local-gpu-rung
  # evidence, three rsync-failed retries against a marker still naming
  # /root/build). Checked BEFORE any ssh round trip: deterministic, no
  # network needed, and it is what the AC actually asks for — "never
  # retried as rsync-failed".
  case "$remote_path" in
    "$REMOTE_ROOT"/*) : ;;
    *)
      clear_dirty "$worktree"
      journal_line "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid remote_path=$remote_path trigger=$trigger cause=remote-path-missing — local target stale, next local build recompiles)"
      return 0
      ;;
  esac

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
# caught on first run). Sets SLOT_HELD="held/cap" and SLOT_INDEX (the actual
# 1..cap slot number acquired — requirement 8 wants this reported per gate);
# holds fd 202 on return.
SLOT_HELD=""
SLOT_INDEX=""
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
        SLOT_INDEX="$i"
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

  # PRD-build-burst-persistent-volume requirement 5: warm attribution — did
  # this worktree's target dir (or .pybuilder/, for a uv-routed run) already
  # exist on the box BEFORE this run's own rsync-up creates it if missing?
  # Checked here, before rsync-up (which `--rsync-path="mkdir -p ..."`
  # unconditionally creates the parent of), and keyed off the same first-arg
  # command name `first`/`kind` are derived from further down — a live
  # volume makes this true on a fresh box's very first run against a
  # worktree it built yesterday (the whole point of the persistent volume);
  # an empty/never-attached tree makes it false, same as today.
  local warm_kind warm=false
  case "$1" in
    */uv|uv) warm_kind="$remote_path/.pybuilder" ;;
    *)       warm_kind="$remote_path/target" ;;
  esac
  remote_dir_exists "$ip" "$warm_kind" && warm=true

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
  # PRD-build-burst-unprivileged-user requirement 2: RUSTUP_HOME/CARGO_HOME
  # hardcoded at root's shared, read-only toolchain regardless of who's
  # running this (a no-op for the REMOTE_USER=root rollback, since that's
  # already root's own default there); SCCACHE_DIR is $REMOTE_USER's OWN
  # cache, never root's — sccache's cache dir needs write, not just read.
  local remote_cmd="cd $remote_path && export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$ROOT_CARGO_HOME CARGO_TARGET_DIR=$remote_path/target RUSTC_WRAPPER=sccache SCCACHE_DIR=$REMOTE_SCCACHE_DIR SCCACHE_CACHE_SIZE=${BURST_SCCACHE_GB}G; timeout 5 sccache --show-stats >/dev/null 2>&1 || { sccache --stop-server >/dev/null 2>&1; sccache --start-server >/dev/null 2>&1; sleep 1; }; timeout 5 sccache --show-stats >/dev/null 2>&1 || { echo 'burst-lane: sccache_unreachable on remote box' >&2; exit 97; }; $first $*"
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
    "remote_user=$(state_read remote_user)" \
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
  attribution_record "$slug" "$id" "$wall_s" "$sync_s" 0 "$worktree" run 1 "$bytes_saved" true "" "$warm"

  flock -u 201

  journal_line "$(now_iso)  burst-lane  run  routed  (server_id=$id worktree=$worktree runs_served=$runs exit=$rc dirty=1 kind=$kind bytes_saved=$bytes_saved slug=$slug wall_s=$wall_s concurrent=$slot_held warm=$warm)"
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

# ---- nextest-based parity (PRD-build-burst-parity-robust requirement 1) ----
# cargo-nextest is already provisioned on the box (GATE_TOOLS_LIST) and
# RedBaron has it locally, so this is the PRIMARY capture path; the
# `cargo_test_suites_json` parser above stays as the fallback used only when
# a side lacks cargo-nextest (Migration/compatibility: rollback is the
# previous parser).
#
# nextest's human run output is one line per test:
#   PASS [   0.003s] (1/3) <binary-id> <test-name>
# (the "(n/m)" progress counter is present under a tty/default profile and
# absent under some profiles — treated as optional). Unlike the Running/
# result pairing cargo_test_suites_json depends on, EVERY line carries its
# own binary-id — there is no "current suite" state to lose track of, so a
# suite that finishes in 0.00s and prints before, after, or interleaved with
# any other binary's lines is never misattributed (requirement 1's actual
# fix, not merely a symptom patch on top of the old parser).
cargo_nextest_suites_json() {  # stdin=log -> stdout JSON object {binary_id: "ok"|"FAILED"}
  python3 -c '
import json, re, sys
line_re = re.compile(r"^\s*(PASS|FAIL|TIMEOUT|LEAK|ABORT)\s+\[\s*[0-9.]+s\]\s+(?:\(\d+/\d+\)\s+)?(\S+)\s+\S")
suites = {}
for line in sys.stdin:
    m = line_re.match(line)
    if not m:
        continue
    status, binary = m.group(1), m.group(2)
    st = "ok" if status == "PASS" else "FAILED"
    # Once FAILED, stays FAILED regardless of what order any other line for
    # the same binary-id shows up in (--no-fail-fast runs every test in a
    # binary even after one fails).
    if suites.get(binary) != "FAILED":
        suites[binary] = st
print(json.dumps(suites))
'
}

# `cargo nextest list --workspace --message-format json`'s "rust-suites" keys
# ARE the binary-ids cargo_nextest_suites_json() attributes result lines to —
# this is the suite SET a run should have produced a result for. Used to seed
# every listed name as "no-output" before the run-parsed results overwrite
# whichever ones actually printed a line, so a suite with zero result lines
# (crashed silently, filtered to zero tests, etc.) reads as the named state
# "no-output" rather than being silently absent from the suites map.
cargo_nextest_list_names() {  # stdin=list --message-format json -> stdout one binary-id per line
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sorted(d.get("rust-suites", {}) or {}):
    print(k)
'
}

nextest_merge_suites() {  # $1=names(newline-separated) $2=results_json -> stdout JSON object
  python3 -c '
import json, sys
names = [n for n in sys.argv[1].split("\n") if n]
results = json.loads(sys.argv[2]) if sys.argv[2] else {}
out = {n: results.get(n, "no-output") for n in names}
# A result for a binary the list call did not enumerate (list/run skew,
# e.g. a binary that only appears once built) is still recorded rather than
# silently dropped.
for k, v in results.items():
    out.setdefault(k, v)
print(json.dumps(out))
' "$1" "$2"
}

# BURST_LANE_FORCE_NEXTEST_LOCAL ("0"/"1") is a selftest-only override —
# unlike the box side (fully mediated through the fake ssh fixture, which
# already answers "command -v cargo-nextest" deterministically), this local
# check is a plain shell builtin against whatever REALLY happens to be on
# this machine's $PATH. RedBaron genuinely has cargo-nextest in ~/.cargo/bin
# (production's intended primary path), so an offline selftest that doesn't
# opt into exercising the nextest path needs a way to force the pre-nextest
# cargo-test fallback deterministically rather than silently depending on
# whatever happens to be installed on whichever machine runs the suite.
nextest_present_local() {
  case "${BURST_LANE_FORCE_NEXTEST_LOCAL:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  command -v cargo-nextest >/dev/null 2>&1
}

# ---- nextest no-output rerun (PRD-build-burst-parity-robust requirement 3) -
# A "no-output" suite (nextest's list enumerated it, but zero PASS/FAIL lines
# for it showed up in the run log) is re-run ALONE — `-E 'binary_id(<name>)'`
# is nextest's own filterset syntax for exactly one binary — once per side,
# before comparison. Small, focused helpers so cmd_parity's box/local
# branches stay symmetric instead of duplicating the parse-and-extract logic.
nextest_rerun_result_local() {  # $1=repo $2=suite_name -> stdout "ok"|"FAILED"|"no-output"
  local repo="$1" name="$2" log
  log="$(cd "$repo" && cargo nextest run --workspace --no-fail-fast -E "binary_id($name)" 2>&1)"
  printf '%s\n' "$log" | cargo_nextest_suites_json | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get(sys.argv[1], "no-output"))
' "$name"
}

nextest_rerun_result_box() {  # $1=ip $2=remote_env_prefix $3=suite_name -> stdout result
  local ip="$1" prefix="$2" name="$3" log
  log="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "$prefix; cargo nextest run --workspace --no-fail-fast -E \"binary_id($name)\"" 2>&1)"
  printf '%s\n' "$log" | cargo_nextest_suites_json | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get(sys.argv[1], "no-output"))
' "$name"
}

json_set_str() {  # $1=json $2=key $3=value -> stdout updated json
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); d[sys.argv[2]] = sys.argv[3]; print(json.dumps(d))
' "$1" "$2" "$3"
}

json_names_with_value() {  # $1=json $2=value -> stdout one matching key per line
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print("\n".join(sorted(k for k, v in d.items() if v == sys.argv[2])))
' "$1" "$2"
}

# ---- session-scoped parity validity (PRD-build-burst-parity-cadence) -------
# requirement 1: a parity receipt is valid for a BOX SESSION + TOOLCHAIN
# FINGERPRINT, not for a single HEAD — the old contract ("head_sha must equal
# the HEAD being gated") forced a fresh full local `cargo test --workspace`
# run on every new commit even though nothing about the box or the toolchain
# had changed. toolchain_fingerprint() hashes the three things that actually
# invalidate a prior proof: the box's own gate-tool versions (GATE_TOOLS_
# STATE_FILE, refreshed by `up`/`provision`), the locally installed rustup
# toolchains (RedBaron's own compiler set), and the box image id (SNAPSHOT_ID)
# — any of those changing means the comparison itself could differ even at an
# unchanged HEAD.
toolchain_fingerprint() {
  local rl gv snap
  rl="$(rustup toolchain list 2>/dev/null | sort | tr '\n' ';')"
  gv="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(json.dumps(d.get("gate_tool_versions", {}), sort_keys=True))
' "$GATE_TOOLS_STATE_FILE" 2>/dev/null)"
  snap="${SNAPSHOT_ID:-$DEFAULT_SNAPSHOT_ID}"
  printf '%s|%s|%s' "$rl" "$gv" "$snap" | sha1sum | awk '{print $1}' | cut -c1-16
}

# `valid_until` is a descriptive field on the receipt (requirement 1: "valid
# for the session end") — the actual validity CHECK (see check_parity_receipt
# below) is session_id + toolchain_fp equality, never a clock comparison, so
# a stale wall clock or a long-lived session is never treated as invalid on
# its own. Empty when a session's boot/ttl bookkeeping isn't available (e.g.
# no active session yet), never fabricated.
session_valid_until() {
  local boot_epoch ttl_hours
  boot_epoch="$(state_read boot_epoch)"
  ttl_hours="$(state_read ttl_hours)"
  case "$boot_epoch" in ''|*[!0-9]*) echo ""; return 0 ;; esac
  case "$ttl_hours" in ''|*[!0-9.]*) echo ""; return 0 ;; esac
  local until_epoch; until_epoch="$(awk -v b="$boot_epoch" -v t="$ttl_hours" 'BEGIN{printf "%d", b + (t*3600)}')"
  date -u -d "@$until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}

# requirement 4: a per-repo `.burst-lane.toml`'s `parity_exclude = [...]`
# array names suites whose outcome is documented as host-dependent. Parsed
# with a small regex rather than a TOML library dependency — the file's own
# convention (see mcphost's `.burst-lane.toml`) is a single flat string
# array, nothing this needs a real parser for. Absent file or absent key
# both read as "nothing excluded".
read_parity_exclude() {  # $1=repo -> stdout: space-separated suite names
  local f="$1/.burst-lane.toml"
  [ -f "$f" ] || { echo ""; return 0; }
  python3 -c '
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^\s*parity_exclude\s*=\s*\[(.*?)\]", text, re.MULTILINE | re.DOTALL)
if not m:
    print("")
    raise SystemExit(0)
items = re.findall(r"\"([^\"]*)\"|\x27([^\x27]*)\x27", m.group(1))
print(" ".join(a or b for a, b in items))
' "$f"
}

# requirement 4's other half: create the placeholder file (empty exclude
# list) when a repo has none yet, so the valve is visible before any repo
# actually needs it — mirrors mcphost's own placeholder, created by hand for
# that repo ahead of this PRD landing.
ensure_parity_exclude_file() {  # $1=repo
  local f="$1/.burst-lane.toml"
  [ -f "$f" ] && return 0
  cat > "$f" <<'EOF'
# Per-repo burst-lane parity valve. Names suites (nextest binary-ids or
# cargo_test_suites_json keys) whose box/local outcome is documented as
# host-dependent (timing budgets, host-only units) — excluded suites are
# still run and recorded on both sides (see box-parity.json's
# "host_sensitive"), just never counted as a parity diff. Owned by
# PRD-build-burst-parity-cadence, which reads and writes this list; stays
# empty until a genuinely host-sensitive suite needs it — do not add an
# entry here as a substitute for fixing a test's own contract.
parity_exclude = []
EOF
}

# requirement 2: RedBaron's load never rises because of parity. Checked
# BEFORE either side (box or local) does any work — a loaded box gets no
# rsync, no ssh, nothing — so a caller waiting up to PARITY_LOAD_WAIT_S can
# see that nothing ran. Off-RedBaron hosts are never gated (mirrors cargo-
# budget.sh's own is_redbaron() convention; test hooks share its env names).
parity_load_ok() {
  local hostname_val="${CARGO_BUDGET_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
  case "$(printf '%s' "$hostname_val" | tr '[:upper:]' '[:lower:]')" in
    redbaron) : ;;
    *) return 0 ;;
  esac
  local loadavg_file="${CARGO_BUDGET_LOADAVG:-/proc/loadavg}"
  local max_load="${CARGO_BUDGET_MAX_LOAD:-64}"
  local la; la="$(awk '{print $1; found=1} END{if(!found) print 0}' "$loadavg_file" 2>/dev/null || echo 0)"
  awk -v a="$la" -v b="$max_load" 'BEGIN{exit !(a+0 <= b+0)}'
}

# requirement 1: a receipt is valid iff it names the CURRENTLY active session
# and the CURRENT toolchain fingerprint and has no (non-excluded) diff —
# `head_sha` is deliberately never compared here. Returns one of "" (valid),
# "parity-diff", "session", "toolchain" on stdout; caller handles the
# missing-file case itself (that stays "parity-unknown", a distinct cause —
# see cmd_gate).
check_parity_receipt() {  # $1=repo -> stdout cause ("" = valid)
  local repo="$1" parity_file="$1/target/autobuilder/receipts/box-parity.json"
  [ -f "$parity_file" ] || { echo "parity-unknown"; return 0; }
  local cur_session cur_fp
  cur_session="$(state_read server_id)"
  cur_fp="$(toolchain_fingerprint)"
  python3 -c '
import json, sys
path, session, fp = sys.argv[1:4]
d = json.load(open(path))
if d.get("diff"):
    print("parity-diff"); raise SystemExit(0)
if not session or d.get("session_id") != session:
    print("session"); raise SystemExit(0)
if not fp or d.get("toolchain_fp") != fp:
    print("toolchain"); raise SystemExit(0)
print("")
' "$parity_file" "$cur_session" "$cur_fp"
}

# requirement 3: once a session exists (adopted or freshly booted), schedule
# this session's ONE parity proof per configured repo, backgrounded so `up`
# itself returns promptly — gate's own routing then reads that receipt
# (check_parity_receipt, session+toolchain matched) instead of triggering a
# fresh full local test run per HEAD. Each repo's scheduling is journaled
# independently so a missing/unresolvable repo never blocks the others.
schedule_session_parity() {  # $1=session_id
  local sid="$1" name repo
  for name in $BURST_PARITY_REPOS; do
    repo="$ATTR_REPOS_DIR/$name"
    if [ ! -d "$repo/.git" ]; then
      journal_line "$(now_iso)  burst-lane  parity  schedule-skip  (repo=$name session=$sid cause=not-a-repo)"
      continue
    fi
    journal_line "$(now_iso)  burst-lane  parity  scheduled  (repo=$name session=$sid)"
    ( cmd_parity "$repo" >/dev/null 2>&1 & disown ) 2>/dev/null || true
  done
}

# ---- parity (PRD-build-gate-on-casper requirement 2) ------------------------
cmd_parity() {
  local repo="${1:-}"
  [ -n "$repo" ] && [ -d "$repo" ] || { echo "usage: burst-lane.sh parity <repo>" >&2; exit 2; }

  # PRD-build-burst-parity-cadence requirement 2: load gate FIRST, before
  # either side (box or local) does any work — including bringing a box up.
  # Polls up to PARITY_LOAD_WAIT_S; still too high at the ceiling means
  # defer, not fail — the caller (gate's reproof, or `up`'s background
  # schedule) gets another chance later.
  local pload_wait_start; pload_wait_start="$(now_epoch)"
  while ! parity_load_ok; do
    local pload_now pload_elapsed; pload_now="$(now_epoch)"; pload_elapsed=$(( pload_now - pload_wait_start ))
    if [ "$pload_elapsed" -ge "$PARITY_LOAD_WAIT_S" ]; then
      journal_line "$(now_iso)  burst-lane  parity  deferred  (cause=load repo=$repo waited=${pload_elapsed}s)"
      echo "fallback: load"
      exit 3
    fi
    sleep "$PARITY_LOAD_POLL_S"
  done

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

  # PRD-build-burst-unprivileged-user: this is the exact call
  # `checkcompat_ac02_ac03` failed under — mcphost's own root-guard makes
  # $REMOTE_USER=root an invalid identity to run its integration suite
  # under, hence build (RUSTUP_HOME/CARGO_HOME per requirement 2).
  local remote_env_prefix="cd $remote_path && export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$ROOT_CARGO_HOME CARGO_TARGET_DIR=$remote_path/target"

  # PRD-build-burst-parity-robust requirement 1: cargo-nextest is the
  # PRIMARY capture on both sides (already provisioned on the box via
  # GATE_TOOLS_LIST; RedBaron has it locally) — every result line carries
  # its own binary name, so attribution never depends on stream-interleave
  # ordering the way the old Running/result pairing did. A side lacking
  # cargo-nextest falls back to `cargo test` (the previous parser, kept
  # verbatim as the rollback path).
  local box_capture="cargo-test"
  if "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
       "$remote_env_prefix; command -v cargo-nextest" >/dev/null 2>&1; then
    box_capture="nextest"
  fi
  local box_log box_suites
  if [ "$box_capture" = "nextest" ]; then
    box_log="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "$remote_env_prefix; cargo nextest run --workspace --no-fail-fast" 2>&1)"
    local box_list_json; box_list_json="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "$remote_env_prefix; cargo nextest list --workspace --message-format json" 2>/dev/null)"
    local box_names; box_names="$(printf '%s' "$box_list_json" | cargo_nextest_list_names)"
    local box_results; box_results="$(printf '%s\n' "$box_log" | cargo_nextest_suites_json)"
    box_suites="$(nextest_merge_suites "$box_names" "$box_results")"
  else
    journal_line "$(now_iso)  burst-lane  parity  capture=cargo-test  (side=box repo=$repo)"
    box_log="$("$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "$remote_env_prefix $CARGO_TEST_RUNNER_TARGET_ENV='stdbuf -o0'; cargo test --workspace --no-fail-fast -- --test-threads=1" 2>&1)"
    box_suites="$(printf '%s\n' "$box_log" | cargo_test_suites_json)"
  fi
  flock -u 206

  # PRD-build-burst-parity-cadence requirement 2: the local test run itself
  # (not the `list`/single-suite-rerun calls below, which are cheap
  # metadata/single-binary calls) goes through cargo-budget.sh — nice -n 15,
  # CARGO_BUDGET_TEST_THREADS (default 4), and a ledger row so parity's cost
  # is visible in the same place every other local cargo invocation's is.
  local local_log_file="$repo/target/autobuilder/test-output.txt" local_log local_suites local_capture="cargo-test"
  if nextest_present_local; then
    local_capture="nextest"
    local_log="$(cd "$repo" && CARGO_BUDGET_TEST_THREADS="${CARGO_BUDGET_TEST_THREADS:-4}" "$CARGO_BUDGET_SH" run -- nice -n 15 cargo nextest run --workspace --no-fail-fast 2>&1)"
    local local_list_json; local_list_json="$(cd "$repo" && cargo nextest list --workspace --message-format json 2>/dev/null)"
    local local_names; local_names="$(printf '%s' "$local_list_json" | cargo_nextest_list_names)"
    local local_results; local_results="$(printf '%s\n' "$local_log" | cargo_nextest_suites_json)"
    local_suites="$(nextest_merge_suites "$local_names" "$local_results")"
  else
    journal_line "$(now_iso)  burst-lane  parity  capture=cargo-test  (side=local repo=$repo)"
    if [ -f "$local_log_file" ]; then
      local_log="$(cat "$local_log_file")"
    else
      mkdir -p "$(dirname "$local_log_file")" 2>/dev/null || true
      local_log="$(cd "$repo" && env "$CARGO_TEST_RUNNER_TARGET_ENV=stdbuf -o0" CARGO_BUDGET_TEST_THREADS="${CARGO_BUDGET_TEST_THREADS:-4}" "$CARGO_BUDGET_SH" run -- nice -n 15 cargo test --workspace --no-fail-fast -- --test-threads=1 2>&1)"
      printf '%s\n' "$local_log" > "$local_log_file"
    fi
    local_suites="$(printf '%s\n' "$local_log" | cargo_test_suites_json)"

    # PRD-build-burst-gate-tools-toolchain requirement 4 (cargo-test fallback
    # only — nextest's own list-derived "no-output" state above already
    # covers "box ran a suite this side never baselined" without a special
    # case): a suite the box actually ran but the cached local baseline
    # simply never had (a stale test-output.txt predating that suite, or one
    # that was never run here before) is "baseline-incomplete", not a diff —
    # refresh the local baseline ONCE and recompare, rather than reporting a
    # false diff against a null. Evidence: 2026-09-11 01:36Z, the first
    # parity on 3b1fdbc reported diff=1 for a suite the stale local output
    # simply lacked; the operator had to refresh the local suite by hand to
    # clear it. This makes that refresh automatic.
    local missing_locally; missing_locally="$(python3 -c '
import json, sys
box = json.loads(sys.argv[1])
local = json.loads(sys.argv[2])
print(",".join(sorted(n for n in box if n not in local)))
' "$box_suites" "$local_suites")"
    if [ -n "$missing_locally" ]; then
      local_log="$(cd "$repo" && env "$CARGO_TEST_RUNNER_TARGET_ENV=stdbuf -o0" CARGO_BUDGET_TEST_THREADS="${CARGO_BUDGET_TEST_THREADS:-4}" "$CARGO_BUDGET_SH" run -- nice -n 15 cargo test --workspace --no-fail-fast -- --test-threads=1 2>&1)"
      printf '%s\n' "$local_log" > "$local_log_file"
      local_suites="$(printf '%s\n' "$local_log" | cargo_test_suites_json)"
      journal_line "$(now_iso)  burst-lane  parity  baseline-refreshed  (repo=$repo names=$missing_locally)"
    fi
  fi

  if [ "$box_capture" != "$local_capture" ]; then
    journal_line "$(now_iso)  burst-lane  parity  capture-mismatch  (repo=$repo box=$box_capture local=$local_capture)"
  fi

  # PRD-build-burst-parity-robust requirement 3: a "no-output" suite is
  # re-run alone on that side once before comparison; if it then reports, the
  # rerun result is used and journaled. A suite still "no-output" after this
  # single rerun is left as-is — the diff computation below already treats
  # any b != l (including two "no-output"s that happen to differ, or one
  # side no-output against the other's ok/FAILED) as an ordinary diff, so a
  # second no-output naturally counts without a separate special case.
  if [ "$box_capture" = "nextest" ]; then
    local name
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      exec 206>"$(wt_lock_file "$repo")"
      flock 206
      local rr; rr="$(nextest_rerun_result_box "$ip" "$remote_env_prefix" "$name")"
      flock -u 206
      if [ "$rr" != "no-output" ]; then
        box_suites="$(json_set_str "$box_suites" "$name" "$rr")"
        journal_line "$(now_iso)  burst-lane  parity  rerun  (suite=$name side=box)"
      fi
    done <<<"$(json_names_with_value "$box_suites" no-output)"
  fi
  if [ "$local_capture" = "nextest" ]; then
    local name
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      local rr; rr="$(nextest_rerun_result_local "$repo" "$name")"
      if [ "$rr" != "no-output" ]; then
        local_suites="$(json_set_str "$local_suites" "$name" "$rr")"
        journal_line "$(now_iso)  burst-lane  parity  rerun  (suite=$name side=local)"
      fi
    done <<<"$(json_names_with_value "$local_suites" no-output)"
  fi

  mkdir -p "$repo/target/autobuilder/receipts" 2>/dev/null || true
  local parity_file="$repo/target/autobuilder/receipts/box-parity.json"
  # PRD-build-burst-parity-robust requirement 2: the raw box and local logs
  # of THIS run, kept beside box-parity.json — a parity diff is diagnosable
  # from one read of these instead of a live reproduction on the box (the
  # 456s round trip the PRD's problem statement measured by hand).
  local box_log_receipt="$repo/target/autobuilder/receipts/parity-box.log"
  local local_log_receipt="$repo/target/autobuilder/receipts/parity-local.log"
  printf '%s\n' "$box_log" > "$box_log_receipt"
  printf '%s\n' "$local_log" > "$local_log_receipt"

  # PRD-build-burst-parity-cadence requirement 4: suites this repo's own
  # `.burst-lane.toml` documents as host-dependent are still run and
  # recorded on both sides, but never counted as a parity diff.
  ensure_parity_exclude_file "$repo"
  local parity_exclude; parity_exclude="$(read_parity_exclude "$repo")"

  local diff_json status_word
  diff_json="$(python3 -c '
import json, sys
box = json.loads(sys.argv[1])
local = json.loads(sys.argv[2])
excluded = set(sys.argv[3].split())
names = sorted(set(box) | set(local))
suites = {}
diff = []
host_sensitive = []
for n in names:
    b, l = box.get(n), local.get(n)
    # A suite the box has but the (possibly just-refreshed) local baseline
    # still genuinely lacks stays "baseline-incomplete" — never counted as
    # a diff on a null value (requirement 4).
    if b is not None and l is None:
        suites[n] = {"box": b, "local": l, "status": "baseline-incomplete"}
        continue
    if n in excluded and b != l:
        suites[n] = {"box": b, "local": l, "status": "host-sensitive"}
        host_sensitive.append(n)
        continue
    suites[n] = {"box": b, "local": l}
    if b != l:
        diff.append(n)
print(json.dumps({"suites": suites, "diff": diff, "host_sensitive": host_sensitive}))
' "$box_suites" "$local_suites" "$parity_exclude")"

  # PRD-build-burst-parity-cadence requirement 1: the receipt is valid for a
  # box SESSION + TOOLCHAIN FINGERPRINT, not a single HEAD — session_id and
  # toolchain_fp are what cmd_gate's check_parity_receipt() actually compares
  # (head_sha stays on the receipt for diagnostics only, never compared).
  local session_id toolchain_fp valid_until
  session_id="$(state_read server_id)"
  toolchain_fp="$(toolchain_fingerprint)"
  valid_until="$(session_valid_until)"

  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
out = {
    "head_sha": sys.argv[2], "box_host": sys.argv[3], "suites": d["suites"], "diff": d["diff"],
    "host_sensitive": d["host_sensitive"],
    "box_log": sys.argv[5], "local_log": sys.argv[6],
    "box_capture": sys.argv[7], "local_capture": sys.argv[8],
    "session_id": sys.argv[9], "toolchain_fp": sys.argv[10], "valid_until": sys.argv[11],
}
json.dump(out, open(sys.argv[4], "w"), indent=2)
' "$diff_json" "$head_sha" "$ip" "$parity_file" "$box_log_receipt" "$local_log_receipt" "$box_capture" "$local_capture" \
  "$session_id" "$toolchain_fp" "$valid_until"

  local diff_count; diff_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["diff"]))' "$diff_json")"
  local host_sensitive_count host_sensitive_names
  host_sensitive_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["host_sensitive"]))' "$diff_json")"
  if [ "$diff_count" -eq 0 ]; then status_word="ok"; else status_word="diff"; fi
  journal_line "$(now_iso)  burst-lane  parity  $status_word  (repo=$repo head=$head_sha box=$ip diff=$diff_count session=$session_id)"
  if [ "$host_sensitive_count" -gt 0 ]; then
    host_sensitive_names="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["host_sensitive"]))' "$diff_json")"
    journal_line "$(now_iso)  burst-lane  parity  host-sensitive  (repo=$repo names=$host_sensitive_names)"
  fi
  echo "parity: $status_word (diff=$diff_count) — $parity_file"
  exit 0
}

# ---- gate in-flight tracking (PRD-build-gate-on-casper requirement 7) ------
# One marker file per repo currently mid-remote-gate, keyed the same
# sha1-prefix way remote_path_for()/dirty_marker_file() key theirs — written
# by cmd_gate right before the remote extend-gate.sh call starts, removed
# the instant it returns (any outcome). GATE_WALL_BUDGET_S is the "wait up
# to the gate's wall-clock budget" ceiling requirement 7 asks for; the
# PRD's own note ("gate budgets from gate-wall-clock") points at another
# PRD's budget figures this pass does not yet read — 1800s (30 min, this
# PRD's own "expected gate wall" target) is a reasonable default until
# that's wired. GATE_WAIT_POLL_S is the poll interval while waiting.
GATE_INFLIGHT_DIR="$STATE_DIR/gate-inflight"
GATE_WALL_BUDGET_S="${BURST_LANE_GATE_WALL_BUDGET_S:-1800}"
GATE_WAIT_POLL_S="${BURST_LANE_GATE_WAIT_POLL_S:-2}"

gate_inflight_marker_file() {  # $1=repo -> stdout path
  local rkey; rkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/%s.json\n' "$GATE_INFLIGHT_DIR" "$rkey"
}

gate_inflight_write() {  # $1=marker_file $2=repo $3=ip $4=head_sha $5=slot
  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  python3 -c '
import json, sys
path, repo, host, started, budget, head_sha, slot = sys.argv[1:8]
json.dump({
    "repo": repo, "host": host, "started_epoch": int(started), "budget_s": int(budget),
    "head_sha": head_sha, "slot": slot,
}, open(path, "w"))
' "$1" "$2" "$3" "$(now_epoch)" "$GATE_WALL_BUDGET_S" "$4" "$5"
}

# `down`/`watchdog` call this right before their own destroy_verify: for
# every repo still marked in-flight, wait (polling the SAME wt-lock
# `cmd_gate` holds for its whole remote round trip) up to that gate's own
# recorded budget. Finishes-in-time -> one more explicit receipts pull (a
# safety net independent of whatever cmd_gate's own process — which may be
# a completely different, now-exited invocation — already did) and a
# `gate  <repo>  <verdict>` line. Past budget -> `gate  abandoned`,
# last-verdict.json is removed (never a stale cache the next tick could
# mistake for a completed gate at this HEAD), the marker is dropped either
# way. Never blocks/aborts the teardown itself past the budget ceiling.
gate_wait_for_inflight() {  # $1=caller(down|watchdog)
  local caller="$1" marker
  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  for marker in "$GATE_INFLIGHT_DIR"/*.json; do
    [ -f "$marker" ] || continue
    local repo ip started_epoch budget_s
    repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo",""))' "$marker" 2>/dev/null)"
    ip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("host",""))' "$marker" 2>/dev/null)"
    started_epoch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("started_epoch",0))' "$marker" 2>/dev/null)"
    budget_s="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("budget_s",1800))' "$marker" 2>/dev/null)"
    if [ -z "$repo" ]; then rm -f "$marker"; continue; fi

    local lockfile; lockfile="$(wt_lock_file "$repo")"
    local finished=0 now age
    while :; do
      now="$(now_epoch)"; age=$(( now - started_epoch ))
      if ( exec 214>"$lockfile"; flock -n 214 ) 2>/dev/null; then
        finished=1
        break
      fi
      [ "$age" -ge "$budget_s" ] && break
      sleep "$GATE_WAIT_POLL_S"
    done

    if [ "$finished" -eq 1 ]; then
      local remote_path; remote_path="$(remote_path_for "$repo")"
      mkdir -p "$repo/target/autobuilder" 2>/dev/null || true
      "$RSYNC_BIN" -az --delete -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/target/autobuilder/" "$repo/target/autobuilder/" >/dev/null 2>&1 || true
      "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/.gate-burst-host" "$repo/.gate-burst-host" >/dev/null 2>&1 || true
      local verdict; verdict="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("block" if d.get("block", 0) else "pass")
except Exception:
    print("unknown")
' "$repo/target/autobuilder/last-verdict.json" 2>/dev/null)"
      journal_line "$(now_iso)  burst-lane  $caller  gate  $verdict  (repo=$repo host=$ip waited=true age=${age}s)"
    else
      journal_line "$(now_iso)  burst-lane  $caller  gate  abandoned  (repo=$repo host=$ip age=${age}s budget=${budget_s}s)"
      rm -f "$repo/target/autobuilder/last-verdict.json"
    fi
    rm -f "$marker"
  done
}

# ---- gate (PRD-build-gate-on-casper requirement 3, + requirement 5's -------
# fallback contract in full, + requirement 6's SAME-REPO half only) ----------
# `gate <repo> --head <sha> [extend-gate args...]` rsyncs <repo> to the box
# (same excludes as `run`/`parity`), runs extend-gate.sh THERE via
# `bash -lc` (RUSTC_WRAPPER=sccache, BURST_LANE=0 — cargo stays local to the
# box, there is no further burst hop from a burst box), rsyncs back ONLY
# target/autobuilder/ and .gate-burst-host, patches a "host" field onto the
# pulled-back last-verdict.json (extend-gate.sh itself is never modified —
# a PRD non-goal — so it has no notion of "host" to write on its own), and
# propagates the remote exit code as this command's own. Any failure before
# the remote extend-gate.sh actually starts (no HEAD, head mismatch, dirty/
# unknown parity, `up` failing, the rsync-up itself, or ssh/bash/extend-
# gate.sh not being runnable on the box at all) prints "fallback: <cause>",
# exits 3, and journals a `gate  fallback` line naming the cause — never a
# fabricated verdict. Once the remote script has actually started, its exit
# code IS the verdict (0 pass, 1 block, else error(<rc>)), carried through
# unchanged. extend-gate.sh is resolved off $PATH with the box's normal
# PATH first and the requirement-1 synced copy APPENDED last (never
# prepended) — the identical append-not-prepend convention extend-gate.sh's
# own P0 PATH-order guard already uses, so a caller-armed override always
# wins; this also lets the offline selftest arm a fake extend-gate.sh ahead
# of the real synced one without touching this function.
#
# Requirement 6 is only PARTIALLY wired here: the per-repo worktree lock
# `run`/`parity` already take also serializes two gates on the SAME repo
# (the "still serializes gates on the same repo" half). Cross-repo
# concurrency via acquire_run_slot (the "gates on different repos... may run
# concurrently" half, weighted 2 in the sub-cap formula) is a later step —
# see the PRD's own requirement list.
cmd_gate() {
  local repo="${1:-}"
  [ -n "$repo" ] && [ -d "$repo" ] || { echo "usage: burst-lane.sh gate <repo> --head <sha> [extend-gate args...]" >&2; exit 2; }
  shift || true

  # PRD-build-gate-on-casper migration: ships dark behind BURST_GATE_REMOTE
  # (default 0 = every gate stays local, today's behavior unchanged). The
  # tick can call this subcommand unconditionally — the on/off decision
  # lives here, in ONE place, rather than duplicated as prose in every
  # caller — and reuses requirement 5's own fallback contract (print
  # "fallback: <cause>", exit 3, caller runs extend-gate.sh locally) so a
  # caller already handling that contract needs no separate branch for
  # "routing disabled" versus "routing tried and failed". Nothing here
  # touches parity, ssh, or rsync, and the journaled line carries no
  # host= field — only the requirement-3 routed-success shape does — so
  # AC8's "no gate remote line is journaled" holds.
  if [ "${BURST_GATE_REMOTE:-0}" != "1" ]; then
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=remote-disabled repo=$repo)"
    echo "fallback: remote-disabled"
    exit 3
  fi

  local head_arg="" extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head_arg="${2:-}"; extra_args+=("$1" "$2"); shift 2 ;;
      *) extra_args+=("$1"); shift ;;
    esac
  done

  local head_now; head_now="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head_now" ]; then
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=no-head repo=$repo)"
    echo "fallback: no-head"
    exit 3
  fi
  if [ -n "$head_arg" ] && [ "$head_arg" != "$head_now" ]; then
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=head-mismatch repo=$repo requested=$head_arg actual=$head_now)"
    echo "fallback: head-mismatch (requested=$head_arg actual=$head_now)"
    exit 3
  fi

  # PRD-build-burst-parity-cadence requirement 1: a receipt is valid for the
  # box SESSION + TOOLCHAIN FINGERPRINT, not for this exact HEAD — head_sha
  # is deliberately never compared here any more (see check_parity_receipt).
  # A session/toolchain MISMATCH (as opposed to a real parity-diff, or no
  # receipt at all) gets exactly one re-proof before falling back, since a
  # fresh box or a toolchain bump genuinely invalidates whatever was proven
  # before and a fresh proof is cheap relative to blocking every gate on a
  # box that's actually fine.
  local parity_file="$repo/target/autobuilder/receipts/box-parity.json"
  local cause=""
  if [ ! -f "$parity_file" ]; then
    cause="parity-unknown"
  else
    cause="$(check_parity_receipt "$repo")"
  fi
  if [ "$cause" = "session" ] || [ "$cause" = "toolchain" ]; then
    journal_line "$(now_iso)  burst-lane  parity  reproof  (cause=$cause repo=$repo)"
    # Subshell: cmd_parity ends every path with an `exit`, correct for a
    # top-level dispatch but fatal to the calling process if invoked as a
    # plain function call — `( ... )` scopes that exit to the subshell only.
    ( cmd_parity "$repo" ) >/dev/null 2>&1 || true
    cause="$(check_parity_receipt "$repo")"
  fi
  if [ -n "$cause" ]; then
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=$cause repo=$repo head=$head_now)"
    echo "fallback: $cause"
    exit 3
  fi

  if ! state_active; then
    local up_out; up_out="$(cmd_up 2>&1)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=up-failed repo=$repo)"
      echo "$up_out"
      exit 3
    fi
  fi
  local id ip; id="$(state_read server_id)"; ip="$(state_read ip)"

  # PRD-build-burst-gate-tools-scope requirement 3: `run` routes on
  # `verified` alone (ordinary cargo/uv/python work never cares about the
  # gate toolchain), but `gate` needs the box's OWN gate tools — extend-
  # gate.sh, autobuilder, cargo-deny, etc. — so it refuses closed here,
  # naming every tool still missing (or version-drifted), rather than
  # discovering the gap 126/127-deep into a remote ssh call below.
  if [ "$(state_read gate_ready)" != "true" ]; then
    local gt_missing; gt_missing="$(state_read gate_tools_missing)"
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=gate-tools-missing repo=$repo missing=${gt_missing:-unknown})"
    echo "fallback: gate-tools-missing (${gt_missing:-unknown})"
    exit 3
  fi

  # Requirement 6: a burst run slot per gate (same acquire_run_slot()
  # semaphore `run` uses, one slot, held for this whole function's
  # lifetime) is what lets gates on DIFFERENT repos proceed concurrently up
  # to BURST_MAX_CONCURRENT_RUNS; the per-repo worktree lock right below is
  # what still SERIALIZES two gates on the SAME repo regardless of slot
  # availability — a third caller for a repo already gating blocks there,
  # not here.
  acquire_run_slot "$repo"

  mkdir -p "$STATE_DIR/locks" 2>/dev/null || true
  exec 212>"$(wt_lock_file "$repo")"
  flock 212

  local remote_path; remote_path="$(remote_path_for "$repo")"
  mkdir -p "$STATE_DIR/logs" 2>/dev/null || true
  local up_log="$STATE_DIR/logs/rsync-gate.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
        "$repo/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    flock -u 212
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" repo=$repo)"
    echo "fallback: rsync to $ip failed rc=$rsync_up_rc (see $up_log)"
    exit 3
  fi

  # PRD-build-gate-on-casper requirement 7: from here on, a real remote
  # process is running — record it so `down`/`watchdog` can wait for (or,
  # past budget, abandon) it instead of destroying the box out from under
  # a gate mid-run. Removed unconditionally the instant this ssh call
  # returns, on EVERY path (success, block, or the 126/127 fallback below)
  # — a marker that outlives this function only means the process running
  # this script itself died mid-remote-call, which is exactly the case
  # gate_wait_for_inflight()'s own budget-based abandonment exists for.
  local inflight_marker; inflight_marker="$(gate_inflight_marker_file "$repo")"
  gate_inflight_write "$inflight_marker" "$repo" "$ip" "$head_now" "$SLOT_INDEX"

  local t0 t1 rc=0
  t0="$(now_fractional)"
  # PRD-build-gate-on-casper "extend-gate.sh remote-aware invocation": the
  # ONE thing extend-gate.sh writes outside the repo is the daily journal
  # (default $HOME/brain/journal/build/<date>.md) — on the box that's
  # $REMOTE_USER's own $HOME, not RedBaron's, so it's redirected here into
  # target/autobuilder/ (already an rsync-back path) and appended onto
  # RedBaron's real tick journal below, keeping the journal single-writer
  # per the PRD's technical considerations. PRD-build-burst-unprivileged-
  # user requirement 2: RUSTUP_HOME/CARGO_HOME point extend-gate.sh's own
  # cargo/rustup calls at root's shared, read-only toolchain the same way
  # every other remote cargo invocation does.
  local remote_journal="$remote_path/target/autobuilder/gate-journal.md"
  local remote_cmd="cd $remote_path && export PATH=\$PATH:$GATE_TOOLS_REMOTE_BIN_DIR:$ROOT_CARGO_HOME/bin:/root/.local/bin:$REMOTE_ROOT/.gate-tools/build-scripts RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$ROOT_CARGO_HOME RUSTC_WRAPPER=sccache SCCACHE_DIR=$REMOTE_SCCACHE_DIR SCCACHE_CACHE_SIZE=${BURST_SCCACHE_GB}G BURST_LANE=0 RUSTBUILD_SCRIPTS=$REMOTE_ROOT/.gate-tools/rustbuild-scripts REVIEWER_PROMPT=$REMOTE_ROOT/.gate-tools/rustbuild-prompts/reviewer-agent.md EXTEND_GATE_JOURNAL=$remote_journal; extend-gate.sh . $(printf '%q ' "${extra_args[@]}")"
  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "bash -lc $(printf '%q' "$remote_cmd")" || rc=$?
  t1="$(now_fractional)"
  rm -f "$inflight_marker"

  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    flock -u 212
    journal_line "$(now_iso)  burst-lane  gate  fallback  (cause=remote-extend-gate-not-runnable rc=$rc repo=$repo)"
    echo "fallback: remote extend-gate.sh not runnable on box (rc=$rc)"
    exit 3
  fi

  "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "echo $ip > $remote_path/.gate-burst-host" 2>/dev/null || true

  mkdir -p "$repo/target/autobuilder" 2>/dev/null || true
  "$RSYNC_BIN" -az --delete -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
    "$REMOTE_USER@$ip:$remote_path/target/autobuilder/" "$repo/target/autobuilder/" >/dev/null 2>&1 || true
  "$RSYNC_BIN" -az -e "$SSH_BIN -o StrictHostKeyChecking=no -i $SSH_KEY" \
    "$REMOTE_USER@$ip:$remote_path/.gate-burst-host" "$repo/.gate-burst-host" >/dev/null 2>&1 || true

  # Fold the box's redirected extend-gate.sh journal onto RedBaron's real
  # tick journal (single-writer: this is the only place a remote gate's
  # journal lines land), then clear it on the box so a later gate on the
  # same persistent remote_path doesn't re-append lines already folded in.
  local pulled_journal="$repo/target/autobuilder/gate-journal.md"
  if [ -s "$pulled_journal" ]; then
    local tj_today; tj_today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
    mkdir -p "$TICK_JOURNAL_DIR" 2>/dev/null || true
    cat "$pulled_journal" >> "$TICK_JOURNAL_DIR/$tj_today.md"
    rm -f "$pulled_journal"
    "$SSH_BIN" -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REMOTE_USER@$ip" "rm -f $remote_journal" 2>/dev/null || true
  fi
  flock -u 212

  local verdict_file="$repo/target/autobuilder/last-verdict.json"
  if [ -f "$verdict_file" ]; then
    python3 -c '
import json, sys
path, host = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d["host"] = host
json.dump(d, open(path, "w"), indent=2)
' "$verdict_file" "$ip" || true
  fi

  local wall_s verdict
  wall_s="$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.3f", a-b}')"
  case "$rc" in
    0) verdict="pass" ;;
    1) verdict="block" ;;
    *) verdict="error($rc)" ;;
  esac
  # PRD-build-gate-on-casper requirement 9: attributed under gate-<repo> —
  # PRD-build-gate-cargo-route-attest's own convention for a gate dispatch
  # (attribution_slug_for's header documents the same "gate-<repo>" shape
  # for the OLDER per-cargo-call routing; this is the gate run AS A WHOLE).
  attribution_record "gate-$(basename "$repo")" "$id" "$wall_s" 0 0 "$repo" gate
  journal_line "$(now_iso)  burst-lane  gate  $verdict  (repo=$repo host=$ip wall=${wall_s}s head=$head_now exit=$rc)"
  exit "$rc"
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

# ---- old-root reap (PRD-build-burst-parity-robust requirement 4) ----------
# migrate_remote_user()'s verified-copy-then-remove step above is the
# PRIMARY fix for migration residue; this is the backstop for whatever it
# left standing — a copy-mismatch migrate-keep, a leftover from before this
# fix shipped, or a `reap` that ran before a migration's copy had landed.
# Deliberately simpler than reap_plan()'s dirty/live/orphan classification:
# that classification exists to protect a directory whose LOCAL worktree
# might still need it, which is the right question for $REMOTE_ROOT (new
# work lands there every day) but the wrong one for $OLD_ROOT_REMOTE_ROOT —
# once REMOTE_USER != root, remote_path_for() never resolves a fresh path
# under the old root again, so anything still sitting there is presumptively
# residue regardless of whether its worktree is alive elsewhere. Only the
# gate-inflight and wt-lock busy checks (the same ones reap_orphans applies)
# still gate removal.
reap_old_root() {
  local reaped_dirs=0 reaped_bytes=0
  if [ -z "$OLD_ROOT_REMOTE_ROOT" ] || [ "$OLD_ROOT_REMOTE_ROOT" = "$REMOTE_ROOT" ]; then
    echo "reaped_dirs=0 reaped_bytes=0"; return 0
  fi
  state_active || { echo "reaped_dirs=0 reaped_bytes=0"; return 0; }
  local ip; ip="$(state_read ip)"
  local list_cmd="find '$OLD_ROOT_REMOTE_ROOT' -mindepth 1 -maxdepth 1 -not -name '.*' -printf '%f\n' 2>/dev/null"
  local list_out; list_out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
      "root@$ip" "$list_cmd" 2>/dev/null)"
  if [ -z "$list_out" ]; then
    echo "reaped_dirs=0 reaped_bytes=0"; return 0
  fi

  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  local inflight_names="" im_marker im_repo
  for im_marker in "$GATE_INFLIGHT_DIR"/*.json; do
    [ -f "$im_marker" ] || continue
    im_repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo",""))' "$im_marker" 2>/dev/null)"
    [ -n "$im_repo" ] || continue
    inflight_names="$inflight_names$(basename "$(remote_path_for "$im_repo")")"$'\n'
  done

  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qxF "$name" <<<"$inflight_names"; then
      journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name root=$OLD_ROOT_REMOTE_ROOT reason=gate-inflight)"
      continue
    fi
    if ! ( exec 208>"$(wt_lock_file "$OLD_ROOT_REMOTE_ROOT/$name")"; flock -n 208 ); then
      journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name root=$OLD_ROOT_REMOTE_ROOT reason=busy)"
      continue
    fi
    local bytes
    bytes="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
        "root@$ip" "du -sb '$OLD_ROOT_REMOTE_ROOT/$name' 2>/dev/null | cut -f1" 2>/dev/null)"
    bytes="${bytes:-0}"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    if "$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
         "root@$ip" "rm -rf '$OLD_ROOT_REMOTE_ROOT/$name'" 2>/dev/null; then
      reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + bytes))
      journal_line "$(now_iso)  burst-lane  reap  ok  (dir=$name root=$OLD_ROOT_REMOTE_ROOT bytes=$bytes reason=old-root)"
    else
      journal_line "$(now_iso)  burst-lane  reap  fail  (dir=$name root=$OLD_ROOT_REMOTE_ROOT cause=rm-failed)"
    fi
  done <<<"$list_out"

  echo "reaped_dirs=$reaped_dirs reaped_bytes=$reaped_bytes"
  return 0
}

# Executes reap_plan()'s decisions against the live box: deletes each orphan
# (skipping one whose worktree lock is currently held — a live run in
# flight on a not-yet-dirty-marked worktree, requirement 5's other named
# protection besides the dirty marker itself), journals every ok/skip/fail
# as plain "burst-lane reap <ok|skip|fail>" lines (same shape whether called
# standalone or from down/watchdog below), never aborts on a single failure
# (requirement 6). Always exits 0 to its caller — a reap trouble is
# journaled, never fatal. Also sweeps $OLD_ROOT_REMOTE_ROOT (requirement 4 of
# PRD-build-burst-parity-robust) so migration residue clears even when the
# direct verified-copy-then-remove step in migrate_remote_user() couldn't.
# Folds reap_old_root()'s own counts into $1/$2 (this call's REMOTE_ROOT
# totals so far) and prints the combined "reaped_dirs=N reaped_bytes=N"
# line — the single exit path every reap_orphans() return below funnels
# through, so $OLD_ROOT_REMOTE_ROOT is swept EVERY time this runs
# (PRD-build-burst-parity-robust requirement 4), not only on the one path
# that happens to reach the bottom of the function.
reap_finish() {  # $1=reaped_dirs $2=reaped_bytes -> stdout combined totals
  local old_out old_dirs old_bytes
  old_out="$(reap_old_root)"
  old_dirs="$(sed -n 's/^reaped_dirs=\([0-9]*\).*/\1/p' <<<"$old_out")"
  old_bytes="$(sed -n 's/.*reaped_bytes=\([0-9]*\)$/\1/p' <<<"$old_out")"
  echo "reaped_dirs=$(( ${1:-0} + ${old_dirs:-0} )) reaped_bytes=$(( ${2:-0} + ${old_bytes:-0} ))"
}

reap_orphans() {
  local reaped_dirs=0 reaped_bytes=0
  mkdir -p "$DIRTY_DIR" "$STATE_DIR/locks" 2>/dev/null || true
  if ! state_active; then
    reap_finish 0 0
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
    reap_finish 0 0
    return 0
  fi
  if [ -z "$list_out" ]; then
    reap_finish 0 0
    return 0
  fi

  local plan; plan="$(printf '%s\n' "$list_out" | sort -n | reap_plan)"
  # PRD-build-gate-on-casper requirement 7: a repo currently mid-remote-gate
  # (tracked the same way gate_wait_for_inflight() reads it) is protected
  # from reap regardless of whether reap_plan's own candidate-root decoding
  # ever found a local worktree for it — the marker names its OWN repo path
  # directly, so this is computed from remote_path_for() rather than from
  # `wt` (empty for any repo path reap_plan's fixed candidate-root list
  # doesn't happen to search). Without this, a gate whose repo isn't under
  # one of those roots could be reaped out from under gate_wait_for_inflight
  # moments later in the SAME down/watchdog call, before it ever gets a
  # chance to wait for or pull the very directory reap just deleted.
  local inflight_names=""
  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  local im_marker im_repo
  for im_marker in "$GATE_INFLIGHT_DIR"/*.json; do
    [ -f "$im_marker" ] || continue
    im_repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo",""))' "$im_marker" 2>/dev/null)"
    [ -n "$im_repo" ] || continue
    inflight_names="$inflight_names$(basename "$(remote_path_for "$im_repo")")"$'\n'
  done

  local name action reason wt
  while IFS=$'\t' read -r name action reason wt; do
    [ -n "$name" ] || continue
    case "$action" in
      keep)  journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=keep)" ;;
      dirty) journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=dirty)" ;;
      live)  : ;;  # untouched, no journal noise on every healthy pass
      orphan)
        if grep -qxF "$name" <<<"$inflight_names"; then
          journal_line "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=gate-inflight)"
          continue
        fi
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

  reap_finish "$reaped_dirs" "$reaped_bytes"
  return 0
}

cmd_reap() {
  local out; out="$(reap_orphans)"
  echo "$out"
  exit 0
}

# ---- box isolation check (PRD-build-burst-selftest-isolation req 3) --------
# While a session is active, lists the box's remote root (same listing
# reap_orphans uses) and refuses if any entry looks like a test fixture
# name that should never have reached a real box: the `burst-*`/`gb-ac*`
# prefixes this suite's own tmpdirs use, or a bare mktemp-style
# `<name>.<6-random-chars>` suffix. A real worktree dir is named
# `<repo>-<slug>` (worktree-extend.sh's own convention) and never matches
# either shape, so this has no false positives against legitimate box
# contents. Read-only: never deletes anything (that's reap's job).
box_isolation_check() {
  state_active || { echo "ok: no active session"; return 0; }
  local ip; ip="$(state_read ip)"
  local list_cmd="find '$REMOTE_ROOT' -mindepth 1 -maxdepth 1 -not -name '.*' -printf '%f\n' 2>/dev/null"
  local list_out
  list_out="$("$SSH_BIN" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
      "$REMOTE_USER@$ip" "$list_cmd" 2>/dev/null)" || { echo "ok: box unreachable, nothing to check"; return 0; }
  local name breach=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      burst-*|gb-ac*|*.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
        echo "isolation-breach: box dir $name" >&2
        breach=1
        ;;
    esac
  done <<<"$list_out"
  [ "$breach" -eq 0 ] && echo "ok: no fixture-named directories on the box"
  return "$breach"
}

cmd_box_isolation_check() {
  box_isolation_check
  exit $?
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

  # PRD-build-burst-selftest-isolation requirement 4: computed unconditionally
  # (harmless if zero), ahead of the cost-ledger gate below, so it's ready to
  # fold into whichever rollup line actually fires below. Deliberately does
  # NOT fire its own early/extra rollup line or consume $ROLLUP_CURSOR on its
  # own — the existing "no slug rows yet -> no-op, cursor untouched, so the
  # line still lands once a teardown does happen later today" invariant
  # (comment above) must survive this addition: an early attempt at that
  # (now removed) starved the very next `down` call's real cost-based rollup
  # of its cursor slot the day this file changed, since $ROLLUP_CURSOR is a
  # once-per-day, not once-per-metric, gate.
  local isolation_refusals=0
  if [ -f "$ISOLATION_LIVE_JOURNAL_FILE" ]; then
    # PRD-build-burst-persistent-volume: `grep -c` already prints a valid
    # count (0 or more) on stdout regardless of match count — it only
    # EXITS 1 when the count is 0, which the old `|| echo 0` here treated
    # as failure and appended a SECOND "0" line, corrupting the caller's
    # single-line $line with an embedded newline (caught by AC8's own
    # rollup-line pairing going missing after this field). No fallback
    # needed: `-f "$ISOLATION_LIVE_JOURNAL_FILE"` above already guards the
    # only real failure mode (missing file).
    isolation_refusals="$(grep -c "^${today}.*  isolation  refused  " "$ISOLATION_LIVE_JOURNAL_FILE" 2>/dev/null)"
  fi

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

  # PRD-build-gate-on-casper requirement 9: gates_remote counts today's
  # completed remote gates — any "burst-lane ... gate ..." line (cmd_gate's
  # own, or a down/watchdog teardown-path line from gate_wait_for_inflight)
  # that reached a real host (a "host=" token) and isn't a "fallback"
  # (fallback means the remote gate never actually started; requirement 5
  # runs the tick's gate locally instead when that happens). gates_local
  # counts today's LOCAL gate runs — extend-gate.sh's own journal line,
  # which lands in this SAME tick-journal file (its header: "writes one
  # thing outside the repo, the daily journal under ~/brain/journal/
  # build/"), never in this script's own $JOURNAL — distinguished from a
  # route-mismatch/record-baseline line by requiring the 4th field to be a
  # real verdict (pass/block/delta-pass).
  local gate_stats gates_remote gates_local
  gate_stats="$(python3 -c '
import sys
today, burst_journal, tick_journal = sys.argv[1], sys.argv[2], sys.argv[3]
remote = 0
try:
    with open(burst_journal) as fh:
        for ln in fh:
            if not ln.startswith(today):
                continue
            if "burst-lane" not in ln or "  gate  " not in ln:
                continue
            if "fallback" in ln or "host=" not in ln:
                continue
            remote += 1
except OSError:
    pass
local_ = 0
try:
    with open(tick_journal) as fh:
        for ln in fh:
            if not ln.startswith(today):
                continue
            parts = ln.split()
            if len(parts) >= 4 and parts[1] == "gate" and parts[3] in ("pass", "block", "delta-pass"):
                local_ += 1
except OSError:
    pass
print(remote, local_)
' "$today" "$JOURNAL" "$TICK_JOURNAL_DIR/$today.md")"
  read -r gates_remote gates_local <<<"$gate_stats"
  line="$line gates_remote=${gates_remote:-0} gates_local=${gates_local:-0}"

  # PRD-build-burst-parity-cadence requirement 5: today's parity activity —
  # completed proofs (ok or diff) and load-deferrals — straight from this
  # script's own $JOURNAL, same source/shape as gates_remote/gates_local
  # just above.
  local parity_stats parity_runs parity_load_deferred
  parity_stats="$(python3 -c '
import sys
today, path = sys.argv[1], sys.argv[2]
runs = 0
deferred = 0
try:
    with open(path) as fh:
        for ln in fh:
            if not ln.startswith(today):
                continue
            if "burst-lane  parity  " not in ln:
                continue
            if "  parity  ok  " in ln or "  parity  diff  " in ln:
                runs += 1
            elif "  parity  deferred  " in ln:
                deferred += 1
except OSError:
    pass
print(runs, deferred)
' "$today" "$JOURNAL")"
  read -r parity_runs parity_load_deferred <<<"$parity_stats"
  line="$line parity_runs=${parity_runs:-0} parity_load_deferred=${parity_load_deferred:-0}"

  # isolation_refusals was already computed above (before the cost-ledger
  # gate), so a refusal count is visible in this line the same as any other
  # metric here (PRD-build-burst-selftest-isolation requirement 4).
  line="$line isolation_refusals=${isolation_refusals:-0}"

  # PRD-build-burst-persistent-volume requirement 7/AC8: volume_gb (the
  # provisioned size — a flat config number, not a probe), the last-known
  # used_pct (whatever `up`'s mount step or `status` last recorded — this
  # rollup runs from `down`, which may fire after the box that would answer
  # a live probe is already gone), and cold_builds_avoided (today's distinct
  # worktrees whose FIRST `run  routed` line already had warm=true — the
  # success-metrics table's own definition: "warm= field on the first run
  # per session").
  local cold_avoided
  cold_avoided="$(python3 -c '
import sys
today, path = sys.argv[1], sys.argv[2]
first_warm = {}
try:
    with open(path) as fh:
        for ln in fh:
            if not ln.startswith(today):
                continue
            if "burst-lane  run  routed" not in ln:
                continue
            wt = None
            warm = None
            for tok in ln.split():
                if tok.startswith("worktree="):
                    wt = tok[len("worktree="):]
                elif tok.startswith("warm="):
                    warm = tok[len("warm="):].rstrip(")")
            if wt is None:
                continue
            if wt not in first_warm:
                first_warm[wt] = (warm == "true")
except OSError:
    pass
print(sum(1 for v in first_warm.values() if v))
' "$today" "$JOURNAL")"
  local rollup_used_pct; rollup_used_pct="$(volume_state_read volume_used_pct)"
  line="$line volume_gb=${BURST_VOLUME_GB:-0} volume_used_pct=${rollup_used_pct:-0} cold_builds_avoided=${cold_avoided:-0}"

  # PRD-build-burst-persistent-volume requirement 9: RedBaron's own free
  # disk, same once-a-day visibility as the volume/box numbers above.
  local rollup_local_free; rollup_local_free="$(local_disk_free_gb "$STATE_DIR")"
  case "$rollup_local_free" in ''|*[!0-9]*) rollup_local_free="null" ;; esac
  line="$line redbaron_free_gb=${rollup_local_free}"

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
        "remote_user=$(state_read remote_user)" \
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
    # PRD-build-gate-on-casper requirement 7: wait for (or, past budget,
    # abandon) any remote gate still running before the box that's running
    # it is destroyed.
    gate_wait_for_inflight down
    # PRD-build-gate-on-casper requirement 4: shred the reviewer credential
    # (if one was ever placed — a no-op, un-journaled, otherwise) before the
    # box that would carry it away is destroyed.
    shred_gate_credential "$(state_read ip)" down
    # PRD-build-burst-persistent-volume requirement 2: sync/unmount/detach
    # BEFORE the server delete that follows — never blocks it (Hetzner
    # detaches on delete regardless; a failure here only marks volume_dirty
    # for the next up's fsck).
    volume_teardown "$(state_read ip)" down
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
    "remote_user=$(state_read remote_user)" \
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
  # PRD-build-gate-on-casper requirement 7: same in-flight gate wait/abandon
  # as `down`'s delete path — the watchdog is a teardown path too.
  gate_wait_for_inflight watchdog
  # PRD-build-gate-on-casper requirement 4: same credential shred as
  # `down`'s delete path — the watchdog is a teardown path too.
  shred_gate_credential "$(state_read ip)" watchdog
  # PRD-build-burst-persistent-volume requirement 2: same teardown-order
  # detach as `down`'s delete path — the watchdog is a teardown path too.
  volume_teardown "$(state_read ip)" watchdog
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

  # PRD-build-gate-on-casper requirement 6: a running remote gate is
  # heavier than a plain branch's cargo run (cargo test --workspace, the
  # full producer sequence, the reviewer) — weighted 2 against this same
  # formula so a tick doesn't admit as many NEW branches while gates are
  # already consuming the box. Applied before the `candidates` clamp (an
  # orthogonal "don't offer more than N candidates" cap, not a resource
  # reading) and after mem/cpu/disk (an already-consumed resource, not a
  # ceiling those three compete against).
  mkdir -p "$GATE_INFLIGHT_DIR" 2>/dev/null || true
  local active_gates=0 gm
  for gm in "$GATE_INFLIGHT_DIR"/*.json; do [ -f "$gm" ] && active_gates=$((active_gates + 1)); done
  local gate_weight=$((active_gates * 2))
  if [ "$gate_weight" -gt 0 ]; then
    subcap=$((subcap - gate_weight))
    [ "$subcap" -lt 0 ] && subcap=0
    bound="gates"
  fi

  if [ "$candidates" -gt 0 ] && [ "$candidates" -lt "$subcap" ]; then subcap=$candidates; bound="candidates"; fi

  local bound_suffix=""
  [ "$bound" = "disk" ] && bound_suffix=" bound=disk"
  [ "$bound" = "gates" ] && bound_suffix=" bound=gates gates_active=$active_gates"

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
  # PRD-build-burst-persistent-volume requirement 7: the volume's monthly
  # line beside the box-hours line above — billed whether attached or not
  # (Technical considerations), so this is a pure BURST_VOLUME_GB *
  # BURST_VOLUME_EUR_PER_GB_MONTH computation, independent of whether a
  # session is even up right now.
  if [ -n "$BURST_VOLUME_NAME" ]; then
    awk -v gb="$BURST_VOLUME_GB" -v rate="$BURST_VOLUME_EUR_PER_GB_MONTH" \
      'BEGIN{printf "volume_gb=%d volume_monthly_eur=%.2f\n", gb, gb*rate}'
  fi
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
    provision) cmd_provision "$@" ;;
    reap)      cmd_reap "$@" ;;
    box-isolation-check) cmd_box_isolation_check "$@" ;;
    route-check) cmd_route_check "$@" ;;
    parity)    cmd_parity "$@" ;;
    gate)      cmd_gate "$@" ;;
    # Undocumented/hidden — PRD-build-burst-unprivileged-user requirement 1:
    # a pure read-only print of the resolved remote identity/paths, no ssh,
    # no filesystem writes outside $STATE_DIR's own mkdir at file top. Exists
    # so the offline selftest can assert the literal DEFAULT values (e.g.
    # $REMOTE_ROOT=/home/build/build) without a test override masking them —
    # every other subcommand needs BURST_LANE_REMOTE_ROOT etc. pinned to a
    # tmpdir for safety, which is exactly what would hide this.
    _debug-remote-config)
      printf 'remote_user=%s\nremote_home=%s\nremote_root=%s\ngate_tools_bin=%s\ngate_cred_path=%s\nsccache_dir=%s\n' \
        "$REMOTE_USER" "$REMOTE_HOME" "$REMOTE_ROOT" "$GATE_TOOLS_REMOTE_BIN_DIR" "$GATE_CRED_REMOTE_PATH" "$REMOTE_SCCACHE_DIR"
      exit 0
      ;;
    # Undocumented/hidden — PRD-build-burst-parity-cadence: a pure read-only
    # print of toolchain_fingerprint()'s current value, same rationale as
    # _debug-remote-config above — lets the offline selftest hand-craft a
    # receipt that is genuinely VALID under the new session+toolchain
    # contract (rather than every non-parity gate fixture accidentally
    # tripping the new one-reproof path just because its hand-crafted
    # receipt predates session_id/toolchain_fp).
    _debug-toolchain-fp)
      toolchain_fingerprint
      exit 0
      ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
