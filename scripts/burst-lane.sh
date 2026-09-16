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
# PRD-build-burst-path-deps: `run` used to rsync exactly one worktree —
# fine for a self-contained crate like mcphost, silently wrong for anything
# with a sibling path dependency outside the worktree (wintermute-brain's
# four: agorabus, wm-local-llm, wm-verify, wm-router), which failed to
# resolve on the box every time since the lane existed. `run` now (1)
# discovers the crate's transitive path dependencies locally
# (scripts/burst-lane-pathdeps.py discover, a regex Cargo.toml reader — no
# full TOML parser, consistent with this skill's other pragmatic parsing),
# (2) rsyncs each one to its own stable remote location
# (dep_remote_path_for(), a deps/ subtree keyed like remote_path_for()
# itself), and (3) rewrites the synced worktree's (and each dep's own)
# `path =` entries that point at a synced dependency to that remote
# location (burst-lane-pathdeps.py rewrite) before the remote command ever
# runs — `cargo metadata`/build/test on the box then resolves it with no
# operator step. A remote exit before any test binary ran (compile/
# resolution error) now journals `run  build-failed  (cause=...)` with
# `phase=build` on its attribution row, instead of the same undistinguished
# `exit=101` a genuine test failure gets (`phase=test`) — the fix for four
# days of "tests red" that were never tests, just an unresolved dependency.
# CARGO_HOME for the build user is now its own ($REMOTE_HOME/.cargo,
# RUN_CARGO_HOME below) rather than root's shared, read-only
# ROOT_CARGO_HOME — cargo's registry/git cache needs WRITES for any not-
# yet-cached crate, which root's chmod'd-read+execute copy never granted
# (the write race an operator chmod'd by hand, 2026-09-11); RUSTUP_HOME
# stays root's shared toolchain, read-only, unchanged. The gate-tools
# probe's PATH no longer falls back to root's bin dirs for the build user
# (it did, purely to mask a hand-installed-under-/root tool — the exact
# 07:48Z incident where `claude` read "present" while actually MISSING for
# build) — see gate_tools_probe()'s `gt_probe_extra`.
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
#       feeds them (with free disk) through run_slot_cap_terms — the same
#       formula run_slot_cap() uses for the run-slot table, PRD-build-burst-
#       run-slots-from-box requirement 3 — computing min(floor(avail_gb/
#       BURST_GB_PER_RUN), floor(nproc/BURST_CORES_PER_RUN)[, candidates])
#       (defaults 8 GB and 4 cores per run; BURST_GB_PER_BRANCH/
#       BURST_CORES_PER_BRANCH still resolve as deprecated aliases), prints
#       "sub-cap=<n> local=0 (avail_gb=<n> nproc=<n>)" and journals
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

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/probe.sh
source "$HERE/lib/probe.sh"

STATE_DIR="${BURST_LANE_STATE_DIR:-$SKILL_DIR/state/burst-lane}"
# PRD-build-burst-state-keyed-by-server-v2 requirement 1: state layout.
# Every PER-BOX path (classified in scripts/burst-state-surface.txt) lives
# under $STATE_DIR/boxes/<server_id>/ and resolves through box_path() below
# — no other function in this file constructs a "boxes/" path by hand
# (checked mechanically by the tripwire selftest, requirement 10).
# $STATE_DIR/current is a symlink to the box most recently made ready
# (`box_activate` below repoints it); BOX_STATE_DIR is that symlink's own
# path, so every existing single-box caller that read
# "$STATE_DIR/<name>" before this PRD reads "$BOX_STATE_DIR/<name>" now and
# — because `current` always resolves to exactly one real box directory —
# sees byte-identical behavior in the single-box case. Multi-box selection
# (an explicit --box <id>, iterating every box) is requirement 2/3
# territory and is NOT wired here — box_path only ever resolves the single
# ACTIVE box via `current`, same as BOX_STATE_DIR.
BOX_STATE_DIR="$STATE_DIR/current"
box_path() { printf '%s/%s\n' "$BOX_STATE_DIR" "$1"; }
# box_path_for <server_id> <name> -> stdout "$STATE_DIR/boxes/<server_id>/<name>"
# -- the multi-box counterpart to box_path() above, added for
# PRD-build-burst-gate-canary-invariant (R5/R6/R8): canary state is keyed
# by server_id, not always the CURRENTLY active box, so it cannot resolve
# through box_path()'s "current"-relative BOX_STATE_DIR alone. Defined here
# (between the BOX_STATE_DIR= assignment and box_activate()'s closing
# brace) rather than hand-rolling "$STATE_DIR/boxes/..." at each call site,
# so it stays inside scripts/burst-state-tripwire.sh's own box_path()/
# box_activate() license region for a "boxes/" literal (AC14) -- placing it
# textually AFTER box_activate() instead (this function's first draft) is
# NOT inside that region: the tripwire's block-end anchor is box_activate()'s
# own closing brace specifically, not "wherever the next related helper
# happens to sit."
box_path_for() { printf '%s/boxes/%s/%s\n' "$STATE_DIR" "${1:-unknown}" "$2"; }
STATE_FILE="$BOX_STATE_DIR/session.json"
# PRD-build-burst-dispatch-reenable requirement 1: the baked-image record —
# `image_id`/`created`/`base_image_id`/`build_skill_sha`/`gate_tool_versions`
# plus a capped `baked_history` (oldest-first, <=2 entries) used to journal
# `bake superseded` when a third bake lands. Absent file == "no baked image
# yet" everywhere that reads it (`up`'s image resolution, `status`).
SNAPSHOT_STATE_FILE="$STATE_DIR/snapshot.json"
# PRD-build-burst-dispatch-reenable requirement 2: set by cmd_up's own
# image-resolution step (baked|env|default) right before it calls
# provision_gate_tools, so that function's install loop can journal
# `bake-stale` when a baked boot still needs a tool install. Left "" (never
# baked) on every OTHER call path (adoption, standalone `provision`) — this
# script only tracks the origin of a boot it just created, not one it
# merely adopted.
CURRENT_BOOT_IMAGE_SOURCE=""
# PRD-build-burst-dispatch-reenable requirement 3/6: `prove`'s own receipt
# (ts, image_id, server_id, worktree, sha, routed, bytes, secs_remote,
# cause) — absent file reads as "never proved" everywhere (`status`,
# `enable`). requirement 4/6: the systemd drop-in `enable` writes/`disable`
# removes/`status` reports the existence of; overridable so a selftest
# never touches this host's REAL ~/.config/systemd/user tree.
PROOF_STATE_FILE="$BOX_STATE_DIR/proof.json"
# PRD-build-burst-dispatch-reenable requirement 7: the image_id `up` resolved
# (resolve_boot_image) the last time a session started — plain text, not
# JSON, since it is only ever compared for equality. Absent file == "no
# tracked baseline image yet" (first session ever, or a selftest's fresh_env)
# and never triggers a refresh on its own; see
# refresh_parity_baseline_on_image_change.
PARITY_BASELINE_IMAGE_FILE="$STATE_DIR/parity-baseline-image"
SYSTEMD_DROPIN="${BURST_LANE_SYSTEMD_DROPIN:-$HOME/.config/systemd/user/claude-build.service.d/burst.conf}"
COST_LEDGER="${BURST_LANE_COST_LEDGER:-$BOX_STATE_DIR/cost.jsonl}"
# PRD-build-burst-dispatch-reenable requirement 5 (auto-disable, trigger b):
# the €/day ceiling on deleted-box cost with no routed run this day — read
# by check_auto_disable() below, never by cmd_enable (enable only ever
# consults proof.json, per requirement 4).
BURST_AUTO_DISABLE_EUR_PER_DAY="${BURST_AUTO_DISABLE_EUR_PER_DAY:-2.00}"
# Requirement 13: which PRD slugs this session served, one per line,
# deduped. Reset on a fresh boot/adopt (alongside runs_served=0), appended
# to (deduped) by every routed `run`, read into the cost-ledger row at
# teardown, then cleared with the rest of the session state.
SERVED_FILE="$BOX_STATE_DIR/prds_served"
# PRD-build-burst-teardown-lifecycle requirement 3: a scratch file, not a
# shell variable — teardown_and_delete runs inside every caller's own
# `$(...)` command substitution, which is a SUBSHELL; a plain variable set
# there never reaches the parent shell that reads it back afterward. A file
# survives that boundary the same way $SERVED_FILE etc. already do.
TEARDOWN_CAUSE_FILE="$BOX_STATE_DIR/.last-teardown-cause"
# PRD-build-burst-teardown-evidence requirement 1: the append-only decision
# trail teardown_decision() writes one row to on every call (ts, server_id,
# caller, decision, cause, evidence) — this is what `why-down` replays.
# Requirement 3: the once-per-hour journal throttle for cause=probe-
# unavailable is tracked separately, in its own tiny mtime-style marker file,
# so a probe outage that lasts all day journals once, not once per caller
# invocation.
DECISIONS_LEDGER="${BURST_LANE_DECISIONS_LEDGER:-$STATE_DIR/decisions.jsonl}"
PROBE_UNAVAILABLE_MARK_FILE="$BOX_STATE_DIR/.probe-unavailable-last"
ENV_FILE="${BURST_LANE_ENV_FILE:-$HOME/.config/wm-burst/.env}"
# PRD-build-journal-single-writer requirement 1: default composes off
# journal_root() (scripts/lib/journal.sh, sourced above) instead of a
# literal brain/journal path, so BUILD_JOURNAL_ROOT redirects it too.
# BURST_LANE_JOURNAL remains a legacy alias journal_line itself honors.
JOURNAL="${BURST_LANE_JOURNAL:-$(journal_root)/burst-lane.log}"
PRD_DIR="${BURST_LANE_PRD_DIR:-$HOME/Documents/PRDs}"
# PRD-build-cost-attribution: per-run attribution ledger (requirement 1),
# the known-repo root used to split a worktree basename into <repo>/<slug>
# (attribution_slug_for below), the once-per-day rollup cursor (requirement
# 4), and the tick journal directory that rollup line lands in — distinct
# from $JOURNAL above, which is this script's own flat log.
ATTR_LEDGER="${BURST_LANE_ATTR_LEDGER:-$BOX_STATE_DIR/attribution.jsonl}"
# PRD-build-burst-pull-on-demand: lazy-pull state. DIRTY_DIR holds one
# marker per worktree (keyed like remote_path_for()'s sha1 scheme) recording
# that a completed remote `run` left target/ (or .pybuilder/) ahead of the
# local worktree; PULLSZ_DIR remembers the last ACTUAL pull's byte count per
# worktree (survives marker clears) so a skipped pull's telemetry can still
# print an `estimate: true` bytes_saved figure instead of a bare zero.
DIRTY_DIR="$BOX_STATE_DIR/dirty"
PULLSZ_DIR="$BOX_STATE_DIR/pull-sizes"
# PRD-build-burst-path-deps-workspaces requirement 3: the lane-owned
# directory manifest — every directory `run` creates under $REMOTE_ROOT that
# does NOT correspond one-to-one with a local worktree (today, concretely,
# each `deps/<name>-<hash8>` mirror; see dep_remote_path_for()) recorded here
# with its owning worktree, so `reap` can tell "lane-created, still needed"
# apart from "lane-created, orphaned" instead of only ever seeing an
# unrecognized top-level `deps` dir and deleting it outright (the
# 2026-09-11 autobuilder incident this PRD fixes — journal
# `reap  ok  (dir=deps reason=legacy-no-local-match)` deleting a dep mirror
# a live worktree needed the very next run). Plain JSON object, one lock
# file guarding read-modify-write the same way STATE_FILE's flock 201
# guards session state.
REMOTE_DIRS_FILE="$BOX_STATE_DIR/remote-dirs.json"
REMOTE_DIRS_LOCK="$BOX_STATE_DIR/remote-dirs.lock"
# PRD-build-burst-path-deps-workspaces requirement 4: per-worktree repeat
# guard for identical consecutive build-failed causes — one small JSON file
# per worktree (same sha1-hash8 keying as dirty_marker_file()) recording the
# cause/count/HEAD of the run of consecutive identical build failures, so a
# repo that cannot build remotely stops burning a cargo invocation a minute
# instead of looping until an operator notices the journal.
BUILD_FAIL_DIR="$STATE_DIR/build-fail"
ATTR_REPOS_DIR="${BURST_LANE_REPOS_DIR:-$HOME/wintermute}"
ROLLUP_CURSOR="$STATE_DIR/.rollup-cursor"
# PRD-build-journal-single-writer requirement 1: default composes off
# journal_root() instead of a literal brain/journal path — the two direct
# `>>` appends below (gate-journal fold, once-a-day rollup line) now route
# through journal_line too, closing the two writers this variable actually
# fed (found alongside the five named in the PRD's engineering target).
TICK_JOURNAL_DIR="${BURST_LANE_TICK_JOURNAL_DIR:-$(journal_root)}"
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
GATE_TOOLS_STATE_FILE="$BOX_STATE_DIR/gate-tools.json"
# PRD-build-burst-provision-forensics: per-tool failure evidence, pruned to
# the newest N sessions (requirement 2) — a flat dir keyed
# "<session_id>-<tool>.log" plus an append-only ledger of which session_id
# produced at least one failure, so pruning never has to parse tool names
# (cargo-deny/cargo-nextest already contain a hyphen) back out of a
# filename.
GATE_TOOLS_FAILED_LOG_DIR="$STATE_DIR/logs/failed"
GATE_TOOLS_FAILED_SESSIONS_LOG="$STATE_DIR/logs/failed-sessions.log"
GATE_TOOLS_FAILED_LOG_RETAIN_SESSIONS="${GATE_TOOLS_FAILED_LOG_RETAIN_SESSIONS:-5}"
# PRD-build-burst-probe-visibility requirement 7: bounds each remote
# `--version` call so one hanging binary can't truncate the whole sweep, and
# names the sentinel line the probe emits after its last tool so the parser
# can tell "sweep completed" from "output cut off mid-stream" (requirement
# 7/AC9). Overridable so a selftest can shrink the timeout without waiting
# out the real default.
GATE_TOOLS_PROBE_TIMEOUT_S="${BURST_LANE_GATE_TOOLS_PROBE_TIMEOUT_S:-5}"
GATE_TOOLS_PROBE_SENTINEL="__GATE_PROBE_DONE__"
# In-flight tool name for the provision-loop abort trap (requirement 1) —
# deliberately a plain global, not a function-local: an EXIT/signal trap
# must read it regardless of exactly which stack frame was executing when
# the shell died.
_GT_CURRENT_TOOL=""
# PRD-build-burst-provision-forensics requirement 4: concurrency guards.
# One flock per lane per command (provision/up), tied to the calling
# process's own fd — never a detached `flock ... sleep &` (see SKILL.md
# Locking section for why that's the one pattern this must never become).
# The matching .pid file is written by the LOCK HOLDER right after it
# acquires the flock, purely so a REFUSED sibling can name a real PID in
# its journal line; it is never itself part of the mutual-exclusion logic.
PROVISION_LOCK_FILE="$STATE_DIR/provision.lock"
PROVISION_PID_FILE="$STATE_DIR/provision.pid"
UP_LOCK_FILE="$BOX_STATE_DIR/up.lock"
UP_PID_FILE="$BOX_STATE_DIR/up.pid"
# PRD-build-burst-prove-inflight-guard requirement 1: cmd_prove's own
# in-flight marker — present from just before its `up` call until its EXIT
# trap fires, so down/idle-guard/watchdog (all three autonomous deleters)
# can see a prove is live before deciding to tear the box down under it
# (2026-09-15: box 165981910 deleted between prove's `up` and `run`).
PROVE_INFLIGHT_FILE="$BOX_STATE_DIR/prove.inflight"
# requirement 4: reap's orphan sweep. INFLIGHT_LOG is an append-only
# "<epoch> <pid> <kind>" ledger, one row per provision/up invocation that
# got far enough to acquire its lock — reap prunes rows whose pid is dead
# and kills+journals rows whose pid is alive, older than
# BURST_ORPHAN_AGE_S, and not the CURRENT lock holder for that kind (read
# fresh from up.pid/provision.pid, never trusted from the ledger row
# itself).
INFLIGHT_LOG="$BOX_STATE_DIR/inflight.log"
BURST_ORPHAN_AGE_S="${BURST_ORPHAN_AGE_S:-600}"
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
# PRD-build-burst-prove-inflight-guard requirement 3: the run-path ssh calls
# (prove's remote-clock probe and cmd_run's remote exec) fail within ~60s of
# a box disappearing instead of hanging on a dead IP with no keepalive at all
# (2026-09-15: box 165981910 deleted mid-prove, `run` hung ~6m until killed).
SSH_RUN_KEEPALIVE_OPTS="-o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# ---- session-scoped host keys (PRD-build-burst-session-hygiene) -----------
# Every ssh/rsync call in this file must pin against a SESSION-scoped known-
# hosts file, never ~/.ssh/known_hosts — a reused Hetzner IP with a stale
# entry in the global file hard-failed `provision` before this PRD landed
# (2026-09-13 04:44Z incident, see header). The file is named by session id
# (the hcloud server id), so a session boundary is also a host-key boundary:
# `up` points $KH_SESSION_ID at the new/adopted id (and truncates the file
# fresh) before the first ssh/rsync call it makes; every other command falls
# back to reading the active session's own server_id out of session.json;
# `down`/`down --force` deletes the file with the rest of session state.
# `accept-new` (not `no`) keeps first-contact pinning while still failing a
# genuine MID-session key change (the Technical considerations tradeoff).
#
# ONE helper (ssh_kh_args) assembles the two -o flags every call site below
# uses — grep showed the ssh option string assembled ad hoc at 40+ call
# sites before this PRD; that is exactly the drift this centralizes.
KH_SESSION_ID=""

session_known_hosts_file() {  # -> stdout path for $1 (session id) or the
                               # active session's own server_id
  local sid="${1:-${KH_SESSION_ID:-$(state_read server_id 2>/dev/null)}}"
  echo "$BOX_STATE_DIR/known_hosts.${sid:-none}"
}

ssh_kh_args() {  # -> stdout "-o UserKnownHostsFile=<path> -o StrictHostKeyChecking=accept-new"
                  # Deliberately unquoted at every call site (four words,
                  # no embedded whitespace — $STATE_DIR is always a plain
                  # repo-relative path) so it drops straight into an
                  # existing "$SSH_BIN" ... invocation without an array.
  printf -- '-o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new' "$(session_known_hosts_file)"
}

session_known_hosts_reset() {  # $1 = new session id -> point KH_SESSION_ID
                                # at it and start the file fresh (up, both
                                # the adopt and create-fresh branches)
  KH_SESSION_ID="$1"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  : > "$(session_known_hosts_file "$1")"
}

session_known_hosts_remove() {  # remove the CURRENT session's known_hosts
                                 # file (down / down --force)
  rm -f "$(session_known_hosts_file)"
}

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
# PRD-build-burst-state-keyed-by-server-v2 requirement 2: SERVER_NAME above
# is now a PREFIX, not a literal server name — every box is
# "$SERVER_NAME-<n>" (n from 1), so a single-box caller (no --count) still
# gets exactly one box, now named wm-burst-lane-1 instead of the old bare
# wm-burst-lane (functionally identical: one box, same lifecycle, same
# journal/cost/state shape — Goal 2 is about behavior, not the literal name
# string). requirement 6: the money cap `up --count` is bounded by — a
# request above it is refused (`up refused cause=max-boxes`) before any
# hcloud call is made; the operator raises this in the same env file as
# SERVER_TYPE (see ENV_FILE below), never by editing this default.
BURST_MAX_BOXES="${BURST_MAX_BOXES:-1}"
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

# ---- pull retry/backoff (PRD-build-burst-pull-remote-target-missing) -------
# A genuine rsync-down failure (box up, dir there, transfer itself failed) is
# retried by `local-read` at 30s, 60s, 120s ... doubling, capped at 900s
# (15 min) — never at the 09-15 storm's ~7s cadence. After
# BURST_PULL_MAX_ATTEMPTS consecutive failures the marker is left dirty with
# stuck=true and `local-read` stops trying it at all until a new routed run
# rewrites the marker (mark_dirty overwrites the whole file, so attempts/
# stuck/next_retry_epoch/last_err all implicitly reset to absent = 0/false).
BURST_PULL_BACKOFF_BASE_S="${BURST_PULL_BACKOFF_BASE_S:-30}"
BURST_PULL_BACKOFF_CAP_S="${BURST_PULL_BACKOFF_CAP_S:-900}"
BURST_PULL_MAX_ATTEMPTS="${BURST_PULL_MAX_ATTEMPTS:-8}"

# ---- prove failure-evidence preservation (PRD-build-burst-prove-evidence-
# preservation) -------------------------------------------------------------
# Requirement 6: the evidence dir must live on the SAME filesystem as the
# disposable worktree's target/ (today under $TMPDIR, /mnt/data/jsy/tmp) so
# preserving a failed assert's pulled target is a `mv` (rename), never a
# `cp` of what can be several GB — $STATE_DIR itself is on a different
# filesystem (/, not /mnt/data) on RedBaron, so the real storage lives under
# BURST_PROVE_TMP and $STATE_DIR/evidence is kept as a symlink to it, giving
# every existing STATE_DIR-relative reader (status/reap/evidence-ls/tests)
# the conventional `state/burst-lane/evidence/<ts>-<server_id>/` path from
# the PRD's acceptance criteria without actually storing bytes there.
BURST_PROVE_TMP="${BURST_PROVE_TMP:-${TMPDIR:-/mnt/data/jsy/tmp}}"
EVIDENCE_ROOT="${BURST_EVIDENCE_ROOT:-$BURST_PROVE_TMP/burst-lane-evidence}"
EVIDENCE_DIR="$BOX_STATE_DIR/evidence"
# Requirement 3: how many evidence sets `reap` keeps, newest first.
BURST_EVIDENCE_KEEP="${BURST_EVIDENCE_KEEP:-3}"
# Persistent across sessions (NOT cleared by state_clear/`down`'s delete —
# the volume, and the fact that its last detach failed, outlive the box that
# was attached to it). volume_state_write's own key=value convention mirrors
# state_write's.
VOLUME_STATE_FILE="$BOX_STATE_DIR/volume.json"

# ---- setup-grace + cold-volume policy (PRD-build-burst-teardown-lifecycle) --
# BURST_SETUP_GRACE_MIN: minutes an autonomous teardown caller (anything
# other than the "down" tag — see teardown_and_delete) must wait past `up`
# before it may delete a session still in phase=setup. Protects the exact
# 2026-09-13 window a provision-failed box and a genuinely-still-setting-up
# one are indistinguishable by gate_ready/runs_served alone.
BURST_SETUP_GRACE_MIN="${BURST_SETUP_GRACE_MIN:-30}"
# BURST_VOLUME_KEEP_MIN_PCT: a volume below this used-pct (or one that has
# never served a build at all) is deleted, not kept, on the teardown that
# ends the lane's activity — a cold 500GB volume bills ~€38/mo for nothing;
# recreating it on the next `up` is cheaper than that idle rent.
BURST_VOLUME_KEEP_MIN_PCT="${BURST_VOLUME_KEEP_MIN_PCT:-5}"

die() { echo "burst-lane: $*" >&2; exit "${2:-1}"; }
usage() { echo "usage: burst-lane.sh {up|status|run|sync-back|pull|ensure-fresh|down|watchdog|idle-guard|why-down|cost|sub-cap|verify|provision|reap|box-isolation-check|route-check|parity|gate|bake} ..." >&2; exit 2; }

now_epoch() { echo "${BURST_LANE_NOW:-$(date -u +%s)}"; }
now_iso()   { date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
# journal_line is now the shared scripts/lib/journal.sh one (sourced above);
# this script's own flat $JOURNAL (burst-lane.log, or BURST_LANE_JOURNAL) is
# an absolute --file target on every call site below (PRD-build-test-isolation-by-default).

# ---- operator authorization (PRD-build-operator-authorization-contract) --
# The money-spending commands below (prove/up/bake) never trust an agent's
# own risk judgment for whether a dispatch is authorized to spend -- the
# operator's PRD-carried `Operator-authorization:` line is a checkable field
# instead. `BURST_LANE_AUTHZ` is the authorization string, set by the
# coordinator's Dispatch injection (SKILL.md's "Operator-authorization,
# dispatch-injected" section) from the PRD's own frontmatter line, verbatim.
# `BURST_LANE_DISPATCH=1` is the dispatch-context marker: set ONLY by a
# /build branch invocation, never by a human running this script directly at
# a terminal -- a human at the keyboard IS the authorization (requirement 6's
# own text), so the refusal below only ever fires for a dispatched call.
authz_journal_suffix() {  # -> " authz=\"<string>\"" or "" when unset
  [ -n "${BURST_LANE_AUTHZ:-}" ] && printf ' authz="%s"' "$BURST_LANE_AUTHZ"
}
authz_refuse_if_missing() {  # $1=subcommand name -> 0 ok to proceed, 1 refused (caller exits)
  if [ "${BURST_LANE_DISPATCH:-0}" = "1" ] && [ -z "${BURST_LANE_AUTHZ:-}" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $1  refused  (cause=no-operator-authorization)"
    echo "$1 refused (cause=no-operator-authorization)" >&2
    return 1
  fi
  return 0
}

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- state layout migration (PRD-build-burst-state-keyed-by-server-v2
# requirement 1) -------------------------------------------------------------
# migrate_state_layout: one-time (per top-level residue) move of every
# PER-BOX name (scripts/burst-state-surface.txt) from $STATE_DIR/<name>
# into $STATE_DIR/boxes/<server_id>/<name>, then points $STATE_DIR/current
# at it. Idempotent — a second call with nothing left at the top level is a
# no-op (checked by the `found` scan below, not by a separate marker file,
# so a crash mid-migration is safely resumed by the next invocation, real
# or a selftest's). Never deletes anything, only `mv`s.
# box_point_current_at <server_id>: make $STATE_DIR/current a symlink to
# boxes/<id>, no matter what `current` was before this call — absent, a
# symlink to some other (or the startup "pending") box, or a plain real
# directory (a fixture writing fixture state under current/ before any
# real box existed this invocation, or this same process's own
# up.lock/up.pid/inflight.log written before the id was known — see
# box_ensure_current). `ln -sfn` alone cannot turn an existing real
# directory into a symlink — it silently nests the new link INSIDE it
# instead, stranding whatever was already there (the exact bug this
# closes: a real `current/` directory left `up.pid` unreachable through
# the symlink forever). A symlink to a DIFFERENT, already-real box is left
# alone — that is genuine prior-session history, never folded into a new
# one; only a real directory or the "pending" placeholder gets folded
# forward.
box_point_current_at() {
  local id="$1"
  [ -n "$id" ] || return 0
  mkdir -p "$STATE_DIR/boxes/$id" 2>/dev/null || true
  if [ -e "$STATE_DIR/current" ] && [ ! -L "$STATE_DIR/current" ]; then
    ( cd "$STATE_DIR/current" 2>/dev/null \
        && find . -mindepth 1 -maxdepth 1 -exec mv -n {} "$STATE_DIR/boxes/$id/" \; ) 2>/dev/null || true
    rm -rf "$STATE_DIR/current" 2>/dev/null || true
  elif [ -L "$STATE_DIR/current" ] && [ "$(readlink "$STATE_DIR/current" 2>/dev/null)" = "boxes/pending" ] \
         && [ "$id" != "pending" ] && [ -d "$STATE_DIR/boxes/pending" ]; then
    ( cd "$STATE_DIR/boxes/pending" 2>/dev/null \
        && find . -mindepth 1 -maxdepth 1 -exec mv -n {} "$STATE_DIR/boxes/$id/" \; ) 2>/dev/null || true
    rmdir "$STATE_DIR/boxes/pending" 2>/dev/null || true
  fi
  ln -sfn "boxes/$id" "$STATE_DIR/current"
}

migrate_state_layout() {
  [ -d "$STATE_DIR" ] || return 0
  local id="" jqbin; jqbin="$(command -v jq 2>/dev/null || true)"
  if [ -f "$STATE_DIR/session.json" ]; then
    if [ -n "$jqbin" ]; then
      id="$("$jqbin" -r '.server_id // empty' "$STATE_DIR/session.json" 2>/dev/null)"
    else
      id="$(grep -oE '"server_id":"?[^,"}]*"?' "$STATE_DIR/session.json" 2>/dev/null \
              | head -n1 | sed -E 's/^[^:]*:"?([^",}]*)"?$/\1/')"
    fi
  fi
  if [ -z "$id" ]; then
    # requirement 1 migration rule: no top-level session.json (box already
    # deleted, or a crash before one was ever written) — fall back to the
    # known_hosts.<id> suffix, the other clue the PRD names.
    local kh
    for kh in "$STATE_DIR"/known_hosts.*; do
      [ -e "$kh" ] || continue
      local cand="${kh##*/known_hosts.}"
      [ "$cand" = "none" ] && continue
      id="$cand"; break
    done
  fi

  # Snapshot every top-level per-box entry that actually exists before
  # moving anything, so the journaled moved=<n> count is exact and stable.
  local perbox_names=(session.json volume.json proof.json run.lock cost.jsonl \
    attribution.jsonl prds_served gate-tools.json remote-dirs.json remote-dirs.lock \
    up.lock up.pid prove.inflight inflight.log .last-teardown-cause .probe-unavailable-last)
  local perbox_dirs=(slots locks dirty pull-sizes evidence gate-inflight)
  # requirement 1's "logs/{...}" bullet — only these prefixes are per-box;
  # logs/failed/ and logs/failed-sessions.log (GATE_TOOLS_FAILED_*) stay
  # lane-wide and are deliberately never matched here.
  local log_prefixes="run-remote rsync-up rsync-gate rsync-parity pathdep-rsync pull-fail prove gate-tools-install gate-tools-apt-update"
  local found=() name f
  for name in "${perbox_names[@]}"; do
    for f in "$STATE_DIR/$name" "$STATE_DIR/$name".backup "$STATE_DIR/$name".stale-* "$STATE_DIR/$name".deleted-*; do
      [ -e "$f" ] && found+=("$f")
    done
  done
  for name in "${perbox_dirs[@]}"; do
    [ -e "$STATE_DIR/$name" ] && found+=("$STATE_DIR/$name")
  done
  for f in "$STATE_DIR"/known_hosts.*; do
    [ -e "$f" ] && found+=("$f")
  done
  if [ -d "$STATE_DIR/logs" ]; then
    local pfx
    for pfx in $log_prefixes; do
      for f in "$STATE_DIR/logs/$pfx".*; do
        [ -e "$f" ] && found+=("$f")
      done
    done
  fi
  [ "${#found[@]}" -gt 0 ] || return 0

  local dest
  if [ -n "$id" ]; then dest="$STATE_DIR/boxes/$id"
  else dest="$STATE_DIR/boxes/_orphan-$(now_epoch)"
  fi
  mkdir -p "$dest" 2>/dev/null || true

  local moved=0 src rel
  for src in "${found[@]}"; do
    rel="${src#"$STATE_DIR"/}"
    mkdir -p "$dest/$(dirname "$rel")" 2>/dev/null || true
    mv -f "$src" "$dest/$rel" 2>/dev/null && moved=$((moved + 1))
  done

  if [ -n "$id" ]; then
    box_point_current_at "$id"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  state  migrated  (server_id=$id moved=$moved)"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  state  migrated-orphan  (dest=$(basename "$dest") moved=$moved)"
  fi
}

# box_ensure_current: guarantee $STATE_DIR/current exists as a real symlink
# before the first per-box path of this invocation is used — migration
# above already sets it when a real server_id was found; this covers the
# remaining "genuinely fresh, or already fully torn down" case so nothing
# downstream (e.g. cmd_up's UP_LOCK_FILE) ever races `mkdir -p` into
# creating `current` itself as a plain directory. cmd_up's box_activate
# repoints this at the real server_id the instant one is known (adopt or
# fresh-create); anything this process writes before that (up.lock,
# up.pid, inflight.log) lands in the disposable "pending" box and is
# folded into the real one by box_activate.
box_ensure_current() {
  if [ ! -e "$STATE_DIR/current" ] && [ ! -L "$STATE_DIR/current" ]; then
    mkdir -p "$STATE_DIR/boxes/pending" 2>/dev/null || true
    ln -sfn "boxes/pending" "$STATE_DIR/current" 2>/dev/null || true
  fi
}

# box_carry_forward_volume_state <new server id>: volume.json is the one
# per-box name (requirement 1's own classification) whose SUBJECT — the
# persistent Hetzner volume PRD-build-burst-persistent-volume introduced —
# outlives the box it happens to be filed under: the same volume reattaches
# to whatever box replaces a deleted one. Left purely per-box, a
# volume_dirty=true flag set by the box that just got torn down would
# vanish into that now-orphaned box's directory the moment `current`
# repoints at a brand-new box id, silently dropping the "fsck before
# mount" signal the persistent-volume PRD depends on (Goal 2: zero
# behavior change for single-box callers). Called BEFORE box_activate
# repoints `current`, while it still names the box that just went away.
box_carry_forward_volume_state() {
  local new_id="$1" old_dir
  old_dir="$(readlink -f "$STATE_DIR/current" 2>/dev/null || true)"
  [ -n "$old_dir" ] && [ -f "$old_dir/volume.json" ] || return 0
  [ "$old_dir" = "$STATE_DIR/boxes/$new_id" ] && return 0
  local new_dir="$STATE_DIR/boxes/$new_id"
  [ -f "$new_dir/volume.json" ] && return 0   # never clobber a box that already has its own
  mkdir -p "$new_dir" 2>/dev/null || true
  cp -p "$old_dir/volume.json" "$new_dir/volume.json" 2>/dev/null || true
}

# box_reset_pending: force `current` to a FRESH, empty "pending" placeholder
# regardless of what it currently names. PRD-build-burst-state-keyed-by-
# server-v2 requirement 2: cmd_up's `--count N` loop calls this between
# box 2..N — each new box's own create/adopt body (up_one_box) writes
# exclusively through box_path()'s "current"-relative globals (STATE_FILE,
# COST_LEDGER, SERVED_FILE, UP_LOCK_FILE, ...), so without this, box 2's own
# up_one_box call would silently overwrite box 1's state the moment
# `current` already names it (box 1 having just been activated by the
# previous loop iteration). Never called for box 1 in that loop — box 1
# reuses whatever `current` already legitimately names, so a caller that
# never passes --count never calls this at all (Goal 2: zero behavior
# change for a single-box caller). Defined here (before box_activate, still
# inside the tripwire's box_path()/migration block) since it shares that
# block's one license to spell "boxes/" literally.
box_reset_pending() {
  rm -rf "$STATE_DIR/boxes/pending" 2>/dev/null || true
  mkdir -p "$STATE_DIR/boxes/pending" 2>/dev/null || true
  ln -sfn "boxes/pending" "$STATE_DIR/current"
}

# count_active_boxes: number of boxes/<id>/ directories carrying a live
# session.json (excludes the "pending" scratch placeholder and any
# "_orphan-<ts>" migration residue, and a torn-down box's directory once
# its session.json has been archived to .stale-*/.deleted-* — same literal-
# file test state_active()/box_point_current_at() already use elsewhere in
# this block). Requirement 9: `prove`/`bake` are only ever attributable to
# ONE box (a proof is per image, not per box) — see their own refusal
# checks below this function.
count_active_boxes() {
  local n=0 d
  for d in "$STATE_DIR"/boxes/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      pending|_orphan-*) continue ;;
    esac
    [ -f "${d}session.json" ] && n=$((n + 1))
  done
  echo "$n"
}

# list_active_box_ids: one server_id per line, `current`-first (requirement
# 3's own ordering rule), then every other box carrying a live session.json —
# the same liveness test count_active_boxes() uses, excluding the "pending"
# scratch placeholder and "_orphan-*" migration residue. Lane-wide iteration
# primitive shared by `run`'s box selection (requirement 3) and, in later
# steps, `down`/`idle_guard`/`watchdog`/`cost`/`reap` (requirements 4/5/8).
list_active_box_ids() {
  local cur_id="" d id
  if [ -L "$STATE_DIR/current" ]; then
    cur_id="$(basename "$(readlink "$STATE_DIR/current" 2>/dev/null)" 2>/dev/null)"
  fi
  if [ -n "$cur_id" ] && [ -f "$STATE_DIR/boxes/$cur_id/session.json" ]; then
    printf '%s\n' "$cur_id"
  fi
  for d in "$STATE_DIR"/boxes/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    case "$id" in pending|_orphan-*) continue ;; esac
    [ "$id" = "$cur_id" ] && continue
    [ -f "${d}session.json" ] && printf '%s\n' "$id"
  done
}

# list_all_box_ids: one server_id per line, every boxes/<id>/ directory
# (excluding "pending"/"_orphan-*") REGARDLESS of whether it still carries a
# live session.json — unlike list_active_box_ids above, a torn-down box's
# directory is never deleted (requirement 8's own reap rule only deletes an
# hcloud resource with NO boxes/<id>/ dir, never the dir itself), so its
# cost.jsonl history is still real spend that happened today. Requirement
# 5's own iteration primitive: `cost --today`/`cost --by-prd` must sum every
# box that billed anything today, active or already torn down, not just
# whichever one(s) are up right now.
list_all_box_ids() {
  local d id
  for d in "$STATE_DIR"/boxes/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    case "$id" in pending|_orphan-*) continue ;; esac
    printf '%s\n' "$id"
  done
}

# box_context <server_id>: repoint every per-box global at boxes/<id> — the
# same right-hand sides the top-level assignments above compute from
# BOX_STATE_DIR, recomputed against an EXPLICIT id instead of the `current`
# symlink. This is the multi-box counterpart to box_path()'s single-box
# resolution: box_path() (and every function that only ever reads
# $BOX_STATE_DIR/$STATE_FILE/etc.) keeps working unchanged, it simply now
# resolves against whichever box this call last selected. Never repoints
# `current` itself — selecting a box for one run does not make it "the"
# box. Used by requirement 3 (`run`'s per-box selection) and, in later
# steps, by requirements 4/5/8's own per-box iteration.
# box_context_at <root>: the shared implementation — repoints every
# per-box global at whatever directory <root> names, literally. Split out
# from box_context() so a caller that resolved to the box `current` ALREADY
# points at can pass "$STATE_DIR/current" itself (see box_context below) —
# preserving the exact literal path string every pre-multibox caller/test
# already depends on (e.g. ssh/rsync's UserKnownHostsFile carrying
# ".../current/known_hosts.<id>", not ".../boxes/<id>/known_hosts.<id>" —
# the same file either way, but a different STRING, and bursthyg AC1's own
# literal-path check caught exactly this when an earlier version of
# select_run_box called box_context() unconditionally even for the box that
# was already `current`).
box_context_at() {
  BOX_STATE_DIR="$1"
  STATE_FILE="$BOX_STATE_DIR/session.json"
  PROOF_STATE_FILE="$BOX_STATE_DIR/proof.json"
  COST_LEDGER="${BURST_LANE_COST_LEDGER:-$BOX_STATE_DIR/cost.jsonl}"
  SERVED_FILE="$BOX_STATE_DIR/prds_served"
  TEARDOWN_CAUSE_FILE="$BOX_STATE_DIR/.last-teardown-cause"
  PROBE_UNAVAILABLE_MARK_FILE="$BOX_STATE_DIR/.probe-unavailable-last"
  DIRTY_DIR="$BOX_STATE_DIR/dirty"
  PULLSZ_DIR="$BOX_STATE_DIR/pull-sizes"
  REMOTE_DIRS_FILE="$BOX_STATE_DIR/remote-dirs.json"
  REMOTE_DIRS_LOCK="$BOX_STATE_DIR/remote-dirs.lock"
  GATE_TOOLS_STATE_FILE="$BOX_STATE_DIR/gate-tools.json"
  UP_LOCK_FILE="$BOX_STATE_DIR/up.lock"
  UP_PID_FILE="$BOX_STATE_DIR/up.pid"
  PROVE_INFLIGHT_FILE="$BOX_STATE_DIR/prove.inflight"
  INFLIGHT_LOG="$BOX_STATE_DIR/inflight.log"
  EVIDENCE_DIR="$BOX_STATE_DIR/evidence"
  VOLUME_STATE_FILE="$BOX_STATE_DIR/volume.json"
  RUN_LOCK="$BOX_STATE_DIR/run.lock"
  GATE_INFLIGHT_DIR="$BOX_STATE_DIR/gate-inflight"
  ATTR_LEDGER="${BURST_LANE_ATTR_LEDGER:-$BOX_STATE_DIR/attribution.jsonl}"
}

# box_context <server_id>: resolve to boxes/<id> EXPLICITLY, except when
# <id> is the box `current` already points at — then resolve through
# "$STATE_DIR/current" itself instead, so the literal path never changes
# for the common case (one box, or a multi-box run that happened to land
# on `current`). Never repoints `current` itself — selecting a box for one
# run does not make it "the" box. Used by requirement 3 (`run`'s per-box
# selection) and, in later steps, by requirements 4/5/8's own per-box
# iteration.
box_context() {
  local id="$1"
  [ -n "$id" ] || return 0
  if [ -L "$STATE_DIR/current" ] && [ "$(basename "$(readlink "$STATE_DIR/current" 2>/dev/null)" 2>/dev/null)" = "$id" ]; then
    box_context_at "$STATE_DIR/current"
  else
    box_context_at "$STATE_DIR/boxes/$id"
  fi
}

# select_run_box: requirement 3 — the first box (current-first order) whose
# slot table has a free slot, ACQUIRED atomically in the same non-blocking
# pass that finds it (never a peek-then-release hint — an earlier version
# of this function only peeked, and every one of N simultaneous callers saw
# the same instant of "free" on the first box, so all of them piled onto
# ITS blocking wait once the real acquisition ran a moment later; caught by
# this PRD's own multibox AC3 concurrency fixture: 12 runs all landed on
# one box instead of splitting 4+4 across two). Leaves box_context pointed
# at whichever box actually granted the slot, and sets SLOT_HELD/
# SLOT_INDEX exactly as acquire_run_slot always has (the caller reads
# $SLOT_HELD immediately after calling this, same as before). When no box
# is active yet at all this is a no-op (the caller's auto-`up` path runs
# first and guarantees at least one box exists before this is ever
# called). Falls back to a BLOCKING wait on `current`'s own table, "as
# today", only when every active box's table was full at this pass's
# snapshot — delegates to the ordinary acquire_run_slot for that case, so
# the 120s slot-wait journal line and the sleep-2 retry cadence are
# byte-identical to single-box behavior.
select_run_box() {  # $1 = worktree (passed through to acquire_run_slot's own journal on the fallback path)
  local id cap i j held any=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    any=1
    box_context "$id"
    run_slot_cap; cap="$RUN_SLOT_CAP"
    mkdir -p "$BOX_STATE_DIR/slots" 2>/dev/null || true
    for i in $(seq 1 "$cap"); do
      exec 202>"$BOX_STATE_DIR/slots/$i.lock"
      if flock -n 202; then
        held=0
        for j in $(seq 1 "$cap"); do
          [ "$j" = "$i" ] && { held=$((held+1)); continue; }
          ( exec 210>"$BOX_STATE_DIR/slots/$j.lock"; flock -n 210 ) 2>/dev/null || held=$((held+1))
        done
        SLOT_HELD="$held/$cap"; SLOT_INDEX="$i"
        return 0
      fi
    done
  done < <(list_active_box_ids)
  # Requirement 3's documented fallback: no active box had a slot free at
  # this pass's snapshot -> pin to `current` and BLOCK on its own table,
  # exactly as the single-box lane always has (acquire_run_slot's own
  # sleep-2 retry loop, journaled after 120s).
  if [ "$any" -eq 1 ] && [ -L "$STATE_DIR/current" ]; then
    box_context "$(basename "$(readlink "$STATE_DIR/current")")"
  fi
  acquire_run_slot "$1"
}

# box_activate <server_id>: point `current` at boxes/<id>, creating it if
# needed, folding forward whatever transient content was already sitting
# at `current` (the startup "pending" placeholder, or a plain directory —
# see box_point_current_at above for why that case needs care), and
# carrying the persistent volume's own state forward (see
# box_carry_forward_volume_state above) before the old box's directory is
# left behind as inert history. Defined last in this block (after
# list_active_box_ids/box_context/select_run_box) so the tripwire's
# box_path()/box_activate() license region — BOX_STATE_DIR= through this
# function's own closing brace — still covers every "boxes/" literal those
# three helpers spell.
box_activate() {
  box_carry_forward_volume_state "$1"
  box_point_current_at "$1"
}

migrate_state_layout
box_ensure_current

# ---- config -------------------------------------------------------------
load_env() {
  # PRD-build-burst-dispatch-reenable requirement 2: start empty (not the
  # default) so the block below can tell whether the env file itself
  # supplied SNAPSHOT_ID -- up's own image-source journal line
  # (baked|env|default) needs to distinguish the latter two tiers, which
  # collapsing straight to DEFAULT_SNAPSHOT_ID up front would erase.
  SNAPSHOT_ID=""
  LOCATION="$DEFAULT_LOCATION"
  SSH_KEY="$HOME/.ssh/id_ed25519"
  # PRD-build-burst-unprivileged-user requirement 1: unprivileged by default.
  # BURST_LANE_REMOTE_USER=root (the selftest fixture's override point, and
  # an operator's documented rollback -- see the header note) is the only way
  # back to the old all-root behavior; an env-file REMOTE_USER= line (none
  # ship today) can still override it, same as every other load_env var.
  REMOTE_USER="${BURST_LANE_REMOTE_USER:-build}"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  if [ -n "$SNAPSHOT_ID" ]; then
    SNAPSHOT_ID_FROM_ENV=1
  else
    SNAPSHOT_ID_FROM_ENV=0
    SNAPSHOT_ID="$DEFAULT_SNAPSHOT_ID"
  fi
  LOCATION="${BUILDER_LOC:-$LOCATION}"
  # BURST_SERVER_TYPE from the env file must win over the pre-source default
  # (SERVER_TYPE is assigned before load_env runs).
  SERVER_TYPE="${BURST_SERVER_TYPE:-$SERVER_TYPE}"
}
load_env

# 2026-09-11 policy: RedBaron-local — burst `up` must refuse unless an
# operator has genuinely opted back in. burst_configured() is the single
# shared predicate (also used by selftests); source it defensively so a
# missing/moved lib file fails the gate open-safe (refuse), never silently
# skips the check. See lib/burst-configured.sh for the full contract.
# shellcheck disable=SC1091
if [ -r "$HERE/lib/burst-configured.sh" ]; then
  source "$HERE/lib/burst-configured.sh"
else
  burst_configured() { return 1; }
fi

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

# PRD-build-burst-path-deps requirement 5: the build user's OWN cargo home
# (registry + git caches) — never root's shared ROOT_CARGO_HOME. RUSTUP_HOME
# stays ROOT_RUSTUP_HOME everywhere below (the shared toolchain is read-only
# and that is fine — only the registry/git CACHE a `cargo` invocation writes
# into needs write access, and root's copy is chmod'd read+execute only, see
# create_remote_user()). The write race this closes: two `run`s as build
# both fetching a not-yet-cached crate into a directory neither of them
# could write raced and failed until an operator chmod'd root's registry by
# hand (2026-09-11, this PRD's five-whys level 5). Root rollback
# (REMOTE_USER=root) keeps CARGO_HOME=ROOT_CARGO_HOME exactly as before this
# PRD — root already owns that tree outright, nothing to fix there. Note
# this only changes the CARGO_HOME *data* directory; the `cargo`/`rustup`
# *binaries* are still found via $ROOT_CARGO_HOME/bin on PATH wherever that
# was already exported (cmd_run, cmd_verify) — CARGO_HOME need not contain
# the binary that reads it.
if [ "$REMOTE_USER" = "root" ]; then
  RUN_CARGO_HOME="$ROOT_CARGO_HOME"
else
  RUN_CARGO_HOME="${BURST_LANE_BUILD_CARGO_HOME:-$REMOTE_HOME/.cargo}"
fi

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

# ---- cost_rate_eur (price box-hours by server type) ------------------------
# Single source of truth for the box-hour rate every cost computation in
# this script uses (teardown_and_delete, prove_snapshot_cost, up's own
# ssh-unreachable-before-boot fallback) — 2026-09-15 finding: a hardcoded
# COST_PER_HOUR_EUR=0.47 kept pricing every box at the old ccx53 estimate
# while the fleet actually ran ccx43 (real 0.522/h) and was about to move
# to ccx53 (real 1.009/h), under-reporting every cost line, cost.jsonl row,
# per-slug proration and the (future) eur/day auto-disable.
#
# Resolution order: 1) an explicit $1 override (a type string — used only
# by the one call site, up's pre-session-json fallback, where the box was
# just created with the current $SERVER_TYPE and no session.json exists
# yet to read back); 2) the SESSION's own recorded server_type (state_read
# — written at `up`/adopt time next to server_id/ip and carried forward,
# unchanged, by every later state_write in this file), so a session
# booted as ccx43 is priced ccx43 for its whole life even if an operator
# flips $SERVER_TYPE/BURST_SERVER_TYPE for the NEXT box before this one
# tears down; 3) the current $SERVER_TYPE var (no session yet at all).
#
# $BURST_COST_PER_HOUR_EUR, when set, overrides the table outright for
# every type, known or not — the documented operator escape hatch. An
# unknown type with no override falls back to the historical
# $COST_PER_HOUR_EUR (0.47) default and journals the fact, so a fleet move
# to a not-yet-priced type is loud (rate-unknown) rather than a silent
# under-charge.
cost_rate_eur() {  # $1 = optional explicit server type override -> stdout eur/h
  local t="${1:-}"
  if [ -z "$t" ]; then
    t="$(state_read server_type 2>/dev/null)"
    [ -n "$t" ] || t="$SERVER_TYPE"
  fi
  if [ -n "${BURST_COST_PER_HOUR_EUR:-}" ]; then
    printf '%s' "$BURST_COST_PER_HOUR_EUR"
    return 0
  fi
  case "$t" in
    ccx33) printf '%s' "0.261" ;;
    ccx43) printf '%s' "0.522" ;;
    ccx53) printf '%s' "1.009" ;;
    ccx63) printf '%s' "1.614" ;;
    *)
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  cost  rate-unknown  (type=$t using=$COST_PER_HOUR_EUR)"
      printf '%s' "$COST_PER_HOUR_EUR"
      ;;
  esac
}

# Migration/compatibility: a session.json written before this PRD has no
# "phase" key at all — that reads as phase=provisioned (existing behavior,
# no grace), never as phase=setup. Every state_write call site that isn't
# itself transitioning phase should preserve the CURRENT value via this
# reader (never hardcode "provisioned" directly), so a genuinely-still-
# "setup" session mid-boot doesn't get silently promoted out of its own
# grace window by an unrelated field update (e.g. cmd_run's runs_served++).
state_read_phase() { local p; p="$(state_read phase)"; printf '%s\n' "${p:-provisioned}"; }

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
  # PRD-build-burst-teardown-lifecycle requirement 5: volume_runs_served
  # joins this preserve-list — like every field here, a partial call (e.g.
  # volume_teardown's own "volume_used_pct=$used_pct" refresh) must never
  # silently drop it; it is this volume's own lifetime "has it ever served
  # a build" signal and has to survive every write that doesn't explicitly
  # touch it, exactly like volume_dirty already does across sessions.
  for k in volume_id volume_mounted volume_dirty volume_size_gb volume_used_pct volume_runs_served; do
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
  # Fail OPEN when hcloud itself is unavailable (binary off PATH, no token):
  # a probe that cannot run says nothing about the server, and archiving a
  # live session as stale on that basis dropped three billed boxes on
  # 2026-09-15 (06:46Z, 07:08Z, 08:51Z). Only hcloud actually answering
  # "not found", or a working hcloud that lists servers without this id,
  # counts as gone.
  command -v "$HCLOUD" >/dev/null 2>&1 || return 0
  local out; out="$("$HCLOUD" server describe "$1" -o json 2>&1)" && return 0
  case "$out" in *"not found"*|*"not exist"*) return 1 ;; esac
  "$HCLOUD" server list -o noheader -o columns=id >/dev/null 2>&1 || return 0
  return 1
}

volume_alive() {  # $1 = volume id -> 0 if hcloud still sees it
  [ -n "$1" ] || return 1
  "$HCLOUD" volume describe "$1" -o json >/dev/null 2>&1
}

# ---- stale-state archiving (PRD-build-burst-session-hygiene requirements --
# 2/4/5) — a state file whose hcloud object is confirmed gone is archived,
# never silently rm -f'd: an operator (or the next `status`) can still see
# what the session/volume WAS, and a bug in the reconcile logic never looks
# like "there was never a session" after the fact.
archive_stale_file() {  # $1 = path to archive as <path>.stale-<utc-ts>
  local f="$1"
  [ -f "$f" ] || return 0
  local ts; ts="$(date -u -d "@$(now_epoch)" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  mv -f "$f" "$f.stale-$ts"
}

# Requirement 2/4: verify session.json's server_id against hcloud. Archives
# and returns 1 if hcloud says the server is gone (or no id was recorded at
# all); returns 0 (no-op) if the server is confirmed alive. Callers that
# need the fresh-session side effects (state_clear-equivalent) do that
# themselves — this only judges truth and archives.
session_reconcile() {
  state_active || return 0
  local id; id="$(state_read server_id)"
  if [ -n "$id" ] && server_alive "$id"; then
    return 0
  fi
  archive_stale_file "$STATE_FILE"
  rm -f "$SERVED_FILE"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  session  stale  (server_id=${id:-none} absent from hcloud — archived session.json, proceeding fresh)"
  return 1
}

# Requirement 5: same treatment for the persistent-volume state file.
# volume.json's own volume_id field (not just BURST_VOLUME_NAME's live
# by-name lookup, which find_volume() already does independently) is what
# gets verified here — an out-of-band `hcloud volume delete` leaves the by-
# name lookup empty too, but this is the one place that ever LOOKS at
# volume.json's claim and corrects it. Empty/absent volume_id (rollback, or
# a session that never attached one) is vacuously verified — nothing to
# reconcile. Returns 1 (and archives) only when a recorded volume_id is
# confirmed gone from hcloud.
volume_reconcile() {
  [ -f "$VOLUME_STATE_FILE" ] || return 0
  local vid; vid="$(volume_state_read volume_id)"
  [ -n "$vid" ] || return 0
  if volume_alive "$vid"; then
    return 0
  fi
  archive_stale_file "$VOLUME_STATE_FILE"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  volume  stale  (volume_id=$vid absent from hcloud — archived volume.json)"
  return 1
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

# find_by_prefix <prefix> -> one line per live server whose name is exactly
# <prefix> or starts with "<prefix>-" (the wm-burst-lane-<n> convention,
# requirement 2): "id ip name", rc 0 if any found else rc 1. Set-discovery
# primitive `up --count`, `reap`, and any future multi-box iterator use
# instead of `find_by_name`'s single-exact-name lookup — hcloud has no
# server-list-by-name-prefix flag, so this lists every server the account
# owns (one hcloud call) and filters client-side; safe at this lane's scale
# (single-digit boxes) and matches the fake hcloud fixture's own `server
# list -o json` shape (a plain JSON array, same envelope the real CLI uses).
find_by_prefix() {
  local prefix="$1" out
  out="$("$HCLOUD" server list -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
prefix = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
servers = d if isinstance(d, list) else d.get("servers", [])
found = False
for s in servers:
    name = s.get("name", "")
    if name == prefix or name.startswith(prefix + "-"):
        ip = s.get("public_net", {}).get("ipv4", {}).get("ip", "")
        print(s.get("id", ""), ip, name)
        found = True
sys.exit(0 if found else 1)
' "$prefix" <<<"$out"
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
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "$setup
[ -f $REMOTE_HOME/.ssh/.burst-lane-key-installed ] || { cat >> $REMOTE_HOME/.ssh/authorized_keys && chown $REMOTE_USER:$REMOTE_USER $REMOTE_HOME/.ssh/authorized_keys && touch $REMOTE_HOME/.ssh/.burst-lane-key-installed; }
chmod 600 $REMOTE_HOME/.ssh/authorized_keys 2>/dev/null || true
true" < "${SSH_KEY}.pub" 2>/dev/null || true
  else
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "$setup
true" 2>/dev/null || true
  fi
}

box_bootstrap() {  # $1 = ip — make a snapshot box ready (idempotent, ~1s when already done)
  # Requirement 3: root only for the apparmor sysctl and apt-based installs.
  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$1" "
    sysctl -qw kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    command -v bwrap >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq bubblewrap; } >/dev/null 2>&1
    command -v python3 >/dev/null 2>&1 || apt-get install -y -qq python3-minimal python3 >/dev/null 2>&1
    true" 2>/dev/null || true
  create_remote_user "$1"
  # Everything else — requirement 3's "everything else uses build@$ip" —
  # including uv, which has no business running as root just to land a
  # binary in a user's own $HOME/.local/bin.
  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
    mkdir -p $REMOTE_ROOT
    # PRD-build-burst-path-deps requirement 5: the build user's own cargo
    # home (registry+git caches), created up front so the first `cargo`
    # invocation that needs to fetch a not-yet-cached crate never races an
    # on-demand mkdir under a directory it doesn't own — a no-op when
    # RUN_CARGO_HOME already equals ROOT_CARGO_HOME (root rollback).
    mkdir -p $RUN_CARGO_HOME/registry $RUN_CARGO_HOME/git
    command -v uv >/dev/null 2>&1 || [ -x $REMOTE_HOME/.local/bin/uv ] || (curl -LsSf https://astral.sh/uv/install.sh | sh) >/dev/null 2>&1
    true" 2>/dev/null || true
}

sandbox_probe() {  # $1 = ip -> echoes true|false
  if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" \
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
# PRD-build-burst-volume-id-parse: single structural parser for every hcloud
# volume JSON response (describe AND create) — id/size/server/linux_device/
# created only, never text-scraped. Reads JSON on stdin, echoes
# "id|size|server|device|created" (server empty when unattached; id empty
# when stdin isn't parseable JSON shaped like a volume — the caller's own
# unwind/failed branch, never this function's, decides what that means).
volume_json_parse() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
d = d.get("volume", d)
sid = d.get("server")
print("%s|%s|%s|%s|%s" % (d.get("id",""), d.get("size",""), sid if sid is not None else "", d.get("linux_device",""), d.get("created","")))
' 2>/dev/null
}

find_volume() {  # -> stdout "id size_gb server_id device created" (server_id
                  # empty if unattached); rc1 if BURST_VOLUME_NAME is unset/
                  # empty (the documented rollback) or hcloud reports no such
                  # volume
  [ -n "$BURST_VOLUME_NAME" ] || return 1
  local out; out="$("$HCLOUD" volume describe "$BURST_VOLUME_NAME" -o json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  # PRD-build-burst-persistent-volume: pipe-delimited, NOT space-delimited —
  # server_id is routinely empty (an unattached volume), and `read`'s
  # default IFS word-splitting collapses consecutive whitespace, silently
  # dropping an empty middle field and shifting linux_device into server_id's
  # slot (caught in offline testing: a fresh, never-attached volume read
  # back as "busy, attached to /dev/disk/by-id/...").
  local parsed; parsed="$(volume_json_parse <<<"$out")"
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

# PRD-build-burst-volume-id-parse P0 (create is transactional): the only
# caller is volume_ensure, right after a create exited 0 but the id could
# not be read back. Locates the volume by NAME (never by a variable this
# branch never got to set — that's the whole reason it's needed) and
# deletes it, so a create the lane cannot track never outlives this
# function call. Journals volume-create-unwound, never volume-create-failed
# — the create itself succeeded; only the tracking of it failed.
volume_unwind_untracked() {  # $1=cause
  local cause="$1"
  local found; found="$(find_volume 2>/dev/null)"
  if [ -z "$found" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-create-unwound  (name=$BURST_VOLUME_NAME id=unknown cause=$cause)"
    return 0
  fi
  local vid vsize vserver vdevice vcreated
  IFS='|' read -r vid vsize vserver vdevice vcreated <<<"$found"
  "$HCLOUD" volume delete "$vid" >/dev/null 2>&1
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-create-unwound  (name=$BURST_VOLUME_NAME id=$vid cause=$cause)"
}

volume_ensure() {  # $1=ip $2=server_id
  local ip="$1" sid="$2"
  if [ -z "$BURST_VOLUME_NAME" ]; then
    volume_state_write "volume_mounted=false"
    return 0
  fi

  local vid vsize vserver vdevice vcreated
  local found; found="$(find_volume)"
  if [ -n "$found" ]; then
    IFS='|' read -r vid vsize vserver vdevice vcreated <<<"$found"
  fi

  # PRD-build-burst-volume-id-parse P0 startup guard: `up` never stacks a
  # second volume on top of an unattached one left behind by a prior run.
  # An unattached volume found here (vserver empty) is adopted when its
  # size already matches what this run wants, or replaced (deleted, then
  # fall through to the create path below) when it doesn't — either way
  # exactly one volume exists once this function returns, and the journal
  # names which happened. A volume already attached to a server (this one
  # or another) skips the guard entirely; the busy/attach logic further
  # down is unchanged.
  if [ -n "$found" ] && [ -z "$vserver" ]; then
    if [ "$vsize" = "$BURST_VOLUME_GB" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume  adopted  (id=$vid name=$BURST_VOLUME_NAME size=${vsize}G cause=unattached-at-startup)"
    else
      if "$HCLOUD" volume delete "$vid" >/dev/null 2>&1; then
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-guard-replaced  (id=$vid name=$BURST_VOLUME_NAME old_size=${vsize}G target_size=${BURST_VOLUME_GB}G cause=size-mismatch)"
      else
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-guard-delete-failed  (id=$vid name=$BURST_VOLUME_NAME size=${vsize}G — booting on root disk)"
        volume_state_write "volume_mounted=false"
        return 0
      fi
      found=""
    fi
  fi

  if [ -z "$found" ]; then
    # P0 correct parse: stdout and stderr captured separately (--quiet on
    # top, so only real errors ever reach stderr) — the id is parsed from
    # stdout alone, never a string that might carry hcloud's own action-
    # progress text. Mirrors cmd_up's own server-create convention above.
    local create_out create_err; create_err="$(mktemp)"
    local create_rc=0
    create_out="$("$HCLOUD" volume create --name "$BURST_VOLUME_NAME" --size "$BURST_VOLUME_GB" --location "$LOCATION" --quiet -o json 2>"$create_err")" || create_rc=$?
    if [ "$create_rc" -ne 0 ]; then
      # P0 honest journal grammar: the ONLY branch that journals
      # volume-create-failed — the create itself exited non-zero, so
      # nothing was made and nothing needs unwinding.
      local emsg; emsg="$(tail -3 "$create_err" 2>/dev/null | tr '\n' ' ')"; rm -f "$create_err"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-create-failed  (name=$BURST_VOLUME_NAME err=\"$emsg\" — booting on root disk)"
      volume_state_write "volume_mounted=false"
      return 0
    fi
    rm -f "$create_err"
    local parsed; parsed="$(volume_json_parse <<<"$create_out")"
    IFS='|' read -r vid vsize vserver vdevice vcreated <<<"$parsed"
    if [ -z "$vid" ]; then
      # P0 create is transactional: the create exited 0 (it really happened
      # server-side) but this id could not be read back — unwind rather
      # than abandon. Never journals volume-create-failed for this case.
      volume_unwind_untracked "could-not-parse-id"
      volume_state_write "volume_mounted=false"
      return 0
    fi
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume  created  (id=$vid name=$BURST_VOLUME_NAME size=${vsize}G)"
  fi

  # Requirement 6: single-attach safety. Hetzner volumes attach to one
  # server at a time; a volume some OTHER live server holds is never
  # attached here — this box boots without it (root disk) rather than
  # racing/stealing it.
  if [ -n "$vserver" ] && [ "$vserver" != "$sid" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume  busy  (attached_to=$vserver id=$vid)"
    volume_state_write "volume_id=$vid" "volume_mounted=false"
    return 0
  fi

  if [ -z "$vserver" ]; then
    if ! "$HCLOUD" volume attach --server "$sid" "$vid" >/dev/null 2>&1; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-attach-failed  (id=$vid server_id=$sid — booting on root disk)"
      volume_state_write "volume_id=$vid" "volume_mounted=false"
      return 0
    fi
  fi

  # Requirement 2 (teardown-order counterpart): a volume left dirty by a
  # prior detach failure gets an fsck before this mount, exactly once.
  if [ "$(volume_state_read volume_dirty)" = "true" ]; then
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
      "fsck -y '$vdevice' >/dev/null 2>&1; true # volume-fsck" >/dev/null 2>&1 || true
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume  fsck  (id=$vid device=$vdevice cause=prior-detach-failed)"
  fi

  # Requirement 1: format only when the volume has no filesystem (a label
  # check on the box itself, not an hcloud-API property) — one combined root
  # ssh round trip, mirroring box_bootstrap's own style. Mounts AT
  # $REMOTE_ROOT (never renames it) so every existing remote_path_for()/
  # dirty-marker path is unaffected by whether a volume happens to be there.
  local mount_out mount_rc=0
  mount_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" "
# volume-mount
label=\$(blkid -s LABEL -o value '$vdevice' 2>/dev/null)
if [ -z \"\$label\" ]; then mkfs.ext4 -L $BURST_VOLUME_NAME '$vdevice' >/dev/null 2>&1 && echo FORMATTED; fi
mkdir -p '$REMOTE_ROOT'
mount '$vdevice' '$REMOTE_ROOT' 2>/dev/null || true
chown -R $REMOTE_USER:$REMOTE_USER '$REMOTE_ROOT'
echo MOUNTED
" 2>/dev/null)" || mount_rc=$?
  if [ "$mount_rc" -ne 0 ] || ! grep -q MOUNTED <<<"$mount_out"; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume-mount-failed  (id=$vid device=$vdevice — booting on root disk)"
    volume_state_write "volume_id=$vid" "volume_mounted=false"
    return 0
  fi

  local dfout used_gb size_gb pct
  dfout="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "df -BG --output=used,size,pcent '$REMOTE_ROOT' 2>/dev/null | tail -n1 # volume-df" 2>/dev/null)"
  used_gb="$(awk '{print $1}' <<<"$dfout" | tr -dc '0-9')"
  size_gb="$(awk '{print $2}' <<<"$dfout" | tr -dc '0-9')"
  pct="$(awk '{print $3}' <<<"$dfout" | tr -dc '0-9')"
  size_gb="${size_gb:-$vsize}"

  volume_state_write "volume_id=$vid" "volume_mounted=true" "volume_dirty=false" \
    "volume_size_gb=${size_gb:-$BURST_VOLUME_GB}" "volume_used_pct=${pct:-0}"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  volume  attached  (id=$vid size=${size_gb:-$BURST_VOLUME_GB}G used=${pct:-0}%)"
}

# ---- persistent volume teardown (requirement 2) ----------------------------
# Called from BOTH cmd_down's delete path and cmd_watchdog's teardown path,
# right before destroy_verify(id) — sync, unmount, detach, verify detached.
# Hetzner detaches a volume automatically on `server delete` regardless, so a
# detach failure here NEVER blocks the server delete that follows it (fail
# open on the teardown, same doctrine as volume_ensure on the way up) — it
# only marks volume_dirty=true so the NEXT up's mount runs fsck first.
volume_teardown() {  # $1=ip $2=caller(down|watchdog|idle-guard)
  local ip="$1" caller="$2"
  [ "$(volume_state_read volume_mounted)" = "true" ] || return 0
  local vid; vid="$(volume_state_read volume_id)"
  [ -n "$vid" ] || return 0

  # PRD-build-burst-teardown-lifecycle requirement 5/Technical
  # considerations: refresh volume_used_pct from a LIVE df probe before
  # unmounting — trusting whatever volume_ensure stamped at `up` time would
  # let a volume that filled up mid-session still read as cold. Reuses the
  # exact "# volume-df" remote command volume_status_probe already uses (and
  # the fake ssh fixture already answers), so this is the same live number
  # `status --json` would show right now, not a second, independently-wired
  # probe. Falls back to the last-stored reading if the probe fails (box
  # already unreachable) — never treated as a hard failure of teardown.
  local dfout used_pct
  dfout="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "df -BG --output=used,size,pcent '$REMOTE_ROOT' 2>/dev/null | tail -n1 # volume-df" 2>/dev/null)"
  used_pct="$(awk '{print $3}' <<<"$dfout" | tr -dc '0-9')"
  used_pct="${used_pct:-$(volume_state_read volume_used_pct)}"
  case "$used_pct" in ''|*[!0-9]*) used_pct=0 ;; esac
  volume_state_write "volume_used_pct=$used_pct"

  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "sync # volume-sync" >/dev/null 2>&1 || true
  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
    "umount '$REMOTE_ROOT' 2>/dev/null; true # volume-umount" >/dev/null 2>&1 || true

  if ! "$HCLOUD" volume detach "$vid" >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume  detach-failed  (id=$vid)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume  detach-failed  (id=$vid cause=still-attached server=$cserver)"
    volume_state_write "volume_dirty=true" "volume_mounted=false"
    return 0
  fi
  volume_state_write "volume_mounted=false" "volume_dirty=false"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume  detached  (id=$vid)"

  # Requirement 5: cold-volume policy. This lane runs exactly one session at
  # a time (SERVER_NAME is singular), so a teardown that reaches this point
  # — the box already destroy_verify-bound right after this call returns —
  # is BY CONSTRUCTION the teardown that ends the lane's activity; there is
  # no "another session still using this volume" case to check for. A
  # volume below BURST_VOLUME_KEEP_MIN_PCT used, or one that has never
  # served a single build across its whole life (volume_runs_served, set by
  # cmd_run — independent of used_pct, so a probe hiccup that reads 0% on a
  # genuinely-used volume still doesn't wrongly delete it if a real run is
  # on record), is deleted rather than left billing ~€38/mo idle; `up`
  # recreates one on demand, cheaper than the idle rent.
  local keep_min="${BURST_VOLUME_KEEP_MIN_PCT:-5}"
  local vruns; vruns="$(volume_state_read volume_runs_served)"
  case "$vruns" in ''|*[!0-9]*) vruns=0 ;; esac
  if [ "$used_pct" -lt "$keep_min" ] || [ "$vruns" -eq 0 ]; then
    if "$HCLOUD" volume delete "$vid" >/dev/null 2>&1; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume  deleted  (id=$vid used_pct=$used_pct runs_served=$vruns cause=cold-volume — recreate-on-next-up cheaper than idle ${BURST_VOLUME_GB}GB)"
      rm -f "$VOLUME_STATE_FILE"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume  delete-failed  (id=$vid used_pct=$used_pct)"
    fi
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  volume-kept  (used_pct=$used_pct)"
  fi
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
  dfout="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" \
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
gate_tools_probe() {  # $1=ip -> stdout: one "tool=version|MISSING" line per
  # tool, terminated by a $GATE_TOOLS_PROBE_SENTINEL line once the sweep
  # actually finishes; returns the ssh call's own exit status (via `return`,
  # not a global — this function is always invoked as `x="$(gate_tools_probe
  # ...)"`, which runs it in a subshell, so a plain global assignment inside
  # it would be lost the instant that subshell exits) so a caller can do
  # `probe_out="$(gate_tools_probe "$ip")"; rc=$?` and tell "ssh itself
  # failed" apart from "ssh succeeded but printed something unparseable"
  # (PRD-build-burst-probe-visibility requirement 1: the raw result — rc
  # included — must survive to be journaled, not just discarded like
  # before).
  # PRD-build-burst-unprivileged-user requirement 2: probing needs no root —
  # reading a tool's own --version never writes anything — so this runs as
  # $REMOTE_USER like everything but the requirement-3 allow-list.
  #
  # PRD-build-burst-path-deps requirement 4: for the BUILD user, this PATH
  # carries no root fallback at all — a tool a human hand-installed under
  # /root (the exact 2026-09-11 07:48Z incident: gate_ready=true while
  # `claude` was MISSING for build, because this probe's PATH could still
  # see /root/.local/bin) must read MISSING here, not silently pass. The
  # ROOT rollback (REMOTE_USER=root) keeps its fallback: root-installed
  # curl tools (uv, claude) land in plain /root/.local/bin, not
  # $ROOT_CARGO_HOME/bin, so root's own probe still needs both listed.
  local gt_probe_extra=""
  [ "$REMOTE_USER" = "root" ] && gt_probe_extra=":$ROOT_CARGO_HOME/bin:/root/.local/bin"
  local gt_out gt_rc=0
  gt_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$1" "
# gate-tools-probe
# PRD-build-burst-gate-tools-scope requirement 1: a non-login ssh shell's
# PATH lacks the cargo-installed tools/uv/claude dirs, so a correctly-
# installed tool read back MISSING without this export — the exact box
# 165449166 failure mode. PRD-build-burst-unprivileged-user: build's own
# \$GATE_TOOLS_REMOTE_BIN_DIR comes first — that is where cargo-deny/
# cargo-nextest/uv/claude/autobuilder actually land for build (requirement
# 2).
export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH$gt_probe_extra
for t in $GATE_TOOLS_LIST; do
  if command -v \"\$t\" >/dev/null 2>&1; then
    # PRD-build-burst-probe-visibility requirement 7: bound per-tool so one
    # hanging binary can't stall (and truncate) the whole sweep.
    v=\"\$(timeout $GATE_TOOLS_PROBE_TIMEOUT_S \"\$t\" --version 2>/dev/null | head -n1)\"
    printf '%s=%s\n' \"\$t\" \"\${v:-unknown}\"
  else
    printf '%s=MISSING\n' \"\$t\"
  fi
done
printf '%s\n' '$GATE_TOOLS_PROBE_SENTINEL'" 2>/dev/null)" || gt_rc=$?
  printf '%s' "$gt_out"
  return "$gt_rc"
}

# PRD-build-burst-probe-visibility requirement 1/7: parses one probe's raw
# stdout (from gate_tools_probe) into a normalized tool->value lookup
# (populated into the caller's associative array via nameref — bash has no
# other clean way to hand back a map), journaling the raw record and any
# anomaly found along the way. Never fatal — a totally empty/garbled probe
# still returns (with an empty lookup), the anomaly itself IS the signal.
#   $1 = phase ("pre" or "final")
#   $2 = raw probe stdout (possibly empty)
#   $3 = probe rc (ssh's own exit status, from _GT_PROBE_RC)
#   $4 = name of caller's associative array to populate (cleared first)
gate_tools_parse_probe() {
  local phase="$1" raw="$2" rc="$3"
  local -n _gt_map="$4"
  _gt_map=()
  local line name val seen_sentinel=0 tools_seen=0 tools_str=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    if [ "$line" = "$GATE_TOOLS_PROBE_SENTINEL" ]; then
      seen_sentinel=1
      continue
    fi
    case "$line" in *=*) ;; *) continue ;; esac
    name="${line%%=*}"
    val="${line#*=}"
    val="${val%$'\r'}"
    _gt_map["$name"]="$val"
    tools_seen=$((tools_seen + 1))
    # requirement 1: "values containing whitespace are collapsed" in the
    # journal record — the lookup above keeps the raw value, only the
    # journaled string is normalized.
    tools_str+="${tools_str:+ }$name=$(_gt_collapse_ws "$val")"
  done <<<"$raw"

  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  probe  (phase=$phase user=$REMOTE_USER rc=$rc tools=\"$tools_str\")"

  # requirement 6/AC6: a probe that failed outright (nonzero ssh rc) or came
  # back with zero parseable tool= lines is "unparseable" — distinguishable
  # from a genuinely-measured empty result, never silently read as one.
  if [ "$rc" != "0" ] || [ "$tools_seen" -eq 0 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  probe-unparseable  (phase=$phase rc=$rc)"
  fi

  # requirement 7/AC9: no sentinel means the stream was cut off before the
  # sweep finished — every tool NOT already in the map (unseen) must be
  # treated as MISSING, never as present; the caller's lookup already does
  # that for free (a tool absent from _gt_map reads MISSING via the
  # probe-absent fail-safe), this just makes the truncation itself visible.
  if [ "$seen_sentinel" != "1" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  probe-truncated  (phase=$phase tools_seen=$tools_seen expected=$(set -- $GATE_TOOLS_LIST; echo $#))"
  fi
}

# requirement 1: collapses embedded whitespace/CR in a probe value down to
# single spaces and trims the ends, so a multi-word `--version` reply (or
# one padded with a stray tab/CR) never breaks the single-line probe record.
_gt_collapse_ws() {  # $1=value -> stdout
  local v="${1//$'\t'/ }"
  v="${v//$'\r'/}"
  # shellcheck disable=SC2086 — deliberate word-splitting collapse+trim
  echo $v
}

# requirement 5/AC5: effective presence of a tool in a parsed probe map —
# a tool the probe never reported reads as MISSING (same fail-safe the
# install loop uses), so disagreement comparison never has to special-case
# "absent" separately from "reported MISSING".
_gt_effective_status() {  # $1=arrayname $2=tool -> stdout
  local -n _gt_arr="$1"
  local tool="$2"
  if [ "${_gt_arr[$tool]+set}" = "set" ]; then
    printf '%s' "${_gt_arr[$tool]}"
  else
    printf '%s' "MISSING"
  fi
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
      # PRD-build-burst-provision-forensics requirement 5: apt lock
      # tolerance — a transient dpkg/apt lock (e.g. an orphaned provision's
      # own apt-update, the exact 2026-09-13 collision) waits up to 120s
      # instead of failing instantly.
      printf '%s\napt-get install -y -qq -o DPkg::Lock::Timeout=120 jq\n' "# gate-tools-install $tool" ;;
    gh)
      # Adds its own apt source right before installing, so its second
      # `apt-get update -qq` here is necessary (the shared pre-update ran
      # before this source existed), not a duplicate of requirement 3.
      printf '%s\n%s\n' "# gate-tools-install $tool" \
        "(curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && apt-get update -qq -o DPkg::Lock::Timeout=120 && apt-get install -y -qq -o DPkg::Lock::Timeout=120 gh)" ;;
    mold)
      printf '%s\napt-get install -y -qq -o DPkg::Lock::Timeout=120 mold\n' "# gate-tools-install $tool" ;;
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
      # RUSTUP_HOME (requirement 2) points `rustup` at root's shared
      # toolchain, read-only, regardless of who's running this; PATH still
      # carries $ROOT_CARGO_HOME/bin so the `cargo`/`rustup` BINARIES
      # resolve (they live there, installed once by root). CARGO_HOME
      # (PRD-build-burst-path-deps requirement 5) is now $RUN_CARGO_HOME —
      # build's OWN registry/git cache, never root's read-only one — because
      # `cargo install` (like any dependency fetch) WRITES into whatever
      # CARGO_HOME resolves to, and root's copy only grants read+execute;
      # `--root` (see above) is a separate matter — it only redirects the
      # installed BINARY's final destination, not the registry cache cargo
      # uses to get there.
      printf '%s\nexport PATH=$PATH:%s/bin RUSTUP_HOME=%s CARGO_HOME=%s; %s; if [ -n "$tc" ]; then cargo +"$tc" install --locked --root %s cargo-deny@%s; else cargo install --locked --root %s cargo-deny@%s; fi\n' \
        "# gate-tools-install $tool" "$ROOT_CARGO_HOME" "$ROOT_RUSTUP_HOME" "$RUN_CARGO_HOME" "$_gate_tools_cargo_toolchain_pick" "$install_root" "$GATE_TOOLS_CARGO_DENY_VERSION" "$install_root" "$GATE_TOOLS_CARGO_DENY_VERSION" ;;
    cargo-nextest)
      printf '%s\nexport PATH=$PATH:%s/bin RUSTUP_HOME=%s CARGO_HOME=%s; %s; if [ -n "$tc" ]; then cargo +"$tc" install --locked --root %s cargo-nextest@%s; else cargo install --locked --root %s cargo-nextest@%s; fi\n' \
        "# gate-tools-install $tool" "$ROOT_CARGO_HOME" "$ROOT_RUSTUP_HOME" "$RUN_CARGO_HOME" "$_gate_tools_cargo_toolchain_pick" "$install_root" "$GATE_TOOLS_CARGO_NEXTEST_VERSION" "$install_root" "$GATE_TOOLS_CARGO_NEXTEST_VERSION" ;;
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
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" "mkdir -p '$dst'" 2>/dev/null || true
    "$RSYNC_BIN" -az --delete -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
      "$src/" "$REMOTE_USER@$ip:$dst/" >/dev/null 2>&1 || true
    # Files only (never -R on the dirs themselves) — a directory stripped of
    # its own write bit can no longer have entries added/removed inside it,
    # which broke both a later re-sync (rsync --delete needs to unlink stale
    # files) and this selftest's own tmpdir cleanup (rm -rf) the first time
    # this shipped with a blanket `chmod -R a-w`.
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" "find '$dst' -type f -exec chmod a-w {} +" 2>/dev/null || true
  done
}

# Sets GATE_READY (true/false) and GATE_TOOLS_MISSING (comma-joined tool
# names, empty when none) on return; writes the full probe result to
# $GATE_TOOLS_STATE_FILE for `verify`'s gate-tools check to read back.
# Never fatal — a total probe failure (ssh unreachable etc.) records every
# tool MISSING rather than crashing `up`.
GATE_READY="false"
GATE_TOOLS_MISSING=""
# PRD-build-burst-provision-forensics requirement 3: space-joined
# "tool=rc" for every GATE_TOOLS_LIST member, set at the end of every
# provision_gate_tools call.
GATE_TOOLS_RC_SUMMARY=""
provision_gate_tools() {  # $1=ip
  local ip="$1" probe_out name ver
  mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true

  probe_out="$(gate_tools_probe "$ip")"
  local pre_probe_rc=$?
  # PRD-build-burst-probe-visibility requirement 1/2: journal the raw
  # pre-install probe and parse it into a lookup the loop below consults —
  # it no longer iterates the probe's own output (a tool the probe omits or
  # misreports used to be skipped in total silence; see requirement 2).
  local -A _gt_pre
  gate_tools_parse_probe "pre" "$probe_out" "$pre_probe_rc" _gt_pre

  # requirement 3: apt-get update runs at most ONCE per provision, before
  # the first apt-based install, and gets its own journal record either
  # way — "ran=false" (no apt tool was missing) reads as deliberately
  # skipped, not silently forgotten, the same ambiguity requirement 2
  # exists to kill for individual tool installs. Driven from GATE_TOOLS_LIST
  # (not the probe's own output) so a tool the probe omitted — fail-safe
  # MISSING per requirement 2 — still counts toward this decision.
  local need_apt_update=0
  for name in $GATE_TOOLS_LIST; do
    ver="$(_gt_effective_status _gt_pre "$name")"
    [ "$ver" = "MISSING" ] && gate_tools_is_apt "$name" && need_apt_update=1
  done
  if [ "$need_apt_update" = "1" ]; then
    local apt_log="$BOX_STATE_DIR/logs/gate-tools-apt-update.$$.log" apt_rc=0
    # Requirement 3: apt-get is root's job, never build's — hardcoded root@,
    # not $REMOTE_USER@, regardless of which user the rest of this function
    # routes to.
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
      "$(printf '%s\napt-get update -qq -o DPkg::Lock::Timeout=120\n' "# gate-tools-apt-update")" >"$apt_log" 2>&1 || apt_rc=$?
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  apt-update  (ran=true rc=$apt_rc)"
    rm -f "$apt_log" 2>/dev/null || true
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  apt-update  (ran=false)"
  fi

  # PRD-build-burst-provision-forensics requirement 1: an EXIT/signal trap
  # scoped to exactly this loop, so a process death mid-tool (nounset
  # exit, `kill`) still names the in-flight tool instead of leaving the
  # journal's last line silently pointing at whichever tool journaled
  # before it (2026-09-13: the gh defect this whole PRD exists to expose).
  # Scoped per Technical considerations — installed right before the loop,
  # removed right after, so it can never fire on this function's own
  # early-return-free body nor on cmd_provision's pre-loop early returns.
  _GT_CURRENT_TOOL=""
  _gt_provision_abort_trap() {
    local trap_rc=$?
    # Disarm before doing anything else: this same handler is bound to
    # TERM/INT/HUP too, and the whole point of a TERM/INT trap firing is
    # that the signal must still actually terminate the process (an
    # untrapped default kill does; a trapped one that never re-exits would
    # silently turn `kill <pid>` into a no-op) — the `exit` below is what
    # makes that true, and disarming first stops that same `exit` from
    # re-entering this handler via its own EXIT trap.
    trap - EXIT TERM INT HUP
    if [ -n "$_GT_CURRENT_TOOL" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  provision-aborted  (during=$_GT_CURRENT_TOOL rc=$trap_rc)"
    fi
    exit "$trap_rc"
  }
  trap _gt_provision_abort_trap EXIT TERM INT HUP

  # requirement 2: session_id keys the failure-log dir; requirement 3:
  # per-tool rc for every tool in GATE_TOOLS_LIST (not just attempted
  # ones — an already-present tool reads rc=0, never attempted).
  local session_id; session_id="$(state_read server_id 2>/dev/null)"
  [ -n "$session_id" ] || session_id="nosession"
  mkdir -p "$GATE_TOOLS_FAILED_LOG_DIR" 2>/dev/null || true
  local -A _gt_rc
  local t attempts_blob=""
  # requirement 4/AC4: "na" (never a numeric exit code) means "never
  # attempted" — the pre-PRD seed of 0 here is exactly what made
  # per_tool_rc="...=0" for six tools that never ran read as six clean
  # successes on the real 2026-09-13 08:46Z run.
  for t in $GATE_TOOLS_LIST; do _gt_rc["$t"]="na"; done

  # requirement 2: iterate GATE_TOOLS_LIST itself, not the probe's own
  # output — a tool the probe never reported is looked up as MISSING
  # (fail-safe: attempt the install) rather than silently falling out of
  # the loop the way `<<<"$probe_out"` used to.
  for name in $GATE_TOOLS_LIST; do
    if [ "${_gt_pre[$name]+set}" = "set" ]; then
      ver="${_gt_pre[$name]}"
    else
      ver="MISSING"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  probe-absent  (tool=$name)"
    fi
    if [ "$ver" != "MISSING" ]; then
      # requirement 3: an explicit terminal record for the "present,
      # nothing to do" outcome — silence was never a valid outcome for a
      # listed tool.
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  install-skipped  (tool=$name reason=present version=\"$(_gt_collapse_ws "$ver")\")"
      continue
    fi
    local start_ts rc secs err_log err_line
    start_ts="$(now_epoch)"
    err_log="$BOX_STATE_DIR/logs/gate-tools-install.$$-$name.log"
    rc=0
    _GT_CURRENT_TOOL="$name"
    # PRD-build-burst-dispatch-reenable requirement 2: a baked image is
    # supposed to need zero installs — any tool still missing on a baked
    # boot means the bake is out of date with respect to GATE_TOOLS_LIST,
    # worth flagging distinctly from an ordinary (unbaked) first-boot
    # install. Installation proceeds exactly as it does today either way.
    if [ "${CURRENT_BOOT_IMAGE_SOURCE:-}" = "baked" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  bake-stale  (tool=$name)"
    fi
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  install-start  (tool=$name)"
    if [ "$name" = "autobuilder" ]; then
      if [ -f "$GATE_TOOLS_AUTOBUILDER_BIN" ]; then
        "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
          "$(printf '%s\nmkdir -p '"'"'%s'"'"'\n' "# gate-tools-install autobuilder" "$GATE_TOOLS_REMOTE_BIN_DIR")" >/dev/null 2>&1 || true
        "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
          "$GATE_TOOLS_AUTOBUILDER_BIN" "$REMOTE_USER@$ip:$GATE_TOOLS_REMOTE_BIN_DIR/autobuilder" >"$err_log" 2>&1 || rc=$?
        "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
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
      "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$install_user@$ip" "$(gate_tools_install_cmd "$name")" >"$err_log" 2>&1 || rc=$?
    fi
    secs="$(( $(now_epoch) - start_ts ))"
    err_line=""
    if [ "$rc" = "0" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  install  (tool=$name rc=0 secs=$secs)"
      rm -f "$err_log" 2>/dev/null || true
    else
      # requirement 1: FIRST non-blank stderr line (apt's/cargo's actual
      # cause usually leads; the LAST line is often just a generic
      # "command failed" wrapper) — this is a deliberate change from the
      # pre-PRD `tail -n1` behavior.
      err_line="$(grep -v '^[[:space:]]*$' "$err_log" 2>/dev/null | head -n1)"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  install-failed  (tool=$name rc=$rc secs=$secs err=\"$err_line\")"
      # requirement 2: evidence retention — survives under logs/failed/,
      # deleted only on the rc=0 path above.
      cp -f "$err_log" "$GATE_TOOLS_FAILED_LOG_DIR/${session_id}-${name}.log" 2>/dev/null || true
      rm -f "$err_log" 2>/dev/null || true
      printf '%s\n' "$session_id" >> "$GATE_TOOLS_FAILED_SESSIONS_LOG" 2>/dev/null || true
    fi
    _gt_rc["$name"]="$rc"
    attempts_blob+="$name"$'\t'"$rc"$'\t'"$err_line"$'\n'
    _GT_CURRENT_TOOL=""
  done

  # Loop finished normally — disarm the abort trap before any further code
  # in this function (or cmd_provision after it returns) can misattribute
  # an unrelated later failure to whatever tool ran last.
  trap - EXIT TERM INT HUP
  prune_failed_gate_tool_logs

  # requirement 3: the final summary — per-tool rc for all 8, printed by
  # cmd_provision below and journaled here so it survives even a `provision`
  # invocation whose caller never captured stdout.
  local gt_summary=""
  for t in $GATE_TOOLS_LIST; do gt_summary+="${gt_summary:+ }$t=${_gt_rc[$t]}"; done
  GATE_TOOLS_RC_SUMMARY="$gt_summary"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  summary  (per_tool_rc=\"$gt_summary\")"

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
  local final_probe_rc=$?
  # requirement 1/6: journal the final probe's raw result the same way the
  # pre-install one was, and parse it into a lookup for the disagreement
  # check below — additive to (never replacing) the existing python
  # tools/missing/gate_tool_versions state-file write just below, which
  # keeps its own independent parse of $final_out on purpose (Migration/
  # compatibility: no existing reader of that JSON shape changes shape).
  local -A _gt_final
  gate_tools_parse_probe "final" "$final_out" "$final_probe_rc" _gt_final
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  version-drift  (tool=autobuilder local=\"$dl\" remote=\"$dr\")"
  fi
  if [ -z "$GATE_TOOLS_MISSING" ]; then GATE_READY="true"; else GATE_READY="false"; fi

  # requirement 5/AC5: the pre-install and final probes disagreeing on
  # whether a tool is present is the exact contradiction observed on
  # 2026-09-13 (six tools present pre-install, missing post-install) and
  # must alarm rather than pass quietly. Excludes the one EXPECTED
  # transition — a tool this run found MISSING and then installed
  # successfully (rc=0) — since seeing that tool present at the final probe
  # is the whole point of provisioning, not an anomaly.
  for t in $GATE_TOOLS_LIST; do
    local _gt_pre_eff _gt_final_eff
    _gt_pre_eff="$(_gt_effective_status _gt_pre "$t")"
    _gt_final_eff="$(_gt_effective_status _gt_final "$t")"
    local _gt_pre_missing=0 _gt_final_missing=0
    [ "$_gt_pre_eff" = "MISSING" ] && _gt_pre_missing=1
    [ "$_gt_final_eff" = "MISSING" ] && _gt_final_missing=1
    if [ "$_gt_pre_missing" != "$_gt_final_missing" ]; then
      if [ "$_gt_pre_missing" = "1" ] && [ "${_gt_rc[$t]:-na}" = "0" ]; then
        continue  # expected: was missing, we installed it, now present
      fi
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate-tools  probe-disagreement  (tool=$t pre=\"$(_gt_collapse_ws "$_gt_pre_eff")\" final=\"$(_gt_collapse_ws "$_gt_final_eff")\")"
    fi
  done

  # requirement 3: gate-tools.json records last_rc/last_err per attempted
  # tool. Merged in AFTER the tools/missing/gate_tool_versions write above
  # (never inline with it) so existing readers of that shape are
  # untouched — this only adds an "attempts" key, tolerated by any
  # jq-based reader per the Migration/compatibility note. base64-encoded
  # because an install's first stderr line can carry quotes/tabs/unicode
  # that would otherwise have to survive three more shell-quoting layers.
  if [ -n "$attempts_blob" ]; then
    local attempts_b64
    attempts_b64="$(printf '%s' "$attempts_blob" | base64 | tr -d '\n')"
    python3 -c '
import base64, json, sys
path, b64 = sys.argv[1], sys.argv[2]
data = base64.b64decode(b64).decode("utf-8", "replace")
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    doc = {}
attempts = doc.get("attempts", {})
for line in data.splitlines():
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    tool, rc = parts[0], parts[1]
    err = parts[2] if len(parts) > 2 else ""
    try:
        rc = int(rc)
    except ValueError:
        rc = None
    attempts[tool] = {"last_rc": rc, "last_err": err}
doc["attempts"] = attempts
with open(path, "w") as f:
    json.dump(doc, f)
' "$GATE_TOOLS_STATE_FILE" "$attempts_b64" 2>/dev/null || true
  fi
}

# requirement 2: prune logs/failed/ to the newest
# GATE_TOOLS_FAILED_LOG_RETAIN_SESSIONS sessions. Keyed off the append-only
# sessions ledger (never off parsing session_id back out of a filename —
# cargo-deny/cargo-nextest already contain a hyphen, so "<session_id>-
# <tool>.log" is not reliably reversible). Distinct sessions are kept in
# first-seen (== chronological, since a session only ever appends while
# it's the current provision) order; the oldest beyond the retain count
# are dropped along with every failed-tool log under their session_id.
prune_failed_gate_tool_logs() {
  [ -f "$GATE_TOOLS_FAILED_SESSIONS_LOG" ] || return 0
  local -a sessions=()
  local line seen_sep seen
  seen_sep=$'\x1e'
  seen="$seen_sep"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$seen" in *"$seen_sep$line$seen_sep"*) continue ;; esac
    sessions+=("$line")
    seen+="$line$seen_sep"
  done < "$GATE_TOOLS_FAILED_SESSIONS_LOG"
  local total="${#sessions[@]}"
  local retain="${GATE_TOOLS_FAILED_LOG_RETAIN_SESSIONS:-5}"
  [ "$total" -gt "$retain" ] || return 0
  local drop_count=$((total - retain))
  local i sid
  for ((i = 0; i < drop_count; i++)); do
    sid="${sessions[$i]}"
    [ -n "$sid" ] || continue
    rm -f "$GATE_TOOLS_FAILED_LOG_DIR/${sid}-"*.log 2>/dev/null || true
  done
  # Rewrite the ledger to just the retained sessions (deduped) so it never
  # grows unbounded across the life of this state dir.
  local tmp="$GATE_TOOLS_FAILED_SESSIONS_LOG.tmp.$$"
  : > "$tmp"
  for ((i = drop_count; i < total; i++)); do
    printf '%s\n' "${sessions[$i]}" >> "$tmp"
  done
  mv -f "$tmp" "$GATE_TOOLS_FAILED_SESSIONS_LOG"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  cred-absent  (BURST_GATE_REVIEWER=1 but no credential file at $GATE_CRED_SRC — reviewer will not run)"
    return 0
  fi
  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "mkdir -p '$(dirname "$GATE_CRED_REMOTE_PATH")'" >/dev/null 2>&1 || true
  if "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
       "$GATE_CRED_SRC" "$REMOTE_USER@$ip:$GATE_CRED_REMOTE_PATH" >/dev/null 2>&1; then
    "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "chmod 600 '$GATE_CRED_REMOTE_PATH'" >/dev/null 2>&1 || true
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  cred  placed  (host=$ip)"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  cred-place-failed  (host=$ip — rsync push failed, reviewer will not run)"
  fi
}

shred_gate_credential() {  # $1=ip $2=caller(down|watchdog)
  local ip="${1:-}" caller="${2:-down}"
  [ -n "$ip" ] || return 0
  if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
       "shred -u -f '$GATE_CRED_REMOTE_PATH'" >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  cred  shredded  (host=$ip)"
  fi
}

# ---- image resolution / status extras (PRD-build-burst-dispatch-reenable) -
# requirement 2: the exact three-tier precedence `up`'s create path and
# `status`'s "which image would the lane boot next" both need — factored
# out so the two never drift apart.
resolve_boot_image() {  # stdout: "<image_id> <image_source(baked|env|default)>"
  local image_id=""
  if [ -f "$SNAPSHOT_STATE_FILE" ]; then
    image_id="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("image_id", ""))
' "$SNAPSHOT_STATE_FILE" 2>/dev/null)"
  fi
  if [ -n "$image_id" ]; then
    printf '%s baked\n' "$image_id"
  elif [ "${SNAPSHOT_ID_FROM_ENV:-0}" = "1" ]; then
    printf '%s env\n' "$SNAPSHOT_ID"
  else
    printf '%s default\n' "$SNAPSHOT_ID"
  fi
}

# requirement 6: the session-INDEPENDENT fields `status` (text and --json)
# always reports — image_id/image_source (what `up` would boot right now,
# via resolve_boot_image above), bake_age_h (hours since snapshot.json's
# own `created`, null if never baked), proof_age_h/proof_routed (same idea
# from proof.json, requirement 3's own receipt — null until `prove` has
# ever run), and enabled (does the systemd drop-in `enable` writes exist
# right now). Every one of these persists whether or not a session is
# currently up, so this is called from ALL FOUR of cmd_status's exit
# points below, not just the active-session one.
status_extra_fields_json() {  # stdout: one JSON object (never fails/exits)
  local img_id img_source
  read -r img_id img_source <<<"$(resolve_boot_image)"
  # R8: canary=<pass|diverged|missing>@<age_h>h head=<sha7>, read via the
  # same canary_read_status() the R6 gates use -- one definition of "the
  # box's canary state" for both gating and display.
  local canary_raw; canary_raw="$(canary_read_status "$(state_read server_id)")"
  python3 -c '
import calendar, glob, json, os, sys, time

img_id, img_source, snap_path, proof_path, dropin_path, logs_dir = sys.argv[1:7]

def age_h(iso):
    try:
        t = time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
        epoch = calendar.timegm(t)
        return round((time.time() - epoch) / 3600.0, 2)
    except Exception:
        return None

bake_age_h = None
try:
    snap = json.load(open(snap_path))
    bake_age_h = age_h(snap.get("created", ""))
except Exception:
    pass

proof_age_h = None
proof_routed = None
# PRD-build-burst-prove-forensics requirement 6: `prove_last` reads the
# newest proof.json (routed/cause/step/exit_code/line — requirement 1s own
# migration-note additions) plus, when a step is named, the matching
# prove.<epoch>.<step>.log this same run wrote (requirement 2) — so the
# tick/operator read the forensics from the last prove run without opening the
# state dir by hand. Absent/malformed proof.json (never proved) leaves
# prove_last null, same as proof_age_h/proof_routed above.
prove_last = None
try:
    proof = json.load(open(proof_path))
    proof_age_h = age_h(proof.get("ts", ""))
    proof_routed = proof.get("routed")
    step = proof.get("step") or None
    cause = proof.get("cause")
    if proof_routed is True:
        outcome = "done"
    elif isinstance(cause, str) and cause.endswith("-aborted"):
        outcome = "aborted"
    else:
        outcome = "failed"
    log_path = None
    if step:
        cands = glob.glob(os.path.join(logs_dir, "prove.*.%s.log" % step))
        cands = [c for c in cands if os.path.isfile(c)]
        if cands:
            log_path = max(cands, key=os.path.getmtime)
    prove_last = {
        "ts": proof.get("ts"),
        "outcome": outcome,
        "step": step,
        "cause": cause,
        "line": proof.get("line"),
        "log": log_path,
    }
except Exception:
    pass

enabled = os.path.isfile(dropin_path)

# PRD-build-burst-prove-evidence-preservation requirement 4: session-
# independent, straight off disk (evidence_status_json), same as every
# other field above — merged in here rather than via status_json_with_extras
# so text mode (status_extra_fields_line) gets it from this one JSON object
# too, not a second script invocation.
evidence = json.loads(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else {"count": 0, "bytes": 0, "newest_ts": None}

# R8: canary_raw is "<verdict> <age_h> <head7> <ts>" from canary_read_status
# (bash side, sys.argv[8]) -- "missing 0 ------- -" when no canary.json
# exists yet for this server_id (the Migration section documents this state).
canary_parts = (sys.argv[8].split() if len(sys.argv) > 8 else ["missing", "0", "-------", "-"])
canary_parts += ["missing", "0", "-------", "-"][len(canary_parts):]
canary_verdict, canary_age_raw, canary_head, canary_ts = canary_parts[:4]
try:
    canary_age_h = float(canary_age_raw)
except Exception:
    canary_age_h = None
canary = {"verdict": canary_verdict, "age_h": canary_age_h, "head": canary_head,
          "ts": None if canary_ts == "-" else canary_ts}

print(json.dumps({
    "image_id": img_id,
    "image_source": img_source,
    "bake_age_h": bake_age_h,
    "proof_age_h": proof_age_h,
    "proof_routed": proof_routed,
    "enabled": enabled,
    "prove_last": prove_last,
    "evidence": evidence,
    "canary": canary,
}))
' "$img_id" "$img_source" "$SNAPSHOT_STATE_FILE" "$PROOF_STATE_FILE" "$SYSTEMD_DROPIN" "$BOX_STATE_DIR/logs" "$(evidence_status_json "$EVIDENCE_DIR")" "$canary_raw"
}

# Same fields, one text-mode summary line (requirement 6: "text and --json").
status_extra_fields_line() {  # stdout: one "image: ..." line -- requirement
  # 4 adds a second "evidence: ..." line right after it (own line, easier to
  # grep than packing byte counts onto the image: line).
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
def s(v):
    return "none" if v is None else v
# R8/AC8: canary=<pass|diverged|missing>@<age_h>h head=<sha7>, appended onto
# this same line 2 rather than a new line -- AC8 names "line 2" itself.
c = d.get("canary") or {"verdict": "missing", "age_h": None, "head": "-------"}
age_h = c.get("age_h")
age_str = ("%.1f" % age_h) if isinstance(age_h, (int, float)) and age_h >= 0 else "?"
print("image: id=%s source=%s bake_age_h=%s proof_age_h=%s proof_routed=%s enabled=%s canary=%s@%sh head=%s" % (
    s(d["image_id"]), s(d["image_source"]), s(d["bake_age_h"]), s(d["proof_age_h"]),
    s(d["proof_routed"]), str(d["enabled"]).lower(), c.get("verdict", "missing"), age_str,
    c.get("head", "-------")))
ev = d.get("evidence") or {"count": 0, "bytes": 0, "newest_ts": None}
gb = (ev.get("bytes") or 0) / 1e9
print("evidence: %s sets, %.2f GB, newest %s" % (ev.get("count", 0), gb, s(ev.get("newest_ts"))))
' "$(status_extra_fields_json)"
}

# requirement 6/12: merge status_extra_fields_json() into an existing JSON
# object string without hand-rolled string concatenation (every field above
# already came through json.dumps, so this is a pure, quote-safe merge).
status_json_with_extras() {  # $1 = base JSON object string -> stdout
  # PRD-build-burst-dispatch-reenable requirement 6: compact separators
  # (no space after ':'/',') to match this codebase's existing
  # `"active":true`-shaped substring-match convention (cmd_route_check and
  # others grep this exact shape) — json.dumps' default separators insert
  # a space and silently broke every one of those matches.
  python3 -c '
import json, sys
base = json.loads(sys.argv[1])
base.update(json.loads(sys.argv[2]))
print(json.dumps(base, separators=(",", ":")))
' "$1" "$(status_extra_fields_json)"
}

# ---- bake (PRD-build-burst-dispatch-reenable requirement 1) ---------------
# Turns a verified, healthy session into a new snapshot image so the next
# `up` boots ready without repeating box_bootstrap's per-tool installs. Never
# invoked automatically by this step (the `down` auto-bake trigger — AC15 —
# and `up`'s image resolution — requirement 2 — are separate, later steps of
# this PRD); this is the standalone, operator/tick-invoked command.
cmd_bake() {
  # PRD-build-burst-selftest-drift-and-bake-gate requirement 4: the same
  # burst_configured() predicate cmd_up/cmd_prove's own dormant-policy gate
  # uses (prove itself forces BUILD_BURST_ENABLED=1 for the duration of its
  # own run — its real gate is authz_refuse_if_missing below, not this one
  # — so an operator who just ran `prove` successfully never sees this
  # check fail; a bare `bake` in a shell that never exported the var does).
  # Unlike the OTHER refusals below in this function, this one used to be
  # silent to the journal — an operator (05:50Z, 2026-09-15) lost a minute
  # to a refusal that never named the key it needed to set.
  if ! burst_configured; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=not-configured key=BUILD_BURST_ENABLED)"
    echo "burst: refused — not configured (RedBaron-local policy); set BUILD_BURST_ENABLED=1 to allow" >&2
    exit 3
  fi
  # PRD-build-burst-state-keyed-by-server-v2 requirement 9: a bake is a
  # point-in-time image freeze — with more than one box up there is no
  # single answer to "which box's disk is this image", so refuse rather
  # than silently picking `current`.
  local bake_active_boxes; bake_active_boxes="$(count_active_boxes)"
  if [ "$bake_active_boxes" -gt 1 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=multi-box boxes=$bake_active_boxes)"
    echo "bake refused (cause=multi-box)" >&2
    exit 3
  fi
  authz_refuse_if_missing bake || exit 3
  if ! state_active; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=no-active-session)"
    echo "bake refused (cause=no-active-session)" >&2
    exit 3
  fi
  local ip id gate_ready sandbox_ok
  ip="$(state_read ip)"; id="$(state_read server_id)"
  gate_ready="$(state_read gate_ready)"
  sandbox_ok="$(state_read sandbox_ok)"
  if [ "$gate_ready" != "true" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=gate-not-ready server_id=$id)"
    echo "bake refused (cause=gate-not-ready)" >&2
    exit 3
  fi
  if [ "$sandbox_ok" != "true" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=sandbox-not-ok server_id=$id)"
    echo "bake refused (cause=sandbox-not-ok)" >&2
    exit 3
  fi
  # R6: a bake freezes this box's disk into the image every future `up`
  # boots from, so it requires a passing CACHED canary verdict (same
  # canary_gate_check the up/enable gates use — see its own header for why
  # this is a cached read, never a live cmd_canary call) before the
  # snapshot is taken. R6 gives bake one unsplit cause (`cause=canary`),
  # unlike enable's canary-missing/canary-diverged split.
  local bake_canary_verdict; read -r bake_canary_verdict _ <<<"$(canary_gate_check bake)"
  case "$bake_canary_verdict" in
    pass) : ;;
    *)
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=canary verdict=$bake_canary_verdict server_id=$id)"
      echo "bake refused (cause=canary verdict=$bake_canary_verdict)" >&2
      exit 3
      ;;
  esac
  # Refuse while a `run` is in flight — a bake is a point-in-time credential
  # shred + image freeze; racing a live run would either bake mid-write or
  # yank the credential out from under it. Non-blocking contention probe:
  # briefly try RUN_LOCK, release immediately either way (this is a refusal
  # check, not a hold — cmd_run still owns the real critical section).
  local bake_fd
  exec {bake_fd}>"$RUN_LOCK"
  if ! flock -n "$bake_fd"; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=run-in-flight server_id=$id)"
    echo "bake refused (cause=run-in-flight)" >&2
    exec {bake_fd}>&-
    exit 3
  fi
  flock -u "$bake_fd"
  exec {bake_fd}>&-

  local start_epoch; start_epoch="$(now_epoch)"

  # Credential must never be baked into the image (Technical considerations).
  shred_gate_credential "$ip" "bake"

  local prev_image_id=""
  if [ -f "$SNAPSHOT_STATE_FILE" ]; then
    prev_image_id="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("image_id", ""))
' "$SNAPSHOT_STATE_FILE" 2>/dev/null)"
  fi

  local build_skill_sha; build_skill_sha="$(git -C "$SKILL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local gate_tool_versions; gate_tool_versions="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(json.dumps(d.get("gate_tool_versions", {}), sort_keys=True))
' "$GATE_TOOLS_STATE_FILE" 2>/dev/null)"
  [ -n "$gate_tool_versions" ] || gate_tool_versions="{}"
  local n_tools; n_tools="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(len(d))' "$gate_tool_versions" 2>/dev/null || echo 0)"

  local created; created="$(now_iso)"
  local description="wm-burst-lane baked ${created%%T*} build-skill=$build_skill_sha tools=$n_tools"

  # 2026-09-14 real-box finding (PRD-build-burst-dispatch-reenable real-box
  # attempt): `server create-image` carries NO `--output`/`-o` flag at all
  # in this hcloud version (1.67.0) — unlike `describe`/`list`/`create` for
  # full resources, it never got one added, so `-o json` here fails at
  # flag-parse time ("unknown shorthand flag: 'o' in -o"), not at the API
  # call. Run it plain (human-readable stdout, discarded) and resolve the
  # new image the same way `up`'s adopt-by-name path already resolves
  # servers it didn't just create: list-and-match, here by this bake's own
  # uniquely ISO-timestamped `$description` via `image list -o json` (which
  # DOES support `-o`, confirmed against the real API), picking the
  # highest id on a (should-never-happen) duplicate description.
  local create_err; create_err="$(mktemp)"
  if ! "$HCLOUD" server create-image --type snapshot --description "$description" "$id" \
        >/dev/null 2>"$create_err"; then
    local emsg; emsg="$(tail -3 "$create_err" 2>/dev/null | tr '\n' ' ')"; rm -f "$create_err"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=hcloud-create-image-failed: $emsg)"
    echo "bake refused (cause=hcloud-create-image-failed: $emsg)" >&2
    exit 3
  fi
  rm -f "$create_err"

  local list_out; list_out="$("$HCLOUD" image list --type snapshot -o json 2>/dev/null)"
  local new_image_id status
  read -r new_image_id status <<<"$(python3 -c '
import json, sys
try:
    imgs = json.loads(sys.stdin.read())
except Exception:
    imgs = []
desc = sys.argv[1]
matches = [i for i in imgs if i.get("description") == desc]
matches.sort(key=lambda i: i.get("id", 0), reverse=True)
if matches:
    print(matches[0].get("id", ""), matches[0].get("status", ""))
else:
    print("", "")
' "$description" <<<"$list_out" 2>/dev/null)"
  if [ -z "${new_image_id:-}" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  refused  (cause=could-not-parse-image-id)"
    echo "bake refused (cause=could-not-parse-image-id)" >&2
    exit 3
  fi

  # Wait for the image to reach "available" (bounded — never hang a tick
  # forever). Some responses already report it available synchronously.
  local waits=0
  while [ "$status" != "available" ] && [ "$waits" -lt 60 ]; do
    status="$("$HCLOUD" image describe "$new_image_id" -o json 2>/dev/null | \
      python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
except Exception:
    d={}
print(d.get("image", d).get("status",""))' 2>/dev/null)"
    [ "$status" = "available" ] && break
    waits=$((waits + 1)); sleep 1
  done

  # Cap baked_history at two entries; a third bake supersedes (journals,
  # never deletes) the oldest.
  local prior_history superseded_id
  prior_history="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(json.dumps(d.get("baked_history", [])))
' "$SNAPSHOT_STATE_FILE" 2>/dev/null)"
  [ -n "$prior_history" ] || prior_history="[]"
  superseded_id="$(python3 -c '
import json, sys
hist = json.loads(sys.argv[1])
new_id = sys.argv[2]
hist.append(new_id)
superseded = ""
while len(hist) > 2:
    superseded = hist.pop(0)
print(superseded)
print(json.dumps(hist))
' "$prior_history" "$new_image_id" > "$STATE_DIR/.bake-history.tmp" 2>/dev/null; \
    head -n1 "$STATE_DIR/.bake-history.tmp" 2>/dev/null)"
  local new_history; new_history="$(tail -n1 "$STATE_DIR/.bake-history.tmp" 2>/dev/null || echo '[]')"
  rm -f "$STATE_DIR/.bake-history.tmp"

  python3 -c '
import json, sys
image_id, created, base_image_id, build_skill_sha, gate_tool_versions_json, history_json, out_path = sys.argv[1:8]
d = {
    "image_id": image_id,
    "created": created,
    "base_image_id": base_image_id,
    "build_skill_sha": build_skill_sha,
    "gate_tool_versions": json.loads(gate_tool_versions_json),
    "baked_history": json.loads(history_json),
}
json.dump(d, open(out_path, "w"), indent=2, sort_keys=True)
' "$new_image_id" "$created" "${SNAPSHOT_ID:-$DEFAULT_SNAPSHOT_ID}" "$build_skill_sha" \
    "$gate_tool_versions" "$new_history" "$SNAPSHOT_STATE_FILE"

  local secs=$(( $(now_epoch) - start_epoch ))
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  done  (image_id=$new_image_id superseded=${prev_image_id:-none} secs=$secs)$(authz_journal_suffix)"
  if [ -n "$superseded_id" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  bake  superseded  (image_id=$superseded_id delete=operator)"
  fi
  echo "bake done: image_id=$new_image_id"
  exit 0
}

# ---- prove (PRD-build-burst-dispatch-reenable requirement 3) --------------
# The one thing `bake`/`enable` alone never establish: that a box can carry
# a REAL cargo run and hand real artifacts back — the 2026-09-09 lesson was
# fourteen runs that looked routed in the journal and were not, so this
# never trusts cmd_run's own journal line alone. It independently re-derives
# each assertion (run's own exit code, the pull's own reported bytes, a
# fresh file on disk, and a remote `hostname` call distinct from this
# caller's own) and stops at the FIRST failing one. BUILD_BURST_ENABLED is
# forced on for this function's own call chain only (a `local -x`, gone the
# moment this function returns) — proving must work precisely when the lane
# is NOT yet opted in, since a proof is `enable`'s own prerequisite.
# Default worktree (Joe, 2026-09-13, decided in Open questions): a
# disposable `git worktree` of ~/wintermute/mcphost at its current HEAD, no
# PRD claimed — 11 of 21 queued PRDs are mcphost rust-extend, so this
# exercises more of the real path than any smaller crate would.
# `prove` always ends with `down` under the existing cost-safe rules
# (requirement 3's own text), success or failure alike.
#
# ---- prove forensics (PRD-build-burst-prove-forensics) --------------------
# On 2026-09-13 a real `prove` died silently between `up` returning and the
# first `run` line: no journal entry, no proof.json, no stderr kept anywhere
# (five-whys in visions/buildloop-operations.md). `cmd_prove` now runs its
# whole body under an EXIT trap so ANY exit — a `set -u` unbound-variable
# reference, an external signal, or an unguarded non-zero exit no `if`/`||`
# was watching — still leaves a receipt naming the step. Two bash quirks
# (verified by hand 2026-09-13/14) drove this shape:
#   1. A `set -u` kill does NOT fire the ERR trap, only EXIT — so `line`
#      (from ERR) is best-effort, honestly empty for that cause rather than
#      guessed.
#   2. bash unwinds a dying function's OWN `local` variables before an EXIT
#      trap set inside that function runs, when the death is a `set -u`
#      kill — a `local` read back from the trap comes back empty even
#      though it was assigned moments earlier. Everything the trap needs is
#      therefore a plain (non-local) `PROVE_*` global, updated as each step
#      starts, never `local` inside cmd_prove.
PROVE_STEP=""
PROVE_START_EPOCH=""
PROVE_WORKTREE=""
PROVE_DISPOSABLE_REPO=""
PROVE_CLEANUP_WORKTREE=""
PROVE_SHA="unknown"
PROVE_ID=""
PROVE_FINISHED=false
PROVE_ERR_LINE=""
PROVE_FAIL_TAIL=""
PROVE_COST_ID=""
PROVE_COST_MINUTES=0
PROVE_COST_EUR="0.0000"
# Requirement 11: cmd_run reads this (never `local`, same plain-global
# reasoning as every other PROVE_* above — cmd_run runs in a command-
# substitution subshell that inherits the parent's globals fine, but any
# `local` cmd_run itself sets would never be visible back in cmd_prove
# anyway) to know whether it should touch the remote clock-based marker at
# all — an ordinary (non-prove) run never does.
PROVE_ACTIVE=false
# Requirement 12: set only when the assert step's freshness check fails,
# holding a JSON object with local_target/files/newest_mtime/marker_mtime/
# remote_date/skew_s — merged into proof.json and rendered into the
# journal's failure line so a no-fresh-artifact verdict is explainable from
# the receipt alone. Empty on any other outcome.
PROVE_ASSERT_DIAG_JSON=""
# The local_target assert actually inspected (the cargo_target_dir_for
# override, or $worktree/target) — named in both the done and failed
# journal lines (AC14) once assert has resolved it; "none" if prove never
# reached assert.
PROVE_LOCAL_TARGET=""

# Requirement 2: capture a step's raw output to a KEPT (never rm -f'd) log
# file before its result is tested; `reap` prunes these after 14 days (see
# reap_prove_logs). prove_log_tail hands back a whitespace-collapsed,
# <=240-char rendering of the log's last 3 non-empty lines for a journal
# line — same forensics for a clean step failure as for an abort.
prove_step_log_path() {  # $1=step
  printf '%s' "$BOX_STATE_DIR/logs/prove.${PROVE_START_EPOCH}.$1.log"
}

prove_write_step_log() {  # $1=step $2=content
  mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
  printf '%s\n' "$2" > "$(prove_step_log_path "$1")" 2>/dev/null || true
}

prove_log_tail() {  # $1=step -> collapsed last 3 non-empty lines, <=240 chars
  local f; f="$(prove_step_log_path "$1")"
  [ -f "$f" ] || { printf ''; return 0; }
  local t; t="$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n3 | tr '\n' ' ')"
  t="$(printf '%s' "$t" | tr -s '[:space:]' ' ')"
  t="${t# }"; t="${t% }"
  printf '%s' "${t:0:240}"
}

# Requirement 11/12: where cmd_run stashes the box's own `date -u` (captured
# at run start, before cargo runs) for cmd_prove's assert step to read back
# — cmd_run runs in a command-substitution subshell, so a plain variable set
# there never survives back to cmd_prove; a file keyed by this same prove's
# PROVE_START_EPOCH does.
prove_remote_date_path() {
  printf '%s' "$BOX_STATE_DIR/logs/prove.${PROVE_START_EPOCH}.remote-date"
}

# Requirement 12: the assert step's own diagnosis, computed once when the
# freshness check fails so a no-fresh-artifact verdict is explainable from
# proof.json/the journal alone, without another box. $2 (the marker) is
# itself excluded from both the file count and "newest" scan — it is
# forensic metadata, never a build artifact. Prints one JSON object line;
# any read/parse failure degrades to nulls/empty rather than aborting
# prove's own assert step over a diagnostics bug.
prove_assert_diag_json() {  # $1=local_target $2=marker_path $3=remote_date_iso -> JSON object (one line)
  python3 -c '
import calendar, json, os, sys, time

local_target, marker, remote_date = sys.argv[1:4]

def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))

files = []
if os.path.isdir(local_target):
    for root, _dirs, names in os.walk(local_target):
        for n in names:
            if n == ".burst-run-marker":
                continue
            files.append(os.path.join(root, n))

newest_mtime = ""
if files:
    try:
        newest_mtime = iso(max(os.path.getmtime(f) for f in files))
    except OSError:
        newest_mtime = ""

marker_mtime = ""
if os.path.isfile(marker):
    try:
        marker_mtime = iso(os.path.getmtime(marker))
    except OSError:
        marker_mtime = ""

skew_s = None
if remote_date:
    try:
        remote_epoch = calendar.timegm(time.strptime(remote_date, "%Y-%m-%dT%H:%M:%SZ"))
        skew_s = int(remote_epoch - time.time())
    except Exception:
        skew_s = None

print(json.dumps({
    "local_target": local_target,
    "files": len(files),
    "newest_mtime": newest_mtime,
    "marker_mtime": marker_mtime,
    "remote_date": remote_date,
    "skew_s": skew_s,
}))
' "$1" "$2" "$3"
}

# Renders a prove_assert_diag_json object back into "k=v k=v ..." for a
# journal line — same field order every time, empty/null values render as
# the empty string rather than the literal "None"/"null".
prove_diag_tail() {  # $1=diag_json -> "local_target=... files=... newest_mtime=... marker_mtime=... remote_date=... skew_s=..."
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1]) if sys.argv[1] else {}
except Exception:
    d = {}
parts = []
for k in ("local_target", "files", "newest_mtime", "marker_mtime", "remote_date", "skew_s"):
    v = d.get(k)
    parts.append("{}={}".format(k, "" if v is None else v))
print(" ".join(parts))
' "$1"
}

# Requirement 5: prove's own `down` and cost line are always journaled by
# prove itself, not left for a caller to infer from `down`'s line — must run
# BEFORE `cmd_down`, while session state (server_id/create_epoch/boot_epoch)
# still exists (a successful teardown clears it). Reuses the same
# create_epoch/COST_PER_HOUR_EUR math `minutes_alive`/`teardown_and_delete`
# use (requirement 9) so this line never disagrees with the ledger row
# `down` writes.
prove_snapshot_cost() {
  PROVE_COST_ID="$(state_read server_id)"
  local base_epoch; base_epoch="$(session_create_epoch)"
  case "$base_epoch" in
    ''|*[!0-9]*) PROVE_COST_MINUTES=0 ;;
    *) PROVE_COST_MINUTES=$(( ($(now_epoch) - base_epoch) / 60 )) ;;
  esac
  PROVE_COST_EUR="$(awk -v m="$PROVE_COST_MINUTES" -v r="$(cost_rate_eur)" 'BEGIN{printf "%.4f", (m/60.0)*r}')"
}

prove_journal_cost() {  # $1=outcome (done|failed|aborted)
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  cost  (server_id=${PROVE_COST_ID:-none} eur=${PROVE_COST_EUR:-0.0000} minutes=${PROVE_COST_MINUTES:-0} outcome=$1)"
}

# Shared proof.json writer — the normal tail and the abort trap both call
# this so the schema (now with exit_code/step/line — Migration note: existing
# readers use only routed/ts and are unaffected) never drifts between paths.
prove_write_proof_json() {  # image_id server_id worktree sha routed bytes secs cause exit_code step line [assert_diag_json]
  python3 -c '
import json, sys
image_id, server_id, worktree, sha, routed, bytes_n, secs, cause, exit_code, step, line, out_path, ts, diag_json, authz = sys.argv[1:16]
d = {
    "ts": ts,
    "image_id": image_id,
    "server_id": server_id,
    "worktree": worktree,
    "sha": sha,
    "routed": routed == "true",
    "bytes": int(bytes_n or 0),
    "secs_remote": int(secs or 0),
    "cause": cause,
    "exit_code": int(exit_code) if exit_code != "" else None,
    "step": step,
    "line": int(line) if line.isdigit() else None,
}
# Requirement 12: merged in only when the assert step computed one (a
# no-fresh-artifact verdict) — local_target/files/newest_mtime/marker_mtime/
# remote_date/skew_s. Existing readers use only routed/ts and are
# unaffected by these extra keys.
if diag_json:
    try:
        d.update(json.loads(diag_json))
    except Exception:
        pass
# PRD-build-operator-authorization-contract requirement 5/AC7: the dispatch
# authorization string, when one was present, so a real spend is checkable
# from the receipt alone rather than trusting a journal line in isolation.
# Absent (no dispatch, or a human-run prove) -> field omitted, not null, so
# an existing reader checking only for presence is unaffected.
if authz:
    d["authz"] = authz
json.dump(d, open(out_path, "w"), indent=2, sort_keys=True)
' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "$PROOF_STATE_FILE" "$(now_iso)" "${12:-}" "${BURST_LANE_AUTHZ:-}"
}

# ---- evidence preservation (PRD-build-burst-prove-evidence-preservation) --
# A failed assert used to `reap` its own disposable worktree at exit, taking
# the pulled target, proof.json's own diagnosis, and the step logs with it —
# the exact evidence a `no-fresh-artifact` diagnosis needs was destroyed
# three times (2026-09-14/15, see the PRD problem statement) before anyone
# thought to point a run at a persistent `--worktree` by hand. This block
# gives every assert-step failure its own durable evidence set instead.

# Requirement 6: idempotent — creates the real (same-filesystem-as-target)
# storage dir and points $EVIDENCE_DIR at it via a symlink so every other
# reader in this file (reap/status/evidence-ls) only ever has to know the
# one conventional STATE_DIR-relative path. Never clobbers a real directory
# that might already be sitting at $EVIDENCE_DIR (pre-migration, or a test
# fixture that made it a plain dir on purpose) — evidence just accumulates
# there directly in that case, still correct, just not guaranteed to be a
# same-filesystem rename.
evidence_link_ensure() {
  mkdir -p "$EVIDENCE_ROOT" 2>/dev/null || true
  if [ -e "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ]; then
    return 0
  fi
  ln -sfn "$EVIDENCE_ROOT" "$EVIDENCE_DIR" 2>/dev/null || true
}

# Requirement 2: the exact freshness check `assert` ran, with paths expanded
# into the evidence dir's own copy of the target, `set -uo pipefail`, and an
# `echo verdict=$?` line so the operator's re-run reports the same 0/1 assert
# ac319ac's own fix depends on (find -L, ! -name marker, -newer, -print
# -quit piped to `grep -q .` — this must stay byte-for-byte the same
# invocation as the one in cmd_prove's assert step above, or a re-run could
# disagree with the verdict it's supposed to reproduce).
prove_write_expression_sh() {  # $1=evidence_dir $2=target-subdir-name
  local dir="$1" tgt="${2:-target}"
  cat > "$dir/expression.sh" <<EOF
#!/usr/bin/env bash
# Generated by burst-lane.sh prove (PRD-build-burst-prove-evidence-
# preservation requirement 2). Reproduces the exact freshness verdict
# assert saw on this evidence set's own preserved target/ — no box needed.
set -uo pipefail
find -L "$dir/$tgt" -type f ! -name '.burst-run-marker' -newer "$dir/$tgt/.burst-run-marker" -print -quit 2>/dev/null | grep -q .
echo "verdict=\$?"
EOF
  chmod +x "$dir/expression.sh" 2>/dev/null || true
}

# Requirement 1/5/6: preserves everything a `no-fresh-artifact` (or any
# other assert-step) diagnosis needs to be re-run offline. Called from
# cmd_prove's own normal failure tail (assert-step failures never abort —
# they fall through to the ordinary end-of-function proof.json write) AND
# from prove_exit_trap (defensive: an assert step that itself crashes/aborts
# mid-check). $1=cause $2=local_target $3=remote_marker_path (may not exist)
# $4=server_id $5=disposable(true/false — true means prove owns $local_target
# and it is about to be `git worktree remove --force`'d anyway, so a `mv` is
# safe; false means an operator supplied --worktree and keeps ownership of
# it, so this copies instead) $6=journal verb (evidence-preserved |
# evidence-kept, per requirement 5's exact wording for the --keep-worktree
# case) $7=extra "k=v" tokens appended verbatim to the journal line's parens
# (requirement 5 needs `reason=operator` there). Never fails prove itself —
# every step is best-effort.
prove_preserve_evidence() {
  local cause="$1" local_target="$2" remote_marker="$3" server_id="$4" disposable="$5" verb="${6:-evidence-preserved}" extra="${7:-}"
  evidence_link_ensure
  local ts; ts="$(date -u -d "@$(now_epoch)" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  local dir="$EVIDENCE_DIR/${ts}-${server_id:-unknown}"
  mkdir -p "$dir" 2>/dev/null || { echo "prove-evidence-mkdir-failed dir=$dir" >&2; return 1; }

  # Requirement 6: the local disk floor check runs BEFORE the move — a
  # breach trims the set to logs + proof.json + expression.sh (no target/)
  # rather than let a multi-GB `mv`/`cp` push RedBaron itself below the
  # floor `run`'s own pull-back guard exists to protect.
  local trimmed=false
  local free_gb; free_gb="$(local_disk_free_gb "$EVIDENCE_ROOT")"
  case "$free_gb" in
    ''|*[!0-9]*) : ;;
    *) [ "$free_gb" -lt "$BURST_LOCAL_DISK_FLOOR_GB" ] && trimmed=true ;;
  esac

  if [ "$trimmed" = true ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  evidence-trimmed  (reason=disk-floor dir=$dir free_gb=${free_gb:-unknown} floor_gb=$BURST_LOCAL_DISK_FLOOR_GB)"
  elif [ -d "$local_target" ]; then
    if [ "$disposable" = true ]; then
      mv "$local_target" "$dir/target" 2>/dev/null || cp -a "$local_target" "$dir/target" 2>/dev/null || true
    else
      cp -a "$local_target" "$dir/target" 2>/dev/null || true
    fi
  fi
  # Requirement 2/6: expression.sh is written REGARDLESS of whether target/
  # itself survived the disk-floor trim above — req 7/AC7 requires it
  # present even in the trimmed case (a stale-forever verdict against a
  # target/ that isn't there is still useful signal: "this evidence set was
  # trimmed, re-run prove for a fresh one"), so this is never conditioned on
  # `[ -d "$dir/target" ]`.
  prove_write_expression_sh "$dir" "target"

  # Step logs (requirement 1) — copy, never move, so prove's own
  # in-progress reads of these paths are unaffected.
  mkdir -p "$dir/logs" 2>/dev/null || true
  local f
  for f in "$BOX_STATE_DIR"/logs/prove."${PROVE_START_EPOCH:-0}".*.log; do
    [ -f "$f" ] && cp -p "$f" "$dir/logs/" 2>/dev/null
  done
  [ -f "$PROOF_STATE_FILE" ] && cp -p "$PROOF_STATE_FILE" "$dir/proof.json" 2>/dev/null
  local remote_date_f; remote_date_f="$(prove_remote_date_path)"
  [ -f "$remote_date_f" ] && cp -p "$remote_date_f" "$dir/remote-date" 2>/dev/null
  [ -f "$STATE_FILE" ] && cp -p "$STATE_FILE" "$dir/session.json" 2>/dev/null

  local bytes; bytes="$(du -sb "$dir" 2>/dev/null | cut -f1)"; bytes="${bytes:-0}"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  $verb  (dir=$dir cause=${cause:-none} bytes=$bytes trimmed=$trimmed${extra:+ $extra})"
  printf '%s' "$dir"
}

# Requirement 4: session-independent evidence roll-up read by both
# status_extra_fields_json (--json) and status_extra_fields_line (text) —
# {count, bytes, newest_ts}, computed straight off the evidence dirs on
# disk (never a cached counter) so it can never disagree with `reap` or
# `evidence ls`. Best-effort: an unreadable/missing evidence dir reads as
# {"count":0,"bytes":0,"newest_ts":null}, never a script failure.
evidence_status_json() {
  python3 -c '
import glob, json, os, sys, time
d = sys.argv[1]
dirs = [p for p in sorted(glob.glob(os.path.join(d, "*"))) if os.path.isdir(p)]
total = 0
newest_mtime = None
for p in dirs:
    for root, _dirs, names in os.walk(p):
        for n in names:
            fp = os.path.join(root, n)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    try:
        mt = os.path.getmtime(p)
    except OSError:
        continue
    if newest_mtime is None or mt > newest_mtime:
        newest_mtime = mt
newest_ts = None
if newest_mtime is not None:
    newest_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(newest_mtime))
print(json.dumps({"count": len(dirs), "bytes": total, "newest_ts": newest_ts}))
' "$1" 2>/dev/null || echo '{"count":0,"bytes":0,"newest_ts":null}'
}

# Requirement 3: keeps at most BURST_EVIDENCE_KEEP evidence dirs, newest
# first (the `<ts>-<server_id>` naming sorts lexicographically ==
# chronologically), journaling one `evidence-deleted` line per removal. A
# set younger than 24h is deleted exactly like any other once the count cap
# requires it — the cap, not age, is the only protection this gives (req 3's
# "unless the count cap forces it" clause).
reap_evidence() {  # -> stdout "evidence-reaped=N"
  [ -d "$EVIDENCE_DIR" ] || { echo "evidence-reaped=0"; return 0; }
  local keep="${BURST_EVIDENCE_KEEP:-3}"
  local n=0 i=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    i=$((i+1))
    [ "$i" -le "$keep" ] && continue
    local bytes age_h mtime
    bytes="$(du -sb "$d" 2>/dev/null | cut -f1)"; bytes="${bytes:-0}"
    mtime="$(stat -c %Y "$d" 2>/dev/null || echo "$(now_epoch)")"
    age_h=$(( ( $(now_epoch) - mtime ) / 3600 ))
    if rm -rf "$d" 2>/dev/null; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  evidence-deleted  (dir=$d bytes=$bytes age_h=$age_h)"
      n=$((n+1))
    fi
  # `-L`: $EVIDENCE_DIR is a symlink to EVIDENCE_ROOT (see evidence_link_
  # ensure) -- plain `find <symlink>` (no -L, no trailing slash) refuses to
  # descend into a symlink given as its OWN top-level argument and reports
  # only the link node itself, silently yielding zero results here.
  done < <(find -L "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  echo "evidence-reaped=$n"
}

# Requirement 7: `burst-lane.sh evidence ls` — one line per set, cause/
# server_id read back from that set's own copy of proof.json (falling back
# to the id parsed from the dirname if proof.json is missing/unreadable).
cmd_evidence() {
  case "${1:-}" in
    ls|'')
      python3 -c '
import glob, json, os, sys, time
d = sys.argv[1]
now = time.time()
for p in sorted(glob.glob(os.path.join(d, "*"))):
    if not os.path.isdir(p):
        continue
    name = os.path.basename(p)
    server_id = name.rsplit("-", 1)[-1] if "-" in name else "unknown"
    cause = None
    try:
        proof = json.load(open(os.path.join(p, "proof.json")))
        cause = proof.get("cause")
        server_id = proof.get("server_id") or server_id
    except Exception:
        pass
    sz = 0
    for root, _dirs, names in os.walk(p):
        for n in names:
            fp = os.path.join(root, n)
            try:
                sz += os.path.getsize(fp)
            except OSError:
                pass
    try:
        age_h = round((now - os.path.getmtime(p)) / 3600.0, 1)
    except OSError:
        age_h = None
    print("evidence: %s cause=%s server_id=%s bytes=%s age_h=%s" % (name, cause, server_id, sz, age_h))
' "$EVIDENCE_DIR"
      ;;
    *) echo "usage: burst-lane.sh evidence ls" >&2; exit 2 ;;
  esac
  exit 0
}

# Requirement 1: the EXIT trap armed at the top of cmd_prove, for the whole
# life of the process. The normal success/failure tails set
# PROVE_FINISHED=true immediately before their own `exit` — this trap's
# signal that proof.json and the journal are already written and it should
# do nothing. Anything else reaching here is a premature exit.
prove_exit_trap() {
  local rc="$1"
  # requirement 1: the marker's whole life is "between the write above and
  # this trap firing" -- removed here on EVERY exit path (finished or
  # aborted) so down/idle-guard/watchdog never keep waiting on an owner
  # that's already gone.
  rm -f "$PROVE_INFLIGHT_FILE" 2>/dev/null || true
  [ "$PROVE_FINISHED" = true ] && exit "$rc"

  local step="${PROVE_STEP:-unknown}"
  local cause="${step}-aborted"
  local tail; tail="$(prove_log_tail "$step")"

  prove_write_proof_json "" "$PROVE_ID" "$PROVE_WORKTREE" "$PROVE_SHA" false 0 \
    "$(( $(now_epoch) - ${PROVE_START_EPOCH:-$(now_epoch)} ))" "$cause" "$rc" "$step" "${PROVE_ERR_LINE:-}"

  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  aborted  (step=$step line=${PROVE_ERR_LINE:-none} rc=$rc${tail:+ tail=\"$tail\"})$(authz_journal_suffix)"

  prove_snapshot_cost
  # PRD-build-fail-loud-evidence-kept AC5: probe_run keeps cmd_down's
  # stderr (was /dev/null) and journals rc/err/log on failure; the explicit
  # `down-failed` line below is this caller's own branch on that failure —
  # cmd_down itself already leaves the session file uncleared on a failed
  # teardown (state_clear only runs on its success path), so a failed
  # `down` here correctly does not clear it either.
  if ! probe_run down -- cmd_down >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  down-failed  (cause=teardown-failed step=$step)"
  fi
  prove_journal_cost aborted

  if [ -n "$PROVE_CLEANUP_WORKTREE" ]; then
    git -C "$PROVE_DISPOSABLE_REPO" worktree remove --force "$PROVE_CLEANUP_WORKTREE" >/dev/null 2>&1 || rm -rf "$PROVE_CLEANUP_WORKTREE"
  fi

  exit "$rc"
}

cmd_prove() {
  local -x BUILD_BURST_ENABLED=1
  local worktree="" disposable_repo="" cleanup_worktree=""
  # Requirement 5: preserve the evidence set on a SUCCESSFUL prove too, not
  # only a failed one — an operator debugging a fixture wants the same set
  # a failure would have produced, without forcing a fake failure to get it.
  local keep_worktree=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) worktree="${2:?prove: --worktree needs a value}"; shift 2 ;;
      --keep-worktree) keep_worktree=true; shift ;;
      *) echo "usage: burst-lane.sh prove [--worktree <path>] [--keep-worktree]" >&2; exit 2 ;;
    esac
  done

  # PRD-build-operator-authorization-contract requirement 6/AC8: refuse
  # BEFORE anything below touches hcloud at all (worktree setup, `up`, ...)
  # when dispatched with no authorization string. Deliberately ahead of the
  # EXIT trap install below -- this is a plain, ordinary early exit, not an
  # abort the trap needs to forensically capture.
  authz_refuse_if_missing prove || exit 3

  # PRD-build-burst-state-keyed-by-server-v2 requirement 9: a proof is per
  # image, not per box — with more than one box up there is no single
  # answer to "which box did this proof run on", so refuse rather than
  # silently proving against whichever box `current` happens to name.
  local prove_active_boxes; prove_active_boxes="$(count_active_boxes)"
  if [ "$prove_active_boxes" -gt 1 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  refused  (cause=multi-box boxes=$prove_active_boxes)"
    echo "prove refused (cause=multi-box)" >&2
    exit 3
  fi

  # `errtrace` lets the ERR trap below fire from inside this function (bash
  # default: ERR is not inherited by functions) — best-effort $LINENO for an
  # ordinary unguarded non-zero exit; see the file-header comment above for
  # why a `set -u` kill never reaches it regardless.
  set -o errtrace
  PROVE_STEP="worktree"
  PROVE_START_EPOCH="$(now_epoch)"
  PROVE_WORKTREE="$worktree"
  PROVE_DISPOSABLE_REPO=""
  PROVE_CLEANUP_WORKTREE=""
  PROVE_SHA="unknown"
  PROVE_ID=""
  PROVE_FINISHED=false
  PROVE_ERR_LINE=""
  PROVE_FAIL_TAIL=""
  PROVE_ACTIVE=true
  PROVE_ASSERT_DIAG_JSON=""
  PROVE_LOCAL_TARGET=""
  trap 'PROVE_ERR_LINE=$LINENO' ERR
  trap 'prove_exit_trap "$?"' EXIT
  # An uncaught TERM/INT kills bash immediately; the OS-reported process
  # exit code still ends up 128+signal either way (verified by hand
  # 2026-09-14), but `$?` AS SEEN BY THE EXIT TRAP ABOVE is NOT reliably
  # 143/130 in that path (bash quirk: `$?` at EXIT-trap-fire time reflects
  # whatever was last set before the async signal arrived, not the killed
  # command's own status) — so proof.json's own exit_code field would be
  # wrong even though the process's real exit code is right. Trapping the
  # signal explicitly and calling `exit` ourselves makes it an ordinary,
  # intentional exit: `$?` at the EXIT trap is then exactly what we passed.
  trap 'exit 143' TERM
  trap 'exit 130' INT

  local start_epoch="$PROVE_START_EPOCH"

  if [ -z "$worktree" ]; then
    disposable_repo="${BURST_PROVE_MCPHOST_REPO:-$HOME/wintermute/mcphost}"
    PROVE_DISPOSABLE_REPO="$disposable_repo"
    if [ ! -d "$disposable_repo/.git" ] && ! git -C "$disposable_repo" rev-parse --git-dir >/dev/null 2>&1; then
      PROVE_FINISHED=true
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  failed  (cause=mcphost-repo-missing)"
      echo "prove failed (cause=mcphost-repo-missing)" >&2
      exit 1
    fi
    worktree="$(mktemp -u "${TMPDIR:-/tmp}/burst-prove-mcphost.XXXXXX")"
    PROVE_WORKTREE="$worktree"
    if ! git -C "$disposable_repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1; then
      PROVE_FINISHED=true
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  failed  (cause=worktree-add-failed)"
      echo "prove failed (cause=worktree-add-failed)" >&2
      exit 1
    fi
    cleanup_worktree="$worktree"
    PROVE_CLEANUP_WORKTREE="$cleanup_worktree"
  fi
  if [ ! -d "$worktree" ]; then
    PROVE_FINISHED=true
    echo "prove failed (cause=no-such-worktree)" >&2
    exit 1
  fi

  local sha; sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo unknown)"
  PROVE_SHA="$sha"

  local routed=false bytes=0 cause="" id="" secs_remote=0 cause_hint=""

  # PRD-build-burst-prove-inflight-guard requirement 1: written before `up`
  # so down/idle-guard/watchdog see this prove as live before the box it's
  # about to create could be torn down out from under it; prove_exit_trap
  # removes it on every exit path below, not this line.
  printf 'pid=%s\nstart_epoch=%s\n' "$$" "$PROVE_START_EPOCH" > "$PROVE_INFLIGHT_FILE" 2>/dev/null || true

  PROVE_STEP="up"
  local up_out up_rc; up_out="$(cmd_up 2>&1)"; up_rc=$?
  prove_write_step_log up "$up_out"
  if [ "$up_rc" -ne 0 ]; then
    cause="up-failed"
  else
    id="$(state_read server_id)"
    PROVE_ID="$id"
    # requirement 1: server_id joins the marker once `up` names one, so a
    # down/idle-guard/watchdog journal line can name the box a live prove
    # is holding, not just the pid.
    [ -n "$id" ] && printf 'pid=%s\nstart_epoch=%s\nserver_id=%s\n' "$$" "$PROVE_START_EPOCH" "$id" > "$PROVE_INFLIGHT_FILE" 2>/dev/null

    PROVE_STEP="run"
    # Test-only fault injection (requirement 7's provefx selftest block):
    # no real caller of `prove` ever sets BURST_PROVE_TEST_ABORT — grep the
    # tree, only burst-lane-selftest.sh does. Lets the offline suite drive
    # the abort trap at the "run" step without a real box, matching AC1 (a
    # `set -u` kill) and AC2 (an external TERM) exactly.
    case "${BURST_PROVE_TEST_ABORT:-}" in
      run-unbound) echo "${BURST_PROVE_TEST_UNBOUND_VAR}" >/dev/null ;;
      run-term) ( sleep 0.2; kill -TERM $$ ) & sleep 2 ;;
    esac
    local run_out run_rc
    run_out="$(cmd_run "$worktree" -- cargo test --workspace 2>&1)"; run_rc=$?
    prove_write_step_log run "$run_out"
    local run_line; run_line="$(grep "burst-lane  run  routed  (server_id=$id worktree=$worktree " "$JOURNAL" 2>/dev/null | tail -n1)"
    if [ "$run_rc" -ne 0 ] || [ -z "$run_line" ] || ! grep -q "exit=0" <<<"$run_line"; then
      cause="run-failed"
    else
      PROVE_STEP="pull"
      local pull_out pull_rc
      pull_out="$(cmd_pull "$worktree" 2>&1)"; pull_rc=$?
      prove_write_step_log pull "$pull_out"
      if [ "$pull_rc" -ne 0 ] || [ "$pull_out" != "pulled" ]; then
        cause="pull-failed"
      else
        PROVE_STEP="assert"
        local pull_line; pull_line="$(grep "burst-lane  pull  ok  (worktree=$worktree " "$JOURNAL" 2>/dev/null | tail -n1)"
        bytes="$(sed -n 's/.*bytes=\([0-9][0-9]*\).*/\1/p' <<<"$pull_line" | tail -n1)"
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        if [ "$bytes" -le 0 ]; then
          cause="pull-zero-bytes"
          # PRD-build-burst-selftest-drift-and-bake-gate requirement 5: a
          # WARM worktree (this run's own routed line already says
          # warm=true — its target existed on the box before this run's
          # rsync-up) pulling zero bytes back is not a mystery: nothing
          # needed recompiling, so there was nothing for the pull to send.
          # Name that explicitly instead of leaving the operator to
          # reconstruct "warm" from the run line themselves.
          case "$run_line" in
            *"warm=true"*)
              cause_hint=" (warm worktree, nothing recompiled — prove needs a fresh worktree; omit --worktree)"
              ;;
          esac
        else
          # Requirement 11: the reference is the marker `run` touched INSIDE
          # the remote target dir immediately before cargo started — it rode
          # back in the very same pull, on the box's OWN clock, so comparing
          # against it (never against this caller's local `mktemp` marker,
          # removed by this requirement) is correct regardless of any skew
          # between this machine's clock and the box's.
          local override local_target remote_marker remote_date
          override="$(cargo_target_dir_for "$worktree")"
          local_target="${override:-$worktree/target}"
          PROVE_LOCAL_TARGET="$local_target"
          remote_marker="$local_target/.burst-run-marker"
          remote_date=""
          [ -f "$(prove_remote_date_path)" ] && remote_date="$(cat "$(prove_remote_date_path)" 2>/dev/null)"
          # PRD-build-burst-prove-evidence-preservation AC8: a real box's
          # own artifacts are naturally fresh, so proving evidence
          # preservation against a real, reachable box needs a way to
          # force the no-fresh-artifact verdict deterministically without
          # actually reproducing a staleness bug — this test-only hook
          # (grep the tree: no real caller ever sets it, same doctrine as
          # BURST_PROVE_TEST_ABORT above) bumps the pulled marker's own
          # mtime to now, after every real artifact the pull just landed.
          if [ "${BURST_PROVE_TEST_FORCE_STALE:-0}" = "1" ] && [ -f "$remote_marker" ]; then
            touch "$remote_marker" 2>/dev/null || true
          fi
          # PRD-build-burst-prove-forensics requirement 11 regression (real
          # run 2026-09-15T05:08:20Z, RedBaron, commit 778dd2a): a genuinely
          # fresher artifact (newest_mtime 82s after marker_mtime) still
          # verdicted no-fresh-artifact. `-L` here matches
          # prove_assert_diag_json's own os.path.getmtime, which STATS
          # THROUGH a symlink to its target's mtime — cargo's target dir can
          # (re)point a symlinked binary/alias at an unchanged cache object
          # on every invocation without this `find` (previously plain
          # `-type f`, which excludes symlinks outright) ever seeing it as a
          # candidate file at all, silently narrowing "at least one file
          # newer than the marker" to "at least one non-symlink file newer
          # than the marker" — a real file can exist and be fresh while the
          # only path find walks to it is the symlink. skew_s is never
          # consulted here or anywhere below — it is diagnostic-only
          # (prove_assert_diag_json), and both sides of this comparison are
          # plain on-disk mtimes rsync -a preserved from the box's own clock.
          if [ ! -f "$remote_marker" ] || ! find -L "$local_target" -type f ! -name '.burst-run-marker' -newer "$remote_marker" -print -quit 2>/dev/null | grep -q .; then
            cause="no-fresh-artifact"
            # Requirement 12: capture the diagnosis right here, before
            # anything below has a chance to change local_target/marker
            # state — a no-fresh-artifact verdict must be explainable from
            # proof.json alone.
            PROVE_ASSERT_DIAG_JSON="$(prove_assert_diag_json "$local_target" "$remote_marker" "$remote_date")"
          else
            local ip local_hostname box_hostname
            ip="$(state_read ip)"
            local_hostname="$(hostname 2>/dev/null || echo unknown)"
            box_hostname="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 $(ssh_kh_args) \
                -i "$SSH_KEY" "$REMOTE_USER@$ip" hostname 2>/dev/null || true)"
            if [ -z "$box_hostname" ]; then
              cause="host-unreachable"
            elif [ "$box_hostname" = "$local_hostname" ]; then
              cause="host-mismatch"
            else
              routed=true
            fi
          fi
        fi
      fi
    fi
  fi

  secs_remote=$(( $(now_epoch) - start_epoch ))

  # Requirement 2: a clean step failure gets the same forensics an abort
  # gets — the captured step log's own tail, right in the failure line.
  case "$cause" in
    up-failed) PROVE_FAIL_TAIL="$(prove_log_tail up)" ;;
    run-failed) PROVE_FAIL_TAIL="$(prove_log_tail run)" ;;
    pull-failed) PROVE_FAIL_TAIL="$(prove_log_tail pull)" ;;
  esac

  local image_id; image_id="$(resolve_boot_image | awk '{print $1}')"
  local exit_code=1; [ "$routed" = true ] && exit_code=0
  prove_write_proof_json "$image_id" "${id:-}" "$worktree" "$sha" "$routed" "$bytes" "$secs_remote" "$cause" "$exit_code" "$PROVE_STEP" "" "$PROVE_ASSERT_DIAG_JSON"

  # PRD-build-burst-prove-evidence-preservation requirement 1/5: preserve
  # the pulled target + diagnostics BEFORE `down`/worktree cleanup below —
  # either an assert-step failure (routed=false, the case this PRD exists
  # for) or an operator's explicit --keep-worktree on a successful run
  # (requirement 5). session.json/logs/proof.json must still be live on
  # disk here, which is why this runs ahead of cmd_down, not after.
  local evidence_disposable=false
  [ -n "$cleanup_worktree" ] && evidence_disposable=true
  if [ "$routed" = true ] && [ "$keep_worktree" = true ]; then
    prove_preserve_evidence "$cause" "${PROVE_LOCAL_TARGET:-}" "${remote_marker:-}" "${id:-}" "$evidence_disposable" \
      "evidence-kept" "reason=operator" >/dev/null
  elif [ "$routed" != true ] && [ "$PROVE_STEP" = "assert" ]; then
    prove_preserve_evidence "$cause" "${PROVE_LOCAL_TARGET:-}" "${remote_marker:-}" "${id:-}" "$evidence_disposable" \
      "evidence-preserved" "" >/dev/null
  fi

  # `prove` always ends with `down`, success or failure — never leaves a
  # box up just because the proof itself failed a check. Requirement 5:
  # snapshot server_id/boot_epoch for the cost line BEFORE down clears them.
  prove_snapshot_cost
  # PRD-build-burst-prove-inflight-guard AC6: this is prove's OWN finishing
  # down call — remove the marker first so prove_inflight_guard (checked by
  # cmd_down at the top, before any delete decision) doesn't see prove's own
  # still-alive pid and keep the box under itself (2026-09-15T05:08:20Z: box
  # left running with journal line "decision=keep cause=prove-inflight
  # pid=4191204" where pid 4191204 was prove itself, not another prove/down/
  # watchdog). The trap below (prove_exit_trap) also removes it unconditionally
  # on every exit path, so this is a no-op if reached twice.
  rm -f "$PROVE_INFLIGHT_FILE" 2>/dev/null || true
  # PRD-build-fail-loud-evidence-kept AC5: same probe_run conversion as
  # prove_exit_trap's own down call above — kept stderr + explicit
  # down-failed branch instead of a bare `|| true`.
  if ! probe_run down -- cmd_down >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  down-failed  (cause=teardown-failed step=finish)"
  fi
  if [ "$routed" = true ]; then
    prove_journal_cost done
  else
    prove_journal_cost failed
  fi

  if [ -n "$cleanup_worktree" ]; then
    git -C "$disposable_repo" worktree remove --force "$cleanup_worktree" >/dev/null 2>&1 || rm -rf "$cleanup_worktree"
  fi

  PROVE_FINISHED=true
  if [ "$routed" = true ]; then
    # Requirement 12/AC14: local_target is named on a success line too — the
    # off-root target-dir case has nothing to diagnose, but the operator
    # still gets to see which path was actually inspected.
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  done  (routed=true image_id=$image_id server_id=$id bytes=$bytes secs=$secs_remote local_target=${PROVE_LOCAL_TARGET:-none})$(authz_journal_suffix)"
    echo "prove done: routed=true image_id=$image_id bytes=$bytes"
    exit 0
  fi
  local fail_msg="cause=$cause$cause_hint image_id=$image_id server_id=${id:-none} local_target=${PROVE_LOCAL_TARGET:-none}"
  [ -n "$PROVE_FAIL_TAIL" ] && fail_msg="$fail_msg tail=\"$PROVE_FAIL_TAIL\""
  # Requirement 12/AC15: a no-fresh-artifact verdict carries its own
  # diagnosis (files/newest_mtime/marker_mtime/remote_date/skew_s) right in
  # the journal line, same fields as proof.json.
  [ -n "$PROVE_ASSERT_DIAG_JSON" ] && fail_msg="$fail_msg $(prove_diag_tail "$PROVE_ASSERT_DIAG_JSON")"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  prove  failed  ($fail_msg)$(authz_journal_suffix)"
  echo "prove failed (cause=$cause$cause_hint)" >&2
  exit 1
}

# ---- enable / disable (PRD-build-burst-dispatch-reenable requirement 4) --
# The tick's ONLY opt-in surface. `enable` never edits
# ~/.config/wm-burst/.env (that file also carries HCLOUD_TOKEN and
# burst-configured.sh deliberately sources it only in a subshell — see that
# file's header); instead it writes a diffable, single-purpose, one-`rm`-
# reversible systemd user-service drop-in that sets BUILD_BURST_ENABLED=1
# for claude-build.service specifically. It reads ONLY `resolve_boot_image`
# (requirement 2, the same precedence `status`/`up` use) and `proof.json`
# (requirement 3's own receipt) — never re-derives its own notion of "what
# would `up` boot" or "is the proof fresh", so `enable` and `status --json`
# can never disagree about either question.
cmd_enable() {
  local boot_image_id boot_image_source
  read -r boot_image_id boot_image_source <<<"$(resolve_boot_image)"

  local decision
  decision="$(python3 -c '
import calendar, json, sys, time

proof_path, boot_image_id = sys.argv[1:3]

def fail(cause):
    print("refuse", cause)
    raise SystemExit(0)

try:
    proof = json.load(open(proof_path))
except Exception:
    fail("no-proof")

if proof.get("routed") is not True:
    fail("not-routed")

ts = proof.get("ts", "")
try:
    t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
    age_h = (time.time() - calendar.timegm(t)) / 3600.0
except Exception:
    fail("no-timestamp")

if age_h > 168:
    fail("stale")

if proof.get("image_id") != boot_image_id:
    fail("image-mismatch")

print("allow", ts, proof.get("image_id", ""))
' "$PROOF_STATE_FILE" "$boot_image_id")"

  local verdict cause_or_ts image_id
  read -r verdict cause_or_ts image_id <<<"$decision"

  if [ "$verdict" != "allow" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  enable  refused  (cause=$cause_or_ts)"
    echo "enable refused (cause=$cause_or_ts)" >&2
    exit 3
  fi

  # R6/AC5: enable requires a passing canary for the CURRENT box before it
  # ever writes the drop-in. This reads canary_read_status's cached verdict
  # rather than invoking a live cmd_canary (same cached-check family as
  # up/bake's canary_gate_check below): AC5's own flow is "canary=missing
  # -> enable refuses -> operator or the timer runs canary -> enable
  # re-runs and succeeds", and the Migration section describes "canary=
  # missing in status until the operator or the timer runs it" -- both
  # read enable as a state CHECK, not a trigger. A live inline run here
  # would also make every enable call pay the canary's own <=25min cold
  # gate wall, never budgeted for enable.
  local canary_verdict canary_age canary_head canary_ts
  local canary_server_id; canary_server_id="$(state_read server_id)"
  if [ "${BURST_CANARY_SKIP:-0}" = "1" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary-skip  (event=enable by=${BURST_CANARY_SKIP_BY:-${SUDO_USER:-${USER:-unknown}}})"
    canary_verdict="pass"; canary_head=""; canary_ts="$(now_iso)"
  else
    read -r canary_verdict canary_age canary_head canary_ts <<<"$(canary_read_status "$canary_server_id")"
    if [ "$canary_verdict" = "missing" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  enable  refused  (cause=canary-missing)"
      echo "enable refused (cause=canary-missing)" >&2
      exit 3
    fi
    if [ "$canary_verdict" != "pass" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  enable  refused  (cause=canary-diverged)"
      echo "enable refused (cause=canary-diverged)" >&2
      exit 3
    fi
  fi

  mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
  printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$SYSTEMD_DROPIN"
  systemctl --user daemon-reload >/dev/null 2>&1 || true

  # R17: enable.json is the sole sanctioned record pairing this
  # BUILD_BURST_ENABLED=1 write with the canary verdict that authorized it.
  # A knob set to 1 with no matching (or stale) record here is what
  # select-tick.sh's knob-ownership check (R17, a later chained step) alarms
  # on -- written atomically (tmp + mv) same as canary.json.
  local enable_json="$STATE_DIR/enable.json" enable_json_tmp
  enable_json_tmp="$(mktemp "$STATE_DIR/.enable.XXXXXX")"
  python3 -c '
import json, sys
ts, canary_verdict, canary_ts, head, out_path = sys.argv[1:6]
json.dump({"ts": ts, "canary_verdict": canary_verdict, "canary_ts": canary_ts, "head": head},
          open(out_path, "w"), indent=2, sort_keys=True)
' "$(now_iso)" "$canary_verdict" "$canary_ts" "$canary_head" "$enable_json_tmp"
  mv -f "$enable_json_tmp" "$enable_json"

  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  enable  done  (proof_ts=$cause_or_ts image_id=$image_id canary=$canary_verdict)"
  echo "enable done: image_id=$image_id"
  exit 0
}

# Shared by cmd_disable (operator-invoked, journals "disable done") and
# check_auto_disable (autonomous, journals "auto-disabled" — a distinct
# event name because AC9's journal text differs from AC7's and, unlike
# cmd_disable, auto-disable fires mid-teardown and must never `exit` its
# caller). Idempotent: safe to call with no drop-in present.
remove_burst_dropin() {
  rm -f "$SYSTEMD_DROPIN"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

cmd_disable() {
  # $1 optional cause — defaults to "operator" (a manual `disable` call).
  local cause="${1:-operator}"
  remove_burst_dropin
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  disable  done  (cause=$cause)"
  echo "disable done (cause=$cause)"
  exit 0
}

# ---- auto-disable (PRD-build-burst-dispatch-reenable requirement 5) --------
# Called at the end of every autonomous teardown (down/watchdog/idle-guard,
# from inside teardown_and_delete, right after that session's own row lands
# in $COST_LEDGER) so both triggers always see the just-finished session.
# No-op when the lane isn't currently enabled (nothing to disable, and a
# disabled lane can't have "served" anything the triggers care about).
#
# Trigger (a) zero-run-sessions: this session-total ledger row (ledger_append
# — no "kind" key, unlike the per-slug proration rows check_auto_disable
# must skip) and the ledger's own PRECEDING session-total row, when both
# fall within the last 24h AND both have an empty "prds" array (equivalent
# to that session's runs_served==0 — SERVED_FILE always gets a non-empty
# entry from ANY routed run, requirement 13), trigger on the second.
#
# Trigger (b) eur-ceiling: sum of today's (UTC calendar date, matching
# maybe_daily_rollup's own convention) session-total rows' eur reaches
# BURST_AUTO_DISABLE_EUR_PER_DAY with NONE of today's sessions having served
# a routed run (non-empty prds) — a lane that spent the ceiling but proved
# nothing today, not just one expensive proven session.
check_auto_disable() {
  [ -f "$SYSTEMD_DROPIN" ] || return 0
  [ -f "$COST_LEDGER" ] || return 0

  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  local decision
  decision="$(python3 -c '
import json, sys, time, calendar

now_epoch, path, threshold, today = float(sys.argv[1]), sys.argv[2], float(sys.argv[3]), sys.argv[4]

def epoch_of(ts):
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None

rows = []
try:
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            # Session-total rows only (ledger_append) — per-slug proration
            # rows (prorate_attribution, kind="slug") are a different shape
            # and would double-count both triggers.
            if d.get("kind") == "slug" or "session_id" not in d:
                continue
            rows.append(d)
except OSError:
    print("trigger=none")
    sys.exit(0)

rows.sort(key=lambda r: r.get("date", ""))

recent = [r for r in rows if (ep := epoch_of(r.get("date", ""))) is not None and (now_epoch - ep) <= 86400]
last_two = recent[-2:]
if len(last_two) == 2 and all(not r.get("prds") for r in last_two):
    ids = ",".join(str(r.get("session_id", "?")) for r in last_two)
    print("trigger=zero-run-sessions sessions=%s" % ids)
    sys.exit(0)

today_rows = [r for r in rows if str(r.get("date", "")).startswith(today)]
total_eur = sum(float(r.get("eur", 0) or 0) for r in today_rows)
any_served = any(r.get("prds") for r in today_rows)
if today_rows and total_eur >= threshold and not any_served:
    print("trigger=eur-ceiling eur=%.4f" % total_eur)
    sys.exit(0)

print("trigger=none")
' "$(now_epoch)" "$COST_LEDGER" "$BURST_AUTO_DISABLE_EUR_PER_DAY" "$today")"

  case "$decision" in
    "trigger=zero-run-sessions "*)
      local sessions="${decision#trigger=zero-run-sessions sessions=}"
      remove_burst_dropin
      local line; line="$(now_iso)  burst-lane  auto-disabled  (cause=zero-run-sessions sessions=$sessions)"
      journal_line --file "$JOURNAL" "$line"
      echo "$line" >&2
      ;;
    "trigger=eur-ceiling "*)
      local eur="${decision#trigger=eur-ceiling eur=}"
      remove_burst_dropin
      local line; line="$(now_iso)  burst-lane  auto-disabled  (cause=eur-ceiling eur=$eur)"
      journal_line --file "$JOURNAL" "$line"
      echo "$line" >&2
      ;;
    *) : ;;
  esac
}

# ---- up-lock holder attribution (PRD-build-burst-prove-forensics req 4) --
# DESIGN NOTE (deviation from the PRD's literal "/proc/locks by the lock
# file's inode" text, verified by hand 2026-09-14): for the
# `exec N>file; flock -n N` idiom this script (and cargo-budget.sh's own
# slot locks) both use, /proc/locks' pid field is the short-lived `flock`
# subprocess that merely tested/took the lock — it is reaped within ~1s of
# acquisition, while the lock itself persists via the long-running shell's
# OWN still-open fd (confirmed empirically: `ps -p <that pid>` finds
# nothing a second later). cargo-budget.sh's slot_lock_holder_pid comment
# already documents rejecting /proc/locks for exactly this reason. So
# up.pid (written by the long-running holder itself, right after it wins
# the flock, and live for as long as it holds the lock) is the reliable
# primary signal for the common real-world case — a genuinely concurrent
# second `up`. /proc/locks is kept as a second-line fallback for a holder
# up.pid never named at all (a leaked fd from an unknown path, or a
# selftest fixture that holds the lock some other way) — it still finds a
# live pid correctly whenever the holder's own syscall-caller process is
# the same one still running (e.g. `flock <file> -c '<held command>'`,
# which never forks a separate short-lived acquirer).
up_lock_holder_pid() {
  local recorded; recorded="$(cat "$UP_PID_FILE" 2>/dev/null || true)"
  case "$recorded" in
    ''|*[!0-9]*) : ;;
    *) if kill -0 "$recorded" 2>/dev/null; then printf '%s' "$recorded"; return 0; fi ;;
  esac
  local inode; inode="$(stat -c %i "$UP_LOCK_FILE" 2>/dev/null || true)"
  [ -n "$inode" ] || { printf ''; return 0; }
  local pid
  pid="$(awk -v i="$inode" '{n=split($6,a,":"); if (n==3 && a[3]==i) print $5}' /proc/locks 2>/dev/null | head -1)"
  case "$pid" in
    ''|*[!0-9]*) printf '' ;;
    *) kill -0 "$pid" 2>/dev/null && printf '%s' "$pid" || printf '' ;;
  esac
}

# up_lock_holder_describe <pid> -> "pid=<n> comm=<c> age=<s>s cmdline=<first80>"
# (or "pid=unknown" when the holder can't be identified at all).
up_lock_holder_describe() {
  local pid="${1:-}"
  [ -n "$pid" ] || { printf 'pid=unknown'; return 0; }
  local comm; comm="$(tr -d '\0\n' < "/proc/$pid/comm" 2>/dev/null)"
  local start_ticks hz uptime_s age
  start_ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)"
  hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
  uptime_s="$(awk '{print $1}' /proc/uptime 2>/dev/null)"
  if [ -n "$start_ticks" ] && [ -n "$uptime_s" ]; then
    age="$(awk -v st="$start_ticks" -v hz="$hz" -v up="$uptime_s" 'BEGIN{printf "%d", up - (st/hz)}' 2>/dev/null)"
  fi
  local cmdline; cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)"
  printf 'pid=%s comm=%s age=%ss cmdline=%s' "$pid" "${comm:-unknown}" "${age:-unknown}" "${cmdline:-unknown}"
}

# ---- pending box-only reality checks on a gate-ready boot (PRD-build-burst-
# dispatch-reenable requirement 8, AC14) -------------------------------------
# `reality-check.sh pending-run` executes every registered box-only pending
# AC (for example volume-id-parse AC9) against whichever box the lane just
# booted or adopted — idempotent (each registration is consumed and removed
# the first time it runs) and a no-op when nothing is pending, so calling it
# on every gate-ready boot is safe even when the pending directory is empty.
# `up` calls this right after gate readiness is known and BEFORE any of its
# own ordinary work (session bookkeeping, `verify`, scheduled parity) so a
# pending registration clears on the very first real boot after this PRD
# lands. Overridable ($BURST_LANE_REALITY_CHECK_SH) so a selftest never
# points a fixture boot at the real reality-check.sh / pending-registration
# directory. Best-effort: never fails `up` — reality-check.sh's own job is
# to record reality, not to gate this lane's boot.
REALITY_CHECK_SH="${BURST_LANE_REALITY_CHECK_SH:-$SKILL_DIR/scripts/reality-check.sh}"
run_pending_reality_check_if_gate_ready() {
  [ "${GATE_READY:-false}" = "true" ] || return 0
  [ -x "$REALITY_CHECK_SH" ] || return 0
  local rc=0
  "$REALITY_CHECK_SH" pending-run build-skill >/dev/null 2>&1 || rc=$?
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  pending-reality-run  (rc=$rc)"
  return 0
}

# ---- canary (PRD-build-burst-gate-canary-invariant, R1-R3/R5) -------------
# `burst-lane.sh canary` proves the box passes the gate, in three variants,
# against a fixed HEAD — see the PRD's TL;DR. THIS PASS implements the
# canary command itself (head resolution, baseline, the three variants,
# canary.json + journal) as a purely additive new subcommand. R6/R8 wiring
# (cmd_up/cmd_bake/cmd_enable/cmd_status all consult it now, via
# canary_read_status/canary_gate_check just below) landed in the chained step
# that added this comment; the daily-cadence/divergence-confirmation state
# machine of R7 is still a later chained step — see the manifest's outcome
# text for what remains.
#
# Variant "delta" is NOT a fourth gate invocation. extend-gate.sh already
# runs `gate-delta.sh verdict` against the repo's committed
# agent/gate-baseline.json as part of EVERY --scope main gate (see its own
# "delta verdict against the committed baseline" section) and caches the
# result at <repo>/target/autobuilder/last-verdict.json. Re-running a full
# gate a third time would blow the "<=1 gate wall + 2 min/variant" budget
# (Non-functional); the delta variant instead reads that cache, which the
# "main" variant's own run just wrote — this is exactly what Technical
# considerations means by "the delta variant reuses it."
CANARY_REPO="${BURST_LANE_CANARY_REPO:-${BURST_PROVE_MCPHOST_REPO:-$HOME/wintermute/mcphost}}"
CANARY_GATE_LAUNCH="${BURST_LANE_CANARY_GATE_LAUNCH:-$HERE/gate-launch.sh}"
CANARY_RECEIPT_DIFF="${BURST_LANE_CANARY_RECEIPT_DIFF:-$HERE/gate-receipt-diff.sh}"
CANARY_GH="${BURST_LANE_GH:-gh}"
CANARY_BASELINE_ROOT="$STATE_DIR/canary-baseline"
CANARY_RUNS_ROOT="$STATE_DIR/canary-runs"

# canary_repo_slug <repo> -> stdout "owner/name" from origin's URL, or empty.
canary_repo_slug() {
  local repo="$1" url
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || { printf ''; return 0; }
  sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' <<<"$url"
}

# canary_gh_run <repo> <ref> -> stdout "<conclusion> <sha>" for the newest
# COMPLETED run at <ref> ("none " when there is none, or gh/network fails —
# fails closed to "not green" per R1, never treats a lookup failure as
# green). Wraps `gh run list` behind $CANARY_GH so a selftest can point it
# at a fixture script instead of the real gh CLI / network (same pattern
# as gate-launch.sh's own overridable tool vars).
canary_gh_run() {
  local repo="$1" ref="$2" slug out
  slug="$(canary_repo_slug "$repo")"
  if [ -z "$slug" ]; then printf 'none \n'; return 0; fi
  out="$("$CANARY_GH" run list --repo "$slug" --branch "$ref" --limit 1 \
        --json conclusion,status,headSha 2>/dev/null)" || out=""
  [ -n "$out" ] || out='[]'
  python3 -c '
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    rows = []
if rows and rows[0].get("status") == "completed":
    print(rows[0].get("conclusion") or "none", rows[0].get("headSha") or "")
else:
    print("none", "")
' "$out"
}

# canary_read_status [server_id] -> stdout "<verdict> <age_h> <head7> <ts>":
# verdict is pass|diverged|missing, read from that server's canary.json
# (R5's per-box state, "boxes/<server_id>/canary.json"); "missing" means no
# canary has ever run for this server_id/image — never treated as a pass.
# A verdict is "diverged" both when canary.json's own diverged[] is
# non-empty AND when any variant's own verdict is "block" (a refused/errored
# variant is not a pass either, even with nothing in diverged[]). Shared by
# cmd_status (R8) and the enable/up/bake gates below (R6) so there is exactly
# one place that decides what "the box's canary state" means.
canary_read_status() {
  local server_id="${1:-$(state_read server_id)}" cf
  cf="$(box_path_for "$server_id" canary.json)"
  python3 -c '
import calendar, json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("missing 0 ------- ")
    raise SystemExit(0)
head = (d.get("head") or "")[:7] or "-------"
ts = d.get("ts", "")
try:
    t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
    age_h = round((time.time() - calendar.timegm(t)) / 3600.0, 2)
except Exception:
    age_h = -1
diverged = d.get("diverged") or []
variants = (d.get("variants") or {}).values()
verdict = "diverged" if (diverged or "block" in variants) else "pass"
print("%s %s %s %s" % (verdict, age_h, head, ts or "-"))
' "$cf"
}

# canary_gate_check <event> -> stdout "<verdict> <age_h> <head7> <ts>",
# same shape as canary_read_status -- shared by up/bake/enable (R6).
# Reads the CACHED verdict; it does not invoke a live cmd_canary. A live
# invocation was this function's first draft and it broke every bake/up
# selftest written before this PRD existed the moment it landed: none of
# them fixture $BURST_LANE_CANARY_GATE_LAUNCH/$BURST_LANE_GH/$CANARY_REPO,
# so a live run fell through to the real $HOME/wintermute/mcphost checkout
# and the real `gh` CLI/network and hung (caught empirically running
# tests/bdrift_ac5_bake_refusal_journals_key.sh during this same chained
# step -- ps showed it stuck for 10+ minutes with no fixture in sight).
# Every lifecycle event here needs to answer in the time `state_read`
# takes, not the canary's own <=25min cold gate wall (Non-functional is
# scoped to the `canary` command itself); the daily timer (R7, not yet
# wired) and the operator/enable's own "run canary, then enable" flow
# (Migration section) are what actually keeps this cache warm.
# BURST_CANARY_SKIP=1 bypasses with a journaled `by=<user>` line (R6's
# emergency escape hatch) and reports "pass".
canary_gate_check() {
  local event="$1"
  if [ "${BURST_CANARY_SKIP:-0}" = "1" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary-skip  (event=$event by=${BURST_CANARY_SKIP_BY:-${SUDO_USER:-${USER:-unknown}}})"
    printf 'pass 0 ------- %s\n' "$(now_iso)"
    return 0
  fi
  canary_read_status "$(state_read server_id)"
}

# canary_resolve_head <repo> <operator_head> -> stdout "<sha> <source>" on
# success (source is operator|green-main|last-green-tag); returns 1 with
# nothing on stdout when neither main nor any tag is green (R1, AC9/AC11).
# An explicit operator_head short-circuits with no CI lookup at all — the
# operator is trusted to have named a real, known-good sha.
canary_resolve_head() {
  local repo="$1" operator_head="$2" concl sha
  if [ -n "$operator_head" ]; then
    printf '%s operator\n' "$operator_head"
    return 0
  fi
  read -r concl sha < <(canary_gh_run "$repo" main)
  if [ "$concl" = "success" ] && [ -n "$sha" ]; then
    printf '%s green-main\n' "$sha"
    return 0
  fi
  local tag
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    read -r concl sha < <(canary_gh_run "$repo" "$tag")
    if [ "$concl" = "success" ] && [ -n "$sha" ]; then
      printf '%s last-green-tag\n' "$sha"
      return 0
    fi
  done < <(git -C "$repo" tag --sort=-creatordate 2>/dev/null)
  return 1
}

# canary_diverged_lines <baseline_dir> <run_dir> -> stdout, one
# "<producer> <local> <box> <route> DIVERGED" line per divergence (empty,
# rc irrelevant, when there is no baseline or no receipts to compare — R2's
# --no-baseline / missing-baseline cases must never report a divergence
# against nothing).
canary_diverged_lines() {
  local baseline_dir="$1" run_dir="$2"
  [ -n "$baseline_dir" ] && [ -d "$baseline_dir" ] || return 0
  [ -n "$(ls -A "$run_dir" 2>/dev/null)" ] || return 0
  "$CANARY_RECEIPT_DIFF" "$baseline_dir" "$run_dir" 2>/dev/null | awk '$NF=="DIVERGED"'
  return 0
}

# canary_build_baseline <head_sha> <baseline_dir> — R2: a local --scope
# main gate at that HEAD, nice -n 10, CARGO_BUDGET_TEST_THREADS=2 (never
# BURST_LANE=1 — this IS the local baseline the box is compared against).
canary_build_baseline() {
  local head_sha="$1" baseline_dir="$2" ts rc=0
  ts="$(now_epoch)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  baseline  building  (head=$head_sha)"
  nice -n 10 env CARGO_BUDGET_TEST_THREADS=2 "$CANARY_GATE_LAUNCH" "$CANARY_REPO" \
    --head "$head_sha" --scope main --slug "canary-baseline-$ts" --wait \
    >/dev/null 2>&1 || rc=$?
  mkdir -p "$baseline_dir"
  cp -f "$CANARY_REPO"/target/autobuilder/receipts/*.json "$baseline_dir"/ 2>/dev/null || true
  if [ -n "$(ls -A "$baseline_dir" 2>/dev/null)" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  baseline  built  (head=$head_sha rc=$rc)"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  baseline  failed  (head=$head_sha rc=$rc)"
  fi
}

# canary_run_variant_main <head_sha> <baseline_dir> <baseline_state> <server_id>
# -> stdout verdict (pass|block|diverged); sets CANARY_LAST_DIVERGED_LINES.
canary_run_variant_main() {
  local head_sha="$1" baseline_dir="$2" baseline_state="$3" server_id="$4"
  local ts rc=0 verdict="pass" n_diverged=0
  ts="$(now_epoch)"
  BURST_LANE=1 "$CANARY_GATE_LAUNCH" "$CANARY_REPO" --head "$head_sha" --scope main \
    --slug "canary-main-$ts" --wait >/dev/null 2>&1 || rc=$?
  local run_dir="$CANARY_RUNS_ROOT/$ts-main/receipts"
  mkdir -p "$run_dir"
  cp -f "$CANARY_REPO"/target/autobuilder/receipts/*.json "$run_dir"/ 2>/dev/null || true
  [ "$rc" -eq 0 ] || verdict="block"
  local diverged_lines=""
  if [ "$baseline_state" = "present" ]; then
    diverged_lines="$(canary_diverged_lines "$baseline_dir" "$run_dir")"
    [ -n "$diverged_lines" ] && verdict="diverged" && n_diverged="$(printf '%s\n' "$diverged_lines" | grep -c .)"
  fi
  CANARY_LAST_DIVERGED_LINES="$diverged_lines"
  CANARY_LAST_RUN_DIR="$run_dir"
  local receipts_n; receipts_n="$(find "$run_dir" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  main  $verdict  (head=$head_sha receipts=$receipts_n diverged=$n_diverged route=burst:${server_id:-unknown})"
  printf '%s\n' "$verdict"
}

# canary_run_variant_branch <head_sha> <baseline_dir> <baseline_state> <server_id>
# -> stdout verdict (pass|block|diverged); sets CANARY_LAST_DIVERGED_LINES.
# The throwaway branch/worktree is never pushed and is deleted after (R3,
# Technical considerations).
canary_run_variant_branch() {
  local head_sha="$1" baseline_dir="$2" baseline_state="$3" server_id="$4"
  local ts branch wt rc=0 verdict="pass" n_diverged=0 branch_head
  ts="$(now_epoch)"
  branch="canary/$ts"
  wt="$(mktemp -u "${TMPDIR:-/tmp}/burst-canary-branch.XXXXXX")"
  if ! git -C "$CANARY_REPO" worktree add -b "$branch" "$wt" "$head_sha" >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  branch  block  (head=$head_sha cause=worktree-add-failed)"
    CANARY_LAST_DIVERGED_LINES=""
    printf 'block\n'
    return 0
  fi
  git -C "$wt" commit --allow-empty -m "canary: throwaway commit for --scope branch" >/dev/null 2>&1
  branch_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "$head_sha")"
  BURST_LANE=1 "$CANARY_GATE_LAUNCH" "$wt" --head "$branch_head" --scope branch \
    --slug "canary-branch-$ts" --wait >/dev/null 2>&1 || rc=$?
  local run_dir="$CANARY_RUNS_ROOT/$ts-branch/receipts"
  mkdir -p "$run_dir"
  cp -f "$wt"/target/autobuilder/receipts/*.json "$run_dir"/ 2>/dev/null || true
  [ "$rc" -eq 0 ] || verdict="block"
  local diverged_lines=""
  if [ "$baseline_state" = "present" ]; then
    diverged_lines="$(canary_diverged_lines "$baseline_dir" "$run_dir")"
    [ -n "$diverged_lines" ] && verdict="diverged" && n_diverged="$(printf '%s\n' "$diverged_lines" | grep -c .)"
  fi
  CANARY_LAST_DIVERGED_LINES="$diverged_lines"
  CANARY_LAST_RUN_DIR="$run_dir"
  local receipts_n; receipts_n="$(find "$run_dir" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  branch  $verdict  (head=$branch_head receipts=$receipts_n diverged=$n_diverged route=burst:${server_id:-unknown})"
  git -C "$CANARY_REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$CANARY_REPO" branch -D "$branch" >/dev/null 2>&1 || true
  printf '%s\n' "$verdict"
}

# canary_run_variant_delta <head_sha> <server_id> -> stdout verdict
# (pass|delta-pass|block|unknown), reading the "main" variant's own
# last-verdict.json cache — see the header comment above for why this is
# not a fourth gate invocation.
canary_run_variant_delta() {
  local head_sha="$1" server_id="$2"
  local verdict_file="$CANARY_REPO/target/autobuilder/last-verdict.json"
  local baseline_state="absent" verdict="unknown"
  if git -C "$CANARY_REPO" show HEAD:agent/gate-baseline.json >/dev/null 2>&1; then
    baseline_state="present"
  fi
  if [ -n "$JQ" ] && [ -f "$verdict_file" ]; then
    verdict="$("$JQ" -r '.verdict // "unknown"' "$verdict_file" 2>/dev/null)"
    [ -n "$verdict" ] || verdict="unknown"
  fi
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  delta  $verdict  (head=$head_sha baseline=$baseline_state route=burst:${server_id:-unknown})"
  printf '%s\n' "$verdict"
}

# canary_write_state_json <out_file> <head> <head_source> <ts> <image_id>
# <baseline_dir> <verdict_main> <verdict_branch> <verdict_delta>
# <diverged_ndjson> — R5's canary.json, written atomically (tmp + mv).
canary_write_state_json() {
  local out_file="$1" head="$2" head_source="$3" ts="$4" image_id="$5" \
        baseline_dir="$6" v_main="$7" v_branch="$8" v_delta="$9" diverged_ndjson="${10}"
  mkdir -p "$(dirname "$out_file")"
  local tmp; tmp="$(mktemp "$(dirname "$out_file")/.canary.XXXXXX")"
  python3 -c '
import json, sys
(head, head_source, ts, image_id, baseline_dir, v_main, v_branch, v_delta,
 diverged_ndjson, out_path) = sys.argv[1:11]
diverged = []
for line in diverged_ndjson.splitlines():
    parts = line.split()
    if len(parts) < 5:
        continue
    diverged.append({"producer": parts[0], "local": parts[1], "box": parts[2], "route": parts[3]})
d = {
    "head": head,
    "head_source": head_source,
    "image_id": image_id,
    "ts": ts,
    "variants": {"main": v_main, "branch": v_branch, "delta": v_delta},
    "diverged": diverged,
    "baseline_dir": baseline_dir,
}
json.dump(d, open(out_path, "w"), indent=2, sort_keys=True)
' "$head" "$head_source" "$ts" "$image_id" "$baseline_dir" "$v_main" "$v_branch" "$v_delta" \
  "$diverged_ndjson" "$tmp"
  mv -f "$tmp" "$out_file"
}

cmd_canary() {
  local head="" variants="main,branch,delta" no_baseline=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="${2:?canary: --head needs a value}"; shift 2 ;;
      --variants) variants="${2:?canary: --variants needs a value}"; shift 2 ;;
      --no-baseline) no_baseline=true; shift ;;
      *) echo "usage: burst-lane.sh canary [--head <sha>] [--variants main,branch,delta] [--no-baseline]" >&2; exit 2 ;;
    esac
  done

  mkdir -p "$BOX_STATE_DIR" "$CANARY_BASELINE_ROOT" "$CANARY_RUNS_ROOT"

  # Non-functional: never more than one canary in flight per box.
  local canary_lock="$BOX_STATE_DIR/canary.inflight.lock"
  exec {_canary_lock_fd}>"$canary_lock"
  if ! flock -n "$_canary_lock_fd"; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  refused  (cause=inflight)"
    echo "canary refused (cause=inflight)" >&2
    exit 3
  fi
  printf 'pid=%s\nstart_epoch=%s\n' "$$" "$(now_epoch)" > "$BOX_STATE_DIR/canary.inflight"
  trap 'rm -f "$BOX_STATE_DIR/canary.inflight"' EXIT

  local resolved head_sha head_source
  if ! resolved="$(canary_resolve_head "$CANARY_REPO" "$head")"; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  refused  (cause=no-green-head)"
    echo "canary refused (cause=no-green-head)" >&2
    exit 4
  fi
  read -r head_sha head_source <<<"$resolved"

  local server_id; server_id="$(state_read server_id)"
  local image_id; image_id="$(state_read image_id)"
  local box_dir; box_dir="$(box_path_for "$server_id" "")"; box_dir="${box_dir%/}"
  mkdir -p "$box_dir"

  local baseline_dir="" baseline_state="absent"
  if [ "$no_baseline" = true ]; then
    baseline_state="skipped"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  canary  baseline=skipped  (head=$head_sha)"
  else
    baseline_dir="$CANARY_BASELINE_ROOT/$head_sha/receipts"
    if [ ! -d "$baseline_dir" ] || [ -z "$(ls -A "$baseline_dir" 2>/dev/null)" ]; then
      canary_build_baseline "$head_sha" "$baseline_dir"
    fi
    [ -d "$baseline_dir" ] && [ -n "$(ls -A "$baseline_dir" 2>/dev/null)" ] && baseline_state="present"
  fi

  local -a want=()
  IFS=',' read -r -a want <<<"$variants"

  local v_main="skipped" v_branch="skipped" v_delta="skipped"
  local diverged_ndjson="" w
  for w in "${want[@]}"; do
    case "$w" in
      main)
        v_main="$(canary_run_variant_main "$head_sha" "$baseline_dir" "$baseline_state" "$server_id")"
        [ -n "$CANARY_LAST_DIVERGED_LINES" ] && diverged_ndjson="$diverged_ndjson$CANARY_LAST_DIVERGED_LINES"$'\n'
        ;;
      branch)
        v_branch="$(canary_run_variant_branch "$head_sha" "$baseline_dir" "$baseline_state" "$server_id")"
        [ -n "$CANARY_LAST_DIVERGED_LINES" ] && diverged_ndjson="$diverged_ndjson$CANARY_LAST_DIVERGED_LINES"$'\n'
        ;;
      delta)
        v_delta="$(canary_run_variant_delta "$head_sha" "$server_id")"
        ;;
      *) echo "canary: unknown variant '$w' (ignored)" >&2 ;;
    esac
  done

  canary_write_state_json "$box_dir/canary.json" "$head_sha" "$head_source" "$(now_iso)" \
    "${image_id:-unknown}" "$baseline_dir" "$v_main" "$v_branch" "$v_delta" "$diverged_ndjson"
  cp -f "$box_dir/canary.json" "$STATE_DIR/canary.json" 2>/dev/null || true

  rm -f "$BOX_STATE_DIR/canary.inflight"
  trap - EXIT
  flock -u "$_canary_lock_fd" 2>/dev/null || true

  case " $v_main $v_branch $v_delta " in
    *" block "*|*" diverged "*) exit 1 ;;
    *) exit 0 ;;
  esac
}

cmd_up() {
  if ! burst_configured; then
    echo "burst: refused — not configured (RedBaron-local policy); set BUILD_BURST_ENABLED=1 to allow" >&2
    return 3
  fi
  authz_refuse_if_missing up || exit 3

  # PRD-build-burst-state-keyed-by-server-v2 requirement 2/6: parse
  # `--count N` (default 1) and enforce the money cap BEFORE taking the
  # up.lock or making any hcloud call — a refused request never journals
  # a lock-held/reclaimed line, it just refuses.
  local UP_COUNT=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --count) UP_COUNT="${2:-1}"; shift 2 ;;
      --count=*) UP_COUNT="${1#--count=}"; shift ;;
      *) shift ;;
    esac
  done
  case "$UP_COUNT" in ''|*[!0-9]*) UP_COUNT=1 ;; esac
  [ "$UP_COUNT" -ge 1 ] || UP_COUNT=1
  if [ "$UP_COUNT" -gt "$BURST_MAX_BOXES" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  refused  (cause=max-boxes requested=$UP_COUNT max=$BURST_MAX_BOXES)"
    echo "up-refused: cause=max-boxes (requested=$UP_COUNT max=$BURST_MAX_BOXES)" >&2
    exit 3
  fi

  # PRD-build-burst-provision-forensics requirement 4: exactly one live
  # `up` per lane. Same fd-tied-to-process, refuse-fast pattern as
  # cmd_provision's 220 above (never a detached holder); a second `up`
  # while a prior one is still alive refuses instead of racing it (the
  # observed 2026-09-13 incident: 3 orphaned `up` processes doing apt work
  # against the box concurrently with a controlled provision). One lock
  # guards the WHOLE `--count N` loop below, not one per box — see
  # up_one_box()'s own header for why a second, genuinely concurrent `up`
  # invocation still serializes here rather than racing a sibling box
  # (a documented simplification, not the tech consideration's ideal).
  exec 221>"$UP_LOCK_FILE"
  if ! flock -n 221; then
    local holder_pid; holder_pid="$(up_lock_holder_pid)"
    local holder_desc; holder_desc="$(up_lock_holder_describe "$holder_pid")"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  up-refused  (lock-held $holder_desc)"
    echo "up-refused: lock held by $holder_desc" >&2
    exit 3
  fi
  # Requirement 4: up.pid's semantics change from "last successful up" to
  # "live up" — written only after the lock is taken, removed (via this
  # trap) whenever THIS invocation of `up` exits, on every exit path. A
  # stale value found here (the lock was free, so nobody holds it, but a
  # prior `up` died without going through a normal exit — a kill -9, say)
  # is reclaimed and journaled rather than silently overwritten.
  local prior_pid; prior_pid="$(cat "$UP_PID_FILE" 2>/dev/null || true)"
  case "$prior_pid" in
    ''|*[!0-9]*) : ;;
    *) kill -0 "$prior_pid" 2>/dev/null || journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  lock-reclaimed  (stale_pid=$prior_pid)" ;;
  esac
  echo "$$" > "$UP_PID_FILE" 2>/dev/null || true
  trap 'rm -f "$UP_PID_FILE" 2>/dev/null || true' EXIT
  printf '%s %s %s\n' "$(now_epoch)" "$$" "up" >> "$INFLIGHT_LOG" 2>/dev/null || true

  # requirement 2: one box per iteration, named "$SERVER_NAME-<n>". n=1
  # reuses whatever `current` already names (a real active box short-
  # circuits to "already-up" inside up_one_box exactly as the pre-count
  # single-box code always has — Goal 2, zero behavior change for a caller
  # that never passes --count). n>=2 always starts from a fresh empty
  # "pending" placeholder — `current` already names box 1 (or an older
  # session) by the time n=2 runs, and box 1's state must never be
  # overwritten by box 2's up_one_box call, which reads/writes exclusively
  # through box_path()'s "current"-relative globals (STATE_FILE,
  # COST_LEDGER, SERVED_FILE, ...).
  local _n _box_name _rc=0 _ready=0 _first_ready_id=""
  for _n in $(seq 1 "$UP_COUNT"); do
    _box_name="${SERVER_NAME}-${_n}"
    if [ "$_n" -gt 1 ]; then
      box_reset_pending
      # Artifact-only re-stamp (NOT a second flock — the fd 221 lock above
      # already guards this whole loop): box N's own up.lock/up.pid exist
      # once box_activate folds "pending" into boxes/<id>, satisfying AC2
      # ("each with its own ... up.lock") without a per-box mutex.
      echo "$$" > "$UP_PID_FILE" 2>/dev/null || true
      : > "$UP_LOCK_FILE" 2>/dev/null || true
      printf '%s %s %s\n' "$(now_epoch)" "$$" "up" >> "$INFLIGHT_LOG" 2>/dev/null || true
    fi
    if up_one_box "$_box_name"; then
      _ready=$((_ready + 1))
      [ -n "$_first_ready_id" ] || _first_ready_id="$(state_read server_id)"
    else
      _rc=$?
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  box-failed  (name=$_box_name n=$_n of=$UP_COUNT rc=$_rc)"
      break
    fi
  done
  # requirement 1/2: `current` names "the first ready one" (AC2) — box 2+
  # becoming ready must never steal it from box 1 (up_one_box's own
  # box_activate always repoints `current` to whichever box it just
  # finished, so the LAST-processed box is what `current` names when the
  # loop above ends; this restores it to the first).
  if [ -n "$_first_ready_id" ]; then
    box_point_current_at "$_first_ready_id"
  fi
  if [ "$UP_COUNT" -gt 1 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  count-done  (requested=$UP_COUNT ready=$_ready current=${_first_ready_id:-none})"
  fi
  [ "$_ready" -ge 1 ] && exit 0
  exit "${_rc:-3}"
}

# up_one_box <box_name>: get exactly one named box ready (adopt an existing
# hcloud server with this name, or create a fresh one) — the pre-
# PRD-build-burst-state-keyed-by-server-v2 body of cmd_up itself, unchanged
# in substance, parameterized by name instead of the (now singular-again-
# per-call) global SERVER_NAME, and using `return` instead of `exit` so
# cmd_up's `--count N` loop above can move on to the next box (or stop and
# report) instead of the whole process dying the moment ANY one box's
# fallback path fires. Concurrency note (requirement 2's tech
# consideration): a genuinely concurrent second `up --count` PROCESS still
# serializes on cmd_up's single up.lock above rather than racing this
# function on a different box in parallel — the PRD's "up.lock lives under
# the box directory so two callers don't serialize on one lock" ideal is
# NOT implemented by this step (that needs a name-keyed lock taken before
# the box's id is known, since `boxes/<id>/` doesn't exist yet); a single
# process's own `--count N` loop, which is what every caller in this repo
# actually uses, is unaffected by that gap — it never races itself.
up_one_box() {
  local SERVER_NAME="$1"

  # Requirement 5: reconcile the persistent-volume state file FIRST, before
  # even the already-up short-circuit below — an operator calling `up`
  # against a box that's still alive must still learn that its volume was
  # deleted out-of-band (2026-09-13: volume 106857883); the already-up fast
  # path returns before ever reaching volume_ensure, so this is the only
  # place in `up` guaranteed to run every single time. Side-effect only
  # (archive+journal); volume_ensure further down still does its own
  # by-name hcloud lookup regardless of what this finds.
  volume_reconcile || true

  # Requirement 2: reconcile session.json against hcloud reality next — an
  # absent server archives the file (session_reconcile) and this falls
  # straight through to the adoption/fresh-create path below exactly as if
  # no session.json had ever existed. A confirmed-alive server short-
  # circuits here, same as the old behavior.
  if state_active; then
    if session_reconcile; then
      echo "already-up: $(state_read server_id) $(state_read ip)"
      return 0
    fi
  fi

  # Adoption path: a session.json can be lost (crash, disk wipe) while the
  # server itself is still alive and billing — never double-create.
  local adopt; adopt="$(find_by_name "$SERVER_NAME" 2>/dev/null || true)"
  if [ -n "$adopt" ]; then
    local aid aip; aid="${adopt%% *}"; aip="${adopt##* }"
    box_activate "$aid"
    session_known_hosts_reset "$aid"
    box_bootstrap "$aip"
    volume_ensure "$aip" "$aid"
    local sbx; sbx="$(sandbox_probe "$aip")"
    provision_gate_tools "$aip"
    place_gate_credential "$aip"
    run_pending_reality_check_if_gate_ready
    : > "$SERVED_FILE"
    # PRD-build-burst-run-slots-from-box requirement 1: probe once, right
    # after gate tools are ready, same as the fresh-boot path below — an
    # adopted box (session.json lost, server still alive) gets its run-slot
    # cap sized from its own hardware exactly like a freshly-booted one.
    local box_cores="" box_mem_gb="" box_disk_gb="" box_probe_out
    if box_probe_out="$(probe_box_specs "$aip")"; then
      read -r box_cores box_mem_gb box_disk_gb <<<"$box_probe_out"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  box-probe  failed  (server_id=$aid)"
    fi
    # Requirement 9: no `server create` happened on this path (the box
    # already existed), so its true creation moment is unknown here — no
    # create_epoch is written and session_create_epoch()'s own fallback to
    # boot_epoch (set to "now", the adoption moment) applies, exactly as it
    # does for a pre-this-PRD session. That undercounts an adopted box's
    # true age, same as before this PRD; closing that gap needs an hcloud
    # server describe round trip and is left for a follow-up.
    state_write "server_id=$aid" "ip=$aip" "server_type=$SERVER_TYPE" \
      "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "ttl_hours=$DEFAULT_TTL_HOURS" \
      "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
      "teardown_scheduled=false" "teardown_epoch=" "remote_user=$REMOTE_USER" \
      "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING" \
      "box_cores=$box_cores" "box_mem_gb=$box_mem_gb" "box_disk_gb=$box_disk_gb" \
      "phase=setup" "phase_epoch=$(now_epoch)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  adopted  (server_id=$aid ip=$aip sandbox_ok=$sbx gate_ready=$GATE_READY)$(authz_journal_suffix)"
    # requirement 5: the slot-cap derivation, journaled once per session so
    # it's auditable without a separate `status` call.
    run_slot_cap
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  slots  (cap=$RUN_SLOT_CAP source=$RUN_SLOT_SOURCE bound=${RUN_SLOT_BOUND:-} cores=${box_cores:-} mem_gb=${box_mem_gb:-} disk_gb=${box_disk_gb:-})"
    # R6: after gate_ready=true, a CACHED canary-status check -- a non-pass
    # never fails `up` itself (the box is kept either way, per this
    # requirement's own wording), it only journals so dispatch is never
    # enabled blind; R6's "dispatch not enabled" is enforced by cmd_enable's
    # own canary check above, not by anything here.
    if [ "${GATE_READY:-false}" = "true" ]; then
      local up_canary_verdict; read -r up_canary_verdict _ <<<"$(canary_gate_check up)"
      [ "$up_canary_verdict" = "pass" ] || journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  canary-diverged  (verdict=$up_canary_verdict server_id=$aid)"
    fi
    # PRD-build-fail-loud-evidence-kept AC4: probe_run keeps cmd_verify's
    # stderr (was /dev/null); the verify-failed-after-adopt line below is
    # still this caller's own explicit branch (unchanged shape), now
    # alongside probe.sh's own additive `probe failed` line naming rc/err/log.
    probe_run verify -- cmd_verify >/dev/null 2>&1 || journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  verify-failed-after-adopt  (lane unverified — run falls back local)"
    local _adopt_image_id; read -r _adopt_image_id _ <<<"$(resolve_boot_image)"
    refresh_parity_baseline_on_image_change "$_adopt_image_id"
    schedule_session_parity "$aid"
    echo "already-up: $aid $aip (adopted)"
    return 0
  fi

  local pre_out; pre_out="$(precondition)"; local pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  fallback  (cause=precondition-failed: $pre_out)"
    echo "fallback: precondition failed - $pre_out"
    return 3
  fi

  # PRD-build-burst-dispatch-reenable requirement 2: resolve the image to
  # boot as snapshot.json -> SNAPSHOT_ID (env) -> DEFAULT_SNAPSHOT_ID (the
  # same three-tier precedence bake/up were designed around), and record
  # which tier won both for the journal and for provision_gate_tools'
  # bake-stale check just below.
  local image_id image_source
  read -r image_id image_source <<<"$(resolve_boot_image)"
  CURRENT_BOOT_IMAGE_SOURCE="$image_source"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  image  (id=$image_id source=$image_source)"

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
        --location "$LOCATION" --image "$image_id" --ssh-key "${HCLOUD_SSH_KEY:-default}" -o json 2>"$create_err")"; then
    local emsg; emsg="$(tail -3 "$create_err" 2>/dev/null | tr '\n' ' ')"; rm -f "$create_err"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  fallback  (cause=hcloud-server-create-failed: $emsg)"
    echo "fallback: hcloud server create failed - $emsg"
    return 3
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  fallback  (cause=could-not-parse-server-id)"
    echo "fallback: could not parse server id from hcloud output"
    return 3
  fi
  box_activate "$id"
  # Requirement 9 (PRD-build-burst-prove-forensics): Hetzner starts billing
  # the instant `server create` returns this id, not when `up` finishes
  # setup and writes boot_epoch below — snapshot it now so every cost/age
  # reader (minutes_alive, prove's cost line, watchdog/idle-guard, and the
  # ssh-unreachable early-exit just below) counts from the true start of the
  # billed hour. 2026-09-14: boxes 165737254/165738778 logged 0.0h each
  # against a started hour because nothing captured this moment.
  local create_epoch; create_epoch="$(now_epoch)"
  session_known_hosts_reset "$id"

  # Wait for ssh (bounded — never hang a tick forever). Hardcoded root@, not
  # $REMOTE_USER@ — on a truly fresh snapshot boot $REMOTE_USER (build) does
  # not exist yet, only root does; box_bootstrap below is what creates it.
  local tries=0
  while [ "$tries" -lt 30 ]; do
    if "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 $(ssh_kh_args) \
         -i "$SSH_KEY" "root@$ip" true >/dev/null 2>&1; then
      break
    fi
    tries=$((tries + 1)); sleep 1
  done
  if [ "$tries" -ge 30 ]; then
    # Requirement 9: this box billed from create_epoch even though it never
    # reached boot_epoch (no session.json was ever written) — journal the
    # same "down ... minutes=... cost_eur=..." shape teardown_and_delete
    # produces, and append the matching cost.jsonl row, so a provision that
    # fails before boot is never a silent 0.0h/eur gap in the ledger.
    local pf_minutes pf_eur
    pf_minutes=$(( ($(now_epoch) - create_epoch) / 60 ))
    pf_eur="$(awk -v m="$pf_minutes" -v r="$(cost_rate_eur "$SERVER_TYPE")" 'BEGIN{printf "%.4f", (m/60.0)*r}')"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  fallback  (cause=ssh-unreachable server_id=$id ip=$ip)"
    "$HCLOUD" server delete "$id" >/dev/null 2>&1 || true
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id cause=ssh-unreachable-before-boot minutes=$pf_minutes cost_eur=$pf_eur prds=none)"
    ledger_append "$(awk -v m="$pf_minutes" 'BEGIN{printf "%.4f", m/60.0}')" "$pf_eur" "$id"
    check_auto_disable
    echo "fallback: ssh never became reachable on $ip after 30s"
    return 3
  fi

  box_bootstrap "$ip"
  volume_ensure "$ip" "$id"
  local sbx; sbx="$(sandbox_probe "$ip")"
  provision_gate_tools "$ip"
  place_gate_credential "$ip"
  run_pending_reality_check_if_gate_ready
  : > "$SERVED_FILE"
  # PRD-build-burst-run-slots-from-box requirement 1: probe the box's own
  # cores/mem/disk once here (after gate tools are ready, over the same
  # bounded ssh helper the gate-tools probe uses) so run_slot_cap() can size
  # the run-slot table from what THIS box actually is, not a number in
  # .env. A failed probe leaves the three fields empty (run_slot_cap() then
  # falls back to source=default) rather than blocking `up` itself.
  local box_cores="" box_mem_gb="" box_disk_gb="" box_probe_out
  if box_probe_out="$(probe_box_specs "$ip")"; then
    read -r box_cores box_mem_gb box_disk_gb <<<"$box_probe_out"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  box-probe  failed  (server_id=$id)"
  fi
  state_write "server_id=$id" "ip=$ip" "server_type=$SERVER_TYPE" \
    "boot_ts=$(now_iso)" "boot_epoch=$(now_epoch)" "create_epoch=$create_epoch" \
    "ttl_hours=$DEFAULT_TTL_HOURS" \
    "hard_ttl_hours=$HARD_TTL_HOURS" "runs_served=0" "sandbox_ok=$sbx" \
    "teardown_scheduled=false" "teardown_epoch=" "remote_user=$REMOTE_USER" \
    "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING" \
    "box_cores=$box_cores" "box_mem_gb=$box_mem_gb" "box_disk_gb=$box_disk_gb" \
    "phase=setup" "phase_epoch=$(now_epoch)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  booted  (server_id=$id ip=$ip type=$SERVER_TYPE sandbox_ok=$sbx gate_ready=$GATE_READY remote_user=$REMOTE_USER)$(authz_journal_suffix)"
  # requirement 5: the slot-cap derivation, journaled once per session so
  # it's auditable without a separate `status` call.
  run_slot_cap
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  slots  (cap=$RUN_SLOT_CAP source=$RUN_SLOT_SOURCE bound=${RUN_SLOT_BOUND:-} cores=${box_cores:-} mem_gb=${box_mem_gb:-} disk_gb=${box_disk_gb:-})"
  # R6: see the matching comment on the adopt path above -- same cached
  # canary_gate_check, same "journal, never fail up" behavior.
  if [ "${GATE_READY:-false}" = "true" ]; then
    local up_canary_verdict; read -r up_canary_verdict _ <<<"$(canary_gate_check up)"
    [ "$up_canary_verdict" = "pass" ] || journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  canary-diverged  (verdict=$up_canary_verdict server_id=$id)"
  fi
  # PRD-build-fail-loud-evidence-kept AC4: same probe_run conversion as
  # the adopt path above.
  probe_run verify -- cmd_verify >/dev/null 2>&1 || journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  verify-failed-after-boot  (lane unverified — run falls back local)"
  if [ "$sbx" = false ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  up  sandbox-unavailable  (server_id=$id — rust selection falls back to local cap for python-kind sandboxed tests this tick)"
  fi
  refresh_parity_baseline_on_image_change "$image_id"
  schedule_session_parity "$id"
  echo "up: $id $ip"
  return 0
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
  # PRD-build-fail-loud-evidence-kept AC4: this rsync roundtrip's own
  # stderr used to be discarded to /dev/null before `vfail` ever saw it —
  # the "verify-failed" journal lines named zero cause. probe_run keeps
  # rsync's real stderr under a kept log and journals it by name; `vfail`
  # still runs unconditionally on failure so the existing fails-count/exit
  # contract is unchanged.
  probe_run verify-rsync -- "$RSYNC_BIN" -az --delete --rsync-path="mkdir -p '$rpath' && rsync" \
      -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
      "$fx/" "$REMOTE_USER@$ip:$rpath/" >/dev/null 2>&1 || vfail "rsync roundtrip (user=$REMOTE_USER)"
  rm -rf "$fx"

  # PRD-build-burst-unprivileged-user requirement 2/4: cargo/uv/python3 all
  # probed as $REMOTE_USER — RUSTUP_HOME points at root's shared, read-only
  # toolchain (requirement 2) regardless of who's asking, so that half is a
  # no-op for the REMOTE_USER=root rollback. CARGO_HOME (PRD-build-burst-
  # path-deps requirement 5) is now $RUN_CARGO_HOME — build's own writable
  # registry cache, not root's — see the registry-writability check below
  # for the check this PRD actually adds; this probe only proves `cargo`
  # itself runs under that CARGO_HOME, not that it can write.
  local rout
  rout="$("$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$RUN_CARGO_HOME; cargo --version && uv --version && python3 -c \"print(1)\"" 2>/dev/null)"
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
  "$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "mkdir -p '$REMOTE_SCCACHE_DIR' && [ -d '$REMOTE_SCCACHE_DIR' ]" >/dev/null 2>&1 \
    || vfail "sccache dir ($REMOTE_SCCACHE_DIR)"

  # PRD-build-burst-path-deps requirement 5 / AC3: CARGO_HOME must resolve
  # to a location the build user actually owns, with a writable registry
  # cache — the exact write race this PRD closes (root's shared registry,
  # chmod'd read+execute only, raced the first parallel dependency fetch
  # until an operator chmod'd it by hand, 2026-09-11). Fails closed, naming
  # the path, rather than a bare "verify FAIL" an operator has to go dig for.
  if [ "$REMOTE_USER" != "root" ] && [[ "$RUN_CARGO_HOME" == /root* ]]; then
    vfail "CARGO_HOME resolves under /root ($RUN_CARGO_HOME) — build user needs its own registry cache"
  elif "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE_USER@$ip" \
    "$(printf '%s\nmkdir -p '"'"'%s/registry'"'"' && touch '"'"'%s/registry/.burst-lane-write-test'"'"' && rm -f '"'"'%s/registry/.burst-lane-write-test'"'"'\n' \
       "# cargo-home-registry-probe" "$RUN_CARGO_HOME" "$RUN_CARGO_HOME" "$RUN_CARGO_HOME")" >/dev/null 2>&1
  then
    echo "cargo-home ok ($RUN_CARGO_HOME writable by $REMOTE_USER)"
  else
    vfail "CARGO_HOME registry not writable by $REMOTE_USER at $RUN_CARGO_HOME/registry"
  fi

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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  verify  gate-tools-missing  (missing=${gt_missing:-unknown})"
  fi

  if [ "$fails" -gt 0 ]; then
    probe_emit burst-verify dirty "$fails check(s) failed — lane stays unverified, all work falls back local" >/dev/null
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  verify  FAILED  ($fails check(s) — lane stays unverified, all work falls back local)"
    exit 1
  fi
  state_write "server_id=$(state_read server_id)" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "create_epoch=$(state_read create_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$(state_read runs_served)" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" \
    "remote_user=$(state_read remote_user)" \
    "gate_ready=$gt_ready" "gate_tools_missing=$gt_missing" \
    "box_cores=$(state_read box_cores)" "box_mem_gb=$(state_read box_mem_gb)" \
    "box_disk_gb=$(state_read box_disk_gb)" \
    "verified=true" "phase=$(state_read_phase)" "phase_epoch=$(state_read phase_epoch)"
  probe_emit burst-verify clean "rsync+cargo+uv+python3+sandbox all real" >/dev/null
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  verify  ok  (rsync+cargo+uv+python3+sandbox all real)"
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
  out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
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
    if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
         "mkdir -p '$new_remote_path' && cp -a '$old_remote_path/.' '$new_remote_path/' 2>/dev/null; rc=\$?; chown -R '$REMOTE_USER:$REMOTE_USER' '$new_remote_path' 2>/dev/null || true; exit \$rc" >/dev/null 2>&1; then
      mark_dirty "$wt" "$(state_read server_id)" "$new_remote_path" "$kind"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  migrated  (worktree=$wt from=$old_remote_path to=$new_remote_path)"

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
        if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" "root@$ip" \
             "rm -rf '$old_remote_path'" >/dev/null 2>&1; then
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  migrated-removed  (from=$old_remote_path)"
        else
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  migrate-keep  (cause=remove-failed from=$old_remote_path)"
        fi
      else
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  migrate-keep  (cause=copy-mismatch from=$old_remote_path old_bytes=$old_bytes new_bytes=$new_bytes old_count=$old_count new_count=$new_count)"
      fi
    else
      clear_dirty "$wt"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  migrate-cold  (worktree=$wt cause=copy-failed old=$old_remote_path new=$new_remote_path)"
    fi
  done
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  user-migrated  (server_id=$(state_read server_id) from=$prior_user to=$REMOTE_USER)"
}

# ---- provision --------------------------------------------------------------
# PRD-build-burst-gate-tools-scope requirement 4: retry every missing gate
# tool's install on the LIVE box and re-run the gate-tools check, without a
# reboot — an operator who fixed whatever blocked an install (a flaky apt
# mirror, a since-corrected autobuilder build on RedBaron) shouldn't have to
# tear a healthy, verified box down and burn another `up` cycle just to pick
# up gate readiness.
cmd_provision() {
  # PRD-build-burst-provision-forensics requirement 4: exactly one
  # provision per lane at a time. flock'd on fd 220, tied to THIS
  # process's own lifetime (never a detached holder) — the fd, and the
  # lock with it, closes the instant this process exits by any path.
  exec 220>"$PROVISION_LOCK_FILE"
  if ! flock -n 220; then
    local holder_pid; holder_pid="$(cat "$PROVISION_PID_FILE" 2>/dev/null || true)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  provision-refused  (lock-held pid=${holder_pid:-unknown})"
    echo "provision-refused: lock held by pid=${holder_pid:-unknown}" >&2
    exit 1
  fi
  echo "$$" > "$PROVISION_PID_FILE" 2>/dev/null || true
  printf '%s %s %s\n' "$(now_epoch)" "$$" "provision" >> "$INFLIGHT_LOG" 2>/dev/null || true

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
  # Requirement 1: provision is the ONLY place a session leaves phase=setup
  # under its own steam — success moves it to phase=provisioned (grace no
  # longer applies, same as always having been provisioned), failure moves
  # it to phase=failed (also grace-exempt: a box that just failed to
  # provision is immediately eligible for autonomous teardown, never made
  # to wait out the rest of a setup window it has already proven it won't
  # use). A session already past "setup" (a re-provision retrying missing
  # gate tools) just re-stamps the same outcome — never re-enters setup.
  local new_phase; [ "$GATE_READY" = "true" ] && new_phase="provisioned" || new_phase="failed"
  state_write "server_id=$(state_read server_id)" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "create_epoch=$(state_read create_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$(state_read runs_served)" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" \
    "verified=$(state_read verified)" "remote_user=$REMOTE_USER" \
    "gate_ready=$GATE_READY" "gate_tools_missing=$GATE_TOOLS_MISSING" \
    "box_cores=$(state_read box_cores)" "box_mem_gb=$(state_read box_mem_gb)" \
    "box_disk_gb=$(state_read box_disk_gb)" \
    "phase=$new_phase" "phase_epoch=$(now_epoch)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  provision  done  (server_id=$(state_read server_id) gate_ready=$GATE_READY gate_tools_missing=${GATE_TOOLS_MISSING:-none} remote_user=$REMOTE_USER per_tool_rc=\"${GATE_TOOLS_RC_SUMMARY:-}\" phase=$new_phase)"
  echo "provision: gate_ready=$GATE_READY missing=${GATE_TOOLS_MISSING:-} per_tool_rc=\"${GATE_TOOLS_RC_SUMMARY:-}\""
  [ "$GATE_READY" = "true" ] && exit 0
  exit 1
}

# ---- status -----------------------------------------------------------------
# Requirement 9 (PRD-build-burst-prove-forensics): Hetzner bills from server
# CREATION, not from `up booted` — a box that dies mid-setup (before
# boot_epoch is ever written, or minutes before it) still owes the started
# hour. Every cost/age reader below counts from create_epoch; sessions
# written before this PRD (or adopted, where the true creation moment is
# unknown to this lane) have no create_epoch and fall back to boot_epoch,
# matching their pre-existing behavior exactly.
session_create_epoch() {
  local ce; ce="$(state_read create_epoch)"
  case "$ce" in
    ''|*[!0-9]*) state_read boot_epoch ;;
    *) echo "$ce" ;;
  esac
}

minutes_alive() {
  local base_epoch; base_epoch="$(session_create_epoch)"
  [ -n "$base_epoch" ] || { echo 0; return; }
  echo $(( ( $(now_epoch) - base_epoch ) / 60 ))
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  if ! state_active; then
    probe_emit burst-status clean "no active session" >/dev/null
    # requirement 6: image/bake/proof/enabled are session-independent —
    # reported in --json here (status_json_with_extras). NOT wired into
    # text mode: the cargo/uv shims (burst-lane-bin/cargo, burst-lane-bin/
    # uv) both do `[ "$status_out" != "no active session" ]` — a byte-exact
    # WHOLE-OUTPUT comparison, not a first-line one — so appending even a
    # second line here flips every no-session shim call to "route to
    # burst" (caught by this PRD's own regression pass). Text-mode wiring
    # (status_extra_fields_line, already written) needs those two shims
    # changed to a first-line comparison first — left for a later step of
    # this PRD rather than risked here.
    if [ "$json" -eq 1 ]; then
      status_json_with_extras '{"active":false}'
    else
      echo "no active session"
    fi
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  status  could-not-check  (session.json corrupted at $STATE_FILE — treating as no active session, falling back local)"
    if [ "$json" -eq 1 ]; then
      status_json_with_extras '{"active":false,"could_not_check":true}'
    else
      echo "could-not-check: session.json corrupted — treating as no active session"
    fi
    exit 0
  fi
  # Requirement 4/AC6: verify the session's server against hcloud before
  # reporting anything as active. An absent server archives session.json
  # (session_reconcile, same helper `up` uses) and status reports
  # active:false + server_verified:false — never the stale truth an out-of-
  # band `hcloud server delete` left behind (2026-09-13 incident).
  if ! session_reconcile; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  status  session-stale  (archived session.json — reporting active:false)"
    if [ "$json" -eq 1 ]; then
      status_json_with_extras '{"active":false,"server_verified":false}'
    else
      echo "active:false server_verified:false — session.json archived (server absent from hcloud)"
    fi
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
    # PRD-build-burst-pull-remote-target-missing requirement 6: always
    # present, even for a marker that has never failed yet (migration note —
    # "old markers without these read as 0/false") rather than only showing
    # up once a failure has actually written them.
    d.setdefault("attempts", 0)
    d.setdefault("next_retry_epoch", 0)
    d.setdefault("stuck", False)
    d.setdefault("last_err", "")
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
  # Requirement 5/AC7: verify volume.json's own volume_id against hcloud
  # before trusting/reporting it — an out-of-band `hcloud volume delete`
  # (2026-09-13: volume 106857883) must never leave `status` still claiming
  # a mount. volume_reconcile archives the file itself when stale;
  # volume_verified reflects that outcome (true also when no volume is
  # tracked at all — vacuously nothing to falsify).
  local volume_verified=true
  volume_reconcile || volume_verified=false

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

  # PRD-build-burst-run-slots-from-box requirement 4: run_slots.cap/source
  # straight from the same run_slot_cap() acquire_run_slot and cmd_sub_cap
  # use — held is $conc's own numerator (count_held_slots already calls
  # run_slot_cap() itself, so the two can never disagree about the cap).
  run_slot_cap
  local run_slots_held="${conc%%/*}"
  case "$run_slots_held" in ''|*[!0-9]*) run_slots_held=0 ;; esac
  # AC4: "bound" (which term won the min — mem/cpu/disk, empty for
  # source=env|default where no box arithmetic ran) is additive to
  # requirement 4's own {cap, held, source, box_cores, box_mem_gb,
  # box_disk_gb} shape — it's how a caller reads "the disk term as the
  # binding one" from `status` without re-deriving the formula itself.
  local run_slots_json
  run_slots_json="$(printf '{"cap":%s,"held":%s,"source":"%s","bound":"%s","box_cores":%s,"box_mem_gb":%s,"box_disk_gb":%s}' \
    "$RUN_SLOT_CAP" "$run_slots_held" "$RUN_SLOT_SOURCE" "$RUN_SLOT_BOUND" \
    "${RUN_SLOT_BOX_CORES:-null}" "${RUN_SLOT_BOX_MEM_GB:-null}" "${RUN_SLOT_BOX_DISK_GB:-null}")"

  # PRD-build-burst-teardown-evidence requirement 8/AC9: next_teardown is a
  # pure preview — teardown_decision's own --dry-run mode, which writes
  # neither decisions.jsonl nor the journal, so polling `status` never spams
  # either trail.
  local nt_out nt_decision nt_cause nt_eta
  nt_out="$(teardown_decision "$id" status --dry-run)"
  nt_decision="$(sed -n 's/^decision=//p' <<<"$nt_out")"
  nt_cause="$(sed -n 's/^cause=//p' <<<"$nt_out")"
  nt_eta="$(sed -n 's/^eta_s=//p' <<<"$nt_out")"
  local next_teardown_json
  next_teardown_json="$(printf '{"decision":"%s","cause":"%s","eta_s":%s}' "$nt_decision" "$nt_cause" "${nt_eta:-null}")"

  if [ "$json" -eq 1 ]; then
    # PRD-build-burst-state-keyed-by-server-v2 requirement 7: a per-box
    # breakdown (boxes) and a summed totals object, so a caller never has
    # to shell out to `cost --today` merely to see how many boxes are up
    # and what each is doing. Built AFTER every single-box field above
    # already computed (run_slots_json, next_teardown_json, ...) so it
    # never disturbs how they read `current`'s own globals; box_context is
    # explicitly restored to `current`'s own id ($id, captured above at the
    # top of cmd_status) immediately after this loop, before
    # status_json_with_extras below touches any BOX_STATE_DIR-relative
    # global again (its proof/bake reads are per-box — requirement 1's own
    # classification of proof.json/prove.inflight — and must keep reading
    # `current`, not whichever box this loop last visited).
    local box_args=() bid b_type b_runs b_held_cap b_held b_cap b_age b_eur
    while IFS= read -r bid; do
      [ -n "$bid" ] || continue
      box_context "$bid"
      b_type="$(state_read server_type)"
      b_runs="$(state_read runs_served)"; case "$b_runs" in ''|*[!0-9]*) b_runs=0 ;; esac
      b_held_cap="$(count_held_slots)"
      b_held="${b_held_cap%%/*}"; b_cap="${b_held_cap##*/}"
      b_age="$(minutes_alive)"
      b_eur="$(python3 -c '
import json, sys
eur = 0.0
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("kind") == "slug":
                continue
            eur += float(d.get("eur", 0) or 0)
except OSError:
    pass
print(f"{eur:.4f}")
' "$COST_LEDGER" 2>/dev/null)"
      case "$b_eur" in ''|*[!0-9.]*) b_eur=0 ;; esac
      box_args+=("$bid" "$b_type" "$b_runs" "$b_held" "$b_cap" "$b_age" "$b_eur")
    done < <(list_active_box_ids)
    box_context "$id"
    local boxes_json totals_json
    boxes_json="$(python3 -c '
import json, sys
rows = sys.argv[1:]
out = []
for i in range(0, len(rows), 7):
    sid, stype, runs, held, cap, age, eur = rows[i:i + 7]
    out.append({
        "server_id": sid, "server_type": stype, "ready": True,
        "runs_served": int(runs), "held": int(held), "cap": int(cap),
        "age_min": int(age), "eur": round(float(eur), 4),
    })
print(json.dumps(out, separators=(",", ":")))
' "${box_args[@]}")"
    totals_json="$(python3 -c '
import json, sys
boxes = json.loads(sys.argv[1])
totals = {
    "boxes": len(boxes),
    "held": sum(b["held"] for b in boxes),
    "cap": sum(b["cap"] for b in boxes),
    "eur": round(sum(b["eur"] for b in boxes), 4),
}
print(json.dumps(totals, separators=(",", ":")))
' "$boxes_json")"
    local status_base
    status_base="$(printf '{"active":true,"server_verified":true,"server_id":"%s","ip":"%s","minutes_alive":%s,"ttl_hours":"%s","sandbox_ok":"%s","concurrent":"%s","run_slots":%s,"free_disk_gb":%s,"disk_state":"%s","dirty":%s,"gates":%s,"gate_ready":"%s","gate_tools_missing":"%s","volume":%s,"volume_verified":%s,"redbaron_free_gb":%s,"parity":%s,"next_teardown":%s,"boxes":%s,"totals":%s}' \
      "$id" "$ip" "$alive" "$ttl" "$sbx" "$conc" "$run_slots_json" "$free_disk_gb" "$disk_state" "$dirty_json" "$gates_json" "$(state_read gate_ready)" "$(state_read gate_tools_missing)" "$vol_json" "$volume_verified" "$redbaron_free_gb" "$parity_json" "$next_teardown_json" "$boxes_json" "$totals_json")"
    status_json_with_extras "$status_base"
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
    status_extra_fields_line
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

# ---- route-check (PRD-build-gate-cargo-route-attest; self-heal +
#      hard-fail added by PRD-build-cargo-route-precedence) ------------------
# Attests whether a `cargo` call made under the CURRENT $PATH — the same
# $PATH a cargo-invoking producer inherits from its caller — would actually
# reach the correct entry point (cargo-budget-bin/cargo, or burst-lane-
# bin/cargo — see cargo-route.sh's cargo_route_path_prefix(): BOTH are
# "clean" when burst is configured, since cargo-budget-bin now chains to
# the burst shim internally) or silently fall straight through to a real
# cargo ahead of them on PATH (the 2026-09-10 defect: extend-gate.sh
# re-prepending $HOME/.cargo/bin ahead of an already-armed shim; recurred
# 2026-09-15 as a legacy-flag/policy drift: 166 route=local vs 49
# route=burst in one day while a box was actually up). `intended` mirrors
# extend-gate.sh's own definition: burst iff `status --json` reports an
# active session RIGHT NOW; local otherwise. `resolved` is `command -v
# cargo` under THIS process's own $PATH. `state`:
#   clean            burst not configured (nothing this probe polices —
#                     no journal lines at all), OR intended=local, OR
#                     resolved already lands in the correct chain.
#   healed            intended=burst, resolved was NOT in the correct
#                     chain, but prepending cargo_route_path_prefix()
#                     would fix it (the shim exists, just shadowed) —
#                     journaled ONCE per gate (dedup on $BURST_ROUTE_LOG's
#                     own content, truncated fresh per gate), never fatal.
#   mismatch          intended=burst, resolved is wrong, AND self-heal
#                     couldn't fix it either (the shim itself is
#                     missing/broken, not just shadowed) — journaled
#                     UNCONDITIONALLY to the shared burst-lane journal
#                     (never only under $BURST_ROUTE_LOG), and this
#                     function exits 9 (documented, distinct from every
#                     other burst-lane.sh subcommand's exit code) so a
#                     caller (extend-gate.sh) refuses before any producer
#                     runs instead of proceeding to a misleading local
#                     verdict.
#   could-not-check   no cargo resolves on $PATH at all.
# On mismatch (only), also appends one synthetic route-log line
# (decision=local cause=shim-not-first) to $BURST_ROUTE_LOG when that env
# var is set, so a caller scanning the route log for local-decision causes
# (extend-gate.sh's own postcondition) still sees this failure mode even
# though the shim itself never ran to log anything about itself. Emits the
# shared three-state probe `gate-cargo-route` (dirty for mismatch — the
# library only knows clean/dirty/could-not-check; "mismatch" is this
# probe's own name for its dirty state, named in the printed line and
# journal below; "healed" still emits probe state clean — it is not a
# guard event by the time this function returns, the route DID resolve).
cmd_route_check() {
  local repo="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:?route-check: --repo needs a value}"; shift 2 ;;
      *) echo "usage: burst-lane.sh route-check [--repo <path>]" >&2; exit 2 ;;
    esac
  done

  # shellcheck disable=SC1091
  if [ -r "$HERE/lib/cargo-route.sh" ]; then
    source "$HERE/lib/cargo-route.sh"
  else
    burst_configured() { return 1; }
    cargo_route_path_prefix() { printf '%s' "$HERE/cargo-budget-bin"; }
  fi

  local shim="$HERE/burst-lane-bin/cargo"
  local status_json intended="local"
  status_json="$("$0" status --json 2>/dev/null || true)"
  case "$status_json" in *'"active":true'*) intended="burst" ;; esac

  local resolved resolved_dir
  resolved="$(command -v cargo 2>/dev/null || true)"
  resolved_dir=""
  [ -n "$resolved" ] && resolved_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P || true)"

  # Nothing configured at all -> this probe has no policy to check against
  # (test-suite AC "burst not configured -> no route lines"): never
  # journals, never emits the probe, always clean.
  if ! burst_configured; then
    printf 'route: intended=%s resolved=%s shim=%s state=clean\n' \
      "$intended" "${resolved:-none}" "$shim"
    exit 0
  fi

  local prefix; prefix="$(cargo_route_path_prefix)"
  # _route_check_is_chain_dir <dir> -> rc0 if <dir> resolves to one of the
  # dirs cargo_route_path_prefix() names (cargo-budget-bin always;
  # burst-lane-bin too, since burst is configured in this branch) — either
  # is "clean": cargo-budget-bin now chains internally to the burst shim
  # (PRD-build-cargo-route-precedence requirement 1), so a caller resolving
  # straight to cargo-budget-bin is exactly as correct as resolving
  # straight to burst-lane-bin.
  _route_check_is_chain_dir() {
    local d="$1" want saved_ifs
    [ -n "$d" ] || return 1
    saved_ifs="$IFS"; IFS=:
    for want in $prefix; do
      IFS="$saved_ifs"
      [ -n "$want" ] || continue
      want="$(cd "$want" 2>/dev/null && pwd -P || true)"
      if [ -n "$want" ] && [ "$d" = "$want" ]; then IFS="$saved_ifs"; return 0; fi
    done
    IFS="$saved_ifs"
    return 1
  }

  local state cause=""
  if [ -z "$resolved" ]; then
    state="could-not-check"
  elif [ "$intended" = "burst" ] && ! _route_check_is_chain_dir "$resolved_dir"; then
    state="mismatch"; cause="shim-not-first"
  else
    state="clean"
  fi

  if [ "$state" = "mismatch" ]; then
    # --- self-heal (requirement 3): would prepending the SAME prefix a
    # correctly-armed caller uses actually resolve cargo into the correct
    # chain? This never mutates the CALLER's own $PATH — route-check runs
    # as a separate process (see cargo-route.sh's own header) — it only
    # distinguishes a healable shadow (the shim exists, just behind
    # something else on $PATH) from a genuinely missing/broken shim.
    local healed_resolved healed_dir
    healed_resolved="$(PATH="$prefix:$PATH" command -v cargo 2>/dev/null || true)"
    healed_dir=""
    [ -n "$healed_resolved" ] && healed_dir="$(cd "$(dirname "$healed_resolved")" 2>/dev/null && pwd -P || true)"
    if [ -n "$healed_dir" ] && _route_check_is_chain_dir "$healed_dir"; then
      state="healed"
    fi
  fi

  case "$state" in
    clean)
      probe_emit gate-cargo-route clean "intended=$intended resolved=${resolved:-none}" >/dev/null
      ;;
    healed)
      # Journaled once per gate: dedup by checking whether THIS gate's own
      # route log ($BURST_ROUTE_LOG, truncated fresh per gate per
      # PRD-build-gate-cargo-route-attest requirement 2) already carries a
      # "route healed" line before writing another.
      if [ -z "${BURST_ROUTE_LOG:-}" ] || [ ! -f "$BURST_ROUTE_LOG" ] \
         || ! grep -q 'route healed' "$BURST_ROUTE_LOG" 2>/dev/null; then
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  route  healed  (intended=$intended resolved=${resolved:-none} shim=$shim cause=shim-not-first repo=$repo)"
      fi
      if [ -n "${BURST_ROUTE_LOG:-}" ]; then
        mkdir -p "$(dirname "$BURST_ROUTE_LOG")" 2>/dev/null || true
        (
          flock -w 2 206 2>/dev/null || exit 0
          printf '%s %s - route healed shim-not-first %s\n' "$(now_iso)" "$$" "$repo" >&206
        ) 206>>"$BURST_ROUTE_LOG" 2>/dev/null || true
      fi
      probe_emit gate-cargo-route clean "intended=$intended healed resolved=${resolved:-none}" >/dev/null
      ;;
    mismatch)
      # Requirement 3: "never silent" — unconditional, regardless of
      # whether the caller set $BURST_ROUTE_LOG.
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  route  mismatch  (intended=$intended resolved=${resolved:-none} shim=$shim cause=$cause caller=burst-lane.sh:route-check repo=$repo)"
      if [ -n "${BURST_ROUTE_LOG:-}" ]; then
        mkdir -p "$(dirname "$BURST_ROUTE_LOG")" 2>/dev/null || true
        (
          flock -w 2 205 2>/dev/null || exit 0
          printf '%s %s - local %s %s\n' "$(now_iso)" "$$" "$cause" "$repo" >&205
        ) 205>>"$BURST_ROUTE_LOG" 2>/dev/null || true
      fi
      probe_emit gate-cargo-route dirty "route-mismatch intended=$intended resolved=${resolved:-none} shim=$shim cause=$cause" >/dev/null
      ;;
    could-not-check)
      probe_emit gate-cargo-route could-not-check "no cargo resolved on \$PATH" >/dev/null
      ;;
  esac

  printf 'route: intended=%s resolved=%s shim=%s state=%s%s\n' \
    "$intended" "${resolved:-none}" "$shim" "$state" "${cause:+ cause=$cause}"

  # Exit code contract (documented here, the only place this rc is
  # produced): 9 = unhealable route mismatch, refused before self-heal
  # could fix it — every other state exits 0.
  if [ "$state" = "mismatch" ]; then
    exit 9
  fi
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
pull_target_incremental() {  # $1=worktree $2=ip [$3=remote_path] -> stdout: bytes transferred; rc 0=ok 1=real failure 2=remote target missing (cold, prints REMOTE_TARGET_MISSING)
  local worktree="$1" ip="$2" remote_path stats local_target remote_target override rc
  # PRD-build-burst-path-deps-workspaces requirement 1: a workspace member's
  # remote_path is keyed by its SYNC ROOT, not the worktree itself (see
  # cmd_run) — recomputing remote_path_for(worktree) fresh here would look
  # in a directory `run` never actually synced to. $3, when passed, is the
  # caller's own already-resolved value (do_marker_pull reads it straight off
  # the dirty marker's own recorded "remote_path" field, the authoritative
  # source); recomputing here remains the fallback for any caller that still
  # only knows the worktree (byte-identical to today for a non-workspace run,
  # where sync_root always equals the worktree itself).
  remote_path="${3:-$(remote_path_for "$worktree")}"
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
  stats="$("$RSYNC_BIN" -az --delete --stats --exclude autobuilder -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_target/" "$local_target/" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # requirement 1/7: rsync's rc 23 (occasionally 12) carrying its own
    # "change_dir ... failed: No such file or directory" text is raised both
    # when the SOURCE directory (remote_target) never existed at all (a
    # routed run that produced no target/ — this PRD's whole grounding) and,
    # in principle, by any other vanished-subpath partial-transfer error —
    # so, ordered AFTER the one rsync attempt (Technical considerations:
    # keep the happy path at one round trip — AC9), confirm directly
    # against the box before ever calling this "nothing was built" rather
    # than a retryable failure.
    case "$rc" in
      23|12)
        if printf '%s\n' "$stats" | grep -qE 'change_dir ".*" failed: No such file or directory' \
            && ! remote_dir_exists "$ip" "$remote_target"; then
          echo "REMOTE_TARGET_MISSING"
          return 2
        fi
        ;;
    esac
    # A caller invoked through command substitution (do_marker_pull below)
    # runs this whole function in a SUBSHELL — a plain global variable
    # assignment here would never escape it, so the rc + full stderr ride
    # back the one channel that DOES survive `$(...)`: stdout itself,
    # rc on its own first line, the rest verbatim. cmd_sync_back's older
    # caller only ever checks `! bytes=$(...)` for failure and never reads
    # this payload, so it is unaffected either way.
    printf '%s\n' "$rc"
    printf '%s\n' "$stats"
    return 1
  fi
  local bytes; bytes="$(echo "$stats" | grep -oE 'Total transferred file size: [0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')"
  echo "${bytes:-0}"
  return 0
}

# rc-classified cause for a real (non-cold) rsync-down failure's journal line
# (requirement 7). 23/12 paired with "change_dir ... No such file" is
# resolved to remote-target-missing INSIDE pull_target_incremental (rc2,
# never reaches here) — anything landing here is a genuine transfer failure.
rsync_failure_cause() {  # $1=rc -> stdout cause
  case "$1" in
    255) echo "ssh-failed" ;;
    30) echo "timeout" ;;
    12) echo "protocol" ;;
    *) echo "rsync-failed" ;;
  esac
}

# Exponential backoff schedule for `local-read` pull retries (requirement 3):
# base * 2^(attempts-1), capped. attempts is the count AFTER the failure
# that's about to be journaled (first failure -> attempts=1 -> base delay).
pull_backoff_delay_s() {  # $1=attempts(>=1) -> stdout delay seconds
  local attempts="${1:-1}" base cap delay
  case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac
  base="$BURST_PULL_BACKOFF_BASE_S"; cap="$BURST_PULL_BACKOFF_CAP_S"
  delay=$(( base * (1 << (attempts - 1)) ))
  [ "$delay" -gt "$cap" ] && delay="$cap"
  printf '%s\n' "$delay"
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
  if ! stats="$("$RSYNC_BIN" -az --delete --stats -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
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
#
# PRD-build-burst-path-deps requirement 3: an optional $13=phase ("build" or
# "test") rides into a kind="run" row so the cost ledger records which class
# of failure (if any) a run hit, alongside the journal's own build-failed/
# routed distinction below — omitted from the JSON row entirely when empty
# (a successful run, or any pre-existing caller that never passes it),
# never written as a literal empty string. Kept as its own trailing
# positional (after persistent-volume's $12=warm, not in place of it) —
# the two land the same tick and describe unrelated things (warm: did the
# target dir already exist; phase: did this run fail before or after tests
# started), so both ride the same row rather than one displacing the other.
attribution_record() {  # $1=slug $2=session_id $3=wall_s $4=sync_s $5=bytes $6=worktree [$7=kind $8=pulls_skipped $9=bytes_saved $10=estimate $11=trigger $12=warm $13=phase]
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local kind="${7:-run}" pulls_skipped="${8:-0}" bytes_saved="${9:-0}" estimate="${10:-false}" trigger="${11:-}" warm="${12:-}" phase="${13:-}"
  python3 -c '
import json, sys
slug, sid, wall_s, sync_s, nbytes, worktree, date, path, kind, pulls_skipped, bytes_saved, estimate, trigger, warm, phase = sys.argv[1:16]
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
    if phase:
        row["phase"] = phase
with open(path, "a") as fh:
    fh.write(json.dumps(row) + "\n")
' "$1" "$2" "$3" "$4" "$5" "$6" "$(now_iso)" "$ATTR_LEDGER" "$kind" "$pulls_skipped" "$bytes_saved" "$estimate" "$trigger" "$warm" "$phase"
}

# ---- run --------------------------------------------------------------------
RUN_LOCK="$BOX_STATE_DIR/run.lock"

# PRD-build-burst-parallel-runs: remote dirs are disjoint PER LOCAL PATH, not
# per basename — ~/repos/synthorg and a worktree both named "synthorg" must
# never share (and --delete-shred) one remote dir. Every sync site derives
# the remote path from this one helper.
remote_path_for() {  # $1=worktree -> stdout remote dir
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/%s-%s\n' "$REMOTE_ROOT" "$(basename "$1")" "$wkey"
}

# PRD-build-burst-path-deps requirement 2: a path dependency's own stable
# remote location — same hash-keyed convention as remote_path_for() (so a
# dep synced by two different worktrees this run shares one copy, and reap
# can find it the same way it finds a worktree's own remote dir), but under
# a distinct deps/ subtree so a dep is never confused for a worktree of its
# own by anything scanning $REMOTE_ROOT's immediate children (reap, the
# rust-work-remains scan in `down`).
dep_remote_path_for() {  # $1=dep local abs dir -> stdout remote dir
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/deps/%s-%s\n' "$REMOTE_ROOT" "$(basename "$1")" "$wkey"
}
worktree_lock_key() { printf '%s' "$1" | sha1sum | cut -c1-16; }
wt_lock_file() { printf '%s/locks/wt-%s.lock\n' "$BOX_STATE_DIR" "$(worktree_lock_key "$1")"; }

# ---- workspace detection (PRD-build-burst-path-deps-workspaces req 1) -----
# `run`'s local read of the crate's own workspace_root, via a real `cargo
# metadata --no-deps` (the PRD's own explicit choice — `--no-deps` is enough
# to learn workspace_root/workspace_members without paying for a full
# dependency-graph resolve on every single `run`). Fails OPEN (empty stdout)
# on anything short of a clean parse: no Cargo.toml, no local cargo, a
# metadata error, or malformed JSON — a probe hiccup must never block a run
# that a bare non-workspace-aware sync would still have handled correctly
# (today's unchanged behavior when this returns empty). Deliberately reads
# LOCALLY (never over ssh) — the worktree's own manifest is right here, and
# reading it before the sync means the sync layout below can be decided
# before a single byte moves.
# BURST_LANE_FAKE_WORKSPACE_ROOT is the offline-test seam (mirrors every
# other BURST_LANE_*-style override here, e.g. BURST_LANE_NOW) — a real
# `cargo metadata` never runs under it.
workspace_root_for() {  # $1 = crate dir (containing Cargo.toml) -> stdout: workspace_root or empty
  local dir="$1"
  [ -f "$dir/Cargo.toml" ] || { echo ""; return 0; }
  if [ -n "${BURST_LANE_FAKE_WORKSPACE_ROOT+x}" ]; then
    echo "$BURST_LANE_FAKE_WORKSPACE_ROOT"
    return 0
  fi
  command -v cargo >/dev/null 2>&1 || { echo ""; return 0; }
  local meta_json meta_rc=0
  meta_json="$(cd "$dir" && timeout 20 cargo metadata --no-deps --format-version 1 2>/dev/null)" || meta_rc=$?
  if [ "$meta_rc" -ne 0 ] || [ -z "$meta_json" ]; then echo ""; return 0; fi
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("workspace_root") or "")
except Exception:
    print("")
' <<<"$meta_json"
}

# ---- lane-owned remote directory manifest (PRD-build-burst-path-deps-
# workspaces requirement 3) ---------------------------------------------
# Plain JSON object: {"<relpath-under-REMOTE_ROOT>": {"owner": "<abs local
# worktree/dep-declaring-crate path>", "ts": "<iso>"}}. Guarded by its own
# flock (distinct from the global session lock 201 — this is mutated from
# `run`, which only briefly re-takes 201 for session-state bookkeeping, and
# from `reap`, which never touches session state at all).
remote_dirs_record() {  # $1=relkey $2=owner
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  exec 209>"$REMOTE_DIRS_LOCK"
  flock 209
  local cur; cur="$(cat "$REMOTE_DIRS_FILE" 2>/dev/null || echo '{}')"
  [ -n "$cur" ] || cur='{}'
  python3 -c '
import json, sys
path, relkey, owner, ts = sys.argv[1:5]
try:
    d = json.loads(sys.argv[5] or "{}")
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
d[relkey] = {"owner": owner, "ts": ts}
with open(path, "w") as fh:
    fh.write(json.dumps(d))
' "$REMOTE_DIRS_FILE" "$1" "$2" "$(now_iso)" "$cur"
  flock -u 209
}

remote_dirs_remove() {  # $1=relkey
  [ -f "$REMOTE_DIRS_FILE" ] || return 0
  exec 209>"$REMOTE_DIRS_LOCK"
  flock 209
  local cur; cur="$(cat "$REMOTE_DIRS_FILE" 2>/dev/null || echo '{}')"
  [ -n "$cur" ] || cur='{}'
  python3 -c '
import json, sys
path, relkey = sys.argv[1:3]
try:
    d = json.loads(sys.argv[3] or "{}")
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
d.pop(relkey, None)
with open(path, "w") as fh:
    fh.write(json.dumps(d))
' "$REMOTE_DIRS_FILE" "$1" "$cur"
  flock -u 209
}

remote_dirs_owner() {  # $1=relkey -> stdout owner or empty; rc1 if no entry
  [ -f "$REMOTE_DIRS_FILE" ] || { echo ""; return 1; }
  python3 -c '
import json, sys
path, relkey = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    d = {}
v = d.get(relkey)
print((v or {}).get("owner", "") if isinstance(v, dict) else "")
sys.exit(0 if v else 1)
' "$REMOTE_DIRS_FILE" "$1"
}

remote_dirs_list_prefix() {  # $1=prefix (e.g. "deps/") -> stdout "relkey\towner" per line
  [ -f "$REMOTE_DIRS_FILE" ] || return 0
  python3 -c '
import json, sys
path, prefix = sys.argv[1:3]
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
for k, v in d.items():
    if k.startswith(prefix) and isinstance(v, dict):
        print("%s\t%s" % (k, v.get("owner", "")))
' "$REMOTE_DIRS_FILE" "$1"
}

# ---- repeat-build-failure guard (PRD-build-burst-path-deps-workspaces
# requirement 4) -------------------------------------------------------
# One small JSON file per worktree recording the cause/count/HEAD of the
# CURRENT run of consecutive identical build failures on that worktree.
# build_fail_guard_check() runs BEFORE any rsync/ssh — a worktree already at
# 3 identical failures at its current HEAD is refused with no cargo
# invocation at all (exit 3, `build-failed  repeated`). build_fail_guard_record()
# runs AFTER a build-classified failure to advance (or reset) the counter.
# worktree_head_for() is its own tiny helper so a non-git fixture (or a test)
# can seam it via BURST_LANE_FAKE_HEAD without every caller needing to know
# that — same "fail open to today's behavior" doctrine as workspace_root_for()
# above: no readable HEAD means the guard simply never engages for that
# worktree (today's unchanged behavior).
worktree_head_for() {  # $1=worktree -> stdout: HEAD sha, or empty
  if [ -n "${BURST_LANE_FAKE_HEAD+x}" ]; then echo "$BURST_LANE_FAKE_HEAD"; return 0; fi
  git -C "$1" rev-parse HEAD 2>/dev/null || echo ""
}

build_fail_guard_file() {  # $1=worktree -> stdout path
  local wkey; wkey="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  printf '%s/%s.json\n' "$BUILD_FAIL_DIR" "$wkey"
}

# rc0 = proceed (guard not tripped); rc1 = blocked — stdout is the cause to
# journal. Reads only; never mutates the guard file (that is
# build_fail_guard_record()'s job, called only after an actual attempt).
build_fail_guard_check() {  # $1=worktree -> stdout cause (if blocked); rc0 proceed / rc1 blocked
  local f; f="$(build_fail_guard_file "$1")"
  [ -s "$f" ] || return 0
  local head; head="$(worktree_head_for "$1")"
  [ -n "$head" ] || return 0
  python3 -c '
import json, sys
path, head = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
if d.get("head") == head and int(d.get("count", 0)) >= 3:
    print(d.get("cause", ""))
    sys.exit(1)
sys.exit(0)
' "$f" "$head"
}

# Advances the guard's counter for a just-observed build failure: same
# HEAD + same cause (string-equal) within BURST_BUILD_FAIL_WINDOW_S
# (default 900s, requirement 4's "within 15 minutes") of the run of
# failures' FIRST timestamp increments the count; anything else (new HEAD,
# different cause, or the window elapsed) resets the run to count=1. Prints
# the post-update count to stdout so the caller can decide whether THIS
# occurrence is the one that just reached 3 (still journaled as an ordinary
# `build-failed` line — the `repeated` line is reserved for the NEXT, BLOCKED
# attempt via build_fail_guard_check() above).
build_fail_guard_record() {  # $1=worktree $2=cause -> stdout: new count
  mkdir -p "$BUILD_FAIL_DIR" 2>/dev/null || true
  local f; f="$(build_fail_guard_file "$1")"
  local head; head="$(worktree_head_for "$1")"
  [ -n "$head" ] || { echo 0; return 0; }
  local now; now="$(now_epoch)"
  local window="${BURST_BUILD_FAIL_WINDOW_S:-900}"
  python3 -c '
import json, sys
path, head, cause, now, window = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
try:
    d = json.load(open(path))
except Exception:
    d = {}
if d.get("head") == head and d.get("cause") == cause and (now - int(d.get("first_ts", 0))) <= window:
    d["count"] = int(d.get("count", 1)) + 1
else:
    d = {"head": head, "cause": cause, "first_ts": now, "count": 1}
d["last_ts"] = now
with open(path, "w") as fh:
    fh.write(json.dumps(d))
print(d["count"])
' "$f" "$head" "$2" "$now" "$window"
}

build_fail_guard_clear() { rm -f "$(build_fail_guard_file "$1")"; }  # $1=worktree

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

mark_dirty() {  # $1=worktree $2=session_id $3=remote_path $4=kind (target|pybuilder) [$5=sync_root]
  mkdir -p "$DIRTY_DIR" 2>/dev/null || true
  # PRD-build-burst-path-deps-workspaces requirement 1/3: $5=sync_root (the
  # workspace root when the worktree is a member, else the worktree itself —
  # cmd_run always passes it now) rides along as its own field so
  # reap_plan()'s "is this remote dir still needed locally" check has the
  # ACTUAL directory $remote_path was synced FROM to test for existence, not
  # only the worktree path a plain (non-workspace) run would already share
  # with it. Without this, a workspace-root sync (remote dir keyed by
  # hash8(sync_root), a directory reap_plan never otherwise learns about)
  # always misses every existence check keyed off "worktree" alone and gets
  # reaped as a false orphan on every pass.
  python3 -c '
import json, sys
worktree, sid, remote_path, kind, sync_root, ts, path = sys.argv[1:8]
row = {"worktree": worktree, "session_id": sid, "remote_path": remote_path, "kind": kind, "sync_root": sync_root, "marked_ts": ts}
with open(path, "w") as fh:
    fh.write(json.dumps(row))
' "$1" "$2" "$3" "$4" "${5:-$1}" "$(now_iso)" "$(dirty_marker_file "$1")"
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
v = d.get(key, "")
# PRD-build-burst-pull-remote-target-missing requirement 4: `stuck` (and any
# future boolean field) must read back as the shell-comparable "true"/
# "false" JSON spells it as — plain print() of a python bool prints
# "True"/"False" (str()s capitalization), which a caller comparing against
# the literal "true" would silently never match.
if isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
' "$f" "$2"
}

clear_dirty() { rm -f "$(dirty_marker_file "$1")"; }  # $1=worktree

# Merge a JSON object's keys into an existing dirty marker in place — used by
# the pull-retry/backoff bookkeeping (attempts, next_retry_epoch, stuck,
# last_err, backoff_logged_epoch) below, which only ever ADD/OVERWRITE
# fields, never replace the whole row the way mark_dirty's fresh write does.
# A no-op (never creates a marker) when the marker is already gone — a race
# with a concurrent clear_dirty is not this helper's problem to fix.
dirty_merge_fields() {  # $1=worktree $2=json object fragment
  local f; f="$(dirty_marker_file "$1")"
  [ -s "$f" ] || return 0
  python3 -c '
import json, sys
path, frag = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    d = {}
try:
    patch = json.loads(frag)
    if isinstance(patch, dict):
        d.update(patch)
except Exception:
    pass
with open(path, "w") as fh:
    fh.write(json.dumps(d))
' "$f" "$2"
}

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
  "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
    "$REMOTE_USER@$1" "[ -d '$2' ]" 2>/dev/null
}

# PRD-build-burst-pull-back-restore AC12 (Joe's 2026-09-13 decision): a
# bounded remote payload probe for do_marker_pull's disk-floor guard. One
# `du -sb` over ssh, wrapped in `timeout` so a hung/unreachable box can
# never stall the guard past BURST_PULL_PROBE_TIMEOUT_S — a probe that
# doesn't return a clean non-negative integer byte count (timeout, ssh
# failure, empty/garbled stdout) is "unavailable", not "zero", so the
# caller falls back to the existing floor/last-observed-size rule
# unchanged rather than treating a probe hiccup as evidence of a tiny
# payload. The `# pull-payload-probe` trailing comment is a no-op on a
# real box (a plain shell comment) and exists only so the offline fake ssh
# fixture can special-case this exact probe call deterministically.
remote_payload_probe_bytes() {  # $1=ip $2=remote_target_dir -> stdout bytes; rc1 unavailable
  local ip="$1" target="$2" out
  out="$(timeout "${BURST_PULL_PROBE_TIMEOUT_S:-10}" "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
    "$REMOTE_USER@$ip" "du -sb '$target' 2>/dev/null | cut -f1  # pull-payload-probe" 2>/dev/null)"
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$out"; return 0 ;;
  esac
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
PULL_OUTCOME=""
do_marker_pull() {  # $1=worktree $2=trigger(local-read|explicit|teardown) -> rc0 handled, rc1 real failure
  # PRD-build-burst-pull-back-restore requirement 1/2: rc0 alone can't tell a
  # caller WHICH handled outcome happened — not-dirty, disk-floor-deferred,
  # cold (no session / moved root / remote dir gone), or an actual transfer
  # all return 0 here, by design (a teardown sweep and ensure-fresh's
  # local-read trigger both want "not a hard failure" collapsed to one rc).
  # Only `cmd_pull` (the explicit operator path) needs the finer distinction,
  # to stop rendering every rc0 as "pulled" — the exact defect this PRD
  # fixes. PULL_OUTCOME is the SLOT_HELD-style side channel for that: set
  # right before every return, read by cmd_pull immediately after the call,
  # ignored by every other caller exactly as before.
  local worktree="$1" trigger="$2" sid remote_path kind
  PULL_OUTCOME="not-dirty"
  is_dirty "$worktree" || return 0
  sid="$(dirty_field "$worktree" session_id)"
  remote_path="$(dirty_field "$worktree" remote_path)"
  kind="$(dirty_field "$worktree" kind)"

  # PRD-build-burst-pull-remote-target-missing requirements 3/4/5: the
  # retry/backoff gate. `local-read` is the only trigger this throttles — a
  # local cargo shim's own retry-on-every-read is exactly the 246-line-per-
  # hour storm this PRD exists to fix. `explicit` (an operator's own `pull`)
  # and `teardown` (a box about to die) always try once regardless of
  # backoff or stuck state (requirement 5), but still record the attempt
  # below on failure. Checked BEFORE the disk-floor guard (whose payload
  # probe branch makes its own ssh call) so a backed-off/stuck local-read
  # truly makes zero network calls (AC4/AC5's "no ssh call is made").
  local pr_attempts pr_next_retry pr_stuck
  pr_attempts="$(dirty_field "$worktree" attempts)"; case "$pr_attempts" in ''|*[!0-9]*) pr_attempts=0 ;; esac
  pr_next_retry="$(dirty_field "$worktree" next_retry_epoch)"; case "$pr_next_retry" in ''|*[!0-9]*) pr_next_retry=0 ;; esac
  pr_stuck="$(dirty_field "$worktree" stuck)"
  if [ "$trigger" = "local-read" ]; then
    if [ "$pr_stuck" = "true" ]; then
      PULL_OUTCOME="stuck"
      return 0
    fi
    if [ "$pr_attempts" -gt 0 ] && [ "$(now_epoch)" -lt "$pr_next_retry" ]; then
      # requirement 3: "at most one pull backoff line per marker per backoff
      # window" — dedupe on next_retry_epoch itself (a fresh value every
      # time a new failure reschedules the window) rather than journaling
      # once per skipped call.
      local pr_logged; pr_logged="$(dirty_field "$worktree" backoff_logged_epoch)"
      if [ "$pr_logged" != "$pr_next_retry" ]; then
        dirty_merge_fields "$worktree" "{\"backoff_logged_epoch\": $pr_next_retry}"
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  backoff  (worktree=$worktree trigger=$trigger attempts=$pr_attempts next_retry_s=$((pr_next_retry - $(now_epoch))))"
      fi
      PULL_OUTCOME="deferred-backoff"
      return 0
    fi
  fi

  # PRD-build-burst-persistent-volume requirement 9: the pull-back
  # DESTINATION guard, checked before every other reason to give up or
  # proceed below — a low-disk RedBaron root must DEFER (marker stays
  # dirty, retried whenever this worktree is next read/pulled/swept) rather
  # than being reclassified "cold" (which permanently drops the artifact)
  # or attempted and left to fail mid-transfer, one gate pull after another,
  # the way four straight 87/49/87/19 GB pulls actually took RedBaron's
  # root to 0 bytes free on 2026-09-11. need_gb defaults to the larger of
  # the configured floor and this worktree's own last-observed pull size
  # (the best static evidence of what THIS pull is about to cost) — fails
  # OPEN (proceeds) on an unreadable probe, never blocking a pull the real
  # disk has room for.
  local pull_free_gb; pull_free_gb="$(local_disk_free_gb "$worktree")"
  case "$pull_free_gb" in
    ''|*[!0-9]*) : ;;
    *)
      local pull_last_bytes pull_last_gb pull_need_gb pull_need_rule
      pull_last_bytes="$(last_pull_size "$worktree")"
      pull_last_gb="$(awk -v b="${pull_last_bytes:-0}" 'BEGIN{printf "%.0f", b/1073741824}')"
      pull_need_gb="$BURST_LOCAL_DISK_FLOOR_GB"
      pull_need_rule="floor"
      [ "${pull_last_gb:-0}" -gt "$pull_need_gb" ] 2>/dev/null && pull_need_gb="$pull_last_gb"

      # PRD-build-burst-pull-back-restore AC12 (Joe's 2026-09-13 decision):
      # when a live session exists, a bounded remote payload probe
      # supersedes the static floor/last-observed rule above — need_gb
      # becomes 2x the payload (rounded up to a whole GB), floored at 2 GB,
      # and capped at BURST_LOCAL_DISK_FLOOR_GB (a probe can only ever
      # LOWER the demand versus the floor, never raise it past what the
      # floor already protects against). A failed or timed-out probe (no
      # active session, no ip, ssh/timeout failure, garbled output) leaves
      # the rule above completely unchanged, per the PRD's own text ("the
      # floor applies unchanged").
      if state_active; then
        local pull_probe_ip pull_probe_target pull_probe_bytes pull_probe_gb
        pull_probe_ip="$(state_read ip)"
        if [ -n "$pull_probe_ip" ]; then
          if [ "$kind" = "pybuilder" ]; then
            pull_probe_target="$remote_path/.pybuilder"
          else
            pull_probe_target="$remote_path/target"
          fi
          if pull_probe_bytes="$(remote_payload_probe_bytes "$pull_probe_ip" "$pull_probe_target")"; then
            pull_probe_gb="$(awk -v b="$pull_probe_bytes" \
              'BEGIN{g=b/1073741824; gi=int(g); if (g>gi) gi+=1; if (gi<1) gi=1; printf "%d", gi}')"
            pull_need_gb=$((pull_probe_gb * 2))
            [ "$pull_need_gb" -lt 2 ] && pull_need_gb=2
            [ "$pull_need_gb" -gt "$BURST_LOCAL_DISK_FLOOR_GB" ] && pull_need_gb="$BURST_LOCAL_DISK_FLOOR_GB"
            pull_need_rule="payload"
          fi
        fi
      fi

      if [ "$pull_free_gb" -lt "$pull_need_gb" ]; then
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  deferred  (worktree=$worktree trigger=$trigger cause=local-disk free_gb=$pull_free_gb need_gb=$pull_need_gb rule=$pull_need_rule)"
        PULL_OUTCOME="deferred"
        return 0
      fi
      ;;
  esac

  if ! state_active; then
    clear_dirty "$worktree"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid trigger=$trigger cause=no-active-session — local target stale, next local build recompiles)"
    PULL_OUTCOME="cold"
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid remote_path=$remote_path trigger=$trigger cause=remote-path-missing — local target stale, next local build recompiles)"
      PULL_OUTCOME="cold"
      return 0
      ;;
  esac

  if ! remote_dir_exists "$ip" "$remote_path"; then
    clear_dirty "$worktree"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid remote_path=$remote_path trigger=$trigger cause=remote-dir-missing — local target stale, next local build recompiles)"
    PULL_OUTCOME="cold"
    return 0
  fi

  local t0 t1 bytes prc=0
  t0="$(now_fractional)"
  if [ "$kind" = "pybuilder" ]; then
    bytes="$(pull_pybuilder_incremental "$worktree" "$ip")"; prc=$?
  else
    # PRD-build-burst-path-deps-workspaces requirement 1: pass the marker's
    # own $remote_path (read above) straight through — a workspace member's
    # actual sync destination, which remote_path_for(worktree) alone can no
    # longer reliably recompute.
    bytes="$(pull_target_incremental "$worktree" "$ip" "$remote_path")"; prc=$?
  fi
  t1="$(now_fractional)"

  # requirement 1: pull_target_incremental's rc2 — the remote target dir
  # itself never existed (a routed run that built nothing) — is a cold
  # outcome, not a failure: clear the marker in one pass, never retried.
  if [ "$prc" -eq 2 ]; then
    clear_dirty "$worktree"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  cold  (worktree=$worktree session_id=$sid remote_path=$remote_path trigger=$trigger cause=remote-target-missing — nothing was built on the box for this marker)"
    PULL_OUTCOME="cold"
    return 0
  fi

  if [ "$prc" -ne 0 ]; then
    # requirements 2/3/4: a genuine rsync-down failure. Keep the stderr this
    # PRD's own grounding shows the old fallback branch discarded — written
    # to its own kept (never rm -f'd) log, with the last non-empty line
    # riding the journal line itself — then advance the backoff/stuck
    # bookkeeping so the NEXT local-read (if any) waits instead of hammering.
    # pull_target_incremental (kind=target) ran inside THIS command
    # substitution's own subshell — a plain global assignment there would
    # never have escaped it, so it rides the rc + full stderr back on
    # stdout itself instead: $bytes here is "<rc>\n<stats...>", rc on its
    # own first line. pull_pybuilder_incremental (non-goal: sharing only
    # the backoff/stuck helpers, not full stderr capture) has no such
    # payload — $bytes is empty on its failure, so pf_rc/pf_stats fall back
    # to a bare "1"/empty.
    local pf_wkey pf_log pf_rc pf_stats pf_err pf_cause pf_new_attempts pf_delay pf_next_epoch pf_stuck
    if [ "$kind" = "pybuilder" ]; then
      pf_rc=1
      pf_stats=""
    else
      pf_rc="$(printf '%s\n' "$bytes" | head -n1)"
      case "$pf_rc" in ''|*[!0-9]*) pf_rc=1 ;; esac
      pf_stats="$(printf '%s\n' "$bytes" | tail -n +2)"
    fi
    pf_wkey="$(printf '%s' "$worktree" | sha1sum | cut -c1-8)"
    mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
    pf_log="$BOX_STATE_DIR/logs/pull-fail.$pf_wkey.$(now_epoch).log"
    printf '%s\n' "$pf_stats" > "$pf_log" 2>/dev/null || true
    pf_err="$(printf '%s\n' "$pf_stats" | awk 'NF{l=$0} END{print l}')"
    pf_err="${pf_err:0:160}"
    pf_cause="$(rsync_failure_cause "$pf_rc")"

    pf_new_attempts=$((pr_attempts + 1))
    pf_delay="$(pull_backoff_delay_s "$pf_new_attempts")"
    pf_next_epoch=$(( $(now_epoch) + pf_delay ))
    pf_stuck=false
    [ "$pf_new_attempts" -ge "$BURST_PULL_MAX_ATTEMPTS" ] && pf_stuck=true

    dirty_merge_fields "$worktree" "$(python3 -c '
import json, sys
attempts, next_retry_epoch, stuck, last_err = sys.argv[1:5]
print(json.dumps({
    "attempts": int(attempts),
    "next_retry_epoch": int(next_retry_epoch),
    "stuck": stuck == "true",
    "last_err": last_err,
}))
' "$pf_new_attempts" "$pf_next_epoch" "$pf_stuck" "$pf_err")"

    if [ "$pf_stuck" = "true" ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  stuck  (worktree=$worktree trigger=$trigger cause=$pf_cause rc=$pf_rc err=\"$pf_err\" attempts=$pf_new_attempts — marker left dirty; needs a new routed run to reset)"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  fallback  (cause=$pf_cause rc=$pf_rc err=\"$pf_err\" attempts=$pf_new_attempts next_retry_s=$pf_delay worktree=$worktree trigger=$trigger)"
    fi
    PULL_OUTCOME="failed"
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
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  ok  (worktree=$worktree trigger=$trigger bytes=${bytes:-0} slug=$slug)"
  PULL_OUTCOME="transferred"
  return 0
}

# PRD-build-burst-run-slots-from-box requirement 2/3: the one arithmetic
# formula both run_slot_cap() (the run-slot table, fed the box's own boot-
# time cores/mem/disk) and cmd_sub_cap (fed a fresh live probe of the same
# three quantities) call — so the two can never independently drift, per
# Goal 2 ("one formula, shared by sub_cap and the slot table"). Pure
# function: no state, no ssh, just min(cores/cores_per, mem_gb/gb_per,
# (disk_gb-disk_floor)/disk_per), each term integer-divided, the disk term
# clamped at >=0 before the min (a box below its own floor contributes 0,
# never a negative number that would falsely win the min against a small
# cpu/mem term). NOT floored at 1 here — cmd_sub_cap legitimately wants 0
# (refuse every new candidate); run_slot_cap() applies its own floor-at-1
# after calling this, per requirement 2.
#
# Requirement 6: BURST_CORES_PER_RUN/BURST_GB_PER_RUN/BURST_GB_DISK_PER_RUN
# are the current names; the older *_PER_BRANCH spellings still resolve (one
# journal deprecation line per call that falls back to one) so an
# unmigrated ~/.config/wm-burst/.env keeps working. Defaults (4 cores / 8 GB
# / 45 GB-per-run) match the values RedBaron's real .env already pins for
# BURST_CORES_PER_BRANCH/BURST_GB_PER_BRANCH/BURST_GB_DISK_PER_BRANCH today
# (requirement 2) — NOT cmd_sub_cap's old built-in fallback of 6 GB / 70 GB
# (those only ever applied when the env knobs were unset, i.e. this
# selftest's own fixtures; production always pinned them explicitly, so
# real behavior is unchanged by this default bump).
run_slot_cap_terms() {  # $1=cores $2=mem_gb $3=disk_gb -> stdout "<cap> <bound>"
  local cores="$1" mem_gb="$2" disk_gb="$3"
  local cores_per gb_per disk_per
  if [ -n "${BURST_CORES_PER_RUN:-}" ]; then
    cores_per="$BURST_CORES_PER_RUN"
  elif [ -n "${BURST_CORES_PER_BRANCH:-}" ]; then
    cores_per="$BURST_CORES_PER_BRANCH"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run-slot-cap  deprecated-knob  (old=BURST_CORES_PER_BRANCH new=BURST_CORES_PER_RUN)"
  else
    cores_per=4
  fi
  if [ -n "${BURST_GB_PER_RUN:-}" ]; then
    gb_per="$BURST_GB_PER_RUN"
  elif [ -n "${BURST_GB_PER_BRANCH:-}" ]; then
    gb_per="$BURST_GB_PER_BRANCH"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run-slot-cap  deprecated-knob  (old=BURST_GB_PER_BRANCH new=BURST_GB_PER_RUN)"
  else
    gb_per=8
  fi
  if [ -n "${BURST_GB_DISK_PER_RUN:-}" ]; then
    disk_per="$BURST_GB_DISK_PER_RUN"
  elif [ -n "${BURST_GB_DISK_PER_BRANCH:-}" ]; then
    disk_per="$BURST_GB_DISK_PER_BRANCH"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run-slot-cap  deprecated-knob  (old=BURST_GB_DISK_PER_BRANCH new=BURST_GB_DISK_PER_RUN)"
  else
    disk_per=45
  fi
  local disk_floor="${BURST_DISK_FLOOR_GB:-40}"
  local by_cpu=$(( cores / cores_per ))
  local by_mem=$(( mem_gb / gb_per ))
  local by_disk=$(( (disk_gb - disk_floor) / disk_per ))
  [ "$by_disk" -lt 0 ] && by_disk=0
  local cap=$by_mem bound="mem"
  if [ "$by_cpu" -lt "$cap" ]; then cap=$by_cpu; bound="cpu"; fi
  if [ "$by_disk" -lt "$cap" ]; then cap=$by_disk; bound="disk"; fi
  printf '%s %s\n' "$cap" "$bound"
}

# PRD-build-burst-run-slots-from-box requirement 2: the run-slot cap the box
# that booted actually supports, sized from session.json's box_cores/
# box_mem_gb/box_disk_gb (written once by `up`'s box probe — see cmd_up).
# MUST be called directly (never via `$(...)` — same subshell-loses-globals
# hazard acquire_run_slot's own header documents), since it reports through
# the RUN_SLOT_* globals below, not stdout. BURST_MAX_CONCURRENT_RUNS, when
# set, pins the cap outright (source=env) — the operator escape hatch
# (Requirement 2/user story 3). No box fields on the session (a probe
# failure, or a pre-this-PRD session — Migration/compatibility) falls back
# to 4 (source=default). Otherwise the box's own numbers feed
# run_slot_cap_terms, floored at 1 (source=box) — a session is never sized
# down to zero concurrent runs by its own box.
RUN_SLOT_CAP=""
RUN_SLOT_SOURCE=""
RUN_SLOT_BOUND=""
RUN_SLOT_BOX_CORES=""
RUN_SLOT_BOX_MEM_GB=""
RUN_SLOT_BOX_DISK_GB=""
run_slot_cap() {
  RUN_SLOT_BOX_CORES="$(state_read box_cores)"
  RUN_SLOT_BOX_MEM_GB="$(state_read box_mem_gb)"
  RUN_SLOT_BOX_DISK_GB="$(state_read box_disk_gb)"
  if [ -n "${BURST_MAX_CONCURRENT_RUNS:-}" ]; then
    RUN_SLOT_CAP="$BURST_MAX_CONCURRENT_RUNS"; RUN_SLOT_SOURCE="env"; RUN_SLOT_BOUND=""
    return 0
  fi
  case "$RUN_SLOT_BOX_CORES" in ''|*[!0-9]*) RUN_SLOT_CAP=4; RUN_SLOT_SOURCE="default"; RUN_SLOT_BOUND=""; return 0 ;; esac
  case "$RUN_SLOT_BOX_MEM_GB" in ''|*[!0-9]*) RUN_SLOT_CAP=4; RUN_SLOT_SOURCE="default"; RUN_SLOT_BOUND=""; return 0 ;; esac
  case "$RUN_SLOT_BOX_DISK_GB" in ''|*[!0-9]*) RUN_SLOT_CAP=4; RUN_SLOT_SOURCE="default"; RUN_SLOT_BOUND=""; return 0 ;; esac
  local cap bound
  read -r cap bound <<<"$(run_slot_cap_terms "$RUN_SLOT_BOX_CORES" "$RUN_SLOT_BOX_MEM_GB" "$RUN_SLOT_BOX_DISK_GB")"
  [ "$cap" -lt 1 ] && cap=1
  RUN_SLOT_CAP="$cap"; RUN_SLOT_SOURCE="box"; RUN_SLOT_BOUND="$bound"
}

# PRD-build-burst-parallel-runs AC6: non-blocking peek at how many run slots
# are currently held, for `status` to report `concurrent=<held>/<cap>`. Never
# acquires a slot itself (a peek that took one would lie about capacity to
# any run racing it) — same try-and-release-immediately probe
# acquire_run_slot already uses to count the OTHER held slots once it has
# taken its own.
count_held_slots() {  # -> stdout "<held>/<cap>"
  run_slot_cap
  local cap="$RUN_SLOT_CAP" held=0 j
  mkdir -p "$BOX_STATE_DIR/slots" 2>/dev/null || true
  for j in $(seq 1 "$cap"); do
    ( exec 211>"$BOX_STATE_DIR/slots/$j.lock"; flock -n 211 ) 2>/dev/null || held=$((held+1))
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
  # PRD-build-burst-run-slots-from-box requirement 3: sized from
  # run_slot_cap() at each acquisition — a session that gained box fields
  # (or an operator's env pin) since the LAST acquisition is honored on the
  # very next one; a table that shrinks never forces an already-held slot
  # to release (this loop only ever offers 1..cap, it never touches a slot
  # index above cap that some earlier, wider-cap acquisition still holds).
  run_slot_cap
  local cap="$RUN_SLOT_CAP" i waited=0
  mkdir -p "$BOX_STATE_DIR/slots" 2>/dev/null || true
  # PRD-build-burst-selftest-drift-and-bake-gate requirement 2: a test-only
  # escape hatch so burstpar-selftest.sh can prove its own peak-overlap
  # counter actually fails when the concurrency contract is violated,
  # instead of only ever exercising the path where the cap holds. Gated on
  # BURST_LANE_TEST=1 (never a bare env check) so a stray
  # BURSTPAR_TEST_BREAK_SLOTS in a real operator's environment can never
  # silently blow the real cap — each call grants its own never-contended
  # lock file, so concurrent callers all "acquire" at once with no
  # serialization at all.
  if [ "${BURST_LANE_TEST:-}" = 1 ] && [ "${BURSTPAR_TEST_BREAK_SLOTS:-}" = 1 ]; then
    exec 202>"$BOX_STATE_DIR/slots/broken-$$.lock"
    flock 202
    SLOT_HELD="broken/$cap"
    SLOT_INDEX="broken-$$"
    return 0
  fi
  while :; do
    for i in $(seq 1 "$cap"); do
      exec 202>"$BOX_STATE_DIR/slots/$i.lock"
      if flock -n 202; then
        local held=0 j
        for j in $(seq 1 "$cap"); do
          [ "$j" = "$i" ] && { held=$((held+1)); continue; }
          ( exec 210>"$BOX_STATE_DIR/slots/$j.lock"; flock -n 210 ) 2>/dev/null || held=$((held+1))
        done
        SLOT_HELD="$held/$cap"
        SLOT_INDEX="$i"
        return 0
      fi
    done
    sleep 2; waited=$((waited+2))
    if [ "$waited" -eq 120 ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  slot-wait  (worktree=$1 cap=$cap waited=${waited}s)"
    fi
  done
}

# remote_sccache_guard — PRD-build-gate-wall-clock requirement 2, box side.
# Same rule sccache-assert.sh now enforces locally (2026-09-15: "busy is
# not dead"): a `--show-stats` timeout means the server didn't ANSWER in
# time, not that it's gone — up to 4 routed runs hit this box concurrently,
# and one run's old stop/start guard was killing every sibling run's
# in-flight compile (the same double-restart anti-pattern proven on
# RedBaron at 12:33:08Z/12:33:09Z the same day). This never calls
# `--stop-server`: a live-but-busy server is left alone; only a genuinely
# DEAD one (no `sccache` process at all) gets started, once, under a flock
# so two concurrent runs can't both start it. Emitted as a function (not
# inlined into $remote_cmd's own quoting) because the loop needs its own
# `$(...)`/`$var` remote-side expansions, which would otherwise have to be
# backslash-escaped inside that already-dense double-quoted string; instead
# this is built with an UNQUOTED heredoc so ${dir} expands here (locally,
# once, to a literal path) while `\$(seq...)`/`\$ok` stay escaped and reach
# the remote shell literally, to be expanded there when $remote_cmd runs.
remote_sccache_guard() {
  local dir="$REMOTE_SCCACHE_DIR"
  cat <<GUARD
timeout 30 sccache --show-stats >/dev/null 2>&1 || { pgrep -x sccache >/dev/null 2>&1 || { flock -x ${dir}.guard.lock sccache --start-server >/dev/null 2>&1; ok=0; for i in \$(seq 1 60); do timeout 1 sccache --show-stats >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done; [ "\$ok" = 1 ] || { echo 'burst-lane: sccache_unreachable on remote box' >&2; exit 97; }; }; }
GUARD
}

cmd_run() {
  local worktree="${1:-}"; shift || true
  while [ "${1:-}" = "--" ]; do shift; done  # guard: doubled -- from stacked wrappers
  [ -n "$worktree" ] && [ $# -ge 1 ] || { echo "usage: burst-lane.sh run <worktree> -- <cargo args...>" >&2; exit 2; }
  [ -d "$worktree" ] || die "no such worktree: $worktree" 2

  # PRD-build-burst-path-deps-workspaces requirement 4: refuse a repeat
  # attempt on a worktree already three-for-three on the SAME build-failed
  # cause at its CURRENT HEAD, before any lock is taken and before a single
  # byte moves — a repo that cannot build remotely burns no further cargo
  # invocations until an operator (or a new commit) changes something. Never
  # touches cargo, never talks to the box.
  local bfg_cause
  if bfg_cause="$(build_fail_guard_check "$worktree")"; then
    :
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  build-failed  repeated  (n=3 cause=\"$bfg_cause\" worktree=$worktree)"
    echo "fallback: build-failed repeated 3x on this worktree's HEAD (cause=\"$bfg_cause\") — refusing to re-run until HEAD changes"
    exit 3
  fi

  # Global lock (201) held ONLY for session ensure — the old whole-run hold
  # serialized the box to width-1 (2026-09-10 5-whys). Phase 1: make sure
  # AT LEAST ONE box is active, exactly as before this PRD (auto-`up`
  # unconditionally targets `current` — with no box yet, that is the only
  # box there is about to be). Requirement 3's own box SELECTION (which of
  # possibly several active boxes this run actually uses) is phase 2,
  # below, deliberately kept separate: selecting/acquiring a slot before a
  # box exists at all is meaningless, and folding the two phases together
  # is what made an earlier version of this change race (every one of N
  # simultaneous launches saw the same box's slot table as "free" for the
  # instant its own hint-only peek held it, then all serialized onto that
  # one box's blocking wait once the real acquisition found it already
  # taken — caught by this PRD's own multibox AC3 fixture, all 12 runs
  # landing on one box instead of splitting 4+4).
  exec 201>"$RUN_LOCK"
  flock 201
  if ! state_active; then
    local up_out; up_out="$(cmd_up 2>&1)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      # PRD-build-burst-dispatch-reenable requirement 5 (AC8): the tick's
      # own fail-closed contract — an ordinary (non-gate) run whose `up`
      # fails must journal the same "run fallback (cause=up-failed ...)"
      # shape the gate wrapper already journals at its own up call site, not
      # just print to stdout and fall back silently as far as the journal
      # is concerned. No server_id yet — up itself never got one.
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  fallback  (cause=up-failed worktree=$worktree)"
      echo "$up_out"
      exit 3
    fi
  fi
  flock -u 201

  # Phase 2 (requirement 3): now that at least one box is active, pick the
  # first box (current-first order) whose slot table has a free slot RIGHT
  # NOW, acquiring it atomically in the same non-blocking pass (never a
  # peek-then-release hint) — see select_run_box's own header for why a
  # hint-only version was wrong. Falls back to a BLOCKING wait on
  # `current`'s own table, "as today", only when every active box's table
  # was full at this pass's snapshot. Leaves box_context pointed at
  # whichever box actually granted the slot, and sets SLOT_HELD/SLOT_INDEX
  # exactly as the old single-box acquire_run_slot always did.
  select_run_box "$worktree"
  local slot_held="$SLOT_HELD"

  # Session lock re-acquired against the box phase 2 actually selected
  # (never `current` unconditionally any more) — this is the fd every
  # later per-box read/write in this function assumes is already held for
  # the read-modify-write it does; verify happens here, once, against that
  # SAME box.
  exec 201>"$RUN_LOCK"
  flock 201
  local id ip; id="$(state_read server_id)"; ip="$(state_read ip)"
  if [ "$(state_read verified)" != "true" ]; then
    # PRD-build-fail-loud-evidence-kept AC4: this was the truly silent
    # run-path verify — probe_run now keeps stderr and journals rc/err/log
    # on failure instead of discarding it outright.
    probe_run verify -- cmd_verify >/dev/null 2>&1 || true
    if [ "$(state_read verified)" != "true" ]; then
      # AC8: cause=verify-failed, same fallback shape as up-failed above
      # (formerly journaled as a bespoke "lane-unverified" event with no
      # other reader depending on that literal text).
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  fallback  (cause=verify-failed server_id=$id worktree=$worktree)"
      echo "fallback: lane not verified (burst-lane.sh verify) — running locally"
      exit 3
    fi
  fi
  flock -u 201
  # Same-worktree runs still serialize: two --delete syncs of one remote dir
  # would shred each other. Different worktrees hold different locks.
  mkdir -p "$BOX_STATE_DIR/locks" 2>/dev/null || true
  exec 203>"$BOX_STATE_DIR/locks/wt-$(worktree_lock_key "$worktree").lock"
  flock 203

  # PRD-build-burst-path-deps-workspaces requirement 1: when this worktree
  # is itself a cargo workspace member, the thing that needs to land on the
  # box as ONE tree is the whole workspace root — not just this worktree
  # (whose own siblings under the workspace, e.g. autobuilder's crates/x,
  # would otherwise get treated as ordinary external path deps and mirrored
  # a second time under deps/, colliding with the copy already inside the
  # worktree's own rsync). `worktree_abs` is the canonical (symlink-
  # resolved) form so string-prefix comparison against cargo metadata's own
  # canonical `workspace_root` is reliable. Two shapes: the worktree itself
  # IS the workspace root (the common case for a `git worktree add` of a
  # whole workspace repo — member_rel stays empty), or the worktree is a
  # member SUBDIRECTORY of a workspace root that lies above it (member_rel
  # is that relative path, and remote_cwd below cds into it after the
  # workspace-root sync). A workspace_root outside the worktree's own tree
  # entirely (neither equal nor an ancestor) is treated as "no workspace" —
  # defensive; cargo metadata should never report that shape.
  local worktree_abs; worktree_abs="$(cd "$worktree" && pwd -P)"
  local ws_root; ws_root="$(workspace_root_for "$worktree_abs")"
  local sync_root="$worktree_abs" member_rel=""
  if [ -n "$ws_root" ] && [ -d "$ws_root" ]; then
    ws_root="$(cd "$ws_root" && pwd -P)"
    case "$worktree_abs" in
      "$ws_root") sync_root="$ws_root" ;;
      "$ws_root"/*) sync_root="$ws_root"; member_rel="${worktree_abs#"$ws_root"/}" ;;
      *) ws_root="" ;;
    esac
  fi
  local remote_path; remote_path="$(remote_path_for "$sync_root")"
  local remote_cwd="$remote_path${member_rel:+/$member_rel}"

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
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  fallback  (cause=disk-low free_gb=$run_free_gb floor_gb=$disk_floor_run worktree=$worktree)"
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
  # PRD-build-burst-path-deps requirement 1/2: sync every transitive path
  # dependency of the worktree's own crate BEFORE the worktree itself, so
  # the worktree's rewritten manifest (below) can point at an
  # already-present remote location. This is the fix for the whole
  # problem statement: wintermute-brain (and any crate with siblings
  # outside the worktree, e.g. agorabus/wm-local-llm/wm-verify/wm-router)
  # used to sync only $worktree/ — cargo on the box then failed to resolve
  # a `path = "../sibling"` dependency that was never there, and the
  # operator had to mirror the crates onto the box by hand (this PRD's
  # five-whys levels 1-3).
  # PRD-build-burst-path-deps-workspaces requirement 1: a dependency that
  # resolves INSIDE $ws_root is excluded here — it is already part of the
  # workspace-root tree the sync below copies as a whole, so mirroring it a
  # second time under deps/ would recreate the exact autobuilder collision
  # (the same package present at both <sync_root>/crates/x and
  # deps/x-<hash>) this PRD exists to fix. discover() still recurses INTO
  # that dependency's own manifest, so a workspace member's OWN external
  # sibling (outside the workspace entirely) is still found and mirrored.
  local pathdeps=() map_file=""
  if [ -f "$worktree_abs/Cargo.toml" ] && [ -f "$HERE/burst-lane-pathdeps.py" ]; then
    while IFS= read -r pd_d; do [ -n "$pd_d" ] && pathdeps+=("$pd_d"); done \
      < <(python3 "$HERE/burst-lane-pathdeps.py" discover "$worktree_abs/Cargo.toml" "$ws_root" 2>/dev/null)
  fi
  mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
  if [ "${#pathdeps[@]}" -gt 0 ]; then
    map_file="$(mktemp)"; : > "$map_file"
    printf '%s\t%s\n' "$worktree_abs" "$remote_path" >> "$map_file"
    local pd_dep pd_remote
    for pd_dep in "${pathdeps[@]}"; do
      printf '%s\t%s\n' "$pd_dep" "$(dep_remote_path_for "$pd_dep")" >> "$map_file"
    done
    local pd_log="$BOX_STATE_DIR/logs/pathdep-rsync.$$.log" pd_rc=0 pd_err
    for pd_dep in "${pathdeps[@]}"; do
      pd_remote="$(dep_remote_path_for "$pd_dep")"
      pd_rc=0
      "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
            --rsync-path="mkdir -p '$pd_remote' && rsync" \
            -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
            "$pd_dep/" "$REMOTE_USER@$ip:$pd_remote/" >"$pd_log" 2>&1 || pd_rc=$?
      if [ "$pd_rc" -ne 0 ]; then
        pd_err="$(grep -v '^[[:space:]]*$' "$pd_log" 2>/dev/null | tail -n1)"
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  fallback  (cause=pathdep-rsync-failed rc=$pd_rc err=\"$pd_err\" worktree=$worktree dep=$pd_dep)"
        echo "fallback: rsync of path dependency $pd_dep to $ip failed rc=$pd_rc (see $pd_log)"
        rm -f "$map_file"
        exit 3
      fi
      # PRD-build-burst-path-deps-workspaces requirement 3: record this
      # mirror in the lane-owned directory manifest, keyed by its path
      # relative to $REMOTE_ROOT (e.g. "deps/sibling-a1b2c3d4") — the thing
      # `reap` cannot otherwise tell apart from a genuine orphan, since
      # neither the candidate worktree roots nor the dirty/attribution
      # ledgers reap_plan() already consults ever contain an arbitrary
      # external sibling crate's own path.
      remote_dirs_record "${pd_remote#"$REMOTE_ROOT"/}" "$worktree_abs"
      # Transitive rewrite: this dep's OWN Cargo.toml may itself declare a
      # path dependency on another dep already in the map — rewrite its
      # synced copy the same way the worktree's own manifest is rewritten
      # below, so a chain of path deps (not just one hop) resolves too.
      if [ -f "$pd_dep/Cargo.toml" ]; then
        local pd_tmp; pd_tmp="$(mktemp)"
        if python3 "$HERE/burst-lane-pathdeps.py" rewrite "$pd_dep/Cargo.toml" "$map_file" > "$pd_tmp" 2>/dev/null; then
          "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
            "$pd_tmp" "$REMOTE_USER@$ip:$pd_remote/Cargo.toml" >>"$pd_log" 2>&1 || true
        fi
        rm -f "$pd_tmp"
      fi
    done
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  pathdeps  (worktree=$worktree deps=${#pathdeps[@]} paths=$(IFS=,; echo "${pathdeps[*]}"))"
  fi

  # PRD-build-burst-path-deps-workspaces requirement 1: sync $sync_root (the
  # workspace root when the worktree is a member, else the worktree itself,
  # byte-identical to today) so a workspace member's own siblings arrive as
  # part of this ONE copy rather than needing a second, colliding one.
  local up_log="$BOX_STATE_DIR/logs/rsync-up.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$sync_root/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" worktree=$worktree)"
    echo "fallback: rsync to $ip failed rc=$rsync_up_rc (see $up_log)"
    rm -f "$map_file"
    exit 3
  fi
  t_up_end="$(now_fractional)"

  # PRD-build-burst-path-deps requirement 2: rewrite the just-synced
  # worktree's own `path =` entries that point at a dependency this run
  # just synced, to that dependency's remote location. `cargo metadata`/
  # build/test on the box then resolves it with no operator step (AC1, AC5).
  if [ -n "$map_file" ]; then
    local wt_tmp; wt_tmp="$(mktemp)"
    if python3 "$HERE/burst-lane-pathdeps.py" rewrite "$worktree_abs/Cargo.toml" "$map_file" > "$wt_tmp" 2>/dev/null; then
      "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$wt_tmp" "$REMOTE_USER@$ip:$remote_cwd/Cargo.toml" >>"$up_log" 2>&1 || true
    fi
    rm -f "$wt_tmp" "$map_file"
  fi

  # A caller (the PATH shims) may hand us the LOCAL absolute binary path —
  # meaningless on the box. Route by bare name; the remote PATH below finds it.
  local first="$1"; shift
  # PRD-build-burst-path-deps requirement 3: the SUBCOMMAND (build/test/
  # metadata/...), captured before this shift consumes it too — `first` is
  # the program name (cargo/uv), never the subcommand, and phase
  # classification below needs the subcommand specifically.
  local subcmd="${1:-}"
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
  # so the equivalent guard runs inline (via remote_sccache_guard() below)
  # rather than shelling out to scripts/sccache-assert.sh (which drives a
  # local systemd-user unit that does not exist on this remote). 2026-09-15:
  # this guard used to be a plain `sccache --stop-server && --start-server`
  # on any timeout — up to 4 runs route to this box concurrently, and a
  # BUSY (not dead) server got stopped out from under every sibling run's
  # in-flight compile. It now only starts a server that is actually gone
  # (no `sccache` process found); a live-but-slow one is left running and
  # simply gets more time to answer. See remote_sccache_guard()'s own
  # comment for the mechanics.
  # PRD-build-burst-unprivileged-user requirement 2: RUSTUP_HOME hardcoded
  # at root's shared, read-only toolchain regardless of who's running this
  # (a no-op for the REMOTE_USER=root rollback, since that's already root's
  # own default there); PATH still carries $ROOT_CARGO_HOME/bin so the
  # `cargo`/`rustup` binaries resolve. CARGO_HOME (PRD-build-burst-path-deps
  # requirement 5) is $RUN_CARGO_HOME — build's own writable registry/git
  # cache, never root's read-only one; this is the write-race fix (a
  # dependency fetch WRITES into CARGO_HOME's registry, which root's copy
  # never granted). SCCACHE_DIR is $REMOTE_USER's OWN cache, never root's —
  # sccache's cache dir needs write, not just read. SCCACHE_CACHE_SIZE
  # (PRD-build-burst-persistent-volume) caps the cache against
  # $BURST_SCCACHE_GB regardless of which CARGO_HOME is in play.
  # PRD-build-burst-path-deps-workspaces requirement 1: cd into the
  # member's own relative path INSIDE the synced tree ($remote_cwd, equal to
  # $remote_path when there is no workspace or the worktree IS the workspace
  # root) so a workspace member's `cargo build`/`test` runs from exactly
  # where it would locally; CARGO_TARGET_DIR still pins the WHOLE workspace's
  # target dir at $remote_path/target regardless of $remote_cwd, matching
  # ordinary cargo workspace semantics (one target dir at the workspace
  # root, not one per member).
  # PRD-build-burst-prove-forensics requirement 11/12: when `prove` is
  # driving this run (never for an ordinary agent run — PROVE_ACTIVE is a
  # plain global only cmd_prove ever sets true), capture the box's own
  # clock and arrange for a marker to be touched INSIDE the remote target
  # dir immediately before cargo starts. The marker rides back in the same
  # pull `assert` already reads, on the box's OWN clock — the fix for
  # `assert` failing "no-fresh-artifact" against a real, fresh remote
  # compile whenever this caller's clock and the box's disagreed (real
  # boxes 165754863/165762013, 2026-09-14).
  local marker_cmd=""
  if [ "${PROVE_ACTIVE:-false}" = true ]; then
    local remote_date_iso
    remote_date_iso="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 $SSH_RUN_KEEPALIVE_OPTS $(ssh_kh_args) \
        -i "$SSH_KEY" "$REMOTE_USER@$ip" "date -u +%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"
    if [ -n "$remote_date_iso" ]; then
      mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
      printf '%s' "$remote_date_iso" > "$(prove_remote_date_path)" 2>/dev/null || true
    fi
    # BURST_PROVE_TEST_MARKER_EPOCH: offline-only hook (grep the tree — only
    # burst-lane-selftest.sh sets it), so a fixture can reproduce a box
    # whose own clock disagrees with the caller's (AC13) without a real
    # skewed box.
    local marker_touch="touch"
    [ -n "${BURST_PROVE_TEST_MARKER_EPOCH:-}" ] && marker_touch="touch -d @${BURST_PROVE_TEST_MARKER_EPOCH}"
    marker_cmd="mkdir -p $remote_path/target; $marker_touch $remote_path/target/.burst-run-marker; "
  fi
  local remote_cmd="cd $remote_cwd && export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$RUN_CARGO_HOME CARGO_TARGET_DIR=$remote_path/target RUSTC_WRAPPER=sccache SCCACHE_DIR=$REMOTE_SCCACHE_DIR SCCACHE_CACHE_SIZE=${BURST_SCCACHE_GB}G SCCACHE_IDLE_TIMEOUT=0; $(remote_sccache_guard); ${marker_cmd}$first $*"
  local rc=0
  local remote_out_log="$BOX_STATE_DIR/logs/run-remote.$$.log"
  "$SSH_BIN" $SSH_RUN_KEEPALIVE_OPTS $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" "$remote_cmd" 2>&1 | tee "$remote_out_log"
  rc="${PIPESTATUS[0]}"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  infra-fail  (server_id=$id worktree=$worktree remote_rc=$rc cmd=$first — falling back local)"
    echo "fallback: remote $first not runnable on box (rc=$rc)"
    exit 3
  fi
  if [ "$rc" -eq 97 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  sccache-unreachable  (server_id=$id worktree=$worktree cmd=$first — falling back local)"
    echo "fallback: remote sccache did not answer after one restart attempt (rc=97)"
    exit 3
  fi

  # PRD-build-burst-path-deps requirement 3: classify a nonzero exit as a
  # BUILD failure (compile/resolution error — nothing ever ran) or a TEST
  # failure (nextest/cargo-test's own red suite) instead of always
  # journaling `exit=101` the same way regardless of which happened. This
  # is the fix for the actual defect: four days of wintermute-brain runs
  # failing before a single test binary ran read as "tests red" in the
  # journal, so the branch agent kept iterating on tests that were never
  # the problem (this PRD's five-whys levels 3-4). A non-cargo/nextest
  # subcommand (e.g. the `bash build.sh` shape several other suites route
  # through this same primitive) keeps the old undistinguished behavior —
  # phase stays empty, exactly as if this PRD had never shipped.
  local phase=""
  if [ "$rc" -ne 0 ]; then
    case "$subcmd" in
      build|clippy|deny|metadata|check) phase="build" ;;
      test|nextest)
        if grep -qE 'Running (unittests|tests)|test result:|Summary \[|Starting [0-9]+ tests' "$remote_out_log" 2>/dev/null; then
          phase="test"
        else
          phase="build"
        fi
        ;;
    esac
  fi
  if [ "$phase" = "build" ]; then
    local build_cause; build_cause="$(grep -iE 'error(\[|:)|error:' "$remote_out_log" 2>/dev/null | head -n1)"
    [ -z "$build_cause" ] && build_cause="$(grep -v '^[[:space:]]*$' "$remote_out_log" 2>/dev/null | tail -n1)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  build-failed  (worktree=$worktree cause=\"$build_cause\")"
    # PRD-build-burst-path-deps-workspaces requirement 4: advance the
    # per-worktree repeat counter — the NEXT attempt's build_fail_guard_check
    # (top of cmd_run) is what actually refuses a 4th run once this reaches 3.
    build_fail_guard_record "$worktree" "$build_cause" >/dev/null
  else
    # A run that did NOT fail at the build phase (success, or a genuine
    # red-test-suite failure — the build itself worked) means this HEAD's
    # build is not broken; clear any stale repeat-guard record so a later,
    # unrelated build failure at the same HEAD starts its own fresh count
    # instead of inheriting one from an earlier, different cause.
    build_fail_guard_clear "$worktree"
  fi
  rm -f "$remote_out_log" 2>/dev/null || true

  # PRD-build-burst-pull-on-demand requirement 1: `run` no longer pulls
  # target/ (or .pybuilder/) back itself — it marks the worktree remote-dirty
  # and returns. The pull happens lazily, at whichever of the three points
  # (explicit `pull`, a local cargo consumer via `ensure-fresh`, or the
  # teardown sweep) actually needs the artifacts next. This is the whole
  # laziness: 19 of 21 pulls in the PRD's own baseline session sat between
  # two remote runs where nothing local ever read the worktree.
  local kind; kind="$([ "$first" = "uv" ] && echo pybuilder || echo target)"
  mark_dirty "$worktree" "$id" "$remote_path" "$kind" "$sync_root"

  # Read-modify-write of session state back under the brief global lock.
  flock 201
  local runs; runs="$(state_read runs_served)"; runs=$((runs + 1))
  state_write "server_id=$id" "ip=$ip" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$(state_read boot_epoch)" \
    "create_epoch=$(state_read create_epoch)" \
    "ttl_hours=$(state_read ttl_hours)" "hard_ttl_hours=$(state_read hard_ttl_hours)" \
    "runs_served=$runs" "sandbox_ok=$(state_read sandbox_ok)" \
    "teardown_scheduled=$(state_read teardown_scheduled)" "teardown_epoch=$(state_read teardown_epoch)" "verified=$(state_read verified)" \
    "remote_user=$(state_read remote_user)" \
    "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)" \
    "box_cores=$(state_read box_cores)" "box_mem_gb=$(state_read box_mem_gb)" \
    "box_disk_gb=$(state_read box_disk_gb)" \
    "phase=$(state_read_phase)" "phase_epoch=$(state_read phase_epoch)"

  # PRD-build-burst-teardown-lifecycle requirement 5: a run that actually
  # reached the box, while a persistent volume is mounted, is this volume's
  # (not just this session's) proof that its cache has served a build —
  # tracked in volume.json (outlives this session, like volume_dirty) so a
  # later teardown's cold-volume decision has a signal independent of
  # whatever used_pct a df probe happens to read.
  if [ "$(volume_state_read volume_mounted)" = "true" ]; then
    local vruns; vruns="$(volume_state_read volume_runs_served)"
    case "$vruns" in ''|*[!0-9]*) vruns=0 ;; esac
    volume_state_write "volume_runs_served=$((vruns + 1))"
  fi

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
  attribution_record "$slug" "$id" "$wall_s" "$sync_s" 0 "$worktree" run 1 "$bytes_saved" true "" "$warm" "$phase"

  flock -u 201

  # PRD-build-burst-path-deps requirement 3: a build-classified failure
  # already got its own `run  build-failed` line above (with the compile/
  # resolution error's first line as cause) — the ordinary `run  routed`
  # line is skipped for it so no `exit=101 ... phase=test`-shaped row ever
  # exists for what was actually a build failure. Every other outcome
  # (success, or a genuine test-phase failure) keeps this line, now also
  # naming its phase alongside PRD-build-burst-persistent-volume's warm=.
  if [ "$phase" != "build" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  run  routed  (server_id=$id worktree=$worktree runs_served=$runs exit=$rc dirty=1 kind=$kind bytes_saved=$bytes_saved slug=$slug wall_s=$wall_s concurrent=$slot_held warm=$warm phase=${phase:-n/a})"
  fi
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
  # PRD-build-burst-path-deps-workspaces requirement 1: prefer the dirty
  # marker's own recorded remote_path (the sync_root a workspace member's
  # `run` actually used), same as do_marker_pull below — falls back to
  # pull_target_incremental's own remote_path_for(worktree) default when
  # there is no marker (this command predates pull-on-demand and never
  # required one).
  local sb_remote_path; sb_remote_path="$(dirty_field "$worktree" remote_path 2>/dev/null || true)"
  if ! bytes="$(pull_target_incremental "$worktree" "$ip" "$sb_remote_path")"; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sync-back  fallback  (cause=rsync-failed worktree=$worktree)"
    echo "fallback: rsync from $ip failed"
    exit 3
  fi
  # PRD-build-burst-pull-on-demand: sync-back is a real pull — it must not
  # leave a stale dirty marker behind claiming target/ is still ahead.
  record_pull_size "$worktree" "${bytes:-0}"
  clear_dirty "$worktree"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sync-back  ok  (worktree=$worktree bytes=$bytes)"
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
  mkdir -p "$BOX_STATE_DIR/locks" 2>/dev/null || true
  exec 205>"$(wt_lock_file "$worktree")"
  if ! flock -n 205; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  pull  refused  (worktree=$worktree cause=worktree-busy — a live run holds this worktree's lock)"
    echo "refused: worktree busy (live run in progress)" >&2
    exit 4
  fi
  if ! is_dirty "$worktree"; then
    flock -u 205
    echo "clean: nothing to pull"
    exit 0
  fi
  PULL_OUTCOME=""
  if do_marker_pull "$worktree" explicit; then
    flock -u 205
    # PRD-build-burst-pull-back-restore requirement 2: success (rc0) alone
    # no longer means "pulled" — only PULL_OUTCOME=transferred does. A
    # deferred/cold outcome is a deliberate skip, not a failure (both stay
    # exit 0, matching burstvol AC9/AC10's pinned rc), but it must never be
    # rendered as though bytes moved.
    case "$PULL_OUTCOME" in
      transferred)
        echo "pulled"
        ;;
      deferred)
        echo "deferred: insufficient local disk, marker left dirty for retry"
        ;;
      cold)
        echo "cold: remote artifacts gone, marker cleared"
        ;;
      *)
        # Defensive: not-dirty (raced clean between the is_dirty check above
        # and do_marker_pull's own) or any future outcome this case doesn't
        # yet name — never default to claiming a transfer we can't show
        # evidence for.
        echo "clean: nothing to pull"
        ;;
    esac
    exit 0
  fi
  flock -u 205
  # PRD-build-burst-dispatch-reenable requirement 5 (AC8, cause=pull-failed):
  # already satisfied by do_marker_pull's own
  # "pull fallback (cause=rsync-failed worktree=... trigger=... — marker
  # left dirty for retry)" line just above this return path — not
  # duplicated here with a second, differently-worded fallback line for the
  # same event.
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
  log="$("$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
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

# ---- parity baseline refresh on image change (PRD-build-burst-dispatch-
# reenable requirement 7, AC13) ----------------------------------------------
# toolchain_fingerprint() already folds SNAPSHOT_ID into the parity key, but
# the CACHED LOCAL suite capture (test-output.txt — the "parity-robust"
# refresh path's own cache, PRD-build-burst-parity-robust) is keyed by repo
# only, never by image. A bake landing between two sessions must not let a
# stale local capture (taken before the bake) get compared against a box
# that just booted a new, differently-tooled image: that comparison is not
# a real parity diff, just a stale cache. Tracks the image `up` resolved at
# the START of the previous session (PARITY_BASELINE_IMAGE_FILE, plain
# text — first-ever session or a selftest's fresh_env leaves it absent and
# never refreshes on that alone); on a change, deletes each configured
# repo's cached local capture so cmd_parity's own "no cached baseline ->
# full local rerun" branch fires fresh on both sides. Called from `up`
# (both the fresh-boot and adopt paths) BEFORE schedule_session_parity so
# the refresh — and its journal line — always precede any parity
# comparison, per AC13.
refresh_parity_baseline_on_image_change() {  # $1=current resolved image_id
  local cur_id="$1" prev_id=""
  [ -f "$PARITY_BASELINE_IMAGE_FILE" ] && prev_id="$(cat "$PARITY_BASELINE_IMAGE_FILE" 2>/dev/null || true)"
  if [ -n "$cur_id" ] && [ -n "$prev_id" ] && [ "$cur_id" != "$prev_id" ]; then
    local name repo f cleared=0
    for name in $BURST_PARITY_REPOS; do
      repo="$ATTR_REPOS_DIR/$name"
      f="$repo/target/autobuilder/test-output.txt"
      if [ -f "$f" ]; then
        rm -f "$f" 2>/dev/null || true
        cleared=$((cleared + 1))
      fi
    done
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  baseline-refreshed  (cause=bake image_id=$cur_id repos_cleared=$cleared)"
  fi
  mkdir -p "$(dirname "$PARITY_BASELINE_IMAGE_FILE")" 2>/dev/null || true
  printf '%s' "$cur_id" > "$PARITY_BASELINE_IMAGE_FILE" 2>/dev/null || true
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  schedule-skip  (repo=$name session=$sid cause=not-a-repo)"
      continue
    fi
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  scheduled  (repo=$name session=$sid)"
    # Requirement 3 (PRD-build-burst-prove-forensics): a backgrounded child
    # inherits whatever fds its parent has open at fork time — including a
    # lock fd (220 provision, 221 up, 201 run, 203 worktree) `up` itself may
    # currently hold. Left open, a `& disown` child keeps that flock alive
    # long after the parent that actually took it has exited, so a refused
    # `up` names a dead pid forever (the 2026-09-13 incident: this exact
    # line, called from inside `cmd_up`, outlived it). Closing all four here
    # is defensive for every caller of schedule_session_parity, not just the
    # two that hold 221 today — `flock -u` is not needed in the child; a
    # close on the fd it inherited is sufficient (see Technical
    # considerations in the PRD).
    # PRD-build-fail-loud-evidence-kept: scripts/lib/probe.sh's probe_bg
    # replaces the bare `( ... & disown )` — the fd closes are preserved
    # via --close-fds, and the child's eventual exit code now reaches the
    # journal (`probe bg-exit`) instead of dying unseen the way the
    # 2026-09-13 incident this comment describes did.
    probe_bg parity --close-fds 220,221,201,203 -- cmd_parity "$repo"
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  deferred  (cause=load repo=$repo waited=${pload_elapsed}s)"
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
  [ -n "$head_sha" ] || { echo "fallback: could not resolve HEAD for $repo"; journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  fallback  (cause=no-head repo=$repo)"; exit 3; }

  # Serialize against a live `run`/`parity` on the SAME worktree — same lock
  # `run`/`pull` already use, so a parity rsync-up never interleaves with a
  # live compile's own rsync of the same remote dir.
  mkdir -p "$BOX_STATE_DIR/locks" 2>/dev/null || true
  exec 206>"$(wt_lock_file "$repo")"
  flock 206

  local remote_path; remote_path="$(remote_path_for "$repo")"
  mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
  local up_log="$BOX_STATE_DIR/logs/rsync-parity.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$repo/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    flock -u 206
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" repo=$repo)"
    echo "fallback: rsync to $ip failed rc=$rsync_up_rc (see $up_log)"
    exit 3
  fi

  # PRD-build-burst-unprivileged-user: this is the exact call
  # `checkcompat_ac02_ac03` failed under — mcphost's own root-guard makes
  # $REMOTE_USER=root an invalid identity to run its integration suite
  # under, hence build. CARGO_HOME is RUN_CARGO_HOME (build's own writable
  # cargo home, requirement 5), NOT ROOT_CARGO_HOME — fixed 2026-09-11
  # (cargo-deny-advisory-db-lock-fails-at-head): this line still pointed
  # CARGO_HOME at root's shared, read+execute-only toolchain home after
  # requirement 5 moved every other remote cargo invocation (cmd_run,
  # cmd_verify) to RUN_CARGO_HOME, so any cargo subcommand needing a WRITE
  # under CARGO_HOME (cargo-deny's advisory-dbs lock, a not-yet-cached
  # registry fetch) failed here with a permission/lock error while the
  # same box's cmd_run path worked fine. $ROOT_CARGO_HOME/bin stays on
  # PATH so the cargo/rustup BINARIES still resolve to root's shared
  # toolchain — only the data directory moved.
  local remote_env_prefix="cd $remote_path && export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH:$ROOT_CARGO_HOME/bin:/root/.local/bin RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$RUN_CARGO_HOME CARGO_TARGET_DIR=$remote_path/target"

  # PRD-build-burst-parity-robust requirement 1: cargo-nextest is the
  # PRIMARY capture on both sides (already provisioned on the box via
  # GATE_TOOLS_LIST; RedBaron has it locally) — every result line carries
  # its own binary name, so attribution never depends on stream-interleave
  # ordering the way the old Running/result pairing did. A side lacking
  # cargo-nextest falls back to `cargo test` (the previous parser, kept
  # verbatim as the rollback path).
  local box_capture="cargo-test"
  if "$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
       "$remote_env_prefix; command -v cargo-nextest" >/dev/null 2>&1; then
    box_capture="nextest"
  fi
  local box_log box_suites
  if [ "$box_capture" = "nextest" ]; then
    box_log="$("$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "$remote_env_prefix; cargo nextest run --workspace --no-fail-fast" 2>&1)"
    local box_list_json; box_list_json="$("$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
      "$remote_env_prefix; cargo nextest list --workspace --message-format json" 2>/dev/null)"
    local box_names; box_names="$(printf '%s' "$box_list_json" | cargo_nextest_list_names)"
    local box_results; box_results="$(printf '%s\n' "$box_log" | cargo_nextest_suites_json)"
    box_suites="$(nextest_merge_suites "$box_names" "$box_results")"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  capture=cargo-test  (side=box repo=$repo)"
    box_log="$("$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" \
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  capture=cargo-test  (side=local repo=$repo)"
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  baseline-refreshed  (repo=$repo names=$missing_locally)"
    fi
  fi

  if [ "$box_capture" != "$local_capture" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  capture-mismatch  (repo=$repo box=$box_capture local=$local_capture)"
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
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  rerun  (suite=$name side=box)"
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
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  rerun  (suite=$name side=local)"
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
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  $status_word  (repo=$repo head=$head_sha box=$ip diff=$diff_count session=$session_id)"
  if [ "$host_sensitive_count" -gt 0 ]; then
    host_sensitive_names="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["host_sensitive"]))' "$diff_json")"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  host-sensitive  (repo=$repo names=$host_sensitive_names)"
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
GATE_INFLIGHT_DIR="$BOX_STATE_DIR/gate-inflight"
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
      "$RSYNC_BIN" -az --delete -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/target/autobuilder/" "$repo/target/autobuilder/" >/dev/null 2>&1 || true
      "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$REMOTE_USER@$ip:$remote_path/.gate-burst-host" "$repo/.gate-burst-host" >/dev/null 2>&1 || true
      local verdict; verdict="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("block" if d.get("block", 0) else "pass")
except Exception:
    print("unknown")
' "$repo/target/autobuilder/last-verdict.json" 2>/dev/null)"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  gate  $verdict  (repo=$repo host=$ip waited=true age=${age}s)"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  gate  abandoned  (repo=$repo host=$ip age=${age}s budget=${budget_s}s)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=remote-disabled repo=$repo)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=no-head repo=$repo)"
    echo "fallback: no-head"
    exit 3
  fi
  if [ -n "$head_arg" ] && [ "$head_arg" != "$head_now" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=head-mismatch repo=$repo requested=$head_arg actual=$head_now)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  parity  reproof  (cause=$cause repo=$repo)"
    # Subshell: cmd_parity ends every path with an `exit`, correct for a
    # top-level dispatch but fatal to the calling process if invoked as a
    # plain function call — `( ... )` scopes that exit to the subshell only.
    # PRD-build-fail-loud-evidence-kept: probe_run keeps the reproof's
    # stderr (was /dev/null) and journals rc/err/log on failure; the
    # `gate fallback (cause=...)` line right below still fires as before —
    # this is additive evidence, not a replacement for it.
    ( probe_run parity-reproof -- cmd_parity "$repo" ) >/dev/null 2>&1 || true
    cause="$(check_parity_receipt "$repo")"
  fi
  if [ -n "$cause" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=$cause repo=$repo head=$head_now)"
    echo "fallback: $cause"
    exit 3
  fi

  if ! state_active; then
    local up_out; up_out="$(cmd_up 2>&1)"; local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=up-failed repo=$repo)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=gate-tools-missing repo=$repo missing=${gt_missing:-unknown})"
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

  mkdir -p "$BOX_STATE_DIR/locks" 2>/dev/null || true
  exec 212>"$(wt_lock_file "$repo")"
  flock 212

  local remote_path; remote_path="$(remote_path_for "$repo")"
  mkdir -p "$BOX_STATE_DIR/logs" 2>/dev/null || true
  local up_log="$BOX_STATE_DIR/logs/rsync-gate.$$.log" rsync_up_rc=0
  "$RSYNC_BIN" -az --delete --exclude target --exclude .git --exclude .venv \
        --rsync-path="mkdir -p '$remote_path' && rsync" \
        -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
        "$repo/" "$REMOTE_USER@$ip:$remote_path/" >"$up_log" 2>&1 || rsync_up_rc=$?
  if [ "$rsync_up_rc" -ne 0 ]; then
    flock -u 212
    local up_err; up_err="$(grep -v '^[[:space:]]*$' "$up_log" 2>/dev/null | tail -n1)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=rsync-up-failed rc=$rsync_up_rc err=\"$up_err\" repo=$repo)"
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
  # per the PRD's technical considerations. RUSTUP_HOME stays
  # ROOT_RUSTUP_HOME (read-only toolchain, fine) but CARGO_HOME is
  # RUN_CARGO_HOME, NOT ROOT_CARGO_HOME — fixed 2026-09-11
  # (cargo-deny-advisory-db-lock-fails-at-head): pointing CARGO_HOME at
  # root's shared, read+execute-only home broke any cargo-deny invocation
  # inside extend-gate.sh's own audit-checks.sh (advisories check needs to
  # create/lock $CARGO_HOME/advisory-dbs, a WRITE root's chmod o+rX never
  # grants build) even though every other remote cargo invocation
  # (cmd_run, cmd_verify) already uses RUN_CARGO_HOME per requirement 5.
  # $ROOT_CARGO_HOME/bin stays on PATH so the cargo/rustup BINARIES still
  # resolve to root's shared toolchain — only the data directory moved.
  local remote_journal="$remote_path/target/autobuilder/gate-journal.md"
  local remote_cmd="cd $remote_path && export PATH=\$PATH:$GATE_TOOLS_REMOTE_BIN_DIR:$ROOT_CARGO_HOME/bin:/root/.local/bin:$REMOTE_ROOT/.gate-tools/build-scripts RUSTUP_HOME=$ROOT_RUSTUP_HOME CARGO_HOME=$RUN_CARGO_HOME RUSTC_WRAPPER=sccache SCCACHE_DIR=$REMOTE_SCCACHE_DIR SCCACHE_CACHE_SIZE=${BURST_SCCACHE_GB}G BURST_LANE=0 RUSTBUILD_SCRIPTS=$REMOTE_ROOT/.gate-tools/rustbuild-scripts REVIEWER_PROMPT=$REMOTE_ROOT/.gate-tools/rustbuild-prompts/reviewer-agent.md EXTEND_GATE_JOURNAL=$remote_journal; extend-gate.sh . $(printf '%q ' "${extra_args[@]}")"
  "$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" "bash -lc $(printf '%q' "$remote_cmd")" || rc=$?
  t1="$(now_fractional)"
  rm -f "$inflight_marker"

  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    flock -u 212
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  fallback  (cause=remote-extend-gate-not-runnable rc=$rc repo=$repo)"
    echo "fallback: remote extend-gate.sh not runnable on box (rc=$rc)"
    exit 3
  fi

  "$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" "echo $ip > $remote_path/.gate-burst-host" 2>/dev/null || true

  mkdir -p "$repo/target/autobuilder" 2>/dev/null || true
  "$RSYNC_BIN" -az --delete -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
    "$REMOTE_USER@$ip:$remote_path/target/autobuilder/" "$repo/target/autobuilder/" >/dev/null 2>&1 || true
  "$RSYNC_BIN" -az -e "$SSH_BIN $(ssh_kh_args) -i $SSH_KEY" \
    "$REMOTE_USER@$ip:$remote_path/.gate-burst-host" "$repo/.gate-burst-host" >/dev/null 2>&1 || true

  # Fold the box's redirected extend-gate.sh journal onto RedBaron's real
  # tick journal (single-writer: this is the only place a remote gate's
  # journal lines land), then clear it on the box so a later gate on the
  # same persistent remote_path doesn't re-append lines already folded in.
  local pulled_journal="$repo/target/autobuilder/gate-journal.md"
  if [ -s "$pulled_journal" ]; then
    local tj_today; tj_today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
    journal_line --file "$TICK_JOURNAL_DIR/$tj_today.md" "$(cat "$pulled_journal")"
    rm -f "$pulled_journal"
    "$SSH_BIN" $(ssh_kh_args) -i "$SSH_KEY" "$REMOTE_USER@$ip" "rm -f $remote_journal" 2>/dev/null || true
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
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  gate  $verdict  (repo=$repo host=$ip wall=${wall_s}s head=$head_now exit=$rc)"
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
  mkdir -p "$BOX_STATE_DIR/locks" 2>/dev/null || true
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
  mkdir -p "$DIRTY_DIR" "$BOX_STATE_DIR/locks" 2>/dev/null || true
  # Money guard (Joe 2026-09-11): pulls at teardown are optional and bounded. With the loop stopped
  # nothing will read them, and on 09-11 a sweep that pulled worktrees back for 10+ min kept a
  # billed box alive past a forced delete. Skip entirely when the loop is inactive; cap each pull.
  if [ "$(systemctl --user is-active claude-build.path 2>/dev/null)" != "active" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  ${1:-down}  sweep-skipped  (cause=loop-stopped — delete proceeds without pulls)"
    return 0
  fi
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  ${1:-down}  sweep-failed  (worktree=$wt — busy or pull failed; marker left in place, sweep continues)"
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
        # PRD-build-burst-path-deps-workspaces requirement 1/3: a workspace
        # sync remote dir is keyed by hash8(sync_root), not hash8(worktree)
        # -- add it too so the found-by-hash8 search below (roots/extra_paths)
        # can actually match it. A plain (non-workspace) run always has
        # sync_root equal to its own worktree, so this is a harmless
        # no-op duplicate in that case.
        sr = d.get("sync_root", "")
        if sr:
            extra_paths.add(sr)
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
    # PRD-build-burst-path-deps-workspaces requirement 3: "deps" itself is
    # the lane own container directory for external path-dependency
    # mirrors, never a worktree -- it matches neither the hash8-suffixed nor
    # the legacy-basename shape below, so without this it always fell
    # through to "no local worktree of that name" and got deleted outright
    # (the exact 2026-09-11 autobuilder incident: reap ok (dir=deps
    # reason=legacy-no-local-match), taking a live dependency mirror with
    # it). Its CHILDREN are reaped individually, by the lane-owned-directory
    # manifest, in reap_orphans() own second pass -- never here.
    if name == "deps":
        print("%s\tcontainer\tlane-owned\t" % name)
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
  local list_out; list_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
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
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name root=$OLD_ROOT_REMOTE_ROOT reason=gate-inflight)"
      continue
    fi
    if ! ( exec 208>"$(wt_lock_file "$OLD_ROOT_REMOTE_ROOT/$name")"; flock -n 208 ); then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name root=$OLD_ROOT_REMOTE_ROOT reason=busy)"
      continue
    fi
    local bytes
    bytes="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
        "root@$ip" "du -sb '$OLD_ROOT_REMOTE_ROOT/$name' 2>/dev/null | cut -f1" 2>/dev/null)"
    bytes="${bytes:-0}"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
         "root@$ip" "rm -rf '$OLD_ROOT_REMOTE_ROOT/$name'" 2>/dev/null; then
      reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + bytes))
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  ok  (dir=$name root=$OLD_ROOT_REMOTE_ROOT bytes=$bytes reason=old-root)"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  fail  (dir=$name root=$OLD_ROOT_REMOTE_ROOT cause=rm-failed)"
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

# ---- deps/ children reap (PRD-build-burst-path-deps-workspaces requirement
# 3) ---------------------------------------------------------------------
# reap_plan()'s top-level scan treats "deps" as a single opaque container
# (action=container, never deleted by the loop above) — its INDIVIDUAL
# mirror subdirectories are what actually need reaping, and neither of
# reap_plan()'s existing "found" sources (the fixed candidate worktree
# roots, the dirty/attribution ledgers) can ever resolve one, since a
# mirrored dependency's local path is an arbitrary external sibling crate
# directory, not a worktree. The lane-owned directory manifest
# (remote_dirs_record(), written by `run`) is what actually answers "is
# this mirror still needed": kept while its recorded owner worktree exists
# locally, reaped with reason=owner-gone the moment it doesn't. A child with
# NO manifest entry (a mirror created before this PRD shipped, per the PRD's
# own migration note) is reaped outright as reason=legacy-no-local-match —
# it is "adopted" into the manifest instead, automatically, the next time
# its owning worktree actually runs and re-syncs it (record happens on
# every dep sync, live or not).
reap_deps_manifest_dirs() {  # $1=ip $2=inflight_names(newline list) -> stdout "reaped_dirs=N reaped_bytes=N"
  local ip="$1" inflight_names="$2"
  local reaped_dirs=0 reaped_bytes=0
  local deps_list_cmd="find '$REMOTE_ROOT/deps' -mindepth 1 -maxdepth 1 -not -name '.*' -printf '%f\n' 2>/dev/null"
  local deps_out
  deps_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
      "$REMOTE_USER@$ip" "$deps_list_cmd" 2>/dev/null)"
  if [ -z "$deps_out" ]; then
    echo "reaped_dirs=0 reaped_bytes=0"; return 0
  fi
  local child relkey owner
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    relkey="deps/$child"
    if grep -qxF "$relkey" <<<"$inflight_names"; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$relkey reason=gate-inflight)"
      continue
    fi
    owner=""
    if owner="$(remote_dirs_owner "$relkey")" && [ -n "$owner" ]; then
      if [ -d "$owner" ]; then
        continue  # live: untouched, no journal noise (matches top-level "live")
      fi
      if ! ( exec 210>"$(wt_lock_file "$owner")"; flock -n 210 ); then
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$relkey reason=busy)"
        continue
      fi
      local bytes
      bytes="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
          "$REMOTE_USER@$ip" "du -sb '$REMOTE_ROOT/$relkey' 2>/dev/null | cut -f1" 2>/dev/null)"
      bytes="${bytes:-0}"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
           "$REMOTE_USER@$ip" "rm -rf '$REMOTE_ROOT/$relkey'" 2>/dev/null; then
        reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + bytes))
        remote_dirs_remove "$relkey"
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  ok  (dir=$relkey bytes=$bytes reason=owner-gone)"
      else
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  fail  (dir=$relkey cause=rm-failed)"
      fi
    else
      # No manifest entry — legacy pre-PRD mirror (or a race with a run
      # that hasn't recorded it yet). Reaped, not adopted; see header note.
      local lbytes
      lbytes="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
          "$REMOTE_USER@$ip" "du -sb '$REMOTE_ROOT/$relkey' 2>/dev/null | cut -f1" 2>/dev/null)"
      lbytes="${lbytes:-0}"; case "$lbytes" in ''|*[!0-9]*) lbytes=0 ;; esac
      if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
           "$REMOTE_USER@$ip" "rm -rf '$REMOTE_ROOT/$relkey'" 2>/dev/null; then
        reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + lbytes))
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  ok  (dir=$relkey bytes=$lbytes reason=legacy-no-local-match)"
      else
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  fail  (dir=$relkey cause=rm-failed)"
      fi
    fi
  done <<<"$deps_out"
  echo "reaped_dirs=$reaped_dirs reaped_bytes=$reaped_bytes"
}

reap_orphans() {
  local reaped_dirs=0 reaped_bytes=0
  mkdir -p "$DIRTY_DIR" "$BOX_STATE_DIR/locks" 2>/dev/null || true
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
  list_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
      "$REMOTE_USER@$ip" "$list_cmd" 2>/dev/null)" || list_rc=$?
  if [ "$list_rc" -ne 0 ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  fail  (cause=ssh rc=$list_rc)"
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
      keep)  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=keep)" ;;
      dirty) journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=dirty)" ;;
      live)  : ;;  # untouched, no journal noise on every healthy pass
      container) : ;;  # "deps" itself — its children are reaped below, never this container
      orphan)
        if grep -qxF "$name" <<<"$inflight_names"; then
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=gate-inflight)"
          continue
        fi
        local busy=0
        if [ -n "$wt" ] && ! ( exec 207>"$(wt_lock_file "$wt")"; flock -n 207 ); then
          busy=1
        fi
        if [ "$busy" -eq 1 ]; then
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  skip  (dir=$name reason=busy)"
          continue
        fi
        local bytes
        bytes="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
            "$REMOTE_USER@$ip" "du -sb '$REMOTE_ROOT/$name' 2>/dev/null | cut -f1" 2>/dev/null)"
        bytes="${bytes:-0}"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        if "$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
             "$REMOTE_USER@$ip" "rm -rf '$REMOTE_ROOT/$name'" 2>/dev/null; then
          reaped_dirs=$((reaped_dirs + 1)); reaped_bytes=$((reaped_bytes + bytes))
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  ok  (dir=$name bytes=$bytes reason=$reason)"
        else
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  fail  (dir=$name cause=rm-failed)"
        fi
        ;;
    esac
  done <<<"$plan"

  # PRD-build-burst-path-deps-workspaces requirement 3: deps/'s own children,
  # judged against the lane-owned directory manifest rather than reap_plan's
  # worktree-shaped classification (see reap_deps_manifest_dirs()'s header).
  local deps_out deps_dirs deps_bytes
  deps_out="$(reap_deps_manifest_dirs "$ip" "$inflight_names")"
  deps_dirs="$(sed -n 's/^reaped_dirs=\([0-9]*\).*/\1/p' <<<"$deps_out")"
  deps_bytes="$(sed -n 's/.*reaped_bytes=\([0-9]*\)$/\1/p' <<<"$deps_out")"
  reaped_dirs=$((reaped_dirs + ${deps_dirs:-0}))
  reaped_bytes=$((reaped_bytes + ${deps_bytes:-0}))

  reap_finish "$reaped_dirs" "$reaped_bytes"
  return 0
}

# PRD-build-burst-provision-forensics requirement 4: local-process orphan
# sweep — distinct from reap_orphans() above, which reaps stale REMOTE
# worktree dirs on the box. This kills stale LOCAL `burst-lane.sh up` /
# `provision` processes: the observed 2026-09-13 incident was 3 such
# processes, one 11+ minutes old, racing a controlled provision and
# holding apt activity on the box — reap_orphans() never looked at them.
#
# Reads $INFLIGHT_LOG (one "<epoch> <pid> <kind>" row per provision/up
# invocation that got far enough to acquire its own lock — see cmd_up /
# cmd_provision above) rather than grepping `ps` for a cmdline pattern:
# a registry row is unambiguous about which pid is which kind, where a
# `ps` pattern match on "burst-lane.sh (up|provision)" would also have to
# reconstruct that same fact from a cmdline string that a test fixture (or
# a real shell wrapper) is free to spell differently. A row is left alone
# when its pid is already dead (pruned silently — normal exit, nothing to
# reap) or younger than BURST_ORPHAN_AGE_S. Deliberately NOT exempted:
# "currently named in up.pid/provision.pid" — the 2026-09-13 incident's
# orphans were genuinely alive and, for as long as they kept running,
# just as capable of holding that file's contents as the process actually
# still doing useful work; age is the only signal this PRD's own
# Requirement 4 names ("older than a threshold with no live session
# activity"), so age alone decides. Everything alive and at or past the
# threshold is killed (TERM, then KILL if it survives 1s) and journaled
# by pid — including, deliberately, a single still-running holder that
# has simply taken too long; an operator who needs a longer-than-default
# install window raises BURST_ORPHAN_AGE_S rather than this function
# special-casing "looks legitimate."
reap_orphan_processes() {
  [ -f "$INFLIGHT_LOG" ] || { echo "orphan-processes-killed=0"; return 0; }
  local now; now="$(now_epoch)"
  local -a keep_rows=()
  local killed=0
  local ts pid kind age
  while read -r ts pid kind; do
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      continue  # already dead — drop the row, nothing to reap
    fi
    age=$((now - ts))
    if [ "$age" -ge "$BURST_ORPHAN_AGE_S" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  orphan-killed  (pid=$pid kind=$kind age_s=$age)"
      killed=$((killed + 1))
    else
      keep_rows+=("$ts $pid $kind")  # alive, still young — leave it running
    fi
  done < "$INFLIGHT_LOG"
  local tmp="$INFLIGHT_LOG.tmp.$$"
  : > "$tmp"
  local row
  for row in "${keep_rows[@]:-}"; do
    [ -n "$row" ] && printf '%s\n' "$row" >> "$tmp"
  done
  mv -f "$tmp" "$INFLIGHT_LOG"
  echo "orphan-processes-killed=$killed"
}

# PRD-build-burst-pull-remote-target-missing requirement 8: a marker
# `local-read` gave up on (stuck=true, 8 straight failures) is only ever
# cleared by a NEW routed run rewriting it (mark_dirty's fresh overwrite) —
# but the session that would run one may itself be gone (crashed, torn
# down without a sweep). Rather than leave a stuck marker dirty forever
# with nobody left to un-stick it, `reap` clears it once its own
# session_id no longer matches the current active session (or there is no
# active session at all) — same "no active session = stale, safe to drop"
# doctrine do_marker_pull's own cold path already uses.
reap_stuck_markers() {  # -> stdout "stuck-markers-reaped=N"
  mkdir -p "$DIRTY_DIR" 2>/dev/null || true
  local n=0 f row stuck wt sid cur_sid=""
  if state_active; then cur_sid="$(state_read server_id)"; fi
  for f in "$DIRTY_DIR"/*.json; do
    [ -e "$f" ] || continue
    row="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print("%s\t%s\t%s" % (str(bool(d.get("stuck", False))).lower(), d.get("worktree", ""), d.get("session_id", "")))
' "$f" 2>/dev/null)"
    IFS=$'\t' read -r stuck wt sid <<<"$row"
    [ "$stuck" = "true" ] || continue
    if [ -z "$cur_sid" ] || [ "$sid" != "$cur_sid" ]; then
      rm -f "$f"
      n=$((n + 1))
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  marker-stuck-cleared  (worktree=$wt session_id=$sid)"
    fi
  done
  echo "stuck-markers-reaped=$n"
}

cmd_reap() {
  if [ "${1:-}" = "--volumes" ]; then
    reap_volumes
    exit 0
  fi
  local proc_out; proc_out="$(reap_orphan_processes)"
  local out; out="$(reap_orphans)"
  local prove_out; prove_out="$(reap_prove_logs)"
  local evidence_out; evidence_out="$(reap_evidence)"
  local stuck_out; stuck_out="$(reap_stuck_markers)"
  # PRD-build-burst-state-keyed-by-server-v2 requirement 8/AC9: a
  # wm-burst-lane* server hcloud still knows about with no boxes/<id>/ dir
  # here is unattributable to any of the other reap/cost/teardown paths
  # above (every one of them is keyed by box_path()'s "boxes/<id>/") — sweep
  # it every plain `reap` call, same cadence as the rest of this function.
  local orphan_box_out; orphan_box_out="$(reap_orphan_boxes)"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$proc_out" "$out" "$prove_out" "$evidence_out" "$stuck_out" "$orphan_box_out"
  exit 0
}

# Requirement 2: prove's per-step logs (state/burst-lane/logs/prove.*.log)
# are kept, never rm -f'd by prove itself — they're the forensics this PRD
# exists to preserve. `reap` is what ages them out, same as any other
# on-disk debris this script owns, after 14 days.
reap_prove_logs() {  # -> stdout "prove-logs-reaped=N"
  local dir="$BOX_STATE_DIR/logs" n=0 f
  [ -d "$dir" ] || { echo "prove-logs-reaped=0"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f" 2>/dev/null && n=$((n+1))
  done < <(find "$dir" -maxdepth 1 -type f -name 'prove.*.log' -mtime +14 2>/dev/null)
  echo "prove-logs-reaped=$n"
}

# ---- orphan volume sweep (PRD-build-burst-teardown-lifecycle requirement 6) -
# Locates a burst-owned volume by NAME (find_volume(), the same by-name
# hcloud lookup `up`/volume_reconcile already use), never by session.json's
# volume_id pointer — a server deleted out-of-band (by hand, or by a caller
# that skipped this script entirely) leaves exactly this shape: the volume
# still exists in hcloud, but this lane's own state files may be stale,
# archived, or gone. A volume still attached to a server hcloud confirms is
# alive is left alone (genuinely in use, not orphaned); anything else —
# unattached, or attached to an id that's no longer alive — is deleted
# unconditionally (no used_pct keep-check here: a stranded volume with no
# session pointer at all has nobody left to decide "keep it for the next
# run", so `reap --volumes` and `down --force` (which calls this too) both
# just remove it rather than let it bill forever undiscovered) and
# journaled with its id and whatever used_pct is on record.
reap_volumes() {  # -> stdout "volumes-reaped=N"
  [ -n "$BURST_VOLUME_NAME" ] || { echo "volumes-reaped=0"; return 0; }
  local found; found="$(find_volume 2>/dev/null)"
  if [ -z "$found" ]; then
    echo "volumes-reaped=0"
    return 0
  fi
  local vid vsize vserver vdevice vcreated
  IFS='|' read -r vid vsize vserver vdevice vcreated <<<"$found"
  if [ -n "$vserver" ] && server_alive "$vserver"; then
    echo "volumes-reaped=0"
    return 0
  fi
  local used_pct; used_pct="$(volume_state_read volume_used_pct)"; used_pct="${used_pct:-unknown}"
  # PRD-build-burst-volume-id-parse AC6: age in hours from hcloud's own
  # "created" timestamp (never from local state — this sweep's whole point
  # is finding volumes with no session pointer at all).
  local age_h="unknown"
  if [ -n "$vcreated" ]; then
    local created_epoch; created_epoch="$(date -u -d "$vcreated" +%s 2>/dev/null || echo "")"
    [ -n "$created_epoch" ] && age_h=$(( ( $(now_epoch) - created_epoch ) / 3600 ))
  fi
  if "$HCLOUD" volume delete "$vid" >/dev/null 2>&1; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  volume-deleted  (id=$vid used_pct=$used_pct size=${vsize:-unknown}G age_h=$age_h cause=orphaned-no-session-pointer)"
    rm -f "$VOLUME_STATE_FILE"
    echo "volumes-reaped=1"
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  volume-delete-failed  (id=$vid used_pct=$used_pct size=${vsize:-unknown}G age_h=$age_h)"
    echo "volumes-reaped=0"
  fi
}

# ---- orphan-box server sweep (PRD-build-burst-state-keyed-by-server-v2
# requirement 8, AC9) --------------------------------------------------------
# A wm-burst-lane* server hcloud still lists but this state dir has no
# boxes/<id>/ directory for is unattributable: every other reap/cost/
# teardown path above is keyed by box_path()'s "boxes/<id>/" (requirement
# 1), so nothing left in this script can ever act on that server again — the
# exact unattributed-billing failure class this PRD exists to close (the
# 09-13 orphaned-volume incident's server-side twin). Unlike reap_volumes
# above (one named lane-wide volume, no used_pct keep-check because it has
# no session pointer to consult), this sweep iterates EVERY server the
# find_by_prefix("$SERVER_NAME") set names, deletes any with no matching
# boxes/ dir unconditionally, and journals `reap  orphan-box-deleted` per
# PRD contract — a server with a boxes/<id>/ dir (active OR already torn
# down, same distinction list_all_box_ids draws) is left alone even if its
# own down/watchdog/idle-guard decision hasn't run yet; this sweep is a
# backstop for a server this script's own bookkeeping never learned about
# at all (created out of band, or whose boxes/<id>/ dir was itself deleted
# by hand), not a substitute for the normal teardown decision path.
reap_orphan_boxes() {  # -> stdout "orphan-boxes-reaped=N"
  # Membership is checked via list_all_box_ids (a helper inside the
  # tripwire's own box_path()/box_activate() license region) rather than a
  # literal "$STATE_DIR/boxes/$id" test here — the tripwire (requirement 10)
  # fails on any "boxes/" literal outside that block, and this function
  # lives far below it alongside the rest of `reap`'s own helpers.
  local n=0 line id ip name known
  known="$(list_all_box_ids)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r id ip name <<<"$line"
    [ -n "$id" ] || continue
    grep -qx "$id" <<<"$known" && continue
    if destroy_verify "$id"; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  orphan-box-deleted  (server_id=$id name=$name cause=no-boxes-dir)"
      n=$((n + 1))
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  reap  orphan-box-delete-failed  (server_id=$id name=$name)"
    fi
  done < <(find_by_prefix "$SERVER_NAME" 2>/dev/null)
  echo "orphan-boxes-reaped=$n"
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
  list_out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
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

# ---- teardown_decision (PRD-build-burst-teardown-evidence) ------------------
# Requirement 1: one pure(ish) decision function reading only evidence the box
# and its own ledgers provide — hcloud's own idea of the server (existence,
# `created`), the last routed run for this server id from attribution.jsonl,
# how much rust/python work is queued, whether the loop is active, and the
# TTL/zero-runs-grace knobs — never local session-state writes a prior `up`
# happened to make (the 2026-09-15 incident: adopt reset runs_served to 0,
# and idle-guard trusted that reset number instead of asking the ledger).
#
# hcloud_probe_status: distinguishes "alive" (with hcloud's own `created`),
# "gone" (hcloud positively says so), and "unavailable" (the probe itself
# could not answer — absent binary, auth failure, API error) — the three-way
# split requirement 3 needs, since only the middle one is real evidence a box
# is actually gone.
hcloud_probe_status() {  # $1 = server id -> stdout "alive <created_iso>"|"gone"|"unavailable"
  local id="$1"
  command -v "$HCLOUD" >/dev/null 2>&1 || { echo "unavailable"; return 0; }
  local out rc
  out="$("$HCLOUD" server describe "$id" -o json 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    local created
    created="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    d = d.get("server", d)
    print(d.get("created",""))
except Exception:
    print("")
' "$out" 2>/dev/null)"
    echo "alive $created"
    return 0
  fi
  case "$out" in
    *"not found"*|*"not exist"*) echo "gone"; return 0 ;;
  esac
  # Ambiguous failure (auth error, network blip, rate limit) — confirm with a
  # second, cheaper call before ever calling it "gone"; fail OPEN to
  # "unavailable" (never a deletion cause, requirement 3) rather than assume
  # the worse of the two readings.
  if "$HCLOUD" server list -o noheader -o columns=id >/dev/null 2>&1; then
    echo "gone"
  else
    echo "unavailable"
  fi
}

# attribution_stats_for: how many attribution.jsonl rows this server id has
# actually served, and the newest row's own date — the two numbers adopt
# should have been deriving all along (requirement 4) and the two numbers
# teardown_decision's own idle-vs-work-queued split (requirement 5, AC4/AC5)
# reads instead of the locally-writable runs_served field.
attribution_stats_for() {  # $1 = server id -> stdout "<count> <last_iso_or_->"
  local id="$1"
  [ -f "$ATTR_LEDGER" ] || { echo "0 -"; return 0; }
  python3 -c '
import json, sys
sid, path = sys.argv[1], sys.argv[2]
count = 0
last = ""
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if str(d.get("session_id")) != sid:
        continue
    count += 1
    dt = d.get("date","")
    if dt > last:
        last = dt
print(count, last or "-")
' "$id" "$ATTR_LEDGER"
}

# queued_work_count: how many build-queue/ PRDs are queued/building/
# in_progress rust-*/python-* work right now — same predicate rust_work_
# remains() already uses, counted instead of short-circuited on the first
# match, so teardown_decision's evidence object can show the actual count.
queued_work_count() {  # -> stdout: integer count
  local dir="$PRD_DIR/build-queue" n=0
  if [ -d "$dir" ]; then
    local f bt st
    for f in "$dir"/PRD-*.md; do
      [ -f "$f" ] || continue
      bt="$(grep -m1 -oE '^-[[:space:]]*build_target:[[:space:]]*[A-Za-z0-9_-]+' "$f" 2>/dev/null | sed -E 's/^-[[:space:]]*build_target:[[:space:]]*//')"
      case "$bt" in rust-cli|rust-lib|rust-extend|python-cli|python-lib|python-agent) ;; *) continue ;; esac
      st="$(grep -m1 -oE '^-[[:space:]]*Status:[[:space:]]*[A-Za-z0-9_-]+' "$f" 2>/dev/null | sed -E 's/^-[[:space:]]*Status:[[:space:]]*//')"
      case "$st" in queued|building|in_progress) n=$((n+1)) ;; esac
    done
  fi
  echo "$n"
}

# loop_active: is claude-build.path (the tick's own path unit) active right
# now — same probe cmd_status's sweep_dirty_worktrees already makes
# (systemctl --user is-active claude-build.path). BURST_LANE_LOOP_ACTIVE_
# OVERRIDE lets the selftest pin true/false without a real systemd user
# session; production never sets it.
loop_active() {  # rc0 = active
  case "${BURST_LANE_LOOP_ACTIVE_OVERRIDE:-}" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  [ "$(systemctl --user is-active claude-build.path 2>/dev/null)" = "active" ]
}

# seconds_to_next_tick / median_first_run_latency: the two terms requirement
# 5's grace formula needs beyond the existing BURST_IDLE_GUARD_ZERO_RUNS_AGE_S
# floor. The lane is event-driven (a DirectoryNotEmpty path unit, not a fixed-
# interval timer — project_build_timer_removed_actively_managed), so neither
# term has a true, always-on measurement to read: seconds_to_next_tick has no
# schedule to consult (env override, default 300s, a conservative guess at
# "how long until a queue change could plausibly fire the path unit"), and
# median_first_run_latency would need a persistent per-session up-> first-
# attribution-row latency log this codebase does not keep yet (adding one is
# out of this PRD's scope — see Non-goals). Both are documented, overridable
# fallbacks; the formula's own max() against BURST_IDLE_GUARD_ZERO_RUNS_AGE_S
# still holds correctly with these fallbacks (AC3's grace_s >= 1200 is
# satisfied by the fallback alone: 300 + 2*1200 = 2700).
seconds_to_next_tick() { echo "${BURST_LANE_TICK_INTERVAL_S:-300}"; }
median_first_run_latency() { echo "${BURST_LANE_MEDIAN_FIRST_RUN_LATENCY_S:-1200}"; }

# _teardown_decision_record: append one row to decisions.jsonl and journal
# one line — requirement 1's own "appends ... and journals" contract.
# Requirement 3: a cause=probe-unavailable journal line is throttled to once
# per hour (tracked in $PROBE_UNAVAILABLE_MARK_FILE) so an outage that lasts
# all day journals once, not once per caller invocation; the decisions.jsonl
# row itself is still appended every call (why-down's own trail).
_teardown_decision_record() {  # $1=id $2=caller $3=decision $4=cause $5=evidence_json
  local id="${1:-none}" caller="$2" decision="$3" cause="$4" evidence="$5"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  python3 -c '
import json, sys
row = {"ts": sys.argv[1], "server_id": sys.argv[2], "caller": sys.argv[3],
       "decision": sys.argv[4], "cause": sys.argv[5], "evidence": json.loads(sys.argv[6])}
with open(sys.argv[7], "a") as fh:
    fh.write(json.dumps(row) + "\n")
' "$(now_iso)" "$id" "$caller" "$decision" "$cause" "$evidence" "$DECISIONS_LEDGER" 2>/dev/null || true
  if [ "$cause" = "probe-unavailable" ]; then
    local last; last="$(cat "$PROBE_UNAVAILABLE_MARK_FILE" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( $(now_epoch) - last )) -lt 3600 ]; then
      return 0
    fi
    echo "$(now_epoch)" > "$PROBE_UNAVAILABLE_MARK_FILE" 2>/dev/null || true
  fi
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  decision=$decision  (server_id=$id cause=$cause evidence=$evidence)"
}

# teardown_decision: the single evidence-backed answer requirement 1 wants.
# $1=server_id $2=caller(down|watchdog|idle-guard|status|why-down-preview)
# $3=--dry-run (optional) — a dry-run NEVER writes decisions.jsonl or the
# journal (status --json's next_teardown preview calls this every poll; a
# ledger row per poll would spam the trail with nothing an operator asked
# for). Stdout, always three lines: decision=<keep|delete>, cause=<c>,
# eta_s=<n|null> (0 when decision=delete, the remaining grace when the cause
# is "grace", null otherwise — requirement 8's own next_teardown.eta_s).
teardown_decision() {
  local id="$1" caller="$2" dry_run=0
  [ "${3:-}" = "--dry-run" ] && dry_run=1

  local probe created_iso=""
  read -r probe created_iso <<<"$(hcloud_probe_status "$id")"

  local decision cause evidence eta_s="null"
  if [ "$probe" = "unavailable" ]; then
    decision=keep; cause=probe-unavailable
    evidence='{"probe":"unavailable"}'
    [ "$dry_run" -eq 1 ] || _teardown_decision_record "$id" "$caller" "$decision" "$cause" "$evidence"
    printf 'decision=%s\ncause=%s\neta_s=%s\n' "$decision" "$cause" "$eta_s"
    return 0
  fi
  if [ "$probe" = "gone" ]; then
    decision=keep; cause=already-gone
    evidence='{"probe":"gone"}'
    [ "$dry_run" -eq 1 ] || _teardown_decision_record "$id" "$caller" "$decision" "$cause" "$evidence"
    printf 'decision=%s\ncause=%s\neta_s=%s\n' "$decision" "$cause" "$eta_s"
    return 0
  fi

  local now; now="$(now_epoch)"
  local server_created_epoch=""
  [ -n "$created_iso" ] && server_created_epoch="$(date -u -d "$created_iso" +%s 2>/dev/null || true)"
  [ -n "$server_created_epoch" ] || server_created_epoch="$(session_create_epoch)"
  local age=$(( now - server_created_epoch ))

  local attr_count attr_last
  read -r attr_count attr_last <<<"$(attribution_stats_for "$id")"

  local queued; queued="$(queued_work_count)"
  local active=false; loop_active && active=true

  local zero_runs_age_s="${BURST_IDLE_GUARD_ZERO_RUNS_AGE_S:-900}"
  local tick_s median_s formula_s grace_s
  tick_s="$(seconds_to_next_tick)"; median_s="$(median_first_run_latency)"
  formula_s=$(( tick_s + 2 * median_s ))
  grace_s=$zero_runs_age_s
  [ "$formula_s" -gt "$grace_s" ] && grace_s=$formula_s

  local last_age=-1
  if [ "$attr_last" != "-" ] && [ -n "$attr_last" ]; then
    local last_epoch; last_epoch="$(date -u -d "$attr_last" +%s 2>/dev/null || true)"
    [ -n "$last_epoch" ] && last_age=$(( now - last_epoch ))
  fi

  # Requirement 5 / AC3: a box that has never served a single run stays
  # inside its evidence-derived grace window regardless of age past the old
  # static 900s floor — this is the direct fix for the 2026-09-15 incident
  # (a box adopted 4s into a tick, zero runs, deleted at 977s by the old
  # hardcoded rule).
  if [ "$attr_count" -eq 0 ] && [ "$age" -lt "$grace_s" ]; then
    decision=keep; cause=grace
  # AC4: a box with a real run history whose last routed run is over an hour
  # stale, with nothing queued to route next, has earned nothing further —
  # delete now rather than waiting out a billed-hour boundary that buys
  # nothing (the hour is already paid for either way).
  elif [ "$last_age" -ge 3600 ] && [ "$queued" -eq 0 ]; then
    decision=delete; cause=idle-no-work
  # AC5: same staleness, but real work is queued and the loop is still
  # running to route it — keep.
  elif [ "$last_age" -ge 3600 ] && [ "$queued" -gt 0 ] && [ "$active" = true ]; then
    decision=keep; cause=work-queued
  # Grace expired with zero runs ever served and nothing queued — the
  # existing idle-guard zero-runs-lifetime cause, now grace-formula-gated
  # instead of a bare 900s constant.
  elif [ "$attr_count" -eq 0 ] && [ "$age" -ge "$grace_s" ] && [ "$queued" -eq 0 ]; then
    decision=delete; cause=idle-guard:zero-runs-lifetime
  else
    decision=keep; cause=work-queued
  fi

  if [ "$decision" = "delete" ]; then
    eta_s=0
  elif [ "$cause" = "grace" ]; then
    eta_s=$(( grace_s - age ))
  fi

  evidence="$(python3 -c '
import json, sys
print(json.dumps({
    "server_created_epoch": int(sys.argv[1]), "age_s": int(sys.argv[2]),
    "attribution_count": int(sys.argv[3]), "last_routed_run": (sys.argv[4] if sys.argv[4] != "-" else None),
    "last_age_s": int(sys.argv[5]), "queued_prds": int(sys.argv[6]), "loop_active": sys.argv[7] == "true",
    "grace_s": int(sys.argv[8]),
}))
' "$server_created_epoch" "$age" "$attr_count" "$attr_last" "$last_age" "$queued" "$active" "$grace_s")"

  [ "$dry_run" -eq 1 ] || _teardown_decision_record "$id" "$caller" "$decision" "$cause" "$evidence"
  printf 'decision=%s\ncause=%s\neta_s=%s\n' "$decision" "$cause" "$eta_s"
}

# cmd_why_down: requirement 6 — replay decisions.jsonl for one server id, in
# order, then the final decision and the matching session.json.deleted-*/
# .stale-* archive file (if any). "no decision recorded" (a real, non-zero
# exit, journaled) when the id has no rows at all — a defect in its own
# right (something deleted this box without ever consulting
# teardown_decision), never silently swallowed as "nothing to show".
cmd_why_down() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "usage: burst-lane.sh why-down <server_id>" >&2; exit 2; }
  if [ ! -f "$DECISIONS_LEDGER" ] || ! grep -q "\"server_id\": *\"$id\"" "$DECISIONS_LEDGER" 2>/dev/null; then
    echo "no decision recorded"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  why-down  unrecorded-deletion  (server_id=$id)"
    exit 1
  fi
  python3 -c '
import json, sys
sid, path = sys.argv[1], sys.argv[2]
rows = []
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if str(d.get("server_id")) == sid:
        rows.append(d)
for r in rows:
    print("%s  %s  decision=%s cause=%s evidence=%s" % (r.get("ts"), r.get("caller"), r.get("decision"), r.get("cause"), json.dumps(r.get("evidence"))))
if rows:
    print("final: decision=%s cause=%s" % (rows[-1].get("decision"), rows[-1].get("cause")))
' "$id" "$DECISIONS_LEDGER"
  local archive; archive="$(ls -1 "$STATE_FILE".deleted-* "$STATE_FILE".stale-* 2>/dev/null | tail -1)"
  if [ -n "$archive" ]; then
    echo "archive: $archive"
  fi
  exit 0
}

# teardown_probe_unavailable_guard: the shared early-exit requirement 3/AC2
# wants in down/watchdog/idle-guard — when hcloud itself cannot answer,
# these three autonomous-ish callers must change nothing (no delete, no
# session_reconcile-driven archive) rather than treat silence as evidence of
# anything. Returns 0 (caller should return/exit immediately) when the probe
# is unavailable; 1 otherwise (proceed as normal). Journals via the same
# once-per-hour throttle teardown_decision's own probe-unavailable path uses.
teardown_probe_unavailable_guard() {  # $1=caller $2=server_id
  local caller="$1" id="${2:-none}"
  command -v "$HCLOUD" >/dev/null 2>&1 && return 1
  _teardown_decision_record "$id" "$caller" keep probe-unavailable '{"probe":"unavailable"}'
  echo "decision=keep cause=probe-unavailable"
  return 0
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
                    # unaffected); $4=server_type (PRD-build-burst-state-
                    # keyed-by-server-v2 requirement 5: cost.jsonl rows carry
                    # server_id AND server_type so a multi-box `cost --today`
                    # can print a per-box type alongside its id — optional,
                    # falls back to cost_rate_eur's own state_read when
                    # omitted, same as every pre-existing caller); reads
                    # $SERVED_FILE (requirement 13: PRD slugs this session
                    # served), one row per session
  local stype="${4:-$(state_read server_type 2>/dev/null)}"
  python3 -c '
import json, sys
date, hours, eur, sid, served_path, stype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
prds = []
try:
    with open(served_path) as f:
        prds = [l.strip() for l in f if l.strip()]
except OSError:
    pass
row = {"date": date, "hours": float(hours), "eur": float(eur), "prds": prds}
if sid:
    row["session_id"] = sid
if stype:
    row["server_type"] = stype
print(json.dumps(row))
' "$(now_iso)" "$1" "$2" "${3:-}" "$SERVED_FILE" "$stype" >> "$COST_LEDGER"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  ${4:-down}  attribution-could-not-check  ($ATTR_LEDGER unreadable — cost NOT attributed to any slug this teardown)"
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

  journal_line --file "$TICK_JOURNAL_DIR/$today.md" "$line"
  printf '%s\n' "$today" > "$ROLLUP_CURSOR"
}

# ---- down ---------------------------------------------------------------------
# Requirement 3: teardown-order side effects (dirty sweep, in-flight gate
# wait, credential shred, volume detach) then destroy_verify — factored out
# of `down`'s scheduled-window delete so requirement 3's new unproven-box
# immediate-delete path (below) gets identical hygiene, not a shortcut
# copy, and so `watchdog`'s matching block never drifts from `down`'s.
# Prints "hrs|eur|served|alive" on stdout and returns 0 on a confirmed
# destroy; prints nothing and returns 1 on a LEAK-FLAG (still present after
# destroy_verify's 3 retries) — caller owns the decision/journal line.
# ---- auto-bake at down (PRD-build-burst-dispatch-reenable requirement 1,
# AC15) -----------------------------------------------------------------
# The bake this session earned: if provisioning had to install at least one
# gate tool this session (the box was booted from a stale or non-existent
# image) AND the session still reached gate_ready=true, the NEXT boot
# should not pay that cost again. Scoped to caller="down" only (an explicit
# operator/tick teardown) — watchdog and idle-guard are autonomous safety
# nets, not the place to spend the extra minute an image freeze costs.
# Never blocks or delays the delete that follows: bake runs in a subshell
# (cmd_bake calls `exit`, not `return`) and any refusal (not configured, no
# authorization, run-in-flight, hcloud failure) is swallowed here — the box
# is deleted either way, baked or not. Counting install-starts via the
# journal (rather than a new state field) avoids touching every one of
# state_write's many full-rewrite call sites just to carry one more flag.
auto_bake_before_delete() {  # $1=id $2=caller
  local id="$1" caller="$2"
  [ "$caller" = "down" ] || return 0
  [ "$(state_read gate_ready)" = "true" ] || return 0
  # `create_epoch` (stamped right after `server create`, before
  # box_bootstrap/provision_gate_tools ever run — see cmd_up) is the
  # correct lower bound, not `boot_ts` (stamped only once provisioning has
  # already finished): an install-start line always lands strictly BETWEEN
  # the two, so filtering from boot_ts undercounts every session to zero.
  local create_epoch since_iso
  create_epoch="$(state_read create_epoch)"
  case "$create_epoch" in ''|*[!0-9]*) return 0 ;; esac
  since_iso="$(date -u -d "@$create_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  [ -n "$since_iso" ] || return 0
  local n
  n="$(awk -v since="$since_iso" '$1 >= since' "$JOURNAL" 2>/dev/null | \
    grep -c 'burst-lane  gate-tools  install-start' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 0
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  auto-bake  (cause=install-start-count=$n server_id=$id)"
  ( cmd_bake >/dev/null 2>&1 ) || true
}

teardown_and_delete() {  # $1=id $2=caller_tag(down|watchdog|idle-guard)
  local id="$1" caller="$2" ip alive
  ip="$(state_read ip)"; alive="$(minutes_alive)"

  # PRD-build-burst-teardown-lifecycle requirements 1-3: setup-grace check.
  # "down" is the one caller tag reserved for an explicit operator call
  # (cmd_down/cmd_down_force) and always bypasses this, matching requirement
  # 2 — every other tag (watchdog, idle-guard; parity no longer reaches this
  # function at all, requirement 4) is autonomous and must never delete a
  # box still inside its post-`up` setup window: an unprovisioned box reads
  # identically to a genuinely failed one (gate_ready=false, runs_served=0)
  # by the prior PRD's own cost-safe rule, which is exactly the 2026-09-13
  # incident this PRD fixes. $TEARDOWN_CAUSE_FILE is cleared every call and
  # written with "setup-grace-expired" only when the grace window has run
  # out with the session still (never provisioned/failed) in phase=setup —
  # callers that want the more specific cause in their own journal line read
  # it right after a successful (rc=0) return; it is deliberately not folded
  # into this function's own stdout tuple (hrs|eur|served|alive), which
  # every existing caller already parses positionally.
  rm -f "$TEARDOWN_CAUSE_FILE"
  if [ "$caller" != "down" ]; then
    local phase; phase="$(state_read_phase)"
    if [ "$phase" = "setup" ]; then
      local phase_epoch grace_min grace_secs now elapsed
      phase_epoch="$(state_read phase_epoch)"; phase_epoch="${phase_epoch:-$(state_read boot_epoch)}"
      grace_min="${BURST_SETUP_GRACE_MIN:-30}"
      grace_secs=$(( grace_min * 60 ))
      now="$(now_epoch)"
      elapsed=$(( now - ${phase_epoch:-$now} ))
      if [ "$elapsed" -lt "$grace_secs" ]; then
        local remaining=$(( grace_secs - elapsed ))
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  teardown-deferred  (cause=setup-grace remaining=${remaining}s server_id=$id)"
        return 2
      fi
      # Grace expired with nobody ever having provisioned this session —
      # deleted below same as any other autonomous decision, but tagged so
      # a forgotten box's cause is distinguishable in the ledger/journal
      # (requirement 3).
      printf '%s' "setup-grace-expired" > "$TEARDOWN_CAUSE_FILE"
    fi
  fi

  auto_bake_before_delete "$id" "$caller"
  sweep_dirty_worktrees "$caller"
  gate_wait_for_inflight "$caller"
  shred_gate_credential "$ip" "$caller"
  volume_teardown "$ip" "$caller"
  if destroy_verify "$id"; then
    local hrs eur served
    hrs="$(awk -v m="$alive" 'BEGIN{printf "%.4f", m/60.0}')"
    eur="$(awk -v h="$hrs" -v r="$(cost_rate_eur)" 'BEGIN{printf "%.4f", h*r}')"
    served="$( [ -f "$SERVED_FILE" ] && paste -sd, "$SERVED_FILE" 2>/dev/null || true)"
    local prorate_out orphan_sid
    prorate_out="$(prorate_attribution "$id" "$hrs" "$eur" "$caller")" || true
    while IFS= read -r orphan_sid; do
      case "$orphan_sid" in
        ORPHANED:*)
          journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $caller  attribution-orphan-included  (session_id=${orphan_sid#ORPHANED:} — crashed prior session's rows folded into this teardown's proration)"
          ;;
      esac
    done <<<"$prorate_out"
    ledger_append "$hrs" "$eur" "$id"
    # Requirement 5, auto-disable: checked after every autonomous teardown's
    # own ledger row lands, so both triggers always see the just-finished
    # session. Stderr only (never stdout) — this function's stdout is the
    # pipe-delimited hrs|eur|served|alive tuple every caller parses
    # positionally via `$(...)`.
    check_auto_disable
    printf '%s|%s|%s|%s\n' "$hrs" "$eur" "${served:-none}" "$alive"
    return 0
  fi
  return 1
}

# PRD-build-burst-prove-inflight-guard requirement 2: the single check
# down/idle-guard/watchdog (the three autonomous deleters) all run BEFORE
# their own delete decision. rc=0 means the caller must stop and report
# decision=keep (a live prove owns the marker; server_id/pid/age are
# journaled by the caller); rc=1 means it's safe to proceed with the normal
# decision — either the marker was never there, or its pid was dead (this
# reclaims and journals that case itself). $1 is the calling command's own
# journal component name (down|watchdog|idle-guard); $2 is that caller's
# server_id, for the journal line only.
prove_inflight_guard() {
  local who="$1" id="${2:-none}"
  [ -f "$PROVE_INFLIGHT_FILE" ] || return 1
  local pid; pid="$(sed -n 's/^pid=//p' "$PROVE_INFLIGHT_FILE" 2>/dev/null | head -n1)"
  case "$pid" in
    ''|*[!0-9]*) rm -f "$PROVE_INFLIGHT_FILE" 2>/dev/null; return 1 ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    local start_epoch age
    start_epoch="$(sed -n 's/^start_epoch=//p' "$PROVE_INFLIGHT_FILE" 2>/dev/null | head -n1)"
    case "$start_epoch" in ''|*[!0-9]*) start_epoch="$(now_epoch)" ;; esac
    age=$(( $(now_epoch) - start_epoch ))
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $who  decision=keep  (server_id=$id cause=prove-inflight pid=$pid age_s=$age)"
    echo "decision=keep"
    return 0
  fi
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  $who  prove-inflight-stale  (pid=$pid)"
  rm -f "$PROVE_INFLIGHT_FILE" 2>/dev/null
  return 1
}

# Requirement 3: an explicit, unconditional teardown — bypasses every keep
# rule, the billed-hour window, and cost/attribution bookkeeping entirely.
# Always rc=0, even when the server hcloud once knew about is already gone
# — this is the exact operator recovery step the 2026-09-13 incident needed
# and didn't have (a raw hcloud delete plus a stale session.json left
# behind after it).
# PRD-build-burst-state-keyed-by-server-v2 requirement 4: force_down_one_box
# assumes box_context has already been pointed at the box it should tear
# down — cmd_down_force below calls this once per active box (current-first
# order from list_active_box_ids) instead of acting on `current` alone, so
# `down --force` with two boxes up force-deletes both (AC5) instead of only
# whichever one `current` happened to name. Never exits — the loop in
# cmd_down_force owns that.
force_down_one_box() {
  # requirement 2: `--force` is the one caller allowed to override a live
  # prove-inflight marker (explicit operator escalation) — it never blocks
  # on it, but the override is still journaled, not silent.
  if [ -f "$PROVE_INFLIGHT_FILE" ]; then
    local ovr_pid; ovr_pid="$(sed -n 's/^pid=//p' "$PROVE_INFLIGHT_FILE" 2>/dev/null | head -n1)"
    case "$ovr_pid" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "$ovr_pid" 2>/dev/null && journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  prove-inflight-overridden  (pid=$ovr_pid cause=force)" ;;
    esac
  fi
  local id; id="$(state_read server_id)"
  if [ -n "$id" ]; then
    if destroy_verify "$id"; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=force-deleted  (server_id=$id)"
    else
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  LEAK-FLAG  (server_id=$id action=page-a-human — force-delete did not confirm destroyed after 3 retries)"
    fi
  else
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=force-deleted  (server_id=none — nothing tracked)"
  fi
  session_known_hosts_remove
  rm -f "$STATE_FILE" "$SERVED_FILE"
}

cmd_down_force() {
  # requirement 4: iterate every box list_active_box_ids knows about
  # (current-first), not just `current` — a zero-box result (genuinely
  # nothing tracked anywhere) falls back to the single, pre-multibox
  # "nothing tracked" line, byte-identical to before this requirement
  # (Goal 2).
  local box_ids; box_ids="$(list_active_box_ids)"
  if [ -z "$box_ids" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=force-deleted  (server_id=none — nothing tracked)"
    echo "decision=force-deleted"
    reap_volumes >/dev/null 2>&1 || true
    exit 0
  fi
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    box_context "$id"
    force_down_one_box
    echo "decision=force-deleted"
  done <<<"$box_ids"
  # Requirement 6: `down --force` sweeps for a stranded volume too, same as
  # `reap --volumes` — bypassing every keep rule (this function's whole
  # point) includes the volume's used_pct keep-check, not just the box.
  reap_volumes >/dev/null 2>&1 || true
  exit 0
}

# PRD-build-burst-state-keyed-by-server-v2 requirement 4: down_one_box is the
# pre-multibox cmd_down body verbatim, minus flag parsing (cmd_down does that
# once per invocation, not once per box) — every `exit` below became a
# `return` so cmd_down's loop can move on to the next box after this one
# decides. Assumes box_context already points at the box to decide for; $2
# is the more_work flag cmd_down parsed once for the whole pass. Returns 0
# for keep/deleted/scheduled/probe-unavailable/prove-inflight, 1 for
# LEAK-FLAG — cmd_down aggregates these across every box in the pass so one
# box's LEAK-FLAG never stops the others from being decided.
down_one_box() {
  local more_work="${2:-0}"
  if ! state_active; then
    echo "no-active-session"
    return 0
  fi

  local id boot_epoch; id="$(state_read server_id)"; boot_epoch="$(state_read boot_epoch)"

  # PRD-build-burst-teardown-evidence requirement 3/AC2: hcloud itself must
  # be reachable before this autonomous-ish path changes anything at all —
  # an absent/unauthenticated probe is never a deletion (or keep-vs-delete
  # bookkeeping) cause.
  if teardown_probe_unavailable_guard down "$id" >/dev/null; then
    echo "decision=keep cause=probe-unavailable"
    return 0
  fi

  # requirement 2: a live prove owns this box — never delete/schedule out
  # from under it. Checked before the reap sweep below too.
  if prove_inflight_guard down "$id"; then
    return 0
  fi

  # PRD-build-burst-remote-disk-guard requirement 6: reap runs on every
  # `down` call, before the keep/scheduled/deleted decision below — disk
  # hygiene does not wait for a box that is about to die anyway (goal 2:
  # "reaped on the next down or watchdog pass"). Never blocks/aborts the
  # decision that follows; a reap trouble (ssh down, rm error) is only ever
  # journaled by reap_orphans itself.
  reap_orphans >/dev/null 2>&1 || true

  if rust_work_remains || [ "$more_work" -eq 1 ]; then
    # Requirement 3 (cost-safe keep rules): rust-work-remains — or any other
    # keep rule — may only keep a box that has actually PROVEN useful:
    # gate_ready AND runs_served>=1. The 2026-09-13 incident: a provision-
    # failed box (gate_ready=false, runs_served=0) was kept anyway because a
    # repo parity diff looked like remaining rust work, and sat billed-and-
    # idle until an operator force-deleted it by hand. An unproven box is
    # ALWAYS deleted here instead, immediately (not scheduled for the end of
    # the billed hour — there is no reason to wait out a box that never
    # earned its keep).
    local gate_ready runs_served
    gate_ready="$(state_read gate_ready)"
    runs_served="$(state_read runs_served)"
    case "$runs_served" in ''|*[!0-9]*) runs_served=0 ;; esac
    if [ "$gate_ready" = "true" ] && [ "$runs_served" -ge 1 ]; then
      if [ "$(state_read teardown_scheduled)" = "true" ]; then
        state_write "server_id=$id" "ip=$(state_read ip)" "server_type=$(state_read server_type)" \
          "boot_ts=$(state_read boot_ts)" "boot_epoch=$boot_epoch" \
          "create_epoch=$(state_read create_epoch)" "ttl_hours=$(state_read ttl_hours)" \
          "hard_ttl_hours=$(state_read hard_ttl_hours)" "runs_served=$(state_read runs_served)" \
          "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=false" "teardown_epoch=" "verified=$(state_read verified)" \
          "remote_user=$(state_read remote_user)" \
          "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)" \
          "box_cores=$(state_read box_cores)" "box_mem_gb=$(state_read box_mem_gb)" \
          "box_disk_gb=$(state_read box_disk_gb)" \
          "phase=$(state_read_phase)" "phase_epoch=$(state_read phase_epoch)"
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=keep  (server_id=$id cause=rust-work-arrived, schedule cancelled)"
      else
        journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=keep  (server_id=$id)"
      fi
      echo "decision=keep"
      return 0
    fi
    local result_u hrs_u eur_u served_u alive_u
    if result_u="$(teardown_and_delete "$id" down)"; then
      IFS='|' read -r hrs_u eur_u served_u alive_u <<<"$result_u"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id cause=unproven-box gate_ready=${gate_ready:-false} runs_served=$runs_served minutes=$alive_u cost_eur=$eur_u prds=$served_u)"
      state_clear
      session_known_hosts_remove
      echo "decision=deleted"
      return 0
    fi
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
    echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
    return 1
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
    local result hrs eur served alive
    if result="$(teardown_and_delete "$id" down)"; then
      IFS='|' read -r hrs eur served alive <<<"$result"
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id minutes=$alive cost_eur=$eur prds=$served)"
      state_clear
      session_known_hosts_remove
      echo "decision=deleted"
      return 0
    fi
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
    echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
    return 1
  fi

  state_write "server_id=$id" "ip=$(state_read ip)" "server_type=$(state_read server_type)" \
    "boot_ts=$(state_read boot_ts)" "boot_epoch=$boot_epoch" \
    "create_epoch=$(state_read create_epoch)" "ttl_hours=$(state_read ttl_hours)" \
    "hard_ttl_hours=$(state_read hard_ttl_hours)" "runs_served=$(state_read runs_served)" \
    "sandbox_ok=$(state_read sandbox_ok)" "teardown_scheduled=true" "teardown_epoch=$window_start" "verified=$(state_read verified)" \
    "remote_user=$(state_read remote_user)" \
    "gate_ready=$(state_read gate_ready)" "gate_tools_missing=$(state_read gate_tools_missing)" \
    "box_cores=$(state_read box_cores)" "box_mem_gb=$(state_read box_mem_gb)" \
    "box_disk_gb=$(state_read box_disk_gb)" \
    "phase=$(state_read_phase)" "phase_epoch=$(state_read phase_epoch)"
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=scheduled  (server_id=$id teardown_at=$(date -u -d "@$window_start" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$window_start"))"
  echo "decision=scheduled"
  return 0
}

cmd_down() {
  local more_work=0
  if [ "${1:-}" = "--force" ]; then
    cmd_down_force
  fi
  # PRD-build-burst-teardown-evidence requirement 7/AC8: a scheduled soft-
  # down is refused outright — the 2026-09-15 incident's `burst-soft-down-
  # 0648` one-shot timer deleted a box 3 minutes into its own adoption.
  # Operators who want a delayed teardown use the TTL; this lane never
  # schedules its own delete via an external timer again.
  if [ "${1:-}" = "--at" ]; then
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  refused  (cause=scheduled-teardown-disabled requested_at=${2:-})"
    echo "refused: scheduled soft-down is disabled — use the TTL instead" >&2
    exit 2
  fi
  [ "${1:-}" = "--more-work-queued" ] && more_work=1

  # PRD-build-cost-attribution requirement 4: cursor-guarded, so this is a
  # no-op after the first `down` call of the UTC day — independent of
  # today's keep/scheduled/deleted decision below, since the wrapper may
  # call `down` many times a day but the rollup line must land exactly once.
  maybe_daily_rollup

  # PRD-build-burst-state-keyed-by-server-v2 requirement 4: iterate every
  # active box (current-first order from list_active_box_ids) instead of
  # acting on `current` alone — a zero-box result is the pre-multibox
  # "nothing active" line, byte-identical to before this requirement
  # (Goal 2); a single active box runs down_one_box exactly once, through
  # box_context's own "already current" short-circuit, so the literal
  # per-box paths and stdout are unchanged too.
  local box_ids; box_ids="$(list_active_box_ids)"
  if [ -z "$box_ids" ]; then
    echo "no-active-session"
    exit 0
  fi

  local id rc leak=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    box_context "$id"
    down_one_box "$id" "$more_work"
    rc=$?
    [ "$rc" -eq 1 ] && leak=1
  done <<<"$box_ids"
  [ "$leak" -eq 1 ] && exit 1
  exit 0
}

# ---- watchdog -------------------------------------------------------------------
# Safety-net TTL check, independent of down's rust-work logic — the backstop
# against a forgotten box. Intended to be invoked periodically (a systemd
# timer wiring it up is a follow-on step, not done in this pass).
# PRD-build-burst-state-keyed-by-server-v2 requirement 4: watchdog_one_box is
# the pre-multibox cmd_watchdog body verbatim (every `exit` -> `return`) —
# see down_one_box's own header for the shared per-box convention. Assumes
# box_context already points at the box to check. Returns 0 for ok/keep/
# teardown/deferred, 1 for LEAK-FLAG.
watchdog_one_box() {
  if ! state_active; then
    echo "no-active-session"
    return 0
  fi
  # PRD-build-burst-teardown-evidence requirement 3/AC2: same guard as
  # `down` — a probe that cannot answer changes nothing.
  if teardown_probe_unavailable_guard watchdog "$(state_read server_id)" >/dev/null; then
    echo "decision=keep cause=probe-unavailable"
    return 0
  fi
  # PRD-build-burst-remote-disk-guard requirement 6: same as `down` — reap
  # runs on every watchdog pass, before the due/not-due decision, never
  # blocking it.
  reap_orphans >/dev/null 2>&1 || true

  local id create_epoch ttl_hours now age ttl_secs
  id="$(state_read server_id)"; create_epoch="$(session_create_epoch)"
  ttl_hours="$(state_read ttl_hours)"; ttl_hours="${ttl_hours:-$DEFAULT_TTL_HOURS}"
  now="$(now_epoch)"; age=$(( now - create_epoch ))
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
    return 0
  fi

  # requirement 2: a live prove owns this box — never delete out from under
  # it, TTL-due or not; watchdog just gets another pass at it later.
  if prove_inflight_guard watchdog "$id"; then
    return 0
  fi

  # The watchdog is a teardown path too — same hygiene (dirty sweep, gate
  # wait, credential shred, volume detach) as `down`'s delete path, via the
  # shared teardown_and_delete helper (PRD-build-burst-session-hygiene).
  # PRD-build-burst-teardown-lifecycle: watchdog is an autonomous caller, so
  # teardown_and_delete may return 2 (setup-grace still open, nothing
  # deleted, its own "teardown-deferred" line already journaled) — that is
  # neither a successful teardown nor a LEAK-FLAG, and must not be reported
  # as either.
  local result rc hrs eur served alive teardown_cause
  result="$(teardown_and_delete "$id" watchdog)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    IFS='|' read -r hrs eur served alive <<<"$result"
    teardown_cause="$(cat "$TEARDOWN_CAUSE_FILE" 2>/dev/null || true)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  watchdog  teardown  (server_id=$id uptime=${alive}m cost_eur=$eur prds=$served${teardown_cause:+ cause=$teardown_cause})"
    state_clear
    session_known_hosts_remove
    echo "watchdog teardown: $id (${alive}m)"
    return 0
  elif [ "$rc" -eq 2 ]; then
    echo "watchdog: teardown deferred (setup-grace)"
    return 0
  fi
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  watchdog  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
  echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
  return 1
}

cmd_watchdog() {
  # PRD-build-burst-state-keyed-by-server-v2 requirement 4: iterate every
  # active box instead of acting on `current` alone — see cmd_down's own
  # comment for the zero/one-box byte-identical-behavior rationale.
  local box_ids; box_ids="$(list_active_box_ids)"
  if [ -z "$box_ids" ]; then
    echo "no-active-session"
    exit 0
  fi
  local id rc leak=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    box_context "$id"
    watchdog_one_box
    rc=$?
    [ "$rc" -eq 1 ] && leak=1
  done <<<"$box_ids"
  [ "$leak" -eq 1 ] && exit 1
  exit 0
}

# ---- idle-guard (PRD-build-burst-teardown-lifecycle requirement 1/4) --------
# A third autonomous teardown caller, alongside watchdog: a box that has
# never served a single run and is already comfortably past a boot grace is
# dead weight regardless of TTL. This is the in-repo home for that decision
# — the exact idle-detection heuristic a standalone, out-of-tree 5-minute
# timer previously reimplemented against a raw `hcloud server delete`, with
# no notion of setup-grace at all (the real-world twin of this PRD's own
# incident: an idle-looking box that was actually still mid-setup). Routing
# the decision through the SAME teardown_and_delete() used by down/watchdog
# means idle-guard inherits the grace check, the volume cold-teardown
# policy, and every other teardown-hygiene step for free, instead of a
# second, independently-drifting deletion path. Wiring an external timer at
# `burst-lane.sh idle-guard` instead of a raw hcloud call is a follow-on
# step outside this repo (the existing timer's unit files live under
# ~/dotfiles, a separate repo this PRD's build_into does not cover).
# PRD-build-burst-state-keyed-by-server-v2 requirement 4: idle_guard_one_box
# is the pre-multibox cmd_idle_guard body verbatim (every `exit` -> `return`)
# — see down_one_box's own header for the shared per-box convention. Assumes
# box_context already points at the box to check. Returns 0 for ok/keep/
# teardown/deferred, 1 for LEAK-FLAG. AC4: with one busy box and one idle
# box, cmd_idle_guard's loop below calls this once per box, so a busy box's
# runs_served>=1 correctly makes THIS call a no-op while the idle box's own
# call still tears it down.
idle_guard_one_box() {
  local multi="${1:-0}"
  if ! state_active; then
    echo "no-active-session"
    return 0
  fi
  # PRD-build-burst-teardown-evidence requirement 3/AC2: same guard as
  # `down`/`watchdog` — a probe that cannot answer changes nothing.
  if teardown_probe_unavailable_guard idle-guard "$(state_read server_id)" >/dev/null; then
    echo "decision=keep cause=probe-unavailable"
    return 0
  fi
  reap_orphans >/dev/null 2>&1 || true

  local id runs_served create_epoch now age
  id="$(state_read server_id)"; runs_served="$(state_read runs_served)"
  case "$runs_served" in ''|*[!0-9]*) runs_served=0 ;; esac
  create_epoch="$(session_create_epoch)"; now="$(now_epoch)"; age=$(( now - create_epoch ))

  local due=0
  local zero_runs_age_s="${BURST_IDLE_GUARD_ZERO_RUNS_AGE_S:-900}"
  if [ "$runs_served" -eq 0 ] && [ "$age" -ge "$zero_runs_age_s" ]; then
    due=1
  fi
  if [ "$due" -eq 0 ]; then
    # PRD-build-burst-state-keyed-by-server-v2 requirement 4/AC4: a healthy
    # box's every-poll "not idle" pass stays silent in the journal in the
    # single-box case (Goal 2 — an idle-guard timer fires often, and this
    # branch is the common case; journaling it every pass would spam the
    # live journal for no operator benefit). With more than one box in this
    # PASS (multi=1, set by cmd_idle_guard's own box count), AC4 needs a
    # decision line attributable to the box idle-guard chose NOT to touch
    # too, so a human reading the journal after a mixed busy/idle pass sees
    # both boxes' outcomes, not just the one that got deleted.
    if [ "$multi" -eq 1 ]; then
      journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  idle-guard  decision=keep  (server_id=$id runs_served=$runs_served age_s=$age)"
    fi
    echo "ok: idle-guard sees no idle condition (runs_served=$runs_served age=${age}s)"
    return 0
  fi

  # requirement 2: a live prove owns this box (a fixture/human `prove` run
  # against runs_served=0 is exactly the idle shape below) — never delete
  # out from under it.
  if prove_inflight_guard idle-guard "$id"; then
    return 0
  fi

  local result rc hrs eur served alive teardown_cause
  result="$(teardown_and_delete "$id" idle-guard)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    IFS='|' read -r hrs eur served alive <<<"$result"
    teardown_cause="$(cat "$TEARDOWN_CAUSE_FILE" 2>/dev/null || true)"
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  down  decision=deleted  (server_id=$id cause=${teardown_cause:-idle-guard:zero-runs-lifetime} minutes=$alive cost_eur=$eur prds=$served)"
    state_clear
    session_known_hosts_remove
    echo "idle-guard teardown: $id (${alive}m)"
    return 0
  elif [ "$rc" -eq 2 ]; then
    echo "idle-guard: teardown deferred (setup-grace)"
    return 0
  fi
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  idle-guard  LEAK-FLAG  (server_id=$id action=page-a-human — destroy failed after 3 retries)"
  echo "LEAK-FLAG: server $id did not confirm destroyed after 3 retries"
  return 1
}

cmd_idle_guard() {
  # PRD-build-burst-state-keyed-by-server-v2 requirement 4/AC4: iterate
  # every active box instead of acting on `current` alone — see cmd_down's
  # own comment for the zero/one-box byte-identical-behavior rationale.
  local box_ids; box_ids="$(list_active_box_ids)"
  if [ -z "$box_ids" ]; then
    echo "no-active-session"
    exit 0
  fi
  local box_count; box_count="$(wc -l <<<"$box_ids")"
  local multi=0; [ "$box_count" -gt 1 ] && multi=1
  local id rc leak=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    box_context "$id"
    idle_guard_one_box "$multi"
    rc=$?
    [ "$rc" -eq 1 ] && leak=1
  done <<<"$box_ids"
  [ "$leak" -eq 1 ] && exit 1
  exit 0
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
  out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
        "$REMOTE_USER@$ip" "$remote_cmd" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  echo "$out"
}

# PRD-build-burst-run-slots-from-box requirement 1: the box's own total
# capacity, probed exactly once at `up` (after gate tools are ready) and
# recorded into session.json — deliberately MemTotal (the box's whole RAM)
# and not probe_remote_capacity's live MemAvailable, since this is a boot-
# time fingerprint of what the box IS, not a live reading of what's free
# right now (that's what probe_remote_capacity, cmd_status's disk_state,
# and cmd_run's own disk-floor check are for — untouched by this PRD). Same
# bounded ConnectTimeout=8 ssh helper the gate-tools probe uses, so this
# adds no more than one extra round trip (well under the 5s budget the
# Technical considerations section sets).
probe_box_specs() {  # $1 = ip -> stdout "cores mem_total_gb disk_avail_gb"; rc 1 on failure
  local ip="$1" out
  local remote_cmd='c=$(nproc); mt=$(grep MemTotal /proc/meminfo | awk "{print \$2}"); dg=$(df -BG --output=avail '"$REMOTE_ROOT"' 2>/dev/null | tail -n1 | tr -dc "0-9"); echo $c $((mt/1024/1024)) ${dg:-}'
  out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -i "$SSH_KEY" \
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  no-session  (local=3, fallback rules apply)"
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
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  sandbox-unavailable  (server_id=$(state_read server_id) local cap=2 this tick)"
    echo "sub-cap=2 local=0 (sandbox unavailable — falling back to local cap 2 this tick)"
    exit 0
  fi

  local ip; ip="$(state_read ip)"
  local probe
  if ! probe="$(probe_remote_capacity "$ip")"; then
    probe_emit burst-subcap could-not-check "capacity probe failed server_id=$(state_read server_id)" >/dev/null
    journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  fallback  (cause=probe-failed server_id=$(state_read server_id))"
    echo "fallback: could not probe box capacity"
    exit 3
  fi
  local avail_gb nproc_n free_disk_gb
  read -r avail_gb nproc_n free_disk_gb <<<"$probe"
  case "$avail_gb" in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac
  case "$nproc_n"  in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac
  # PRD-build-burst-remote-disk-guard requirement 1: a probe missing the
  # third (disk) field is the same bad-probe-output fallback as a missing
  # mem/cpu field — never a silently-skipped disk check.
  case "$free_disk_gb" in ''|*[!0-9]*) probe_emit burst-subcap could-not-check "bad probe output: $probe" >/dev/null; journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  fallback  (cause=bad-probe-output out=$probe)"; echo "fallback: bad probe output"; exit 3 ;; esac

  # PRD-build-burst-run-slots-from-box requirement 3: the exact same
  # min(cores,mem,disk) arithmetic run_slot_cap() uses for the run-slot
  # table (Goal 2 — "one formula, shared by sub_cap and the slot table, so
  # the two never disagree"), fed THIS call's live-probed numbers rather
  # than the box's boot-time snapshot — sub-cap's whole reason to exist is
  # admitting new candidates against capacity as it stands right now, not
  # as it stood at `up`. (PRD-build-burst-remote-disk-guard requirement 2's
  # disk-floor folding lives inside run_slot_cap_terms now, not inline
  # here.)
  local subcap bound
  read -r subcap bound <<<"$(run_slot_cap_terms "$nproc_n" "$avail_gb" "$free_disk_gb")"

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
  journal_line --file "$JOURNAL" "$(now_iso)  burst-lane  sub-cap  computed  (burst: sub-cap=$subcap (avail_gb=$avail_gb nproc=$nproc_n free_disk_gb=$free_disk_gb)${bound_suffix} local=0)"
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
  local today; today="$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"

  # PRD-build-burst-state-keyed-by-server-v2 requirement 5: sum across every
  # box that ever billed today — list_all_box_ids (active or already torn
  # down; a box's cost.jsonl history outlives its own teardown, see that
  # helper's header) — not just `current`. Zero box directories at all
  # (genuinely fresh state, no box has ever existed) falls back to the
  # pre-multibox "no ledger yet" one-liner, byte-identical to before this
  # requirement (Goal 2).
  local box_ids; box_ids="$(list_all_box_ids)"
  if [ -z "$box_ids" ]; then
    [ -f "$COST_LEDGER" ] || { echo "hours=0.00 eur=0.00"; exit 0; }
    box_ids="$(basename "$(readlink -f "$STATE_DIR/current" 2>/dev/null)" 2>/dev/null)"
  fi

  local cost_args=() bid
  while IFS= read -r bid; do
    [ -n "$bid" ] || continue
    box_context "$bid"
    cost_args+=("$bid" "$COST_LEDGER" "$(state_read server_type)")
  done <<<"$box_ids"

  python3 -c '
import json, sys

today = sys.argv[1]
triples = sys.argv[2:]
total_hours = total_eur = 0.0
prds = []
rows = []
for i in range(0, len(triples), 3):
    bid, path, stype = triples[i], triples[i + 1], triples[i + 2]
    bh = be = 0.0
    try:
        fh = open(path)
    except OSError:
        rows.append((bid, stype or "unknown", bh, be))
        continue
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            # Requirement 2/3 (PRD-build-cost-attribution): kind:"slug" rows
            # are the per-slug proration of a session-total row already
            # counted below — summing them here too would double the day
            # total.
            if d.get("kind") == "slug":
                continue
            if not str(d.get("date", "")).startswith(today):
                continue
            bh += float(d.get("hours", 0) or 0)
            be += float(d.get("eur", 0) or 0)
            for p in d.get("prds", []) or []:
                if p not in prds:
                    prds.append(p)
            row_stype = d.get("server_type")
            if row_stype:
                stype = row_stype
    total_hours += bh
    total_eur += be
    rows.append((bid, stype or "unknown", bh, be))

prds_str = ",".join(prds) if prds else "none"
print(f"hours={total_hours:.2f} eur={total_eur:.2f} prds={prds_str}")
# Requirement 5 / AC7: a per-box breakdown, only once there is more than
# one box to break down — the single-box case prints exactly the one line
# above, byte-identical to every caller of this command before this PRD.
if len(rows) > 1:
    for bid, stype, bh, be in rows:
        print(f"  server_id={bid} server_type={stype} hours={bh:.2f} eur={be:.2f}")
    print(f"  TOTAL boxes={len(rows)} hours={total_hours:.2f} eur={total_eur:.2f}")
' "$today" "${cost_args[@]}"
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
    idle-guard) cmd_idle_guard "$@" ;;
    cost)      cmd_cost "$@" ;;
    sub-cap)   cmd_sub_cap "$@" ;;
    verify)    cmd_verify "$@" ;;
    provision) cmd_provision "$@" ;;
    reap)      cmd_reap "$@" ;;
    box-isolation-check) cmd_box_isolation_check "$@" ;;
    route-check) cmd_route_check "$@" ;;
    why-down)  cmd_why_down "$@" ;;
    parity)    cmd_parity "$@" ;;
    gate)      cmd_gate "$@" ;;
    bake)      cmd_bake "$@" ;;
    prove)     cmd_prove "$@" ;;
    evidence)  cmd_evidence "$@" ;;
    enable)    cmd_enable "$@" ;;
    disable)   cmd_disable "$@" ;;
    canary)    cmd_canary "$@" ;;
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
    # Undocumented/hidden — PRD-build-burst-gate-canary-invariant R1: a
    # direct call into canary_resolve_head() so a selftest can exercise
    # the green-main/last-green-tag/no-green-head logic against a fixture
    # repo + fixture $BURST_LANE_GH without running the rest of `canary`
    # (baseline build, real gate launches) at all. Same rationale as
    # _debug-remote-config/_debug-toolchain-fp above.
    _debug-canary-resolve-head)
      _dcrh_repo="${1:?usage: _debug-canary-resolve-head <repo> [--head <sha>]}"
      shift
      _dcrh_head=""
      if [ "${1:-}" = "--head" ]; then _dcrh_head="${2:-}"; fi
      canary_resolve_head "$_dcrh_repo" "$_dcrh_head"
      exit $?
      ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
