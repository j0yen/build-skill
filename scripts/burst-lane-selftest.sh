#!/usr/bin/env bash
# burst-lane-selftest.sh — offline proof for burst-lane.sh (requirement 9,
# PRD-build-burst-lane-ccx53) using the fake hcloud/ssh/rsync under
# tests/fixtures/burst-lane-fake/. No network calls, no real Hetzner spend.
#
# Covers: single-box refusal + session adoption (AC1), run's exit-code
# passthrough (AC2 — updated by PRD-build-burst-pull-on-demand: `run` no
# longer pulls target/ back itself, it marks the worktree dirty and an
# explicit `pull` fetches it), the incremental pull-back's shrinking byte
# count across two explicit pulls of the same worktree (AC11, requirement
# 10 — the scenario moved from "two consecutive runs" to "two explicit
# pulls separated by a re-dirtying run", since runs themselves no longer
# pull), watchdog TTL teardown (AC6), down's keep/scheduled/
# deleted decision as rust work does/doesn't remain in build-queue/ (AC8),
# the never-poweroff/shutdown/stop invariant (AC14), the cargo shim's
# local fallback when no session exists (AC3, partial — the routed-through
# half needs a live `run` and is exercised indirectly via AC2 above), and
# the requirement-7 sub-cap formula (AC7: 120GB/32cores -> 8, 40GB/32cores
# -> 6, no session -> local cap 3 only). Also covers requirement 13 (cost
# ledger PRD-served attribution): run's BURST_LANE_PRD_SLUG opt-in and its
# worktree-basename fallback both land in prds_served, ride into the
# cost.jsonl row at teardown, and are printed back out by cost --today
# (AC13); and requirement 12's pull-back half (AC12): a uv-routed run pulls
# .pybuilder/ back instead of target/, since a python run has no Cargo
# target-dir to resolve.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/burst-lane.sh"
FAKE="$HERE/../tests/fixtures/burst-lane-fake"
SHIM="$HERE/burst-lane-bin/cargo"
[ -x "$BL" ] || { echo "selftest: $BL not executable" >&2; exit 2; }

# PRD-build-burst-selftest-isolation requirement 1: this whole process runs
# under the sentinel from the very first line, not just inside fresh_env's
# per-case setup — belt-and-suspenders against a future test block that
# calls burst-lane.sh (or a helper that shells to it) before ever calling
# fresh_env. Refuses to start rather than silently running unguarded if,
# for any reason, the export below didn't take.
export BURST_LANE_TEST=1
[ "${BURST_LANE_TEST:-}" = "1" ] || {
  echo "burst-lane-selftest: BURST_LANE_TEST not set in own environment — refusing to start" >&2
  exit 2
}

fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# PRD-build-burst-pull-back-restore AC11: a durable, re-derivable ledger of
# every "pullback"-labeled case's outcome from THIS run (see block_start
# "pullback" below and expect()'s own PULLBACK_FAILURE_CAUSES append) —
# written to the REAL repo state dir, never $BURST_LANE_STATE_DIR (this
# run's own sandboxed tmpdir, gone the moment fresh_env's next call or this
# process's own cleanup trap fires). One line appended per run; see the
# write site near the bottom of this file.
PULLBACK_ITER_LOG="$HOME/.claude/skills/build/state/pullback-transfer-log.jsonl"
PULLBACK_FAILURE_CAUSES=()

# ---- Live audit (PRD-build-burst-selftest-isolation requirement 3) --------
# audit_snapshot: sha256sum of every file under a state dir + the last 200
# lines of a journal, as one comparable text blob. Generic over its paths
# (not hardcoded to the real live ones) so isolate_ac3/isolate_ac5 below can
# exercise the mechanism against disposable fixtures instead of ever
# planting a real change into the actual live tree to prove it works.
# audit_diff: rc 0 if two snapshots are byte-identical, else prints
# `isolation-breach: <name(s)>` naming what changed and returns 1.
audit_snapshot() {  # $1 = state dir, $2 = journal file -> stdout
  local state_dir="$1" journal_file="$2"
  if [ -d "$state_dir" ]; then
    find "$state_dir" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
  fi
  echo "---journal-tail---"
  tail -n 200 "$journal_file" 2>/dev/null
}
audit_diff() {  # $1 = before-snapshot-file, $2 = after-snapshot-file
  diff -q "$1" "$2" >/dev/null 2>&1 && return 0
  local changed
  changed="$(diff "$1" "$2" 2>/dev/null | grep -E '^[<>]' | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  echo "isolation-breach: ${changed:-live tree differs}"
  return 1
}

# AC2/requirement 3's real top-level wrap: snapshot the ACTUAL live
# burst-lane state dir + journal now, before this suite's own (fully
# sandboxed, per fresh_env) work runs, and diff again at the very end —
# this suite touching its own $T fixtures all day must never move a single
# byte under the real live paths. Scoped to burst-lane's own state
# subdirectory and journal file specifically (not the whole shared
# build-skill state/ or brain/journal/ tree), since other concurrent
# /build lanes and PRDs legitimately touch unrelated parts of those during
# a real tick — this audit is about THIS mechanism's own blast radius, not
# a claim that nothing else on the host is running.
ISO_LIVE_STATE_DIR="$HOME/.claude/skills/build/state/burst-lane"
ISO_LIVE_JOURNAL="$HOME/brain/journal/build/burst-lane.log"
iso_audit_before="$(mktemp "${TMPDIR:-/tmp}/bl-audit-before.XXXXXX")"
iso_audit_after="$(mktemp "${TMPDIR:-/tmp}/bl-audit-after.XXXXXX")"
ALL_TMPDIRS+=("$iso_audit_before" "$iso_audit_after")
# A REAL, independently-running burst-lane session (this host's own live
# lane serving other PRDs/gates right now — session.json present BEFORE
# this suite starts) legitimately mutates its own state/journal the whole
# time this suite runs (a pull, a run, a teardown from an unrelated tick).
# The audit below cannot distinguish that from a leak by diffing alone; it
# is scoped to "did the fixtures in THIS FILE ever touch the live tree",
# not "did anything on the host". Record whether one was already up so the
# final check below reports skipped-not-failed in that case, rather than
# perpetually false-failing this suite on every host that has a live lane
# in normal production use (Technical considerations: this audit's zero-
# diff guarantee only holds absent independent concurrent live activity).
iso_audit_live_session_pre="false"
[ -f "$ISO_LIVE_STATE_DIR/session.json" ] && iso_audit_live_session_pre="true"
audit_snapshot "$ISO_LIVE_STATE_DIR" "$ISO_LIVE_JOURNAL" > "$iso_audit_before"

expect() {
  local label="$1" cond="$2"
  local blk; blk="$(block_of "$label")"
  [ -n "${BLOCK_OPENED[$blk]:-}" ] && BLOCK_TOTAL[$blk]=$(( ${BLOCK_TOTAL[$blk]} + 1 ))
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
    [ -n "${BLOCK_OPENED[$blk]:-}" ] && BLOCK_FAIL[$blk]=$(( ${BLOCK_FAIL[$blk]} + 1 ))
    # PRD-build-burst-pull-back-restore AC11: every failing case in the
    # "pullback" block (this PRD's own AC3/AC5/AC12 fixtures) is recorded by
    # label so the end-of-run ledger names the cause of each, not just a
    # bare count.
    [ "$blk" = "pullback" ] && PULLBACK_FAILURE_CAUSES+=("$label")
  fi
}

# ---- Block-scoped summaries (PRD-build-burst-selftest-block-scoped-summary)-
# $fail above is suite-wide: every block's closing "every <block> case above
# ran green" assertion used to read `[ $fail -eq 0 ]` directly, so one real
# failure anywhere turned every LATER block's summary red too (observed
# 2026-09-13: 8-9 of 23-24 reported failures were this cascade, including
# `FAIL bursthyg: ...` with all 44 bursthyg cases individually green).
#
# block_start/expect_block_green give each block its own dedicated ok/fail
# counters, keyed by NAME rather than by textual position or a single
# "current block" pointer — parityr's own cases are physically interleaved
# with burstuser's further down this file (parityr AC4 sits inside
# burstuser's own commented section, and burstuser AC6 resumes in between
# two parityr cases), so a position-based baseline/delta would misattribute
# exactly the cases this PRD is trying to stop misattributing. Instead,
# `expect` above attributes every case to the block named by the label's own
# leading word (stripping a trailing colon covers both "parityr AC4: ..."
# and "bursthyg: ..." forms) — the same word a human already reads first
# when triaging a FAIL line.
declare -A BLOCK_TOTAL=()
declare -A BLOCK_FAIL=()
declare -A BLOCK_OPENED=()
declare -A BLOCK_SKIPPED=()

block_of() {  # $1 = a case label -> its block name
  local word="${1%% *}"
  printf '%s' "${word%:}"
}

block_start() {  # $1 = block name. Call at every entry point of that
  # block's cases (safe to call more than once for the same name across an
  # interleaved resume — counters are dedicated to the name and are never
  # reset once opened, only ever added to).
  local name="$1"
  BLOCK_OPENED["$name"]=1
  : "${BLOCK_TOTAL[$name]:=0}"
  : "${BLOCK_FAIL[$name]:=0}"
}

block_skip() {  # $1 = block name. The block did not run at all this pass
  # (e.g. a feature it needs is dormant); its summary reports skipped —
  # neither green nor red — and takes no baseline from a neighboring block.
  BLOCK_SKIPPED["$1"]=1
}

expect_block_green() {  # $1 = block name, $2 = the exact passing-line text
  # (kept byte-stable per block so existing greps on a passing line still
  # match — see this PRD's Migration section).
  local name="$1" label="$2"
  if [ "${BLOCK_SKIPPED[$name]:-0}" = "1" ]; then
    echo "SKIP $name: block skipped, no cases ran"
    return
  fi
  if [ -z "${BLOCK_OPENED[$name]:-}" ]; then
    echo "FAIL $name: block_start was never called for this block (0 cases counted, not necessarily 0 cases run)" >&2
    fail=1
    return
  fi
  local total="${BLOCK_TOTAL[$name]:-0}" bfail="${BLOCK_FAIL[$name]:-0}"
  if [ "$bfail" -eq 0 ]; then
    echo "ok  $label"
  else
    echo "FAIL $name: $bfail of $total cases failed" >&2
    fail=1
  fi
}

# ---- Regression lint (AC6): no block summary may hand-roll the global ------
# counter. A future block that copies the old `[ $fail -eq 0 ]` pattern
# instead of calling expect_block_green must be caught here, immediately,
# not discovered as a cascading summary weeks later. Scans this script's own
# source; the final suite verdict at the bottom is a plain `echo`, not an
# `expect "... ran green ..."` call, so it can never match this pattern and
# needs no special-case exclusion.
blockscope_lint_hits="$(grep -nE 'expect "[^"]*ran green[^"]*"[[:space:]]+"\[ \$fail -eq 0 \]"' "$HERE/$(basename "$0")" 2>/dev/null || true)"
if [ -n "$blockscope_lint_hits" ]; then
  echo "FAIL block-summary-lint: a block summary hand-rolls the global \$fail counter instead of expect_block_green:" >&2
  echo "$blockscope_lint_hits" >&2
  fail=1
fi

# 2026-09-11 RedBaron-local policy: the real Hetzner burst box is deleted;
# this whole suite exercises burst-lane.sh's routing/lifecycle logic
# against a FAKE hcloud/ssh/rsync, which proves nothing about whether
# burst is the box this fleet should actually be dispatching to right
# now. Gated, not deleted — see lib/burst-configured.sh's header for the
# exact condition and how to force this suite to run for real. Checked
# before fresh_env's first call, which overrides BURST_LANE_ENV_FILE with
# this run's own fake one.
# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — see burst-configured.sh"
  exit 0
fi

# ---- PRD-build-burst-pull-back-restore P0/AC1: the suite controls the -----
# pull-back disk guard instead of being silently governed by it. Every
# fixture worktree below lands under fresh_env's own `mktemp -d
# "${TMPDIR:-/tmp}/..."`, which on RedBaron (and this dev box) is a tmpfs
# with single-digit GB free — far under do_marker_pull's production
# BURST_LOCAL_DISK_FLOOR_GB default of 60. Left alone, every fixture pull
# gets deferred by that guard before a single byte moves: ~14 red
# burstpull/burstvol cases that never exercised the transfer layer at all
# (the false diagnosis this PRD traces). Rather than let the suite inherit
# the production floor by accident, it sets its OWN — small enough for its
# own worktree filesystem to satisfy, honoring an operator's own
# BURST_LOCAL_DISK_FLOOR_GB export if one is already present (e.g. the
# tests/pullback_ac*.sh wrappers' BURST_LOCAL_DISK_FLOOR_GB=2, which now
# becomes redundant with this default but is left alone rather than
# fought over) — and journals which filesystem holds its worktrees and how
# much free space it found, to this run's own stdout (read by every
# tests/pullback_ac*.sh wrapper via combined stdout+stderr, since the real
# BURST_LANE_JOURNAL doesn't exist yet at this point — fresh_env hasn't
# run its first time). A worktree filesystem that cannot even satisfy the
# small fixture floor fails the WHOLE suite fast, naming the filesystem,
# the free space, and the floor — never another wall of misleading
# `deferred` reds.
: "${BURST_LOCAL_DISK_FLOOR_GB:=2}"
export BURST_LOCAL_DISK_FLOOR_GB
_pullback_wt_base="${TMPDIR:-/tmp}"
_pullback_wt_fs="$(df -h --output=source,fstype "$_pullback_wt_base" 2>/dev/null | tail -n1 | tr -s ' ')"
_pullback_wt_free_gb="$(df -BG --output=avail "$_pullback_wt_base" 2>/dev/null | tail -n1 | tr -dc '0-9')"
echo "selftest: worktree filesystem $_pullback_wt_base (${_pullback_wt_fs:-unreadable}) free_gb=${_pullback_wt_free_gb:-unknown} — fixture floor set to BURST_LOCAL_DISK_FLOOR_GB=$BURST_LOCAL_DISK_FLOOR_GB"
case "$_pullback_wt_free_gb" in
  ''|*[!0-9]*)
    echo "selftest: WARNING — could not read free space on $_pullback_wt_base; skipping the fail-fast floor precondition (fixture pulls may still defer)" >&2
    ;;
  *)
    if [ "$_pullback_wt_free_gb" -lt "$BURST_LOCAL_DISK_FLOOR_GB" ]; then
      echo "FATAL: worktree filesystem $_pullback_wt_base has only ${_pullback_wt_free_gb}GB free, below the fixture floor of ${BURST_LOCAL_DISK_FLOOR_GB}GB (BURST_LOCAL_DISK_FLOOR_GB) — every fixture pull would defer before transferring a byte; refusing to run rather than report a wall of misleading 'deferred' reds. Lower BURST_LOCAL_DISK_FLOOR_GB, free space on $_pullback_wt_base, or point \$TMPDIR at a roomier filesystem." >&2
      exit 9
    fi
    ;;
esac
unset _pullback_wt_base _pullback_wt_fs _pullback_wt_free_gb

# PRD-build-burst-pull-back-restore AC11: open the "pullback" block now, so
# every "pullback AC<n>: ..." case anywhere below this point (AC3/AC5/AC12)
# is counted into BLOCK_TOTAL/BLOCK_FAIL["pullback"] via expect()'s own
# block_of() attribution — the ledger written near the bottom of this file
# reads those two counters plus PULLBACK_FAILURE_CAUSES.
block_start "pullback"

# PRD-build-burst-parity-cadence: every hand-crafted box-parity.json fixture
# in this suite must carry the ACTIVE session's session_id + toolchain_fp
# (matching what a real `parity` run would write) so cmd_gate's session/
# toolchain validity check reads it as valid — a receipt missing these
# fields correctly reads as the pre-migration shape (see the PRD's own
# Migration/compatibility section) and triggers a re-proof, which would
# change the assertions of every gate fixture here that predates the field
# and isn't itself testing that re-proof path (see the dedicated
# `paritycad AC2` case for that). Call only after `up` — needs an active
# session.
pc_active_session_id() { grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2; }
pc_active_toolchain_fp() { "$BL" _debug-toolchain-fp; }

# PRD-build-burst-pull-on-demand: rc0 iff `status --json`'s "dirty" array
# lists $1 by exact worktree path (used instead of a raw grep since a JSON
# array's field order/whitespace is an implementation detail this selftest
# should not pin down).
dirty_has() {
  "$BL" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(x.get("worktree") == sys.argv[1] for x in d.get("dirty", [])) else 1)
' "$1"
}

fresh_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/bl-selftest.XXXXXX")"
  ALL_TMPDIRS+=("$T")
  export PATH="$FAKE:$PATH"
  # PRD-build-burst-selftest-isolation requirement 1: every fixture here
  # runs under the sentinel, so a future path this function forgets to
  # override fails closed (exit 9) instead of silently falling through to
  # the live default — isolation becomes a property of burst-lane.sh
  # itself, not of this function staying exhaustive forever.
  export BURST_LANE_TEST=1
  export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  # PRD-build-burst-state-keyed-by-server-v2: pre-create $BURST_LANE_STATE_DIR/current
  # so every existing fixture in this file that writes a per-box path
  # directly (e.g. "$BURST_LANE_STATE_DIR/current/up.pid") before the
  # first real burst-lane.sh invocation of this fresh_env block keeps
  # working unchanged, exactly as it did against the old flat
  # "$BURST_LANE_STATE_DIR/<name>" layout. burst-lane.sh's own
  # box_point_current_at() folds this plain directory's content into the
  # real box the moment one is known (box_activate/migrate_state_layout),
  # so this placeholder never leaks into two different box ids.
  mkdir -p "$BURST_LANE_STATE_DIR/current"
  export BURST_LANE_JOURNAL="$T/journal.log"
  # PRD-build-burst-prove-evidence-preservation requirement 6: the real
  # BURST_PROVE_TMP default is /mnt/data/jsy/tmp — scope it under $T like
  # every other path here, or every provekeep fixture below would mv/cp
  # real bytes onto the actual host's disk instead of this sandbox.
  export BURST_PROVE_TMP="$T/prove-tmp"; mkdir -p "$BURST_PROVE_TMP"
  # isolation-guard.sh's OWN refusal record (a deliberate exception to
  # "everything under the sentinel is sandboxed" — see its header) defaults
  # to the real live journal; point it at this fixture's journal too so
  # this suite's own isolate_ac* cases (and every other case here) never
  # read or write the real ~/brain/journal/build/burst-lane.log.
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$T/remote"
  # PRD-build-burst-unprivileged-user: $REMOTE_USER now defaults to `build`,
  # and create_remote_user() does a real (offline-safe, but still real)
  # `mkdir -p $REMOTE_HOME/.ssh` — scope it under $T like every other
  # remote-path override, or every `up` in this whole file would attempt to
  # touch this machine's actual /home/build.
  export BURST_LANE_REMOTE_HOME="$T/remote-home"
  # PRD-build-burst-unprivileged-user requirement 2: every remote cargo
  # invocation now exports RUSTUP_HOME/CARGO_HOME pointing at root's shared
  # toolchain (/root/.rustup, /root/.cargo in production) — this offline
  # fixture's "remote" is really this machine's own filesystem, so pointing
  # those at a real /root (unreadable to this test-runner) would break every
  # real `cargo --version`/`cargo test` the fake ssh eval's for real.
  # Pointing them at THIS machine's own real toolchain instead exercises the
  # exact same code path (an env override, read-only) without a real /root.
  # PRD-build-burst-dispatch-reenable AC8c root cause: under
  # run-selftests.sh isolation, $HOME is redirected to an empty
  # $BUILD_TEST_ROOT/home with no real rustup/cargo install, so pointing
  # these at $HOME (as before) silently pointed `cargo --version` at a
  # toolchain-less HOME and every real remote-cargo/uv/python3 verify
  # check failed (3 vfail lines), making `run` fall back local and never
  # mark the worktree dirty — the exact AC8c symptom (pull saw a clean
  # worktree, exited 0, never reached the rsync-failure path at all).
  # isolation.sh exports BUILD_TEST_REAL_HOME for exactly this: the
  # pre-override real $HOME, which actually has the toolchain. Falls back
  # to plain $HOME for a bare (non-isolated) invocation, unchanged.
  export BURST_LANE_ROOT_RUSTUP_HOME="${BUILD_TEST_REAL_HOME:-$HOME}/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="${BUILD_TEST_REAL_HOME:-$HOME}/.cargo"
  export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
  export FAKE_HCLOUD_STATE="$T/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$T/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  # PRD-build-burst-dispatch-reenable requirement 1 (bake): fake `hcloud
  # server create-image` / `hcloud image describe` state, scoped under $T
  # like every other fake-hcloud state file above.
  export FAKE_HCLOUD_IMAGE_STATE="$T/hcloud-image.state"
  # requirement 4/6: this host's REAL ~/.config/systemd/user tree must
  # never be touched by this suite — every enable/disable/status case
  # scopes the drop-in under $T, and it does not exist by default (a fresh
  # session reads enabled:false until a case explicitly creates it).
  export BURST_LANE_SYSTEMD_DROPIN="$T/systemd-user/claude-build.service.d/burst.conf"
  export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$T/cost.jsonl"
  # Three-state retrofit (PRD-build-three-state-probes): sandbox the shared
  # probe ledger too, so this offline selftest never writes into the real
  # state/probes/ledger.jsonl or ~/brain/journal/build/.
  export BUILD_STATE_DIR="$T/state"
  export PROBE_JOURNAL_DIR="$T/probe-journal"
  # PRD-build-burst-dispatch-reenable requirement 8 (AC14): `up` now calls
  # reality-check.sh pending-run on every gate-ready boot/adopt (see
  # run_pending_reality_check_if_gate_ready in burst-lane.sh) — which, left
  # at its own defaults, reads/writes $HOME/brain/journal/build and this
  # repo's real state/reality-pending, and (had a registration existed)
  # would write_frontmatter_keys + commit_and_push against a REAL PRD file.
  # Isolation is a property of the harness (PRD-build-burst-selftest-
  # isolation's own framing), not of each fixture remembering this one new
  # call path — every `up` fixture in this file gets these three overrides
  # for free. The pending dir is left empty/absent here (created lazily by
  # reality-check.sh itself), so the ordinary case is a pure no-op; AC14's
  # own cases below populate it explicitly.
  export BUILD_JOURNAL_DIR="$T/reality-journal"
  export BUILD_RECEIPTS_DIR="$T/reality-journal/receipts"
  export REALITY_CHECK_PENDING_DIR="$T/reality-pending"
  # PRD-build-cost-attribution: sandbox the attribution ledger, the
  # known-repo root attribution_slug_for() consults, and the tick-journal
  # directory the daily rollup line lands in — never the real
  # ~/wintermute or ~/brain/journal/build/.
  export BURST_LANE_ATTR_LEDGER="$T/attribution.jsonl"
  export BURST_LANE_REPOS_DIR="$T/repos"; mkdir -p "$BURST_LANE_REPOS_DIR"
  export BURST_LANE_TICK_JOURNAL_DIR="$T/tick-journal"; mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
  # PRD-build-gate-on-casper requirement 1: gate-tools provisioning state,
  # scoped under $T so the fake ssh/rsync fixtures never touch this
  # machine's real ~/.cargo/bin or /root — see burst-lane.sh's own
  # GATE_TOOLS_REMOTE_BIN_DIR comment for why the destination must be
  # test-scoped (the fake rsync fixture never expands a tilde).
  export FAKE_GATE_TOOLS_STATE="$T/gate-tools-installed"
  export BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR="$T/remote-cargo-bin"
  # PRD-build-gate-on-casper requirement 4: the reviewer credential's REMOTE
  # destination must be test-scoped too (same tilde/absolute-path hazard as
  # GATE_TOOLS_REMOTE_BIN_DIR — the fake rsync/ssh never touch a real
  # remote host, only this machine's own filesystem). BURST_GATE_REVIEWER
  # stays unset by default so no test accidentally exercises credential
  # placement (and BURST_CLAUDE_CRED_SRC keeps pointing at its real default
  # of ~/.claude/.credentials.json) unless a test opts in explicitly.
  export BURST_LANE_GATE_CRED_REMOTE_PATH="$T/remote-cred/.credentials.json"
  # PRD-build-gate-on-casper AC8: production ships dark (BURST_GATE_REMOTE
  # unset/0 keeps every gate local) but every OTHER gatebox test here wants
  # to exercise the routed path, so default it on per-block and let the
  # dedicated AC8 block below override it back to unset for its own case.
  export BURST_GATE_REMOTE=1
  # PRD-build-burst-parity-robust requirement 1: force the pre-nextest
  # cargo-test fallback by default on the LOCAL side — this machine (and any
  # other running this suite) may genuinely have cargo-nextest on $PATH, and
  # only the dedicated parityr nextest-path tests below opt into exercising
  # it (see nextest_present_local()'s override contract in burst-lane.sh).
  # The box side needs no such override: it's fully mediated through the
  # fake ssh fixture's own explicit `command -v cargo-nextest` case, which
  # already defaults to "missing" unless a test sets FAKE_SSH_NEXTEST_PRESENT=1.
  export BURST_LANE_FORCE_NEXTEST_LOCAL=0
  # PRD-build-burst-persistent-volume: every pre-existing test in this file
  # predates the volume feature and asserts exact hcloud/ssh call sequences
  # around `up` — defaulting to the documented rollback (BURST_VOLUME_NAME
  # empty) keeps every one of them byte-for-byte unaffected (no `hcloud
  # volume` call, no extra root@/build@ round trip). The dedicated "burstvol"
  # block below opts back in per-case.
  export BURST_VOLUME_NAME=""
  export FAKE_HCLOUD_VOLUME_STATE="$T/hcloud-volume.state"
  unset FAKE_HCLOUD_AUTH_FAIL FAKE_HCLOUD_CREATE_FAIL FAKE_HCLOUD_DELETE_FAIL FAKE_SSH_REMOTE_FAIL FAKE_SSH_SANDBOX_FAIL FAKE_RSYNC_FAIL BURST_LANE_NOW \
        FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL FAKE_SSH_AUTOBUILDER_VERSION BURST_GATE_REVIEWER BURST_CLAUDE_CRED_SRC \
        FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR \
        FAKE_SSH_GATE_TOOLS_TOOLCHAIN_SIM FAKE_GATE_TOOLS_TOOLCHAIN_BIN FAKE_RUSTUP_TOOLCHAINS FAKE_CARGO_REQUIRE_TOOLCHAIN \
        FAKE_SSH_GATE_TOOLS_APT_UPDATE_FAIL FAKE_SSH_NEXTEST_PRESENT \
        FAKE_HCLOUD_VOLUME_CREATE_FAIL FAKE_HCLOUD_VOLUME_ATTACH_FAIL FAKE_HCLOUD_VOLUME_DETACH_FAIL \
        FAKE_HCLOUD_VOLUME_CREATE_STDERR_NOISE FAKE_HCLOUD_VOLUME_CREATE_GARBLED \
        FAKE_SSH_VOLUME_LABEL_PRESENT FAKE_SSH_VOLUME_MOUNT_FAIL FAKE_SSH_VOLUME_USED_GB FAKE_SSH_VOLUME_SIZE_GB FAKE_SSH_VOLUME_USED_PCT \
        FAKE_SSH_VOLUME_FSCK_CALLLOG \
        FAKE_HCLOUD_CREATE_IMAGE_FAIL FAKE_HCLOUD_CREATE_IMAGE_PENDING \
        FAKE_SSH_PULL_PROBE_BYTES FAKE_SSH_PULL_PROBE_FAIL FAKE_SSH_PULL_PROBE_HANG BURST_PULL_PROBE_TIMEOUT_S
}

# ---- AC1: single-box refusal + adoption ------------------------------------
fresh_env
out1="$("$BL" up)"; rc1=$?
expect "first up creates a server (exit 0)" "[ $rc1 -eq 0 ]"
expect "first up prints 'up: <id> <ip>'" "grep -q '^up: ' <<<\"$out1\""
create_calls="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "exactly one create call so far" "[ \"$create_calls\" -eq 1 ]"

out2="$("$BL" up)"; rc2=$?
expect "second up adopts, exits 0" "[ $rc2 -eq 0 ]"
expect "second up reports already-up, no new create" "grep -q '^already-up: ' <<<\"$out2\""
create_calls2="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "second up made no additional create call" "[ \"$create_calls2\" -eq 1 ]"

# adoption path: drop local session.json but leave the fake server alive
rm -f "$BURST_LANE_STATE_DIR/current/session.json"
out3="$("$BL" up)"; rc3=$?
expect "up with lost state adopts existing server (exit 0)" "[ $rc3 -eq 0 ]"
expect "adoption reported explicitly" "grep -q 'adopted' <<<\"$out3\""
create_calls3="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "adoption made no create call" "[ \"$create_calls3\" -eq 1 ]"
expect "adoption journaled" "grep -q 'burst-lane  up  adopted' \"$BURST_LANE_JOURNAL\""

# ---- AC2: run's exit-code passthrough; PRD-build-burst-pull-on-demand ------
# requirement 1 supersedes the old "run pulls target/ back itself" behavior:
# `run` now only marks the worktree remote-dirty and returns — the artifact
# is fetched lazily, at whichever consumer actually needs it next (here, an
# explicit `pull`).
WT="$T/worktree"; mkdir -p "$WT"
echo 'mkdir -p target && echo built > target/out.txt; exit 7' > "$WT/build.sh"
run_out="$("$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc=$?
expect "run propagates the remote exit code" "[ $run_rc -eq 7 ]"
expect "run does NOT pull target/ back itself (burstpull req 1)" "[ ! -e \"$WT/target\" ]"
expect "run journaled the routed call" "grep -q 'burst-lane  run  routed' \"$BURST_LANE_JOURNAL\""
expect "run's journal line marks the worktree dirty instead of pulling (burstpull req 1)" \
  "grep -q 'burst-lane  run  routed.*dirty=1' \"$BURST_LANE_JOURNAL\""
expect "run leaves the worktree listed dirty by status (burstpull req 3)" "dirty_has \"$WT\""

# requirement 3 / AC3: `status` (text mode, the operator-facing one) lists
# each dirty worktree with its age in seconds — "dirty: <worktree> age=<n>s"
# per cmd_status's own dirty_lines formatting.
status_txt="$("$BL" status 2>&1)"
expect "status lists the dirty worktree with age (burstpull req 3 / AC3)" \
  "grep -qF \"dirty: $WT age=\" <<<\"\$status_txt\""

pull_out="$("$BL" pull "$WT" 2>&1)"; pull_rc=$?
expect "explicit pull succeeds (burstpull req 3)" "[ $pull_rc -eq 0 ] && [ \"$pull_out\" = pulled ]"
expect "explicit pull fetched target/ back (burstpull req 3)" "[ -f \"$WT/target/out.txt\" ]"
expect "explicit pull cleared the dirty marker (burstpull req 3)" "! dirty_has \"$WT\""
# requirement 10 / AC11 (first half): this explicit pull is the FIRST rsync
# --stats call against $WT's destination (the fake rsync's per-dst call
# counter starts at 1 here) — bytes1 is the baseline the re-dirtied pull
# below must come in under.
bytes1="$(grep 'burst-lane  pull  ok' "$BURST_LANE_JOURNAL" | tail -1 | grep -oE 'bytes=[0-9]+' | cut -d= -f2)"
expect "first explicit pull journaled a byte count (req 10)" "[ -n \"$bytes1\" ] && [ \"$bytes1\" -gt 0 ]"

# ---- burstpull AC1: two consecutive remote runs on one worktree pull ZERO
# times between them — the marker stays dirty across both, and both
# attribution rows carry pulls_skipped with an estimate flag (requirement 1,
# requirement 5).
rm -rf "$WT/target"
run_out2="$("$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc2=$?
expect "second run also propagates the remote exit code" "[ $run_rc2 -eq 7 ]"
run_out2b="$("$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc2b=$?
expect "third (consecutive) run also propagates the remote exit code" "[ $run_rc2b -eq 7 ]"
expect "no pull ran between two consecutive remote runs (AC1)" "[ ! -e \"$WT/target\" ]"
expect "worktree still listed dirty after two consecutive runs (AC1)" "dirty_has \"$WT\""
ac1_rc=0
python3 -c "
import json
rows = [json.loads(l) for l in open('$BURST_LANE_ATTR_LEDGER') if l.strip()]
last_two = [r for r in rows if r.get('kind', 'run') == 'run'][-2:]
assert len(last_two) == 2, 'expected 2 run rows, got %d' % len(last_two)
for r in last_two:
    assert r.get('pulls_skipped') == 1, r
    assert r.get('estimate') is True, r
" || ac1_rc=1
expect "both consecutive-run attribution rows carry pulls_skipped + estimate=true (AC1)" "[ $ac1_rc -eq 0 ]"
# requirement 10 / AC11 (second half): $WT is dirty again (the two runs
# above), so this pull is a real second rsync --stats call against the same
# destination — the fake rsync's per-dst counter is now at 2, so it must
# report fewer bytes than bytes1 above, proving pull_target_incremental's
# delta reuse still holds under the new lazy-pull contract (only the call
# site moved, per the PRD's own "Technical considerations").
"$BL" pull "$WT" >/dev/null 2>&1   # leave the worktree clean for the next block
bytes2="$(grep 'burst-lane  pull  ok' "$BURST_LANE_JOURNAL" | tail -1 | grep -oE 'bytes=[0-9]+' | cut -d= -f2)"
expect "second explicit pull journaled a byte count (req 10)" "[ -n \"$bytes2\" ] && [ \"$bytes2\" -gt 0 ]"
expect "second explicit pull's bytes are fewer than the first's (AC11, incremental delta reuse)" "[ \"$bytes2\" -lt \"$bytes1\" ]"

# ---- requirement 13: cost-ledger PRD-served attribution ---------------------
# A caller that knows its own PRD slug (branch/gate dispatch) exports
# BURST_LANE_PRD_SLUG; a caller that doesn't still gets attributed by the
# worktree's own basename (both runs above, unset, should have recorded
# "worktree" — $WT's basename).
run_out3="$(BURST_LANE_PRD_SLUG=fake-prd-slug-1 "$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc3=$?
expect "third run (explicit slug) also propagates the remote exit code" "[ $run_rc3 -eq 7 ]"
expect "prds_served recorded the explicit BURST_LANE_PRD_SLUG" \
  "grep -qxF fake-prd-slug-1 \"$BURST_LANE_STATE_DIR/current/prds_served\""
expect "prds_served also recorded the worktree-basename fallback from the earlier unset-slug runs" \
  "grep -qxF worktree \"$BURST_LANE_STATE_DIR/current/prds_served\""

# ---- requirement 12: a uv-routed run pulls .pybuilder/ back, not target/ ----
# (pull_target_incremental hardcodes target/ or its Cargo override — a
# python run has neither, so before this fix AC12's ".pybuilder/ receipts
# appear locally afterwards" silently never happened even though routing
# itself worked.) A fake `uv` on PATH stands in for the real one: `run`
# resolves the routed command to the bare name "uv" whenever its first arg
# ends in "/uv" (mirroring the shim's own real-uv absolute path), so the
# eval'd fake-ssh remote command finds this fake `uv` and writes receipts
# under the (locally-rooted) remote_path's own .pybuilder/.
WT_PY="$T/worktree-py"; mkdir -p "$WT_PY"
FAKEBIN_PY="$T/fakebin-py"; mkdir -p "$FAKEBIN_PY"
cat > "$FAKEBIN_PY/uv" <<'EOF'
#!/usr/bin/env bash
mkdir -p .pybuilder
echo "receipt" > .pybuilder/out.txt
exit 0
EOF
chmod +x "$FAKEBIN_PY/uv"
py_run_out="$(PATH="$FAKEBIN_PY:$PATH" "$BL" run "$WT_PY" -- "$FAKEBIN_PY/uv" run pytest 2>&1)"; py_run_rc=$?
expect "python run (uv-routed) exits 0" "[ $py_run_rc -eq 0 ]"
# PRD-build-burst-pull-on-demand: laziness applies to the pybuilder pull-back
# exactly like the cargo one — `run` marks the worktree dirty (kind=pybuilder)
# and does not pull; an explicit pull fetches .pybuilder/, never target/.
expect "python run does NOT pull .pybuilder/ back itself (burstpull req 1)" \
  "[ ! -e \"$WT_PY/.pybuilder\" ] && [ ! -e \"$WT_PY/target\" ]"
expect "python run journaled the routed call" "grep -q 'burst-lane  run  routed.*worktree=$WT_PY' \"$BURST_LANE_JOURNAL\""
expect "python run journaled dirty=1 kind=pybuilder (burstpull req 1)" \
  "grep -q 'burst-lane  run  routed.*worktree=$WT_PY.*dirty=1 kind=pybuilder' \"$BURST_LANE_JOURNAL\""
py_pull_out="$("$BL" pull "$WT_PY" 2>&1)"; py_pull_rc=$?
expect "explicit pull fetches .pybuilder/ back, not target/ (burstpull req 3)" \
  "[ $py_pull_rc -eq 0 ] && [ -f \"$WT_PY/.pybuilder/out.txt\" ] && [ ! -e \"$WT_PY/target\" ]"

# ---- unit: cargo_target_dir_for (worktree-targets-off-root interaction) ----
# mcphost-call-limits-honest, 2026-09-09 19:58Z: a worktree's own
# .cargo/config.toml can point target-dir at an absolute path outside the
# worktree (PRD-build-worktree-targets-off-root); pull_target_incremental
# used to hardcode $worktree/target, which never existed for such a
# worktree on the box, so every off-root worktree's rsync-down failed and
# fell back local even after a real remote build succeeded. Checked as a
# direct unit test (sourcing burst-lane.sh without running main) since the
# fake rsync/ssh pair shares one filesystem for "remote" and "local" and
# can't distinguish "pulled from the wrong path, worked anyway" from
# "pulled from the right path" the way a real two-host rsync would.
unit_rc=0
( source "$BL"
  wt_plain="$T/wt-plain"; mkdir -p "$wt_plain"
  wt_off="$T/wt-offroot"; mkdir -p "$wt_off/.cargo"
  printf '[build]\ntarget-dir = "/mnt/data/jsy/cargo-targets/fake-slug"\n' > "$wt_off/.cargo/config.toml"
  got_plain="$(cargo_target_dir_for "$wt_plain")"
  got_off="$(cargo_target_dir_for "$wt_off")"
  [ -z "$got_plain" ] || { echo "plain worktree should have no override, got '$got_plain'" >&2; exit 1; }
  [ "$got_off" = "/mnt/data/jsy/cargo-targets/fake-slug" ] || { echo "off-root override mismatch, got '$got_off'" >&2; exit 1; }
) 2>"$T/unit-cargo-target-dir.err" || unit_rc=$?
[ "$unit_rc" -eq 0 ] || cat "$T/unit-cargo-target-dir.err" >&2
expect "cargo_target_dir_for resolves an off-root target-dir, none for a plain worktree" "[ $unit_rc -eq 0 ]"

# ---- AC14: never poweroff/shutdown/stop -------------------------------------
expect "no poweroff/shutdown/stop/reboot call was ever made" \
  "! grep -qE 'server (poweroff|shutdown|stop|reboot)' \"$FAKE_HCLOUD_CALLLOG\""

# ---- AC14: primary IP goes with the server, never a standalone/orphan-able
# one — `server create` never attaches an existing Primary IP (--primary-ipv4)
# and no separate `primary-ip create`/`primary-ip delete` call is ever made;
# left at the default, Hetzner auto-manages an ephemeral Primary IPv4 that is
# deleted in the same `server delete` call destroy_verify already makes, so
# down's deletion removes the server's primary IP in the same step.
expect "server create never attaches a standalone primary IP (--primary-ipv4)" \
  "! grep -qE '^server create.*--primary-ipv4' \"$FAKE_HCLOUD_CALLLOG\""
expect "no separate primary-ip create call was ever made (would outlive server delete)" \
  "! grep -qE '^primary-ip create' \"$FAKE_HCLOUD_CALLLOG\""
expect "no separate primary-ip delete call was needed (server delete already took it)" \
  "! grep -qE '^primary-ip delete' \"$FAKE_HCLOUD_CALLLOG\""

# ---- AC8: down keeps while rust work remains --------------------------------
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust.md" <<'EOF'
# PRD — fake-rust

- Status: queued
- build_target: rust-extend
EOF
# PRD-build-burst-session-hygiene requirement 3: rust-work-remains may only
# KEEP a box that has proven itself (gate_ready AND runs_served>=1) — this
# session's own gate_ready is false (this dev host's real autobuilder check,
# unrelated to this fixture's own concern), so simulate a proven box the
# same way this suite already hand-patches other session.json fields
# (sandbox_ok, remote_user above) rather than dragging in a full gate-tools
# fixture just to flip one bit. runs_served is already >=1 from AC1/AC2's
# four `run` calls above.
sed -i 's/"gate_ready":"false"/"gate_ready":"true"/' "$BURST_LANE_STATE_DIR/current/session.json"
down_out="$("$BL" down)"
expect "down keeps the session while rust work is queued (proven box)" "[ \"$down_out\" = 'decision=keep' ]"
expect "down journaled decision=keep" "grep -q 'decision=keep' \"$BURST_LANE_JOURNAL\""

# ---- AC8: down schedules, then deletes at the hour boundary -----------------
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust.md"
boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch + 600))   # 10 minutes in — not near the hour boundary
down_out2="$("$BL" down)"
expect "down schedules teardown when no rust work remains, early in the hour" "[ \"$down_out2\" = 'decision=scheduled' ]"

export BURST_LANE_NOW=$((boot_epoch + 3600 - 60))   # 1 minute before the hour boundary
down_out3="$("$BL" down)"
expect "down deletes once inside the last-two-minutes window" "[ \"$down_out3\" = 'decision=deleted' ]"
expect "deletion journaled with cost" "grep -q 'burst-lane  down  decision=deleted' \"$BURST_LANE_JOURNAL\""
expect "cost ledger got a row" "[ -s \"$BURST_LANE_COST_LEDGER\" ]"

# ---- requirement 13 (cont'd): the deleted session's cost.jsonl row carries
# every PRD slug that session served, and `cost --today` prints them back.
expect "cost ledger row records the PRDs this session served (req 13)" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_COST_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if {'worktree', 'fake-prd-slug-1'}.issubset(set(d.get('prds', []))) else 1)\""
cost_today_out="$("$BL" cost --today)"
expect "cost --today prints hours and euros" "grep -qE 'hours=[0-9.]+ eur=[0-9.]+' <<<\"$cost_today_out\""
expect "cost --today prints the PRDs served this session (AC13)" \
  "grep -q 'prds=' <<<\"$cost_today_out\" && grep -q 'fake-prd-slug-1' <<<\"$cost_today_out\" && grep -q 'worktree' <<<\"$cost_today_out\""
expect "state cleared prds_served after deletion" "[ ! -f \"$BURST_LANE_STATE_DIR/current/prds_served\" ]"
unset BURST_LANE_NOW

# ---- burstpull AC2: a dirty worktree's local cargo consumer (the shim's
# local-fallback path) triggers exactly one pull first, clears the marker,
# and the pull's own attribution row records trigger=local-read with the
# reading slug (requirement 2).
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
WT_LR="$BURST_LANE_REPOS_DIR/mcphost"   # -> attribution_slug_for = shared-mcphost
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_LR/build.sh"
"$BL" run "$WT_LR" -- bash build.sh >/dev/null 2>&1
expect "burstpull AC2 setup: run left the worktree dirty" "dirty_has \"$WT_LR\""
expect "burstpull AC2 setup: target/ not present yet" "[ ! -e \"$WT_LR/target\" ]"

FAKEBIN_LR="$T/fakebin-lr"; mkdir -p "$FAKEBIN_LR"
cat > "$FAKEBIN_LR/cargo" <<'EOF'
#!/usr/bin/env bash
echo "local-cargo-ran: $*"
exit 0
EOF
chmod +x "$FAKEBIN_LR/cargo"
# `check` is never routed regardless of BURST_LANE — a deterministic way to
# exercise the shim's local-fallback path (and therefore ensure-fresh).
shim_lr_out="$(cd "$WT_LR" && PATH="$HERE/burst-lane-bin:$FAKEBIN_LR:$FAKE:$PATH" BURST_LANE=1 "$SHIM" check 2>&1)"
expect "burstpull AC2: shim ran local cargo (after the pull)" "grep -q 'local-cargo-ran: check' <<<\"$shim_lr_out\""
expect "burstpull AC2: one pull happened before the local cargo ran" "[ -f \"$WT_LR/target/out.txt\" ]"
expect "burstpull AC2: marker cleared after the local-read pull" "! dirty_has \"$WT_LR\""
ac2lr_rc=0
python3 -c "
import json
rows = [json.loads(l) for l in open('$BURST_LANE_ATTR_LEDGER') if l.strip()]
pulls = [r for r in rows if r.get('kind') == 'pull']
assert len(pulls) == 1, pulls
assert pulls[0]['trigger'] == 'local-read', pulls[0]
assert pulls[0]['slug'] == 'shared-mcphost', pulls[0]
" || ac2lr_rc=1
expect "burstpull AC2: exactly one pull attribution row, trigger=local-read, reading slug (req 2)" "[ $ac2lr_rc -eq 0 ]"

# ---- burstpull AC5: an explicit pull racing a live run on the SAME
# worktree is refused (named error, no rsync) rather than interleaved with
# it (requirement 6). $WT_LR is already dirty from the AC2 block's re-run
# above; a background holder of the SAME worktree lock file `run` itself
# would hold (acquire_run_slot's fd 203 lock, keyed by worktree_lock_key)
# stands in for a live run in flight — never call `run` itself here, since
# it would just block on that same lock rather than race it.
"$BL" run "$WT_LR" -- bash build.sh >/dev/null 2>&1   # re-dirty it for this test
lockfile_lr="$BURST_LANE_STATE_DIR/current/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_LR").lock"
mkdir -p "$(dirname "$lockfile_lr")"
(
  exec 209>"$lockfile_lr"
  flock 209
  sleep 2
) &
holder_pid=$!
sleep 0.3   # let the background subshell actually take the flock first
race_out="$("$BL" pull "$WT_LR" 2>&1)"; race_rc=$?
wait "$holder_pid" 2>/dev/null || true
expect "burstpull AC5: explicit pull is refused while the worktree lock is held" "[ $race_rc -eq 4 ]"
expect "burstpull AC5: refusal names the cause" "grep -qi 'refused: worktree busy' <<<\"$race_out\""
expect "burstpull AC5: refusal journaled" "grep -q 'burst-lane  pull  refused' \"$BURST_LANE_JOURNAL\""
"$BL" pull "$WT_LR" >/dev/null 2>&1   # clean up now that the holder has released

# ---- burstpull AC4: teardown sweep pulls every still-dirty worktree before
# the box dies; a worktree whose remote dir has vanished goes cold (cleared,
# journaled) instead of aborting the sweep or leaking a stale read; the
# other two dirty worktrees are still pulled and the box is deleted only
# after the sweep runs (requirement 4).
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
declare -a sweep_wts=()
for slug in sw-one sw-two sw-cold sw-busy; do
  wt="$T/mcphost-$slug"; mkdir -p "$wt"
  echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt/build.sh"
  "$BL" run "$wt" -- bash build.sh >/dev/null 2>&1
  sweep_wts+=("$wt")
done
for wt in "${sweep_wts[@]}"; do
  expect "burstpull AC4 setup: $(basename "$wt") is dirty before teardown" "dirty_has \"$wt\""
done
# Simulate "the box already gone for this one worktree": delete its remote
# dir out from under the (otherwise still-alive) session.
cold_remote="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('remote_path',''))" \
  "$BURST_LANE_STATE_DIR/current/dirty/$(printf '%s' "$T/mcphost-sw-cold" | sha1sum | cut -c1-8).json")"
rm -rf "$cold_remote"

# Simulate "a live run is still in flight on this one worktree right as the
# box is about to die": hold its wt-lock in the background — the sweep must
# skip it (leave it dirty, journal a failure) rather than abort (requirement
# 4: "per-worktree failure does not abort the sweep").
busy_lockfile="$BURST_LANE_STATE_DIR/current/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$T/mcphost-sw-busy").lock"
mkdir -p "$(dirname "$busy_lockfile")"
( exec 208>"$busy_lockfile"; flock 208; sleep 3 ) &
busy_holder_pid=$!
sleep 0.3

boot_epoch_sw="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch_sw + 3600 - 60))
down_sw_out="$("$BL" down)"
wait "$busy_holder_pid" 2>/dev/null || true
expect "burstpull AC4: teardown still deletes cleanly despite one cold + one busy worktree" "[ \"$down_sw_out\" = 'decision=deleted' ]"
expect "burstpull AC4: the two pullable worktrees got their target/ back" \
  "[ -f \"$T/mcphost-sw-one/target/out.txt\" ] && [ -f \"$T/mcphost-sw-two/target/out.txt\" ]"
expect "burstpull AC4: the cold worktree's target/ was never fetched" "[ ! -e \"$T/mcphost-sw-cold/target\" ]"
expect "burstpull AC4: the busy worktree's target/ was never fetched either (sweep skipped it, did not wait)" \
  "[ ! -e \"$T/mcphost-sw-busy/target\" ]"
# NOTE: `dirty_has` reads `status --json`'s "dirty" array, which (like
# "no active session" above) is only populated while a session is active —
# `down` just tore this one down, so from here on marker state must be
# checked as raw files on disk instead (marker_file mirrors
# dirty_marker_file()'s own sha1-prefix key scheme).
marker_file() { printf '%s/current/dirty/%s.json\n' "$BURST_LANE_STATE_DIR" "$(printf '%s' "$1" | sha1sum | cut -c1-8)"; }
expect "burstpull AC4: the pulled/cold markers are cleared after the sweep" \
  "[ ! -s \"$(marker_file "$T/mcphost-sw-one")\" ] && [ ! -s \"$(marker_file "$T/mcphost-sw-two")\" ] && [ ! -s \"$(marker_file "$T/mcphost-sw-cold")\" ]"
expect "burstpull AC4: the busy worktree's marker is LEFT dirty for a later retry (sweep does not abort on it)" \
  "[ -s \"$(marker_file "$T/mcphost-sw-busy")\" ]"
expect "burstpull AC4: the cold worktree was journaled cold, not silently dropped" \
  "grep -q 'burst-lane  pull  cold.*mcphost-sw-cold' \"$BURST_LANE_JOURNAL\""
expect "burstpull AC4: the busy worktree's sweep failure is journaled, and the sweep continued past it" \
  "grep -q 'burst-lane  down  sweep-failed.*mcphost-sw-busy' \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_NOW

# ---- AC6: watchdog TTL teardown ----------------------------------------------
fresh_env
"$BL" up >/dev/null
boot_epoch2="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch2 + 7 * 3600))   # past the default 6h ttl
wd_out="$("$BL" watchdog)"
expect "watchdog deletes a session past its TTL" "grep -q '^watchdog teardown: ' <<<\"$wd_out\""
expect "watchdog journal line names uptime" "grep -q 'burst-lane  watchdog  teardown' \"$BURST_LANE_JOURNAL\""
expect "state cleared after watchdog teardown" "[ ! -f \"$BURST_LANE_STATE_DIR/current/session.json\" ]"
unset BURST_LANE_NOW

# ---- AC3 (shim, local-fallback half): no session -> local cargo, journaled --
fresh_env
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/cargo" <<'EOF'
#!/usr/bin/env bash
echo "local-cargo-ran: $*"
exit 0
EOF
chmod +x "$FAKEBIN/cargo"
shim_out="$(cd "$WT" && PATH="$HERE/burst-lane-bin:$FAKEBIN:$FAKE:$PATH" BURST_LANE=1 "$SHIM" test 2>&1)"
expect "shim falls through to local cargo with no session" "grep -q 'local-cargo-ran: test' <<<\"$shim_out\""
expect "shim journals the no-session fallback to stderr" "grep -q 'burst-lane: no session, local' <<<\"$shim_out\""

# ---- AC7: sub-cap formula ----------------------------------------------------
# No session -> only the local cap (3) applies; nothing computed from a box.
fresh_env
subcap_nosession="$("$BL" sub-cap)"
expect "sub-cap with no session reports local=3" "grep -q 'local=3' <<<\"$subcap_nosession\""
expect "sub-cap with no session journals it" "grep -q 'burst-lane  sub-cap  no-session' \"$BURST_LANE_JOURNAL\""

"$BL" up >/dev/null

# 120 GB avail, 32 cores, 10 rust candidates -> floor(120/8)=15, floor(32/4)=8,
# min(15,8,10)=8 (AC7; default GB-per-run bumped 6->8, cpu term still binds).
subcap8="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap admits 8 on a 120GB/32-core box (AC7)" "grep -q '^sub-cap=8 local=0' <<<\"$subcap8\""
# PRD-build-burst-remote-disk-guard requirement 2 added a trailing
# free_disk_gb field to this same journal line (the fake ssh's default disk
# reading, deliberately abundant so it's never the binding term here).
expect "sub-cap journals the AC7-shaped line" \
  "grep -q 'burst: sub-cap=8 (avail_gb=120 nproc=32 free_disk_gb=100000) local=0' \"$BURST_LANE_JOURNAL\""

# 40 GB avail, 32 cores -> floor(40/8)=5, floor(32/4)=8, min(5,8,10)=5 (AC7).
# PRD-build-burst-run-slots-from-box requirement 2 bumped the default
# GB-per-run knob from 6 to 8 (run_slot_cap_terms, shared with the run-slot
# table, defaults to the values RedBaron's real .env already pins) — this
# expectation moved from 6 to 5 accordingly; see that PRD's own boxslots
# AC6 for the "one function" proof.
subcap6="$(FAKE_SSH_MEMINFO_GB=40 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap admits 5 on a 40GB/32-core box (AC7, default GB-per-run bumped to 8)" "grep -q '^sub-cap=5 local=0' <<<\"$subcap6\""

# A failed probe never blocks the caller: fallback exit 3, no crash.
subcap_fail_rc=0
FAKE_SSH_PROBE_FAIL=1 "$BL" sub-cap >/dev/null 2>&1 || subcap_fail_rc=$?
expect "sub-cap exits 3 (fallback, never blocks) when the probe fails" "[ $subcap_fail_rc -eq 3 ]"

# ---- Requirement 6 / AC5: sandbox-unavailable session caps rust selection
# at local=2 (a lower, more conservative fallback than the no-session cap of
# 3) instead of honoring the box's memory/cpu-computed width — a session
# whose `up` sandbox probe failed still has a session.json (state_active is
# true), so without this check sub-cap would otherwise report the full
# 8-wide box capacity computed above regardless of sandbox status.
sed -i 's/"sandbox_ok":"true"/"sandbox_ok":"false"/' "$BURST_LANE_STATE_DIR/current/session.json"
subcap_nosandbox="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap falls back to local cap 2 when sandbox is unavailable (req 6 / AC5)" \
  "grep -q '^sub-cap=2 local=0' <<<\"$subcap_nosandbox\""
expect "sub-cap journals the sandbox-unavailable reason" \
  "grep -q 'burst-lane  sub-cap  sandbox-unavailable' \"$BURST_LANE_JOURNAL\""
sed -i 's/"sandbox_ok":"false"/"sandbox_ok":"true"/' "$BURST_LANE_STATE_DIR/current/session.json"

# =============================================================================
# PRD-build-cost-attribution: every burst euro/box-hour lands on a PRD slug.
# =============================================================================

# ---- AC1: slug derivation from the build-worktrees basename convention -----
# `mcphost-mcphost-schedules` under a known-repo root containing "mcphost"
# -> slug "mcphost-schedules" (everything after "<repo>-").
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
WT_AC1="$T/mcphost-mcphost-schedules"; mkdir -p "$WT_AC1"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_AC1/build.sh"
"$BL" run "$WT_AC1" -- bash build.sh >/dev/null 2>&1
expect "AC1: attribution row derives slug=mcphost-schedules from the worktree basename" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if d.get('slug')=='mcphost-schedules' else 1)\""
expect "AC1: attribution row has wall_seconds > 0" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if float(d.get('wall_seconds',0)) > 0 else 1)\""
expect "AC1: attribution row carries the run's bytes" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if 'bytes' in d else 1)\""

# ---- AC2: shared-checkout and gate-burst/selftest-fixture derivation -------
# Nothing is ever dropped: a run against the shared checkout itself (no
# per-PRD worktree) -> "shared-<repo>"; a run under a gb-ac<N> fixture tmpdir
# (tests/gate_burst_ac*.sh's own convention) -> "selftest".
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
WT_SHARED="$BURST_LANE_REPOS_DIR/mcphost"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_SHARED/build.sh"
"$BL" run "$WT_SHARED" -- bash build.sh >/dev/null 2>&1
expect "AC2: the shared checkout itself is attributed shared-mcphost" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if d.get('slug')=='shared-mcphost' else 1)\""
WT_FIXTURE="$T/gb-ac99.fixtureXYZ/repo"; mkdir -p "$WT_FIXTURE"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_FIXTURE/build.sh"
"$BL" run "$WT_FIXTURE" -- bash build.sh >/dev/null 2>&1
expect "AC2: a gb-ac fixture path is attributed selftest" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if d.get('slug')=='selftest' else 1)\""
expect "AC2: nothing dropped — both runs landed a row (2 total)" \
  "[ \"$(wc -l < "$BURST_LANE_ATTR_LEDGER")\" -eq 2 ]"

# ---- AC3: teardown prorates 3 slugs' eur, summing exactly to the session's -
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
sid3="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
for slug in alpha beta gamma; do
  wt="$T/mcphost-$slug"; mkdir -p "$wt"
  echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt/build.sh"
  "$BL" run "$wt" -- bash build.sh >/dev/null 2>&1
done
boot_epoch3="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch3 + 3600 - 60))
down_out3="$("$BL" down)"
expect "AC3: teardown with 3 attributed slugs still deletes cleanly" "[ \"$down_out3\" = 'decision=deleted' ]"
ac3_rc=0
python3 <<PY || ac3_rc=$?
import json, sys
rows = [json.loads(l) for l in open("$BURST_LANE_COST_LEDGER") if l.strip()]
sid = "$sid3"
session_rows = [r for r in rows if r.get("session_id") == sid and "hours" in r]
slug_rows = [r for r in rows if r.get("kind") == "slug" and r.get("session_id") == sid]
# PRD-build-burst-pull-on-demand requirement 4: none of these 3 runs had a
# local reader, so all 3 worktrees are still dirty at teardown — the sweep
# pulls all 3 before the box dies, landing a 4th "teardown" slug row (lane
# overhead, requirement 7) alongside alpha/beta/gamma.
if len(slug_rows) != 4:
    print("expected 4 slug rows (alpha/beta/gamma + teardown), got", len(slug_rows), file=sys.stderr); sys.exit(1)
if not any(r.get("slug") == "teardown" for r in slug_rows):
    print("expected a teardown-attributed slug row from the sweep", file=sys.stderr); sys.exit(1)
if not session_rows:
    print("no session row found for", sid, file=sys.stderr); sys.exit(1)
total = sum(r["eur"] for r in slug_rows)
if abs(total - session_rows[-1]["eur"]) > 1e-6:
    print("conservation mismatch", total, session_rows[-1]["eur"], file=sys.stderr); sys.exit(1)
sys.exit(0)
PY
expect "AC3: cost ledger gains 4 slug rows (incl. teardown sweep) whose eur sums exactly to the session eur" "[ \"$ac3_rc\" -eq 0 ]"

# ---- AC4: `cost --by-prd --session <id>` lists the 3 slugs + a totals row -
by_prd_out="$("$BL" cost --by-prd --session "$sid3" 2>&1)"; by_prd_rc=$?
expect "AC4: cost --by-prd --session exits 0 (conservation check passes)" "[ $by_prd_rc -eq 0 ]"
expect "AC4: cost --by-prd lists all 3 slugs" \
  "grep -q '^alpha' <<<\"$by_prd_out\" && grep -q '^beta' <<<\"$by_prd_out\" && grep -q '^gamma' <<<\"$by_prd_out\""
expect "AC4: cost --by-prd prints a TOTAL row" "grep -q '^TOTAL' <<<\"$by_prd_out\""
# ---- burstpull P1 AC7: the skip yield (pulls_skipped, bytes_saved -> GB) is
# readable in the same table, per-slug — not a separate report (requirement
# 5). alpha/beta/gamma above were never locally read, so the teardown sweep
# skip-accounted them; a "teardown" row (the sweep's own pulls) and the
# alpha/beta/gamma rows should all show up under the header.
expect "burstpull P1 AC7: cost --by-prd table header includes the skip-yield columns" \
  "grep -qE '^slug .*skipped.*GBsaved' <<<\"$by_prd_out\""
unset BURST_LANE_NOW

# ---- AC5: a crashed prior session's rows roll into the next teardown, ------
# named in the journal — never silently discarded.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
sid5="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
python3 <<PY
import json
row = {"date": "2026-09-01T00:00:00Z", "session_id": "crashed-999", "slug": "orphan-work",
       "wall_seconds": 42.0, "sync_s": 1.0, "bytes": 100, "worktree": "/tmp/orphan"}
with open("$BURST_LANE_ATTR_LEDGER", "a") as fh:
    fh.write(json.dumps(row) + "\n")
PY
wt5="$T/mcphost-live"; mkdir -p "$wt5"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt5/build.sh"
"$BL" run "$wt5" -- bash build.sh >/dev/null 2>&1
boot_epoch5="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch5 + 3600 - 60))
down_out5="$("$BL" down)"
expect "AC5: teardown with an orphaned prior-session row still deletes cleanly" "[ \"$down_out5\" = 'decision=deleted' ]"
expect "AC5: the orphaned session's slug is included in this teardown's proration" \
  "python3 -c \"import json; rows=[json.loads(l) for l in open('$BURST_LANE_COST_LEDGER') if l.strip()]; got=[r for r in rows if r.get('kind')=='slug' and r.get('session_id')=='$sid5' and r.get('slug')=='orphan-work']; import sys; sys.exit(0 if got else 1)\""
expect "AC5: journal names the orphaned session by id, not a silent discard" \
  "grep -q 'attribution-orphan-included.*session_id=crashed-999' \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_NOW

# ---- AC6: two `down` calls the same day -> exactly one daily rollup line --
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
wt6="$T/mcphost-rollupwork"; mkdir -p "$wt6"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt6/build.sh"
"$BL" run "$wt6" -- bash build.sh >/dev/null 2>&1
boot_epoch6="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch6 + 3600 - 60))
"$BL" down >/dev/null   # tears the box down and writes today's slug rows
"$BL" down >/dev/null   # today's slug rows now exist -> rollup fires on THIS call
today_file="$BURST_LANE_TICK_JOURNAL_DIR/$(date -u -d "@$BURST_LANE_NOW" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d).md"
rollup_count="$(grep -c '^burst-cost:' "$today_file" 2>/dev/null || echo 0)"
expect "AC6: exactly one daily burst-cost rollup line after two down calls same day" "[ \"$rollup_count\" -eq 1 ]"
expect "AC6: rollup line names eur/slug-count/top slug" "grep -q '^burst-cost: .* across .* slugs; top ' \"$today_file\""
# ---- burstpull P1 AC8: the same daily rollup line also carries the lazy-
# pull yield — pulls skipped and estimated GB saved (requirement 5/8). wt6's
# run above was never locally read before teardown, so its sweep pull counts
# as one skip surfaced here (bytes_saved=0 the first time anything ever ran
# against a fresh worktree — no prior pull to estimate from).
expect "burstpull P1 AC8: daily rollup line names pulls skipped and GB saved" \
  "grep -qE '^burst-cost: .*; pulls skipped [0-9]+, saved ~[0-9.]+ GB' \"$today_file\""
unset BURST_LANE_NOW

# =============================================================================
# PRD-build-burst-remote-disk-guard: the burst lane reads its own disk before
# it routes. (test_prefix: burstdisk)
# =============================================================================

# ---- burstdisk AC1: sub-cap is disk-bound when free disk is the tightest
# term — avail_gb=59/nproc=16 alone would admit 4 (floor(16/4)), but
# free_disk_gb=200 with the default 40 GB floor / 45 GB-per-run admits only
# floor((200-40)/45)=3 (requirement 2). PRD-build-burst-run-slots-from-box
# requirement 2 bumped the default disk-per-run knob from 70 to 45 (and
# GB-per-run from 6 to 8: floor(59/8)=7) — this case's binding term is still
# disk (3 < 4 and 3 < 7), just at a new value; see that PRD's boxslots AC6.
fresh_env
"$BL" up >/dev/null
subcap_disk="$(FAKE_SSH_MEMINFO_GB=59 FAKE_SSH_NPROC=16 FAKE_SSH_DISK_GB=200 "$BL" sub-cap)"
expect "burstdisk AC1: sub-cap is disk-bound at 3 on a 59GB/16-core/200GB-disk box (default disk-per-run bumped to 45)" \
  "grep -q '^sub-cap=3 local=0' <<<\"$subcap_disk\""
expect "burstdisk AC1: stdout names the binding term" "grep -q 'bound=disk' <<<\"$subcap_disk\""
expect "burstdisk AC1: journal carries free_disk_gb and bound=disk" \
  "grep -q 'sub-cap=3 (avail_gb=59 nproc=16 free_disk_gb=200) bound=disk' \"$BURST_LANE_JOURNAL\""

# ---- burstdisk AC2: `run` refuses to route below the disk floor, before
# any rsync is attempted (requirement 3).
WT_DISK="$T/worktree-disklow"; mkdir -p "$WT_DISK"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_DISK/build.sh"
remote_before="$(find "$BURST_LANE_REMOTE_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
disklow_out="$(FAKE_SSH_DISK_GB=12 "$BL" run "$WT_DISK" -- bash build.sh 2>&1)"; disklow_rc=$?
remote_after="$(find "$BURST_LANE_REMOTE_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
expect "burstdisk AC2: run exits 3 below the disk floor" "[ $disklow_rc -eq 3 ]"
expect "burstdisk AC2: stdout starts fallback: disk-low" "grep -q '^fallback: disk-low' <<<\"$disklow_out\""
expect "burstdisk AC2: journal carries cause=disk-low free_gb=12 floor_gb=40" \
  "grep -q 'cause=disk-low free_gb=12 floor_gb=40' \"$BURST_LANE_JOURNAL\""
expect "burstdisk AC2: no rsync-up was attempted (no new remote dir)" "[ \"$remote_before\" = \"$remote_after\" ]"

# ---- burstdisk AC3: a real rsync-up failure is named — rc and the log's
# own last stderr line, log captured under state/logs (requirement 4).
WT_RSYNCFAIL="$T/worktree-rsyncfail"; mkdir -p "$WT_RSYNCFAIL"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_RSYNCFAIL/build.sh"
rsyncfail_out="$(FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=11 \
  FAKE_RSYNC_FAIL_MSG='rsync: write failed: No space left on device (28)' \
  "$BL" run "$WT_RSYNCFAIL" -- bash build.sh 2>&1)"; rsyncfail_rc=$?
expect "burstdisk AC3: run exits 3 on a named rsync-up failure" "[ $rsyncfail_rc -eq 3 ]"
expect "burstdisk AC3: journal carries rc and the log's last stderr line" \
  "grep -qF 'cause=rsync-up-failed rc=11 err=\"rsync: write failed: No space left on device (28)\"' \"$BURST_LANE_JOURNAL\""
expect "burstdisk AC3: the captured log lives under state/logs, not /tmp" \
  "ls \"$BURST_LANE_STATE_DIR/current/logs\"/rsync-up.*.log >/dev/null 2>&1"

# ---- burstdisk AC4: reap deletes an orphan, skips a dirty-marked dir and a
# keep-listed dir, leaves a live worktree's dir untouched (requirement 5).
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null

# bar: a real, still-live worktree — synced, then explicitly pulled so it is
# no longer dirty (reap must find it via candidate-root decoding, not the
# dirty-marker shortcut).
WT_BAR="$BURST_LANE_REPOS_DIR/mcphost-bar"; mkdir -p "$WT_BAR"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_BAR/build.sh"
"$BL" run "$WT_BAR" -- bash build.sh >/dev/null 2>&1
"$BL" pull "$WT_BAR" >/dev/null 2>&1
bar_hash="$(printf '%s' "$WT_BAR" | sha1sum | cut -c1-8)"
bar_dir="$BURST_LANE_REMOTE_ROOT/mcphost-bar-$bar_hash"
expect "burstdisk AC4 setup: bar's remote dir exists" "[ -d \"$bar_dir\" ]"

# baz: was synced (dirty marker still present) but its local worktree is
# now gone — the dirty marker alone must protect it (requirement 5).
WT_BAZ="$T/mcphost-baz"; mkdir -p "$WT_BAZ"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_BAZ/build.sh"
"$BL" run "$WT_BAZ" -- bash build.sh >/dev/null 2>&1
baz_hash="$(printf '%s' "$WT_BAZ" | sha1sum | cut -c1-8)"
baz_dir="$BURST_LANE_REMOTE_ROOT/mcphost-baz-$baz_hash"
rm -rf "$WT_BAZ"
expect "burstdisk AC4 setup: baz is still dirty-marked" "[ -s \"$BURST_LANE_STATE_DIR/current/dirty/$baz_hash.json\" ]"

# foo: an orphaned remote dir whose hash suffix decodes to no known local
# worktree at all.
foo_dir="$BURST_LANE_REMOTE_ROOT/foo-abcd1234"; mkdir -p "$foo_dir"; echo x > "$foo_dir/f.txt"

# mcphost: the bare, un-hashed legacy shared checkout (requirement 7) —
# always protected via the BURST_REAP_KEEP default.
keep_dir="$BURST_LANE_REMOTE_ROOT/mcphost"; mkdir -p "$keep_dir"; echo x > "$keep_dir/f.txt"

reap_out="$("$BL" reap 2>&1)"
expect "burstdisk AC4: reap reports exactly one reaped dir" "grep -q '^reaped_dirs=1 ' <<<\"$reap_out\""
expect "burstdisk AC4: foo (no local worktree) is deleted" "[ ! -e \"$foo_dir\" ]"
expect "burstdisk AC4: bar (live worktree) is untouched" "[ -d \"$bar_dir\" ]"
expect "burstdisk AC4: baz (dirty marker) is untouched" "[ -d \"$baz_dir\" ]"
expect "burstdisk AC4: mcphost (keep-listed) is untouched" "[ -d \"$keep_dir\" ]"
expect "burstdisk AC4: journal has one reap-ok line naming foo, with bytes" \
  "grep -q 'burst-lane  reap  ok  (dir=foo-abcd1234 bytes=' \"$BURST_LANE_JOURNAL\""
expect "burstdisk AC4: journal has a reap-skip line for baz (reason=dirty)" \
  "grep -q \"burst-lane  reap  skip  (dir=mcphost-baz-$baz_hash reason=dirty)\" \"$BURST_LANE_JOURNAL\""
expect "burstdisk AC4: journal has a reap-skip line for mcphost (reason=keep)" \
  "grep -q 'burst-lane  reap  skip  (dir=mcphost reason=keep)' \"$BURST_LANE_JOURNAL\""

# ---- burstdisk AC5: a reap-listing ssh failure is journaled and never
# blocks down's own keep/scheduled/deleted decision (requirement 6).
fresh_env
"$BL" up >/dev/null
down_reapfail_out="$(FAKE_SSH_REAP_FAIL=255 "$BL" down 2>&1)"; down_reapfail_rc=$?
expect "burstdisk AC5: down still exits 0 despite a failed reap listing" "[ $down_reapfail_rc -eq 0 ]"
expect "burstdisk AC5: journal names the ssh rc" \
  "grep -q 'burst-lane  reap  fail  (cause=ssh rc=255)' \"$BURST_LANE_JOURNAL\""
reapfail_line="$(grep -n 'burst-lane  reap  fail' "$BURST_LANE_JOURNAL" | tail -1 | cut -d: -f1)"
downdecision_line="$(grep -n 'burst-lane  down  decision=' "$BURST_LANE_JOURNAL" | tail -1 | cut -d: -f1)"
expect "burstdisk AC5: the reap-fail line precedes down's own decision line" \
  "[ -n \"$reapfail_line\" ] && [ -n \"$downdecision_line\" ] && [ \"$reapfail_line\" -lt \"$downdecision_line\" ]"

# ---- burstdisk AC6: status --json reports free_disk_gb/disk_state, and the
# same low-disk reading collapses sub-cap to 0 — the same shape as "no
# session" — so lane-claim.sh's effective_subcap() (which only ever honors
# a box number matching [1-9]|[1-9][0-9]) falls straight through to the
# local cap without any lane-claim.sh code change (requirement 3, AC6).
fresh_env
"$BL" up >/dev/null
status_low_json="$(FAKE_SSH_DISK_GB=15 "$BL" status --json)"
expect "burstdisk AC6: status --json reports disk_state=low" "grep -q '\"disk_state\":\"low\"' <<<\$status_low_json"
expect "burstdisk AC6: status --json free_disk_gb is an integer" "grep -qE '\"free_disk_gb\":15,' <<<\$status_low_json"
subcap_low="$(FAKE_SSH_DISK_GB=15 "$BL" sub-cap)"
expect "burstdisk AC6: sub-cap collapses to 0 (same shape as no-session) when disk is low" \
  "grep -q '^sub-cap=0 local=0' <<<\"$subcap_low\""
ac6lc_rc=0
( source "$HERE/lane-claim.sh"
  BURST_LANE_SH="$BL"
  fake_target="$T/fake-rust-target"; mkdir -p "$fake_target"
  echo '[package]' > "$fake_target/Cargo.toml"
  got="$(FAKE_SSH_DISK_GB=15 effective_subcap "$fake_target")"
  [ "$got" = "$SAME_LANE_SUBCAP" ] || { echo "expected local cap $SAME_LANE_SUBCAP, got '$got'" >&2; exit 1; }
) 2>"$T/lane-claim-disklow.err" || ac6lc_rc=$?
[ "$ac6lc_rc" -eq 0 ] || cat "$T/lane-claim-disklow.err" >&2
expect "burstdisk AC6: lane-claim.sh effective_subcap treats low disk the same as no session" "[ $ac6lc_rc -eq 0 ]"

# ---- burstdisk AC7: the daily rollup folds in reap yield + disk-low
# fallbacks (requirement 8). Two reap-ok lines totalling 125 GB and one
# disk-low fallback are injected directly — a real 125 GB reap isn't
# reproducible offline, and reap_orphans' own ssh/du/rm plumbing is already
# covered by AC4 above; this block is testing maybe_daily_rollup's own
# journal scan.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
wt7="$T/mcphost-rollup7"; mkdir -p "$wt7"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt7/build.sh"
"$BL" run "$wt7" -- bash build.sh >/dev/null 2>&1
bytes_a=$((60 * 1073741824))
bytes_b=$((65 * 1073741824))
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  burst-lane  reap  ok  (dir=fake-a bytes=$bytes_a)"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  burst-lane  reap  ok  (dir=fake-b bytes=$bytes_b)"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  burst-lane  run  fallback  (cause=disk-low free_gb=10 floor_gb=40 worktree=$wt7)"
} >> "$BURST_LANE_JOURNAL"
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch7 + 3600 - 60))
"$BL" down >/dev/null   # tears the box down and writes today's slug rows
"$BL" down >/dev/null   # today's slug rows now exist -> rollup fires on THIS call
today7_file="$BURST_LANE_TICK_JOURNAL_DIR/$(date -u -d "@$BURST_LANE_NOW" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d).md"
expect "burstdisk AC7: rollup line names reaped_dirs, reaped_gb, disk_low_fallbacks" \
  "grep -qE 'reaped_dirs=2 reaped_gb=125 disk_low_fallbacks=1' \"$today7_file\""
unset BURST_LANE_NOW

# =============================================================================
# PRD-build-gate-cargo-route-attest: the gate proves where its cargo ran.
# "gateroute" cases (requirement 7): shim-first resolution under a fake
# session, intended-local with no session, a mismatch event when a fake
# real cargo is forced first on PATH, and per-gate route log isolation
# between two concurrent fake gates.
# =============================================================================

# ---- gateroute: shim-first resolution under a fake session -----------------
# route-check reads the CURRENT $PATH/session state without ever touching
# cmd_run (no rsync/ssh round trip, so no interaction with the fake-ssh
# stub's own environment-inheritance quirks — see the isolation block below
# for why `run`'s own literal-"cargo" remote command is unsafe to replay
# through this offline fixture) — this is exactly the check extend-gate.sh
# runs at gate start.
fresh_env
"$BL" up >/dev/null
FAKEBIN_GR="$T/fakebin-gateroute"; mkdir -p "$FAKEBIN_GR"
cat > "$FAKEBIN_GR/cargo" <<'EOF'
#!/usr/bin/env bash
echo "fake-real-cargo: $*"
exit 0
EOF
chmod +x "$FAKEBIN_GR/cargo"

rc_shim_first="$(PATH="$HERE/burst-lane-bin:$FAKEBIN_GR:$FAKE:$PATH" "$BL" route-check --repo "$T" 2>&1)"
expect "gateroute: shim-first resolution reports intended=burst" "grep -q 'intended=burst' <<<\"$rc_shim_first\""
expect "gateroute: shim-first resolution resolves to the shim itself" "grep -q \"resolved=$HERE/burst-lane-bin/cargo\" <<<\"$rc_shim_first\""
expect "gateroute: shim-first resolution is state=clean" "grep -q 'state=clean' <<<\"$rc_shim_first\""
expect "gateroute: shim-first resolution probed the gate-cargo-route probe clean" \
  "grep -q '\"probe\": \"gate-cargo-route\", \"reason\": \"intended=burst' \"$BUILD_STATE_DIR/probes/ledger.jsonl\""

# ---- gateroute: intended-local with no session ------------------------------
fresh_env
rc_nosession="$(PATH="$HERE/burst-lane-bin:$FAKEBIN_GR:$FAKE:$PATH" "$BL" route-check --repo "$T" 2>&1)"
expect "gateroute: no session reports intended=local" "grep -q 'intended=local' <<<\"$rc_nosession\""
expect "gateroute: no session is state=clean regardless of PATH order" "grep -q 'state=clean' <<<\"$rc_nosession\""

# ---- gateroute: shadowed-but-healable shim (fake real-cargo forced first
# on PATH, both shim dirs still present further down) ------------------------
# The exact 2026-09-10 defect, reproduced structurally: a session is up
# (intended=burst) but something (the pre-fix extend-gate.sh, here just a
# fake real-cargo directory) sits ahead of the shim on $PATH. Since
# PRD-build-cargo-route-precedence (2026-09-15), route-check no longer just
# detects this and stops: it self-heals whenever the shim dirs genuinely
# exist further down $PATH (they do here), journals "route healed" ONCE,
# and exits 0 — a true, unhealable "mismatch" (rc=9) now requires the shim
# itself to be absent/broken, not merely shadowed (see the dedicated case
# right after this one).
fresh_env
"$BL" up >/dev/null
ROUTE_LOG_HEALED="$T/route-healed.log"
rc_healed="$(BURST_ROUTE_LOG="$ROUTE_LOG_HEALED" PATH="$FAKEBIN_GR:$HERE/burst-lane-bin:$FAKE:$PATH" "$BL" route-check --repo "$T" 2>&1)"; rc_healed_rc=$?
expect "gateroute: shadowed-but-healable shim reports intended=burst" "grep -q 'intended=burst' <<<\"$rc_healed\""
expect "gateroute: shadowed-but-healable shim resolves (pre-heal) to the fake real cargo, not the shim" "grep -q \"resolved=$FAKEBIN_GR/cargo\" <<<\"$rc_healed\""
expect "gateroute: shadowed-but-healable shim is state=healed" "grep -q 'state=healed' <<<\"$rc_healed\""
expect "gateroute: healed self-heal exits 0 (never fatal to the caller)" "[ \"$rc_healed_rc\" -eq 0 ]"
expect "gateroute: healed seeded a synthetic 'route healed' route-log line" \
  "[ -f \"$ROUTE_LOG_HEALED\" ] && grep -q 'route healed shim-not-first' \"$ROUTE_LOG_HEALED\""
expect "gateroute: healed still probes the gate-cargo-route probe clean (the route DID resolve)" \
  "grep -q '\"probe\": \"gate-cargo-route\", \"reason\": \"intended=burst healed' \"$BUILD_STATE_DIR/probes/ledger.jsonl\""
healed_journal_count_1="$(grep -c '  route  healed  ' "$BURST_LANE_JOURNAL" 2>/dev/null)"; healed_journal_count_1="${healed_journal_count_1:-0}"
rc_healed_again="$(BURST_ROUTE_LOG="$ROUTE_LOG_HEALED" PATH="$FAKEBIN_GR:$HERE/burst-lane-bin:$FAKE:$PATH" "$BL" route-check --repo "$T" 2>&1)"
healed_journal_count_2="$(grep -c '  route  healed  ' "$BURST_LANE_JOURNAL" 2>/dev/null)"; healed_journal_count_2="${healed_journal_count_2:-0}"
expect "gateroute: a second route-check against the SAME per-gate route log never double-journals 'route healed'" \
  "[ \"$healed_journal_count_2\" -eq \"$healed_journal_count_1\" ]"

# ---- gateroute: genuinely unhealable mismatch (the shim itself missing,
# not just shadowed) is covered by tests/cargoroute_ac3_unhealable_mismatch
# _exits_9.sh, not here — self-heal here resolves the shim by its real,
# ABSOLUTE on-disk location (cargo_route_path_prefix() names the real
# scripts/cargo-budget-bin and scripts/burst-lane-bin directories
# regardless of what THIS test's own $PATH happens to contain), so nothing
# constructible by manipulating $PATH alone inside this file's shared
# fixture (which shares $HERE with the real, on-disk burst-lane.sh) can
# ever fail to self-heal. Proving the truly-missing-shim case needs its
# own isolated copy of the scripts/ tree with cargo-budget-bin deliberately
# absent — see that dedicated test file's own header.

# ---- gateroute: per-gate route log isolation between two concurrent fake
# gates (requirement 2's own "counts are per gate, not global") — two shim
# invocations against two different worktrees, each with its own
# BURST_ROUTE_LOG, launched together; neither's log gains the other's line.
# Uses `check` (always passthrough) and an unrouted-by-omission `build`
# (BURST_LANE unset -> local, no session needed) so neither call ever
# reaches cmd_run's rsync/ssh path — deliberately avoiding a real routed
# ("burst") call here: `run`'s remote command reduces an absolute cargo
# path to the bare name "cargo" (meaningless on a real box, resolved by
# the REMOTE's own PATH there), but this offline fixture's fake ssh is
# just a local `eval` that inherits the CALLING process's own $PATH — with
# this shim's directory still on it, that bare "cargo" would recurse back
# into the shim forever. A real remote box's PATH never has this shim on
# it, so this is a fake-ssh-fixture-only hazard, not a production one; the
# "burst" decision path itself is already covered by the shim-first
# resolution case above (which asserts the shim is what gets EXECed,
# without following that exec through a live round trip).
fresh_env
WT_G1="$T/gate1-wt"; mkdir -p "$WT_G1"
WT_G2="$T/gate2-wt"; mkdir -p "$WT_G2"
LOG_G1="$T/gate1-route.log"
LOG_G2="$T/gate2-route.log"
( cd "$WT_G1" && PATH="$HERE/burst-lane-bin:$FAKEBIN_GR:$FAKE:$PATH" BURST_ROUTE_LOG="$LOG_G1" "$SHIM" check ) >/dev/null 2>&1 &
pid_g1=$!
( cd "$WT_G2" && PATH="$HERE/burst-lane-bin:$FAKEBIN_GR:$FAKE:$PATH" BURST_ROUTE_LOG="$LOG_G2" "$SHIM" build ) >/dev/null 2>&1 &
pid_g2=$!
wait "$pid_g1" "$pid_g2" 2>/dev/null
expect "gateroute isolation: gate1's log has exactly one passthrough line" \
  "[ \"\$(awk '\$4==\"passthrough\"' \"$LOG_G1\" 2>/dev/null | wc -l)\" -eq 1 ]"
expect "gateroute isolation: gate2's log has exactly one local line (BURST_LANE unset -> local)" \
  "[ \"\$(awk '\$4==\"local\"' \"$LOG_G2\" 2>/dev/null | wc -l)\" -eq 1 ]"
expect "gateroute isolation: gate1's log does not contain gate2's worktree" "! grep -q \"$WT_G2\" \"$LOG_G1\" 2>/dev/null"
expect "gateroute isolation: gate2's log does not contain gate1's worktree" "! grep -q \"$WT_G1\" \"$LOG_G2\" 2>/dev/null"

# ---- gateroute AC7 (P1, requirement 6): a caller that exports
# BURST_LANE_PRD_SLUG=gate-<repo> (extend-gate.sh's own convention) is
# attributed under that exact slug — not attribution_slug_for()'s
# worktree-basename guess — in attribution.jsonl, and that slug's own row
# survives into `cost --by-prd`.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/gateroute-repo"
WT_G7="$BURST_LANE_REPOS_DIR/gateroute-repo"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_G7/build.sh"
BURST_LANE_PRD_SLUG="gate-gateroute-repo" "$BL" run "$WT_G7" -- bash build.sh >/dev/null 2>&1
expect "gateroute AC7: attribution row uses the explicit gate-<repo> slug, not the worktree-basename guess" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_ATTR_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if d.get('slug')=='gate-gateroute-repo' else 1)\""

boot_epoch_g7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch_g7 + 3600 - 60))
"$BL" down >/dev/null
unset BURST_LANE_NOW
cost_by_prd_g7="$("$BL" cost --by-prd)"
expect "gateroute AC7: cost --by-prd shows a gate-<repo> row for the gate's own cargo cost" \
  "grep -q 'gate-gateroute-repo' <<<\"$cost_by_prd_g7\""

# =============================================================================
# PRD-build-gate-on-casper: the whole gate runs on casper, not RedBaron.
# (test_prefix: gatebox)
# =============================================================================

# ---- gatebox AC1: `up` provisions the gate toolchain when tools are
# missing, records gate_ready:true with a version for every tool, and
# `verify` reports "gate-tools ok" (requirement 1).
fresh_env
FAKE_AB_SRC="$T/fake-autobuilder-src"; mkdir -p "$FAKE_AB_SRC"
cat > "$FAKE_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$FAKE_AB_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$FAKE_AB_SRC/autobuilder"
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder jq"
gatebox1_out="$("$BL" up)"; gatebox1_rc=$?
expect "gatebox AC1: up succeeds even though autobuilder+jq start missing" "[ $gatebox1_rc -eq 0 ]"
expect "gatebox AC1: session state records gate_ready:true after provisioning" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
gt_missing_field="$(grep -oE '"gate_tools_missing":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
expect "gatebox AC1: gate_tools_missing is empty once provisioning completed" "[ -z \"$gt_missing_field\" ]"
gatebox1_tools_rc=0
python3 -c "
import json
d = json.load(open('$BURST_LANE_STATE_DIR/current/gate-tools.json'))
expected = {'autobuilder', 'jq', 'gh', 'mold', 'cargo-deny', 'cargo-nextest', 'uv', 'claude'}
got = set(d.get('tools', {}).keys())
assert got == expected, ('tool set mismatch', got)
for t, v in d['tools'].items():
    assert v and v != 'MISSING', (t, v)
assert d.get('missing') == [], d.get('missing')
" || gatebox1_tools_rc=1
expect "gatebox AC1: gate-tools.json records a version for every requirement-1 tool" "[ $gatebox1_tools_rc -eq 0 ]"
expect "gatebox AC1: the install path actually ran for the two initially-missing tools" \
  "grep -qx autobuilder \"$FAKE_GATE_TOOLS_STATE\" && grep -qx jq \"$FAKE_GATE_TOOLS_STATE\""

gatebox1_verify_out="$("$BL" verify 2>&1)"; gatebox1_verify_rc=$?
expect "gatebox AC1: verify exits 0 once gate-tools (and everything else) is provisioned" "[ $gatebox1_verify_rc -eq 0 ]"
expect "gatebox AC1: verify reports 'gate-tools ok'" "grep -q '^gate-tools ok$' <<<\"$gatebox1_verify_out\""

# A second `up` (adoption path — state cleared but the fake server survives)
# re-provisions via the adoption branch too, not just the fresh-create one.
rm -f "$BURST_LANE_STATE_DIR/current/session.json"
unset FAKE_SSH_GATE_TOOLS_MISSING
gatebox1b_out="$("$BL" up)"; gatebox1b_rc=$?
expect "gatebox AC1: adoption path also succeeds and re-provisions" "[ $gatebox1b_rc -eq 0 ]"
expect "gatebox AC1: adoption path also records gate_ready:true" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""

# ---- gatebox AC2: `parity` runs the workspace suite on the box and
# compares it to RedBaron's own baseline, writing exactly the differing
# suites into receipts/box-parity.json; a following `gate` call then
# refuses (exit 3, fallback: parity-diff) while that parity stands
# (requirement 2 + requirement 5's fallback contract). The fake `cargo` on
# $PATH tells "box" and "local" runs apart by $PWD (the remote run always
# cd's under $BURST_LANE_REMOTE_ROOT first; the local run cd's into $repo
# directly) rather than any burst-lane.sh-side special-casing, so the real
# cargo-test-log parser (cargo_test_suites_json) is exercised authentically
# instead of being handed canned JSON.
fresh_env
"$BL" up >/dev/null
WT_PARITY="$T/parity-repo"; mkdir -p "$WT_PARITY"
( cd "$WT_PARITY" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PARITY="$T/fakebin-parity"; mkdir -p "$FAKEBIN_PARITY"
cat > "$FAKEBIN_PARITY/cargo" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "test" ]; then
  case "\$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*)
      # box run: parity=ok, other=ok, integration=FAILED
      cat <<'LOG'
     Running unittests src/lib.rs (target/debug/deps/parity-1111111111111111)

running 1 test
test a ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/other.rs (target/debug/deps/other-2222222222222222)

running 1 test
test b ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running tests/integration.rs (target/debug/deps/integration-3333333333333333)

running 1 test
test c ... FAILED

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
LOG
      ;;
    *)
      # local (RedBaron) baseline run: parity=ok (matches), other=FAILED,
      # integration=ok — exactly two suites (other, integration) differ
      # from the box's run above.
      cat <<'LOG'
     Running unittests src/lib.rs (target/debug/deps/parity-4444444444444444)

running 1 test
test a ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/other.rs (target/debug/deps/other-5555555555555555)

running 1 test
test b ... FAILED

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running tests/integration.rs (target/debug/deps/integration-6666666666666666)

running 1 test
test c ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
LOG
      ;;
  esac
  exit 0
fi
echo "fake-cargo(parity): unhandled args: \$*" >&2
exit 1
EOF
chmod +x "$FAKEBIN_PARITY/cargo"

parity_out="$(PATH="$FAKEBIN_PARITY:$PATH" "$BL" parity "$WT_PARITY" 2>&1)"; parity_rc=$?
expect "gatebox AC2: parity exits 0 (it records the diff, doesn't fail on one)" "[ $parity_rc -eq 0 ]"
expect "gatebox AC2: parity reports diff=2" "grep -q 'diff=2' <<<\"$parity_out\""
expect "gatebox AC2: journal has 'parity  diff'" "grep -q 'burst-lane  parity  diff' \"$BURST_LANE_JOURNAL\""
parity_file="$WT_PARITY/target/autobuilder/receipts/box-parity.json"
expect "gatebox AC2: box-parity.json was written" "[ -s \"$parity_file\" ]"
parity_json_rc=0
python3 -c "
import json
d = json.load(open('$parity_file'))
assert sorted(d['diff']) == ['integration::tests/integration.rs', 'other::src/other.rs'], d['diff']
assert d['head_sha'], d
assert d['box_host'], d
assert 'parity::src/lib.rs' not in d['diff']
" || parity_json_rc=1
expect "gatebox AC2: box-parity.json diff lists exactly the two differing suites (req 2)" "[ $parity_json_rc -eq 0 ]"
expect "gatebox AC2: a fresh local baseline was cached to target/autobuilder/test-output.txt" \
  "[ -s \"$WT_PARITY/target/autobuilder/test-output.txt\" ]"

gate_out="$(PATH="$FAKEBIN_PARITY:$PATH" "$BL" gate "$WT_PARITY" --head "$(git -C "$WT_PARITY" rev-parse HEAD)" 2>&1)"; gate_rc=$?
expect "gatebox AC2: gate refuses to route while parity is diff (exit 3)" "[ $gate_rc -eq 3 ]"
expect "gatebox AC2: gate prints fallback: parity-diff" "grep -q '^fallback: parity-diff$' <<<\"$gate_out\""
expect "gatebox AC2: gate journaled the fallback with cause" "grep -q 'burst-lane  gate  fallback.*cause=parity-diff' \"$BURST_LANE_JOURNAL\""

# A brand-new repo with no parity receipt at all is "unknown", not "diff" —
# same refusal, a different named cause.
WT_NOPARITY="$T/noparity-repo"; mkdir -p "$WT_NOPARITY"
( cd "$WT_NOPARITY" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
gate_unknown_out="$("$BL" gate "$WT_NOPARITY" --head "$(git -C "$WT_NOPARITY" rev-parse HEAD)" 2>&1)"; gate_unknown_rc=$?
expect "gatebox AC2: gate refuses on no parity receipt at all (exit 3)" "[ $gate_unknown_rc -eq 3 ]"
expect "gatebox AC2: gate names the parity-unknown cause" "grep -q '^fallback: parity-unknown$' <<<\"$gate_unknown_out\""

# ---- gatebox AC3: given parity ok, `gate` actually invokes extend-gate.sh
# on the box (once, with --head <sha>), rsyncs back ONLY target/autobuilder/
# and .gate-burst-host, patches "host" onto the pulled-back last-verdict.json,
# and propagates the remote exit code (requirement 3). A fake extend-gate.sh
# stands in for the real one (armed ahead of the requirement-1 synced copy
# on $PATH, per cmd_gate's own append-not-prepend convention) so this stays
# offline and deterministic.
fresh_env
"$BL" up >/dev/null
WT_GATE="$T/gate-repo"; mkdir -p "$WT_GATE"
( cd "$WT_GATE" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_gate="$(git -C "$WT_GATE" rev-parse HEAD)"
mkdir -p "$WT_GATE/target/autobuilder/receipts"
sid_gate3="$(pc_active_session_id)"; tfp_gate3="$(pc_active_toolchain_fp)"
cat > "$WT_GATE/target/autobuilder/receipts/box-parity.json" <<EOF
{"head_sha": "$head_gate", "box_host": "127.0.0.1", "suites": {}, "diff": [], "session_id": "$sid_gate3", "toolchain_fp": "$tfp_gate3"}
EOF

FAKEBIN_GATE="$T/fakebin-gate"; mkdir -p "$FAKEBIN_GATE"
EXTEND_GATE_CALLLOG="$T/extend-gate-calls.log"
cat > "$FAKEBIN_GATE/extend-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$EXTEND_GATE_CALLLOG"
mkdir -p target/autobuilder/receipts
echo '{"pass": 24, "block": 1}' > target/autobuilder/last-verdict.json
echo "receipt" > target/autobuilder/receipts/some-producer.json
echo "should-not-sync" > should-not-sync.txt
# "extend-gate.sh remote-aware invocation": the real script writes its one
# outside-the-repo line to \$EXTEND_GATE_JOURNAL when set (cmd_gate arms
# this on the box); this fake stands in for that behavior too.
[ -n "\${EXTEND_GATE_JOURNAL:-}" ] && { mkdir -p "\$(dirname "\$EXTEND_GATE_JOURNAL")"; echo "fake-extend-gate-journal-line-AC3" >> "\$EXTEND_GATE_JOURNAL"; }
exit "\${FAKE_EXTEND_GATE_EXIT:-0}"
EOF
chmod +x "$FAKEBIN_GATE/extend-gate.sh"

gate3_out="$(PATH="$FAKEBIN_GATE:$PATH" FAKE_EXTEND_GATE_EXIT=1 "$BL" gate "$WT_GATE" --head "$head_gate" 2>&1)"; gate3_rc=$?
expect "gatebox AC3: gate propagates the remote extend-gate.sh's own exit code" "[ $gate3_rc -eq 1 ]"
expect "gatebox AC3: fake extend-gate.sh was invoked exactly once" "[ \"\$(wc -l < "$EXTEND_GATE_CALLLOG")\" -eq 1 ]"
expect "gatebox AC3: fake extend-gate.sh was invoked with --head <sha>" "grep -qF -- '--head '\"$head_gate\" \"$EXTEND_GATE_CALLLOG\""
expect "gatebox AC3: target/autobuilder/ was rsynced back (receipts present locally)" \
  "[ -f \"$WT_GATE/target/autobuilder/receipts/some-producer.json\" ]"
expect "gatebox AC3: .gate-burst-host was rsynced back" "[ -s \"$WT_GATE/.gate-burst-host\" ]"
expect "gatebox AC3: only target/autobuilder/ and .gate-burst-host were rsynced back (nothing else)" \
  "[ ! -e \"$WT_GATE/should-not-sync.txt\" ]"
gate3_verdict_rc=0
python3 -c "
import json
d = json.load(open('$WT_GATE/target/autobuilder/last-verdict.json'))
assert d.get('host'), d
assert d.get('pass') == 24 and d.get('block') == 1, d
" || gate3_verdict_rc=1
expect "gatebox AC3: last-verdict.json carries a host field (extend-gate.sh itself never touched)" "[ $gate3_verdict_rc -eq 0 ]"
expect "gatebox AC3: journal gate line names the verdict, host, and wall time" \
  "grep -qE 'burst-lane  gate  block  \(repo=.*host=[0-9.]+ wall=[0-9.]+s head='\"$head_gate\" \"$BURST_LANE_JOURNAL\""
expect "gatebox AC3 (extend-gate.sh remote-aware): the box's redirected journal folded onto RedBaron's tick journal" \
  "grep -qF 'fake-extend-gate-journal-line-AC3' \"$BURST_LANE_TICK_JOURNAL_DIR/$(date -u +%Y-%m-%d).md\""
expect "gatebox AC3 (extend-gate.sh remote-aware): the folded journal was not left behind under target/autobuilder/" \
  "[ ! -e \"$WT_GATE/target/autobuilder/gate-journal.md\" ]"

# ---- gatebox AC4: BURST_GATE_REVIEWER=1 places the reviewer credential at
# `up` (mode 0600) and shreds it at `down`, and the sentinel token never
# lands in the journal (requirement 4).
fresh_env
FAKE_CRED="$T/fake-claude-creds.json"
echo '{"token": "SENTINEL-GATEBOX-TOKEN-XYZ123"}' > "$FAKE_CRED"
export BURST_GATE_REVIEWER=1
export BURST_CLAUDE_CRED_SRC="$FAKE_CRED"
gatebox4_up_out="$("$BL" up)"; gatebox4_up_rc=$?
expect "gatebox AC4: up succeeds with the reviewer credential enabled" "[ $gatebox4_up_rc -eq 0 ]"
expect "gatebox AC4: the credential exists on the fake box after up" "[ -s \"$BURST_LANE_GATE_CRED_REMOTE_PATH\" ]"
cred_mode="$(stat -c '%a' "$BURST_LANE_GATE_CRED_REMOTE_PATH" 2>/dev/null)"
expect "gatebox AC4: the placed credential is mode 0600" "[ \"$cred_mode\" = 600 ]"
expect "gatebox AC4: journal has 'cred  placed'" "grep -q 'burst-lane  up  cred  placed' \"$BURST_LANE_JOURNAL\""

boot_epoch4="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch4 + 3600 - 60))
gatebox4_down_out="$("$BL" down)"; gatebox4_down_rc=$?
unset BURST_LANE_NOW
expect "gatebox AC4: down deletes cleanly with the reviewer credential in play" "[ \"$gatebox4_down_out\" = 'decision=deleted' ]"
expect "gatebox AC4: the credential is gone from the fake box after down" "[ ! -e \"$BURST_LANE_GATE_CRED_REMOTE_PATH\" ]"
expect "gatebox AC4: journal has 'cred  shredded'" "grep -q 'burst-lane  down  cred  shredded' \"$BURST_LANE_JOURNAL\""
expect "gatebox AC4: the sentinel token never appears in the journal" "! grep -q 'SENTINEL-GATEBOX-TOKEN-XYZ123' \"$BURST_LANE_JOURNAL\""

# ---- gatebox AC8: BURST_GATE_REMOTE=0 (the ships-dark default) keeps a
# gate entirely local -- cmd_gate refuses before touching parity, ssh, or
# rsync at all, reusing requirement 5's own fallback contract (print
# "fallback: <cause>", exit 3), and the journal line it writes carries no
# host= field (only the requirement-3 routed-success shape does), so
# nothing here reads as "a gate ran remotely".
fresh_env
"$BL" up >/dev/null
WT_AC8="$T/ac8-repo"; mkdir -p "$WT_AC8/target/autobuilder/receipts"
( cd "$WT_AC8" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_ac8="$(git -C "$WT_AC8" rev-parse HEAD)"
sid_ac8="$(pc_active_session_id)"; tfp_ac8="$(pc_active_toolchain_fp)"
echo "{\"head_sha\": \"$head_ac8\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_ac8\", \"toolchain_fp\": \"$tfp_ac8\"}" > "$WT_AC8/target/autobuilder/receipts/box-parity.json"
FAKEBIN_AC8="$T/fakebin-ac8"; mkdir -p "$FAKEBIN_AC8"
AC8_CALLLOG="$T/ac8-extend-gate-calls.log"
cat > "$FAKEBIN_AC8/extend-gate.sh" <<EOF
#!/usr/bin/env bash
echo called >> "$AC8_CALLLOG"
exit 0
EOF
chmod +x "$FAKEBIN_AC8/extend-gate.sh"

unset BURST_GATE_REMOTE
ac8_out="$(PATH="$FAKEBIN_AC8:$PATH" "$BL" gate "$WT_AC8" --head "$head_ac8" 2>&1)"; ac8_rc=$?
expect "gatebox AC8: gate exits 3 when BURST_GATE_REMOTE is unset (ships dark)" "[ $ac8_rc -eq 3 ]"
expect "gatebox AC8: gate prints fallback: remote-disabled" "grep -q '^fallback: remote-disabled$' <<<\"$ac8_out\""
expect "gatebox AC8: journal has a gate fallback line naming cause=remote-disabled" \
  "grep -q 'burst-lane  gate  fallback  (cause=remote-disabled' \"$BURST_LANE_JOURNAL\""
expect "gatebox AC8: that journal line carries no host= field (it's not a remote line)" \
  "! grep 'cause=remote-disabled' \"$BURST_LANE_JOURNAL\" | grep -q 'host='"
expect "gatebox AC8: the remote extend-gate.sh was never invoked" "[ ! -f \"$AC8_CALLLOG\" ]"

export BURST_GATE_REMOTE=0
ac8b_out="$(PATH="$FAKEBIN_AC8:$PATH" "$BL" gate "$WT_AC8" --head "$head_ac8" 2>&1)"; ac8b_rc=$?
expect "gatebox AC8: BURST_GATE_REMOTE=0 (explicit) behaves the same as unset" \
  "[ $ac8b_rc -eq 3 ] && [ \"\$ac8b_out\" = 'fallback: remote-disabled' ]"
export BURST_GATE_REMOTE=1

# ---- gatebox AC7: teardown waits for (or abandons) a still-in-flight
# remote gate instead of destroying the box out from under it (requirement
# 7). Both scenarios hand-craft a gate-inflight marker (rather than driving
# a real `gate` call) so the wait loop's own two outcomes are exercised
# directly and fast: a background holder of the SAME per-repo worktree
# lock `cmd_gate` itself takes stands in for "the gate is still running".
# started_epoch is pinned to the SAME frozen $BURST_LANE_NOW the `down`
# call below uses (not real wall-clock) so `age` is deterministic even
# though the wait loop's own polling still uses a real `sleep`.
fresh_env
"$BL" up >/dev/null
ip7="$(grep -oE '"ip":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch7 + 3600 - 60))
export BURST_LANE_GATE_WAIT_POLL_S=0.1

# Scenario A: the gate finishes WITHIN budget — down waits (polling the
# real lock release), pulls receipts as a safety net, journals the
# verdict, then still deletes the box.
WT_GATE7A="$T/gate7a-repo"; mkdir -p "$WT_GATE7A"
remote_path_7a="$BURST_LANE_REMOTE_ROOT/$(basename "$WT_GATE7A")-$(printf '%s' "$WT_GATE7A" | sha1sum | cut -c1-8)"
mkdir -p "$remote_path_7a/target/autobuilder/receipts"
echo '{"pass": 25, "block": 0}' > "$remote_path_7a/target/autobuilder/last-verdict.json"
echo "receipt" > "$remote_path_7a/target/autobuilder/receipts/some.json"
echo "$ip7" > "$remote_path_7a/.gate-burst-host"
marker_7a="$BURST_LANE_STATE_DIR/current/gate-inflight/$(printf '%s' "$WT_GATE7A" | sha1sum | cut -c1-8).json"
mkdir -p "$(dirname "$marker_7a")"
python3 -c "import json; json.dump({'repo': '$WT_GATE7A', 'host': '$ip7', 'started_epoch': $BURST_LANE_NOW, 'budget_s': 30}, open('$marker_7a', 'w'))"
lockfile_7a="$BURST_LANE_STATE_DIR/current/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_GATE7A").lock"
mkdir -p "$(dirname "$lockfile_7a")"
( exec 220>"$lockfile_7a"; flock 220; sleep 1 ) &
holder7a_pid=$!
sleep 0.2   # let the holder actually take the lock first

down7a_out="$("$BL" down)"; down7a_rc=$?
wait "$holder7a_pid" 2>/dev/null || true
expect "gatebox AC7 (finishes in time): down still deletes the box" "[ \"$down7a_out\" = 'decision=deleted' ]"
expect "gatebox AC7 (finishes in time): receipts pulled as a safety net" \
  "[ -f \"$WT_GATE7A/target/autobuilder/receipts/some.json\" ]"
expect "gatebox AC7 (finishes in time): journal has 'gate  pass' with waited=true" \
  "grep -qE 'burst-lane  down  gate  pass  \(repo='\"$WT_GATE7A\"' host='\"$ip7\"' waited=true' \"$BURST_LANE_JOURNAL\""
expect "gatebox AC7 (finishes in time): the in-flight marker was cleared" "[ ! -e \"$marker_7a\" ]"

unset BURST_LANE_NOW BURST_LANE_GATE_WAIT_POLL_S

# Scenario B: the gate is still running PAST its budget — down abandons it
# (no wait beyond the budget), invalidates the local verdict cache so the
# next tick re-gates, journals `gate  abandoned`, and still deletes. Fresh
# session — scenario A's `down` already deleted its own box above.
fresh_env
"$BL" up >/dev/null
ip7="$(grep -oE '"ip":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch7 + 3600 - 60))
export BURST_LANE_GATE_WAIT_POLL_S=0.1
WT_GATE7B="$T/gate7b-repo"; mkdir -p "$WT_GATE7B/target/autobuilder"
echo '{"pass": 25, "block": 0, "stale": true}' > "$WT_GATE7B/target/autobuilder/last-verdict.json"
marker_7b="$BURST_LANE_STATE_DIR/current/gate-inflight/$(printf '%s' "$WT_GATE7B" | sha1sum | cut -c1-8).json"
mkdir -p "$(dirname "$marker_7b")"
python3 -c "import json; json.dump({'repo': '$WT_GATE7B', 'host': '$ip7', 'started_epoch': $((BURST_LANE_NOW - 999)), 'budget_s': 30}, open('$marker_7b', 'w'))"
lockfile_7b="$BURST_LANE_STATE_DIR/current/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_GATE7B").lock"
mkdir -p "$(dirname "$lockfile_7b")"
( exec 221>"$lockfile_7b"; flock 221; sleep 2 ) &
holder7b_pid=$!
sleep 0.2

down7b_out="$("$BL" down)"; down7b_rc=$?
expect "gatebox AC7 (past budget): down still deletes the box" "[ \"$down7b_out\" = 'decision=deleted' ]"
expect "gatebox AC7 (past budget): journal has 'gate  abandoned' naming host and age" \
  "grep -qE 'burst-lane  down  gate  abandoned  \(repo='\"$WT_GATE7B\"' host='\"$ip7\"' age=[0-9]+s budget=30s' \"$BURST_LANE_JOURNAL\""
expect "gatebox AC7 (past budget): the stale last-verdict.json was invalidated" "[ ! -e \"$WT_GATE7B/target/autobuilder/last-verdict.json\" ]"
expect "gatebox AC7 (past budget): the in-flight marker was cleared" "[ ! -e \"$marker_7b\" ]"
kill "$holder7b_pid" 2>/dev/null || true
wait "$holder7b_pid" 2>/dev/null || true
unset BURST_LANE_NOW BURST_LANE_GATE_WAIT_POLL_S

# ---- gatebox AC6: gates on different repos proceed concurrently (each
# taking one acquire_run_slot() slot, same semaphore `run` uses) and
# status --json lists them; a third call for one of the SAME repos still
# waits on that repo's own lock (requirement 6). Three REAL `gate`
# invocations run in the background against a fake extend-gate.sh that
# sleeps, so overlap (or its absence) is observable from real start/end
# timestamps rather than asserted from hand-crafted state.
fresh_env
"$BL" up >/dev/null
CONC_CALLLOG="$T/conc-calls.log"; : > "$CONC_CALLLOG"
FAKEBIN_CONC="$T/fakebin-conc"; mkdir -p "$FAKEBIN_CONC"
cat > "$FAKEBIN_CONC/extend-gate.sh" <<EOF
#!/usr/bin/env bash
echo "start \$(date +%s.%N) \$PWD" >> "$CONC_CALLLOG"
mkdir -p target/autobuilder
echo '{"pass": 25, "block": 0}' > target/autobuilder/last-verdict.json
sleep "\${FAKE_EXTEND_GATE_SLEEP:-1.2}"
echo "end \$(date +%s.%N) \$PWD" >> "$CONC_CALLLOG"
exit 0
EOF
chmod +x "$FAKEBIN_CONC/extend-gate.sh"

sid_conc="$(pc_active_session_id)"; tfp_conc="$(pc_active_toolchain_fp)"
WT_C1="$T/conc1-repo"; mkdir -p "$WT_C1/target/autobuilder/receipts"
( cd "$WT_C1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_c1="$(git -C "$WT_C1" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_c1\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_conc\", \"toolchain_fp\": \"$tfp_conc\"}" > "$WT_C1/target/autobuilder/receipts/box-parity.json"

WT_C2="$T/conc2-repo"; mkdir -p "$WT_C2/target/autobuilder/receipts"
( cd "$WT_C2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_c2="$(git -C "$WT_C2" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_c2\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_conc\", \"toolchain_fp\": \"$tfp_conc\"}" > "$WT_C2/target/autobuilder/receipts/box-parity.json"

export BURST_MAX_CONCURRENT_RUNS=7   # AC6's own "sub-cap 7" — comfortably >= 2
PATH="$FAKEBIN_CONC:$PATH" "$BL" gate "$WT_C1" --head "$head_c1" >"$T/gate-c1.out" 2>&1 &
pid_c1=$!
PATH="$FAKEBIN_CONC:$PATH" "$BL" gate "$WT_C2" --head "$head_c2" >"$T/gate-c2.out" 2>&1 &
pid_c2=$!
sleep 0.5   # let both acquire their slot+lock and start the fake remote gate

status_conc="$("$BL" status --json 2>&1)"
gates_count_mid="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('gates', [])))" "$status_conc" 2>/dev/null || echo 0)"
expect "gatebox AC6: status --json lists two gates while both are in flight" "[ \"$gates_count_mid\" -eq 2 ]"

# A third call for the SAME repo as c1 — must wait on c1's own worktree
# lock, launched now so its own start (once unblocked) lands in the log.
PATH="$FAKEBIN_CONC:$PATH" "$BL" gate "$WT_C1" --head "$head_c1" >"$T/gate-c3.out" 2>&1 &
pid_c3=$!

wait "$pid_c1"; rc_c1=$?
wait "$pid_c2"; rc_c2=$?
wait "$pid_c3"; rc_c3=$?
unset BURST_MAX_CONCURRENT_RUNS

expect "gatebox AC6: all three gate calls eventually exit 0" "[ $rc_c1 -eq 0 ] && [ $rc_c2 -eq 0 ] && [ $rc_c3 -eq 0 ]"
expect "gatebox AC6: extend-gate.sh was invoked exactly 3 times (c1, c2, c3)" "[ \"$(grep -c '^start ' "$CONC_CALLLOG")\" -eq 3 ]"

conc_check_rc=0
python3 -c "
import sys
starts = {}
for line in open('$CONC_CALLLOG'):
    parts = line.split()
    if parts[0] != 'start':
        continue
    ts, pwd = float(parts[1]), parts[2]
    if 'conc1-repo' in pwd and 'c1' not in starts:
        starts['c1'] = ts
    elif 'conc2-repo' in pwd and 'c2' not in starts:
        starts['c2'] = ts
if 'c1' not in starts or 'c2' not in starts:
    sys.exit(1)
# concurrency: both different-repo starts land close together — well under
# one gate's own sleep duration — rather than one waiting for the other.
sys.exit(0 if abs(starts['c1'] - starts['c2']) < 1.0 else 1)
" || conc_check_rc=1
expect "gatebox AC6: the two different-repo gates actually overlapped (concurrent, not serialized)" "[ $conc_check_rc -eq 0 ]"

serial_check_rc=0
python3 -c "
import sys
starts_c1, ends_c1 = [], []
for line in open('$CONC_CALLLOG'):
    parts = line.split()
    kind, ts, pwd = parts[0], float(parts[1]), parts[2]
    if 'conc1-repo' in pwd:
        (starts_c1 if kind == 'start' else ends_c1).append(ts)
if len(starts_c1) != 2 or len(ends_c1) != 2:
    sys.exit(1)
starts_c1.sort(); ends_c1.sort()
# no overlap on the SAME repo: the second (c3's) start must be at or after
# the first (c1's) end.
sys.exit(0 if starts_c1[1] >= ends_c1[0] else 1)
" || serial_check_rc=1
expect "gatebox AC6: a third call for the SAME repo waited for the first to finish (no overlap)" "[ $serial_check_rc -eq 0 ]"

# ---- gatebox requirement 6 (sub-cap weighting, unit-level): one active
# in-flight gate marker subtracts 2 from sub-cap's own mem/cpu/disk-derived
# width, floored at 0 — checked directly against a hand-crafted marker
# (fast, no need to drive a real multi-second gate for this part).
fresh_env
"$BL" up >/dev/null
mkdir -p "$BURST_LANE_STATE_DIR/current/gate-inflight"
python3 -c "import json; json.dump({'repo': '/fake/repo', 'host': '127.0.0.1', 'started_epoch': 0, 'budget_s': 1800}, open('$BURST_LANE_STATE_DIR/current/gate-inflight/fakegate.json', 'w'))"
subcap_gates="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
# 120GB/32cores -> floor(120/8)=15, floor(32/4)=8 -> unweighted sub-cap=8
# (AC7's own baseline, default GB-per-run bumped 6->8; cpu term still binds);
# one active gate subtracts 2 -> 6.
expect "gatebox req6: one active gate subtracts 2 from sub-cap (8 -> 6)" "grep -q '^sub-cap=6 local=0' <<<\"$subcap_gates\""
expect "gatebox req6: sub-cap names the gates bound and count" "grep -q 'bound=gates gates_active=1' <<<\"$subcap_gates\""

# ---- gatebox AC9: two remote gates and one local gate the same day ->
# the daily rollup line carries gates_remote=2 gates_local=1 (requirement
# 9), and each remote gate's own attribution row is slug=gate-<repo>,
# remote=true (the PRD-build-gate-cargo-route-attest slug convention).
# Uses real wall-clock time (no BURST_LANE_NOW override) so a hand-appended
# extend-gate.sh-shaped local-gate line's own timestamp genuinely matches
# "today" the same way maybe_daily_rollup computes it.
fresh_env
"$BL" up >/dev/null
FAKEBIN_R9="$T/fakebin-r9"; mkdir -p "$FAKEBIN_R9"
cat > "$FAKEBIN_R9/extend-gate.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p target/autobuilder
echo '{"pass": 25, "block": 0}' > target/autobuilder/last-verdict.json
exit 0
EOF
chmod +x "$FAKEBIN_R9/extend-gate.sh"

sid_r9="$(pc_active_session_id)"; tfp_r9="$(pc_active_toolchain_fp)"
WT_R1="$T/r9-repo-one"; mkdir -p "$WT_R1/target/autobuilder/receipts"
( cd "$WT_R1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_r1="$(git -C "$WT_R1" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_r1\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_r9\", \"toolchain_fp\": \"$tfp_r9\"}" > "$WT_R1/target/autobuilder/receipts/box-parity.json"
PATH="$FAKEBIN_R9:$PATH" "$BL" gate "$WT_R1" --head "$head_r1" >/dev/null 2>&1

WT_R2="$T/r9-repo-two"; mkdir -p "$WT_R2/target/autobuilder/receipts"
( cd "$WT_R2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_r2="$(git -C "$WT_R2" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_r2\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_r9\", \"toolchain_fp\": \"$tfp_r9\"}" > "$WT_R2/target/autobuilder/receipts/box-parity.json"
PATH="$FAKEBIN_R9:$PATH" "$BL" gate "$WT_R2" --head "$head_r2" >/dev/null 2>&1

r9_attr_rc=0
python3 -c "
import json
rows = [json.loads(l) for l in open('$BURST_LANE_ATTR_LEDGER') if l.strip()]
gate_rows = [r for r in rows if r.get('kind') == 'gate']
assert len(gate_rows) == 2, gate_rows
for r in gate_rows:
    assert r.get('remote') is True, r
    assert r.get('slug', '').startswith('gate-r9-repo-'), r
" || r9_attr_rc=1
expect "gatebox AC9: each remote gate attributes slug=gate-<repo> remote=true" "[ $r9_attr_rc -eq 0 ]"

today_r9="$(date -u +%Y-%m-%d)"
mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
printf '%s  gate  somecrate  pass  (head=abc123 base=v1.0.0 gate: head=abc123 pass=25 block=0 verdict=pass blocking=none wall=42s lock_wait=0s cargo=burst:0/local:5)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BURST_LANE_TICK_JOURNAL_DIR/$today_r9.md"

# force a real teardown (hour boundary) so prorate_attribution folds the
# two gate attribution rows into today's cost.jsonl slug rows — same
# two-`down`-calls pattern the existing cost-rollup AC6 test above uses:
# the FIRST down does the actual delete (and writes the slug rows) but
# fires maybe_daily_rollup too early to see them; the SECOND (no-op,
# no-active-session) down sees them and emits the real rollup line.
boot_epoch_r9="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch_r9 + 3600 - 60))
"$BL" down >/dev/null
"$BL" down >/dev/null
unset BURST_LANE_NOW

rollup_line_r9="$(grep '^burst-cost:' "$BURST_LANE_TICK_JOURNAL_DIR/$today_r9.md" | tail -1)"
expect "gatebox AC9: the daily rollup line carries gates_remote=2 gates_local=1" \
  "grep -q 'gates_remote=2 gates_local=1' <<<\"$rollup_line_r9\""

# ---- gatebox requirement 8: `status` (text mode) lists a running remote
# gate with repo, HEAD (shortened), age, and slot; `status --json` carries
# the same fields plus gate_ready. A hand-crafted marker (same shape
# cmd_gate itself now writes, including head_sha/slot since step 6) is
# enough here — the marker's own SHAPE is already exercised end-to-end by
# a real `gate` call in the AC6/AC9 blocks above.
fresh_env
"$BL" up >/dev/null
mkdir -p "$BURST_LANE_STATE_DIR/current/gate-inflight"
python3 -c "import json; json.dump({'repo': '/fake/status-repo', 'host': '127.0.0.1', 'started_epoch': $(date -u +%s) - 90, 'budget_s': 1800, 'head_sha': 'abcdef0123456789', 'slot': '2'}, open('$BURST_LANE_STATE_DIR/current/gate-inflight/statusgate.json', 'w'))"
status_text_r8="$("$BL" status 2>&1)"
expect "gatebox req8: status (text) lists the gate with repo/head/age/slot" \
  "grep -qE 'gate: /fake/status-repo head=abcdef012345 age=[0-9]+s slot=2' <<<\"$status_text_r8\""
status_json_r8="$("$BL" status --json 2>&1)"
r8_json_rc=0
python3 -c "
import json, sys
d = json.loads(sys.argv[1])
gates = d.get('gates', [])
assert len(gates) == 1, gates
g = gates[0]
assert g.get('repo') == '/fake/status-repo', g
assert g.get('head_sha') == 'abcdef0123456789', g
assert g.get('slot') == '2', g
assert g.get('age_seconds', 0) >= 90, g
assert 'gate_ready' in d, d
" "$status_json_r8" || r8_json_rc=1
expect "gatebox req8: status --json carries the gate with repo/head_sha/slot/age_seconds and gate_ready" "[ $r8_json_rc -eq 0 ]"

# ---- gatebox AC5: an ssh/rsync-level failure BEFORE the remote extend-
# gate.sh ever starts refuses cleanly — the PRD's own literal scenario
# ("the fake ssh fails before the remote gate starts"), distinct from the
# parity/head-mismatch fallbacks already covered under the AC2 block above
# (those also print "fallback: <cause>" and exit 3, but this is the one
# that exercises the rsync-up-failed path specifically).
fresh_env
"$BL" up >/dev/null
WT_AC5="$T/ac5-repo"; mkdir -p "$WT_AC5/target/autobuilder/receipts"
( cd "$WT_AC5" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_ac5="$(git -C "$WT_AC5" rev-parse HEAD)"
sid_ac5="$(pc_active_session_id)"; tfp_ac5="$(pc_active_toolchain_fp)"
echo "{\"head_sha\": \"$head_ac5\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_ac5\", \"toolchain_fp\": \"$tfp_ac5\"}" > "$WT_AC5/target/autobuilder/receipts/box-parity.json"

ac5_out="$(FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=11 FAKE_RSYNC_FAIL_MSG='rsync: fake gate rsync failure' "$BL" gate "$WT_AC5" --head "$head_ac5" 2>&1)"; ac5_rc=$?
expect "gatebox AC5: gate exits 3 when the rsync-up itself fails before the remote gate starts" "[ $ac5_rc -eq 3 ]"
expect "gatebox AC5: gate prints fallback: <cause>" "grep -q '^fallback: rsync to .* failed' <<<\"$ac5_out\""
expect "gatebox AC5: exactly one gate fallback journal line naming the cause" \
  "[ \"\$(grep -c 'burst-lane  gate  fallback.*cause=rsync-up-failed' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"

# =============================================================================
# PRD-build-burst-gate-tools-scope: a missing gate tool blocks gates, not
# the lane. (test_prefix: gatetools)
# =============================================================================

# ---- gatetools AC1: given a fake box without autobuilder, `up` copies it
# (fake rsync = real local `cp` onto BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR)
# and session state records its version.
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
gt1_out="$("$BL" up)"; gt1_rc=$?
expect "gatetools AC1: up succeeds with autobuilder initially missing" "[ $gt1_rc -eq 0 ]"
expect "gatetools AC1: the autobuilder binary was copied (rsync) to the remote cargo bin dir" \
  "[ -f \"$BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR/autobuilder\" ]"
expect "gatetools AC1: session state records autobuilder's version once provisioned" \
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/current/gate-tools.json')); sys.exit(0 if d.get('tools',{}).get('autobuilder') not in (None,'','MISSING') else 1)\""
unset FAKE_SSH_GATE_TOOLS_MISSING

# ---- gatetools AC2: given a fake box where the autobuilder copy fails
# (install-fail knob, so the fake never records it as installed even though
# a plain rsync retry underneath it is a no-op either way), `verify` reports
# verified=true gate_ready=false, journals gate-tools-missing, and `run`
# still routes.
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null
gt2_verify_out="$("$BL" verify 2>&1)"; gt2_verify_rc=$?
expect "gatetools AC2: verify exits 0 (lane checks alone decide verified) even though gate-tools failed" "[ $gt2_verify_rc -eq 0 ]"
expect "gatetools AC2: session state is verified:true" "grep -q '\"verified\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "gatetools AC2: session state is gate_ready:false" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "gatetools AC2: verify journals gate-tools-missing naming autobuilder" \
  "grep -q 'burst-lane  verify  gate-tools-missing.*missing=autobuilder' \"$BURST_LANE_JOURNAL\""

WT_GT2="$T/gt2-repo"; mkdir -p "$WT_GT2"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_GT2/build.sh"
gt2_run_out="$("$BL" run "$WT_GT2" -- bash build.sh 2>&1)"; gt2_run_rc=$?
expect "gatetools AC2: run <worktree> -- cargo build still routes despite gate_ready=false" \
  "[ $gt2_run_rc -eq 0 ] && ! grep -q 'lane not verified' <<<\"$gt2_run_out\""
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL

# ---- gatetools AC3: given gate_ready=false, `gate <repo> --head <sha>`
# refuses with `fallback: gate-tools-missing (<list>)`, exit 3, one journal
# line.
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null
WT_GT3="$T/gt3-repo"; mkdir -p "$WT_GT3/target/autobuilder/receipts"
( cd "$WT_GT3" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_gt3="$(git -C "$WT_GT3" rev-parse HEAD)"
sid_gt3="$(pc_active_session_id)"; tfp_gt3="$(pc_active_toolchain_fp)"
echo "{\"head_sha\": \"$head_gt3\", \"box_host\": \"x\", \"suites\": {}, \"diff\": [], \"session_id\": \"$sid_gt3\", \"toolchain_fp\": \"$tfp_gt3\"}" > "$WT_GT3/target/autobuilder/receipts/box-parity.json"
gt3_out="$("$BL" gate "$WT_GT3" --head "$head_gt3" 2>&1)"; gt3_rc=$?
expect "gatetools AC3: gate exits 3 when gate_ready=false" "[ $gt3_rc -eq 3 ]"
expect "gatetools AC3: gate prints fallback: gate-tools-missing naming the tool" \
  "grep -q '^fallback: gate-tools-missing (autobuilder)$' <<<\"$gt3_out\""
expect "gatetools AC3: exactly one gate fallback journal line naming the cause" \
  "[ \"\$(grep -c 'burst-lane  gate  fallback.*cause=gate-tools-missing' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL

# ---- gatetools AC4: `burst-lane.sh provision` retries the missing install
# on the LIVE box and re-runs the gate-tools check without a reboot (no new
# hcloud server create call).
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null
gt4_creates_before="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "gatetools AC4 setup: gate_ready:false after up (copy failed)" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/current/session.json\""

unset FAKE_SSH_GATE_TOOLS_INSTALL_FAIL
gt4_out="$("$BL" provision 2>&1)"; gt4_rc=$?
expect "gatetools AC4: provision exits 0 once the retried install succeeds" "[ $gt4_rc -eq 0 ]"
expect "gatetools AC4: gate_ready becomes true without a reboot" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
gt4_creates_after="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "gatetools AC4: no additional hcloud server create call happened" "[ \"$gt4_creates_after\" -eq \"$gt4_creates_before\" ]"
gt4_status_out="$("$BL" status)"
expect "gatetools AC4: status shows missing= empty" "grep -q 'missing=$' <<<\"$gt4_status_out\""
unset FAKE_SSH_GATE_TOOLS_MISSING

# ---- gatetools AC5: a box whose autobuilder version differs from this
# host's own `autobuilder --version` sets gate_ready=false and journals
# `gate-tools  version-drift`, even though the tool is found (not MISSING).
fresh_env
export FAKE_SSH_AUTOBUILDER_VERSION="autobuilder 1.0.0"
gt5_out="$("$BL" up)"; gt5_rc=$?
expect "gatetools AC5: up succeeds even though autobuilder's version drifted" "[ $gt5_rc -eq 0 ]"
expect "gatetools AC5: gate_ready is false due to version drift" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "gatetools AC5: journal names gate-tools version-drift" \
  "grep -q 'burst-lane  gate-tools  version-drift' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_AUTOBUILDER_VERSION

# =============================================================================
# PRD-build-burst-gate-tools-toolchain: cargo-based gate-tool installs run
# under the newest toolchain the box has (not the too-old default), and
# every install attempt — success or failure — leaves per-tool journal
# evidence instead of only a single missing-tools summary line.
# (test_prefix: gatetc)
# =============================================================================

# ---- gatetc AC1: given a fake box listing toolchains 1.85.0 and 1.88.0
# whose fake cargo fails unless invoked with +1.88.0, `up` still installs
# cargo-deny and cargo-nextest and reaches gate_ready=true — proves
# gate_tools_install_cmd() really emits `cargo +<newest> install`, not a
# bare `cargo install` that would fail under the box's default 1.85 (the
# exact box-165449166 refusal: "cargo-deny 0.18.3 supports rustc 1.85.0").
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="cargo-deny cargo-nextest"
export FAKE_SSH_GATE_TOOLS_TOOLCHAIN_SIM=1
export FAKE_GATE_TOOLS_TOOLCHAIN_BIN="$FAKE/toolchain-bin"
export FAKE_RUSTUP_TOOLCHAINS="1.85.0 1.88.0"
export FAKE_CARGO_REQUIRE_TOOLCHAIN="1.88.0"
gtc1_out="$("$BL" up)"; gtc1_rc=$?
expect "gatetc AC1: up succeeds (exit 0)" "[ $gtc1_rc -eq 0 ]"
expect "gatetc AC1: gate_ready is true once cargo-deny/cargo-nextest install under +1.88.0" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "gatetc AC1: journal records cargo-deny install rc=0" \
  "grep -q 'gate-tools  install  (tool=cargo-deny rc=0' \"$BURST_LANE_JOURNAL\""
expect "gatetc AC1: journal records cargo-nextest install rc=0" \
  "grep -q 'gate-tools  install  (tool=cargo-nextest rc=0' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_TOOLCHAIN_SIM FAKE_GATE_TOOLS_TOOLCHAIN_BIN FAKE_RUSTUP_TOOLCHAINS FAKE_CARGO_REQUIRE_TOOLCHAIN

# ---- gatetc AC2: given a fake box where the mold install exits 100 with
# stderr "E: Unable to locate package mold", the journal has the exact
# install-failed line and the provision summary line still lists mold.
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="mold"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL="mold"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC=100
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR='E: Unable to locate package mold'
"$BL" up >/dev/null
gtc2_out="$("$BL" provision 2>&1)"; gtc2_rc=$?
expect "gatetc AC2: provision exits 1 (mold still missing)" "[ $gtc2_rc -eq 1 ]"
# PRD-build-burst-provision-forensics requirement 1: the terminal line now
# carries secs=S too (install-start/install-failed grammar) — match on the
# rc/err substring only, not the whole line, so this assertion doesn't pin
# down the exact duration.
expect "gatetc AC2: journal has the exact install-failed line for mold" \
  "grep -q 'gate-tools  install-failed  (tool=mold rc=100 secs=[0-9]* err=\"E: Unable to locate package mold\")' \"$BURST_LANE_JOURNAL\""
expect "gatetc AC2: provision summary line lists mold in gate_tools_missing" \
  "grep -q 'burst-lane  provision  done.*gate_tools_missing=mold' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR

# ---- gatetc AC3: any provision run journals exactly one gate-tools
# install line per attempted tool, plus one apt-update record.
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="jq mold gh"
"$BL" up >/dev/null
expect "gatetc AC3: exactly one apt-update record for this provision" \
  "[ \"\$(grep -c 'burst-lane  gate-tools  apt-update' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"
expect "gatetc AC3: apt-update record says ran=true (an apt tool was missing)" \
  "grep -q 'gate-tools  apt-update  (ran=true' \"$BURST_LANE_JOURNAL\""
for gtc3_t in jq mold gh; do
  expect "gatetc AC3: exactly one install line for $gtc3_t" \
    "[ \"\$(grep -c 'gate-tools  install  (tool='$gtc3_t' rc=' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"
done
unset FAKE_SSH_GATE_TOOLS_MISSING

# ---- gatetc AC3b: a provision run where no apt tool was missing still
# gets exactly one apt-update record, marked ran=false (never silently
# skipped — see gatetc AC3's ran=true counterpart above for the apt case).
# No FAKE_SSH_GATE_TOOLS_MISSING set at all — the fake probe's default
# reports every one of the 8 tools already present.
fresh_env
"$BL" up >/dev/null
expect "gatetc AC3b: exactly one apt-update record when no apt tool is missing" \
  "[ \"\$(grep -c 'burst-lane  gate-tools  apt-update' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"
expect "gatetc AC3b: apt-update record says ran=false" \
  "grep -q 'gate-tools  apt-update  (ran=false)' \"$BURST_LANE_JOURNAL\""

# ---- gatetc AC4: a suite the box ran but the cached local baseline never
# had (stale test-output.txt) is "baseline-incomplete", not a diff — parity
# refreshes the local baseline once, journals baseline-refreshed, and the
# refreshed comparison reports the suite as compared (ok), never a diff
# against a null local value. Same fake-cargo-tells-box-from-local-by-$PWD
# trick as gatebox AC2 above; the only difference here is the PRE-SEEDED
# stale $WT_AC4/target/autobuilder/test-output.txt this local baseline
# starts from, which lacks the "extra" suite the box (and the refresh) has.
fresh_env
"$BL" up >/dev/null
WT_AC4="$T/gatetc-ac4-repo"; mkdir -p "$WT_AC4"
( cd "$WT_AC4" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_AC4="$T/fakebin-gatetc-ac4"; mkdir -p "$FAKEBIN_AC4"
cat > "$FAKEBIN_AC4/cargo" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "test" ]; then
  case "\$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*)
      # box run: parity=ok, extra=ok — "extra" is a suite the stale local
      # baseline below was seeded WITHOUT.
      cat <<'LOG'
     Running unittests src/lib.rs (target/debug/deps/parity-1111111111111111)

running 1 test
test a ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/extra.rs (target/debug/deps/extra-7777777777777777)

running 1 test
test d ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
LOG
      ;;
    *)
      # refreshed local run: now also reports "extra", matching the box's
      # ok — this is what parity's own refresh call to cargo produces.
      cat <<'LOG'
     Running unittests src/lib.rs (target/debug/deps/parity-4444444444444444)

running 1 test
test a ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/extra.rs (target/debug/deps/extra-8888888888888888)

running 1 test
test d ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
LOG
      ;;
  esac
  exit 0
fi
echo "fake-cargo(gatetc-ac4): unhandled args: \$*" >&2
exit 1
EOF
chmod +x "$FAKEBIN_AC4/cargo"
mkdir -p "$WT_AC4/target/autobuilder"
cat > "$WT_AC4/target/autobuilder/test-output.txt" <<'LOG'
     Running unittests src/lib.rs (target/debug/deps/parity-4444444444444444)

running 1 test
test a ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
LOG

gtc4_out="$(PATH="$FAKEBIN_AC4:$PATH" "$BL" parity "$WT_AC4" 2>&1)"; gtc4_rc=$?
expect "gatetc AC4: parity exits 0" "[ $gtc4_rc -eq 0 ]"
expect "gatetc AC4: journal has 'parity  baseline-refreshed' naming the extra suite" \
  "grep -q 'burst-lane  parity  baseline-refreshed.*names=extra::' \"$BURST_LANE_JOURNAL\""
expect "gatetc AC4: the refreshed local baseline file now has the extra suite" \
  "grep -q 'extra.rs' \"$WT_AC4/target/autobuilder/test-output.txt\""
expect "gatetc AC4: parity reports diff=0 (the suite compared ok, not as a diff on a null)" \
  "grep -q 'diff=0' <<<\"$gtc4_out\""
gtc4_json_rc=0
python3 -c "
import json
d = json.load(open('$WT_AC4/target/autobuilder/receipts/box-parity.json'))
assert 'extra::src/extra.rs' not in d['diff'], d['diff']
assert d['suites']['extra::src/extra.rs'] == {'box': 'ok', 'local': 'ok'}, d['suites']['extra::src/extra.rs']
" || gtc4_json_rc=1
expect "gatetc AC4: box-parity.json compares the extra suite ok/ok, not baseline-incomplete" "[ $gtc4_json_rc -eq 0 ]"

# =============================================================================
# PRD-build-burst-unprivileged-user: every remote step of the lane (up
# provisioning, rsync, cargo, gate-tools install, credential placement/
# shred, verify) runs as an unprivileged `build` user, never root — mcphost
# refuses to run its own integration suite as real uid 0 (its
# `refuse_to_serve_as_root` guard), which makes root an invalid identity for
# a remote gate. FAKE_SSH_CALL_LOG/FAKE_RSYNC_CALL_LOG (both
# "<user@host>\t<cmd>" lines, one per invocation — see the fixtures' own
# headers) let these cases prove ROUTING directly, rather than trusting
# burst-lane.sh's own claims about who it called.
# (test_prefix: burstuser)
# =============================================================================

# ---- burstuser AC1: `up` creates the user + key, session state records
# remote_user=build, every later call targets build@.
fresh_env
export FAKE_SSH_CALL_LOG="$T/ssh.calls"; : > "$FAKE_SSH_CALL_LOG"
bu1_out="$("$BL" up 2>&1)"; bu1_rc=$?
block_start "burstuser"
expect "burstuser AC1: up exits 0" "[ $bu1_rc -eq 0 ]"
expect "burstuser AC1: root ssh received the user-creation call" \
  "grep -P '^root@\\S+\\t.*# user-create' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC1: the same root call installs the ssh key (authorized_keys)" \
  "grep -P '^root@\\S+\\t.*authorized_keys' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC1: session.json records remote_user=build" \
  "grep -q '\"remote_user\":\"build\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "burstuser AC1: booted journal line names remote_user=build" \
  "grep -q 'burst-lane  up  booted.*remote_user=build' \"$BURST_LANE_JOURNAL\""
# Every OTHER call this `up` made — sandbox probe, gate-tools probe, the
# uv-install/mkdir step — targeted build@, not root@ (the sysctl/apt/
# user-create root calls are the only allow-listed exceptions, asserted
# above by name rather than by absence here).
expect "burstuser AC1: at least one later call targeted build@ (sandbox/gate-tools probes)" \
  "grep -qP '^build@' \"$FAKE_SSH_CALL_LOG\""

# ---- burstuser AC1 (default literal check): every OTHER case in this
# block deliberately overrides REMOTE_ROOT/GATE_TOOLS_REMOTE_BIN_DIR/
# GATE_CRED_REMOTE_PATH to a tmpdir for safety (same reason fresh_env
# always has) — which masks requirement 1/5's own literal default values.
# `_debug-remote-config` does no ssh/rsync/filesystem work beyond $STATE_DIR
# (already tmpdir-scoped), so it is safe to call with those three specific
# overrides unset, proving the literal defaults for real instead of by
# code inspection alone.
bu1b_state="$T/debug-config-state"; mkdir -p "$bu1b_state"
bu1b_out="$(BURST_LANE_STATE_DIR="$bu1b_state" \
            BURST_LANE_REMOTE_ROOT= BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR= BURST_LANE_GATE_CRED_REMOTE_PATH= BURST_LANE_REMOTE_HOME= \
            "$BL" _debug-remote-config 2>&1)"
expect "burstuser AC1: the literal default remote_root is /home/build/build" \
  "grep -qx 'remote_root=/home/build/build' <<<\"\$bu1b_out\""
expect "burstuser AC1: the literal default gate_tools_bin is /home/build/.local/bin" \
  "grep -qx 'gate_tools_bin=/home/build/.local/bin' <<<\"\$bu1b_out\""
expect "burstuser AC1: the literal default gate_cred_path is /home/build/.claude/.credentials.json" \
  "grep -qx 'gate_cred_path=/home/build/.claude/.credentials.json' <<<\"\$bu1b_out\""

# ---- burstuser AC2: `verify`'s cargo/uv/python3/sandbox/gate-tools probes
# all execute as build.
: > "$FAKE_SSH_CALL_LOG"
bu2_out="$("$BL" verify 2>&1)"; bu2_rc=$?
expect "burstuser AC2: verify exits 0 (gate-tools-missing is informational only)" "[ $bu2_rc -eq 0 ]"
expect "burstuser AC2: the cargo/uv/python3 probe ran as build@" \
  "grep -P '^build@\\S+\\t.*cargo --version' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC2: the bwrap sandbox probe ran as build@" \
  "grep -P '^build@\\S+\\t.*bwrap' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC2: no verify probe call targeted root@" \
  "! grep -qP '^root@' \"$FAKE_SSH_CALL_LOG\""

# ---- burstuser AC3: `run <worktree> -- cargo test` routes as build under
# $REMOTE_HOME/build/<key>, and no fake root call ever carries cargo.
WT_BU="$T/wt-burstuser"; mkdir -p "$WT_BU"
export FAKE_RSYNC_CALL_LOG="$T/rsync.calls"; : > "$FAKE_RSYNC_CALL_LOG"
: > "$FAKE_SSH_CALL_LOG"
bu3_out="$("$BL" run "$WT_BU" -- cargo test 2>&1)"
expect "burstuser AC3: the remote cargo call targeted build@" \
  "grep -P '^build@\\S+\\t.*cargo test' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC3: the remote path is under \$REMOTE_ROOT (which itself defaults to \$REMOTE_HOME/build — see the _debug-remote-config check below)" \
  "grep -P '^build@\\S+\\t.*cd '\"\$BURST_LANE_REMOTE_ROOT\"'/' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC3: no fake root ssh call carries cargo" \
  "! grep -P '^root@[^\\t]*\\t' \"$FAKE_SSH_CALL_LOG\" | grep -q cargo"
expect "burstuser AC3: no fake root ssh call happened at all during run" \
  "! grep -qP '^root@' \"$FAKE_SSH_CALL_LOG\""
expect "burstuser AC3: the worktree rsync-up targeted build@" \
  "grep -q 'build@' \"$FAKE_RSYNC_CALL_LOG\""
expect "burstuser AC3: no rsync call targeted root@" \
  "! grep -q 'root@' \"$FAKE_RSYNC_CALL_LOG\""

# ---- burstuser AC4 (light — full suite-diff correctness is gatebox AC2's
# job): parity's remote `cargo test --workspace` call routes as build.
WT_BU_PAR="$T/wt-burstuser-parity"; mkdir -p "$WT_BU_PAR"
( cd "$WT_BU_PAR" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
: > "$FAKE_SSH_CALL_LOG"
"$BL" parity "$WT_BU_PAR" >/dev/null 2>&1
expect "burstuser AC4: parity's remote cargo test call routed as build@" \
  "grep -P '^build@\\S+\\t.*cargo test --workspace' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC4: no fake root ssh call happened during parity" \
  "! grep -qP '^root@' \"$FAKE_SSH_CALL_LOG\""

# ---- burstuser AC5: BURST_GATE_REVIEWER=1 places the credential under
# $REMOTE_HOME/.claude/.credentials.json (build's own home, not root's) and
# shreds it on down.
fresh_env
export FAKE_SSH_CALL_LOG="$T/ssh.calls"; : > "$FAKE_SSH_CALL_LOG"
export FAKE_RSYNC_CALL_LOG="$T/rsync.calls"; : > "$FAKE_RSYNC_CALL_LOG"
export BURST_GATE_REVIEWER=1
export BURST_CLAUDE_CRED_SRC="$T/fake-credentials.json"
echo '{"token":"fake-token-not-real"}' > "$BURST_CLAUDE_CRED_SRC"
bu5_up_out="$("$BL" up 2>&1)"
# fresh_env pins BURST_LANE_GATE_CRED_REMOTE_PATH to its own tmpdir (same
# isolation reason as REMOTE_ROOT/GATE_TOOLS_REMOTE_BIN_DIR) — this IS the
# resolved $REMOTE_HOME/.claude/.credentials.json path when unoverridden
# (proven separately by the _debug-remote-config check below); what this
# case actually proves is that the push landed there AND ran as build@.
cred_path_default="$BURST_LANE_GATE_CRED_REMOTE_PATH"
expect "burstuser AC5: the credential landed at the resolved cred path" \
  "[ -f \"$cred_path_default\" ]"
cred_dirname="$(dirname "$BURST_LANE_GATE_CRED_REMOTE_PATH")"
expect "burstuser AC5: the credential mkdir+chmod over ssh targeted build@" \
  "grep -F \"build@\" \"$FAKE_SSH_CALL_LOG\" | grep -qF \"$cred_dirname\""
expect "burstuser AC5: the credential rsync push targeted build@" \
  "grep -qF \"build@\" \"$FAKE_RSYNC_CALL_LOG\""
expect "burstuser AC5: journal names the placement (no token bytes)" \
  "grep -q 'burst-lane  up  cred  placed' \"$BURST_LANE_JOURNAL\" && ! grep -q 'fake-token-not-real' \"$BURST_LANE_JOURNAL\""
# Force an immediate teardown (1 minute before the hour boundary, same
# convention every other down/watchdog case in this file uses) so
# shred_gate_credential actually runs instead of merely scheduling.
bu5_boot_epoch="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/current/session.json'))['boot_epoch'])")"
export BURST_LANE_NOW=$((bu5_boot_epoch + 3600 - 60))
"$BL" down >/dev/null 2>&1 || true
unset BURST_LANE_NOW
expect "burstuser AC5: the credential file is gone after down" "[ ! -f \"$cred_path_default\" ]"
expect "burstuser AC5: journal records the shred, still no token bytes" \
  "grep -q 'cred  shredded' \"$BURST_LANE_JOURNAL\" && ! grep -q 'fake-token-not-real' \"$BURST_LANE_JOURNAL\""
unset BURST_GATE_REVIEWER BURST_CLAUDE_CRED_SRC

# ---- burstuser AC6: `provision` migrates a live ROOT-ONLY session (one
# that booted before this PRD shipped, or is running the documented
# BURST_LANE_REMOTE_USER=root rollback) onto build without a reboot: the
# user gets created, a still-dirty worktree's remote tree is copied from
# the old root-owned path into the new one, and a following `run` routes as
# build with no second `up`.
fresh_env
export FAKE_SSH_CALL_LOG="$T/ssh.calls"; : > "$FAKE_SSH_CALL_LOG"
"$BL" up >/dev/null 2>&1
bu6_sid="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/current/session.json'))['server_id'])")"
# Simulate a pre-ship (or rolled-back) root-only session: hand-edit
# remote_user back to root, and fabricate a dirty marker + remote artifact
# shaped like one a root-routed `run` would have left behind.
sed -i 's/"remote_user":"build"/"remote_user":"root"/' "$BURST_LANE_STATE_DIR/current/session.json"
WT_MIG="$T/wt-migrate"; mkdir -p "$WT_MIG"
OLD_REMOTE_MIG="$T/old-root-remote-tree"; mkdir -p "$OLD_REMOTE_MIG"
echo "pre-existing build artifact" > "$OLD_REMOTE_MIG/artifact.txt"
mkdir -p "$BURST_LANE_STATE_DIR/current/dirty"
bu6_wkey="$(printf '%s' "$WT_MIG" | sha1sum | cut -c1-8)"
python3 -c "
import json
json.dump({'worktree': '$WT_MIG', 'session_id': '$bu6_sid', 'remote_path': '$OLD_REMOTE_MIG', 'kind': 'target', 'marked_ts': '2026-01-01T00:00:00Z'},
           open('$BURST_LANE_STATE_DIR/current/dirty/$bu6_wkey.json', 'w'))
"
: > "$FAKE_SSH_CALL_LOG"
bu6_prov_out="$("$BL" provision 2>&1)"
expect "burstuser AC6: session.json now records remote_user=build" \
  "grep -q '\"remote_user\":\"build\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "burstuser AC6: journal records the user migration (root -> build)" \
  "grep -q 'burst-lane  provision  user-migrated.*from=root to=build' \"$BURST_LANE_JOURNAL\""
expect "burstuser AC6: journal records the worktree's tree migrated, not gone cold" \
  "grep -qF \"provision  migrated  (worktree=$WT_MIG\" \"$BURST_LANE_JOURNAL\""
bu6_new_remote="$BURST_LANE_REMOTE_ROOT/$(basename "$WT_MIG")-$bu6_wkey"
expect "burstuser AC6: the worktree's remote artifact landed in the NEW (build) tree" \
  "[ -f \"$bu6_new_remote/artifact.txt\" ]"
expect "burstuser AC6: the migration copy ran over root ssh (only user who can read the old tree)" \
  "grep -P '^root@\\S+\\t.*cp -a' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
# PRD-build-burst-parity-robust requirement 4 / parityr AC4: the old-root
# copy is a single small file, so its verified-copy check (size+count) must
# match and the source directory must be gone afterward — no residue left
# from a migration whose copy genuinely succeeded.
block_start "parityr"
expect "parityr AC4: old-root copy verified (bytes+count match) and removed after migration" \
  "[ ! -d \"$OLD_REMOTE_MIG\" ]"
expect "parityr AC4: journal records migrated-removed naming the old path" \
  "grep -qF \"provision  migrated-removed  (from=$OLD_REMOTE_MIG)\" \"$BURST_LANE_JOURNAL\""
: > "$FAKE_SSH_CALL_LOG"
bu6_run_out="$("$BL" run "$WT_MIG" -- bash -c 'exit 0' 2>&1)"; bu6_run_rc=$?
expect "burstuser AC6: a following run exits cleanly without a second up" "[ $bu6_run_rc -eq 0 ]"
expect "burstuser AC6: that run routed as build@, no reboot needed" \
  "grep -qP '^build@' \"$FAKE_SSH_CALL_LOG\""
expect "burstuser AC6: that run made no root@ call" \
  "! grep -qP '^root@' \"$FAKE_SSH_CALL_LOG\""

# ---- parityr AC4 (continued): a copy MISMATCH keeps the old directory and
# journals migrate-keep(cause=copy-mismatch) rather than losing data. Same
# root-only-session setup as burstuser AC6 above, but the NEW remote path is
# pre-seeded with an extra file `cp -a`'s merge semantics won't remove, so
# the post-copy size/count can never match the old tree's.
fresh_env
export FAKE_SSH_CALL_LOG="$T/ssh.calls"; : > "$FAKE_SSH_CALL_LOG"
"$BL" up >/dev/null 2>&1
pr4_sid="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/current/session.json'))['server_id'])")"
sed -i 's/"remote_user":"build"/"remote_user":"root"/' "$BURST_LANE_STATE_DIR/current/session.json"
WT_PR4="$T/wt-migrate-mismatch"; mkdir -p "$WT_PR4"
OLD_REMOTE_PR4="$T/old-root-remote-tree-mismatch"; mkdir -p "$OLD_REMOTE_PR4"
echo "pre-existing build artifact" > "$OLD_REMOTE_PR4/artifact.txt"
mkdir -p "$BURST_LANE_STATE_DIR/current/dirty"
pr4_wkey="$(printf '%s' "$WT_PR4" | sha1sum | cut -c1-8)"
python3 -c "
import json
json.dump({'worktree': '$WT_PR4', 'session_id': '$pr4_sid', 'remote_path': '$OLD_REMOTE_PR4', 'kind': 'target', 'marked_ts': '2026-01-01T00:00:00Z'},
           open('$BURST_LANE_STATE_DIR/current/dirty/$pr4_wkey.json', 'w'))
"
pr4_new_remote="$BURST_LANE_REMOTE_ROOT/$(basename "$WT_PR4")-$pr4_wkey"
mkdir -p "$pr4_new_remote"
echo "pre-existing extra file the copy will not clear" > "$pr4_new_remote/extra.txt"
pr4_prov_out="$("$BL" provision 2>&1)"
expect "parityr AC4: a copy mismatch keeps the old directory" "[ -d \"$OLD_REMOTE_PR4\" ]"
expect "parityr AC4: journal records migrate-keep(cause=copy-mismatch) naming the old path" \
  "grep -qF \"provision  migrate-keep  (cause=copy-mismatch from=$OLD_REMOTE_PR4\" \"$BURST_LANE_JOURNAL\""

# ---- parityr (requirement 4, second half): `reap` sweeps
# $OLD_ROOT_REMOTE_ROOT too, removing residue left behind (a copy-mismatch
# keep, or a leftover from before this fix ever shipped) even though nothing
# new ever lands there again once the session has migrated off root.
fresh_env
export BURST_LANE_OLD_ROOT_REMOTE_ROOT="$T/old-root-scan"
mkdir -p "$BURST_LANE_OLD_ROOT_REMOTE_ROOT/leftover-abc12345"
echo "stale residue" > "$BURST_LANE_OLD_ROOT_REMOTE_ROOT/leftover-abc12345/f.txt"
"$BL" up >/dev/null 2>&1
mkdir -p "$BURST_LANE_REMOTE_ROOT"
reap_old_out="$("$BL" reap 2>&1)"
expect "parityr: reap removes the old-root leftover" "[ ! -d \"$BURST_LANE_OLD_ROOT_REMOTE_ROOT/leftover-abc12345\" ]"
expect "parityr: reap journals the old-root removal tagged with its root" \
  "grep -qF \"reap  ok  (dir=leftover-abc12345 root=$BURST_LANE_OLD_ROOT_REMOTE_ROOT\" \"$BURST_LANE_JOURNAL\""
expect "parityr: reap's own summary counts the old-root dir too" "grep -qE '^reaped_dirs=[1-9]' <<<\"$reap_old_out\""

# ---- parityr AC1/AC2: nextest is the primary capture path on both sides;
# every result line is attributed by the binary name IT carries (never by
# position), so a comparison stays correct even when box and local list
# their suites in completely different orders — the exact misattribution
# class this PRD closes (see problem statement: a 0.01s suite's line landing
# out of order got attributed to the wrong neighbor, or dropped). Also
# covers requirement 2's raw-log receipts.
fresh_env
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
WT_PR1="$T/parityr-repo"; mkdir -p "$WT_PR1"
( cd "$WT_PR1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PR1="$T/fakebin-parityr"; mkdir -p "$FAKEBIN_PR1"
cat > "$FAKEBIN_PR1/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local ;;
  esac
  filt=""
  for a in "$@"; do
    case "$a" in
      binary_id\(*\)) filt="${a#binary_id(}"; filt="${filt%)}" ;;
    esac
  done
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity::other": {}, "parity::fast": {}, "parity::slow": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    if [ -n "$filt" ]; then
      echo "fake-cargo(parityr): unexpected single-suite rerun for $filt" >&2
      exit 1
    fi
    if [ "$side" = "box" ]; then
      # box order: other(FAIL), fast(PASS), slow(PASS) — deliberately NOT
      # the same order local emits below.
      cat <<'LOG'
        FAIL [   0.050s] (1/3) parity::other test_o
        PASS [   0.001s] (2/3) parity::fast test_f
        PASS [   0.030s] (3/3) parity::slow test_s
LOG
    else
      # local order: slow, fast, other — other now PASSES (the one real
      # diff); fast/slow match the box despite the reordering.
      cat <<'LOG'
        PASS [   0.030s] (1/3) parity::slow test_s
        PASS [   0.001s] (2/3) parity::fast test_f
        PASS [   0.049s] (3/3) parity::other test_o
LOG
    fi
    exit 0
  fi
fi
echo "fake-cargo(parityr): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PR1/cargo"
pr1_out="$(PATH="$FAKEBIN_PR1:$PATH" "$BL" parity "$WT_PR1" 2>&1)"; pr1_rc=$?
pr1_parity_file="$WT_PR1/target/autobuilder/receipts/box-parity.json"
expect "parityr AC1: parity exits 0" "[ $pr1_rc -eq 0 ]"
expect "parityr AC1: both sides captured via nextest" \
  "grep -q '\"box_capture\": \"nextest\"' \"$pr1_parity_file\" && grep -q '\"local_capture\": \"nextest\"' \"$pr1_parity_file\""
expect "parityr AC1: exactly one true diff (parity::other), despite box/local listing suites in different order" \
  "grep -q 'diff=1' <<<\"$pr1_out\""
pr1_json_rc=0
python3 -c "
import json
d = json.load(open('$pr1_parity_file'))
assert d['diff'] == ['parity::other'], d['diff']
assert d['suites']['parity::fast'] == {'box': 'ok', 'local': 'ok'}, d['suites']['parity::fast']
assert d['suites']['parity::slow'] == {'box': 'ok', 'local': 'ok'}, d['suites']['parity::slow']
assert d['suites']['parity::other'] == {'box': 'FAILED', 'local': 'ok'}, d['suites']['parity::other']
" || pr1_json_rc=1
expect "parityr AC1: fast/slow attributed ok/ok, other attributed FAILED/ok — never misattributed by line order" \
  "[ $pr1_json_rc -eq 0 ]"
expect "parityr AC2: receipts/parity-box.log exists and is non-empty" "[ -s \"$WT_PR1/target/autobuilder/receipts/parity-box.log\" ]"
expect "parityr AC2: receipts/parity-local.log exists and is non-empty" "[ -s \"$WT_PR1/target/autobuilder/receipts/parity-local.log\" ]"
expect "parityr AC2: box-parity.json names both raw-log receipt paths" \
  "grep -q 'parity-box.log' \"$pr1_parity_file\" && grep -q 'parity-local.log' \"$pr1_parity_file\""

# ---- parityr AC3: a "no-output" suite (nextest's list enumerated it, but
# zero PASS/FAIL lines for it showed up in the run log — e.g. a silent
# crash) is re-run ALONE on that side exactly once; if the rerun reports,
# that result is used instead of a permanent false diff.
fresh_env
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
WT_PR3="$T/parityr-rerun-repo"; mkdir -p "$WT_PR3"
( cd "$WT_PR3" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PR3="$T/fakebin-parityr-rerun"; mkdir -p "$FAKEBIN_PR3"
export PARITYR_RERUN_MARK="$T/pr3-box-rerun-count"
cat > "$FAKEBIN_PR3/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local ;;
  esac
  filt=""
  for a in "$@"; do
    case "$a" in
      binary_id\(*\)) filt="${a#binary_id(}"; filt="${filt%)}" ;;
    esac
  done
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity": {}, "parity::flaky": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    if [ -n "$filt" ]; then
      if [ "$side" = "box" ] && [ "$filt" = "parity::flaky" ]; then
        echo "1" >> "$PARITYR_RERUN_MARK"
        echo "        PASS [   0.002s] (1/1) parity::flaky test_flaky"
        exit 0
      fi
      echo "        PASS [   0.002s] (1/1) $filt test_x"
      exit 0
    fi
    if [ "$side" = "box" ]; then
      # parity::flaky prints NOTHING here — simulated silent crash, zero
      # output lines for a suite nextest's own list still enumerated.
      echo "        PASS [   0.001s] (1/2) parity tests::test_a"
    else
      echo "        PASS [   0.001s] (1/2) parity tests::test_a"
      echo "        PASS [   0.002s] (2/2) parity::flaky test_flaky"
    fi
    exit 0
  fi
fi
echo "fake-cargo(parityr-rerun): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PR3/cargo"
pr3_out="$(PATH="$FAKEBIN_PR3:$PATH" "$BL" parity "$WT_PR3" 2>&1)"; pr3_rc=$?
pr3_parity_file="$WT_PR3/target/autobuilder/receipts/box-parity.json"
expect "parityr AC3: parity exits 0" "[ $pr3_rc -eq 0 ]"
expect "parityr AC3: exactly one rerun journaled for the no-output suite (box side)" \
  "[ \"\$(grep -c 'burst-lane  parity  rerun  (suite=parity::flaky side=box)' \"$BURST_LANE_JOURNAL\")\" = 1 ]"
expect "parityr AC3: the rerun actually executed exactly once" \
  "[ \"\$(wc -l < \"$PARITYR_RERUN_MARK\" 2>/dev/null || echo 0)\" -eq 1 ]"
expect "parityr AC3: after the rerun reports, diff=0 (the recovered result is used, not left as a false diff)" \
  "grep -q 'diff=0' <<<\"$pr3_out\""
pr3_json_rc=0
python3 -c "
import json
d = json.load(open('$pr3_parity_file'))
assert d['suites']['parity::flaky'] == {'box': 'ok', 'local': 'ok'}, d['suites']['parity::flaky']
" || pr3_json_rc=1
expect "parityr AC3: box-parity.json shows the recovered suite as ok/ok, not no-output" "[ $pr3_json_rc -eq 0 ]"

# ---- parityr AC6 (P1): this fixture set exits 0 and names the parityr
# cases — an explicit, in-band assertion of the requirement's own selftest
# check, matching every sibling AC's "does the suite name its own cases"
# convention (see burstuser AC7 just below).
expect_block_green "parityr" "parityr AC6: every parityr case above ran green"

# ---- burstuser AC7: the fixture set (this file) exits 0 and names the
# burstuser cases — checked here as an explicit, in-band assertion (rather
# than only by the exit code the harness wrapper around this file checks)
# so tests/burstuser_ac7_*.sh has a real "ok" line of its own to grep for,
# matching every sibling AC's own convention.
expect_block_green "burstuser" "burstuser AC7: every burstuser case above ran green (fail=0 through AC1-AC6)"

# ---- reality (PRD-build-post-ship-reality-check, test_prefix: reality) ----
# reality-check.sh's plan/run + verified-completed.sh's two new archive
# checks + prd-lint.sh's negative-case warn, exercised offline: every real
# side (burst-lane status, curl, the receipt selftest) is faked via the
# scripts' own env-var overrides, so this whole section never touches the
# network or the real ~/Documents/PRDs clone.
RC="$HERE/reality-check.sh"
VC="$HERE/verified-completed.sh"
PL="$HERE/prd-lint.sh"
RT="$(mktemp -d "${TMPDIR:-/tmp}/reality-selftest.XXXXXX")"
ALL_TMPDIRS+=("$RT")
mkdir -p "$RT/build-queue" "$RT/built-prds" "$RT/visions" "$RT/fake-bin"
touch "$RT/visions/fixture.md"
git init -q "$RT" >/dev/null 2>&1
git -C "$RT" config user.email t@t; git -C "$RT" config user.name t

cat >"$RT/built-prds/PRD-realityfix.md" <<'EOF'
# PRD — realityfix: a fixture PRD for the reality selftest

- Status: built
- build_target: shell
- build_into: /tmp/reality-selftest-target
- Vision: visions/fixture.md

## Acceptance criteria

1. P0 — Given a green HEAD, When `parity ~/wintermute/mcphost` runs against the live lane, Then zero diffs are reported.
2. P0 — Given the deploy on casper, When the operator checks it, Then it behaves correctly.
EOF
git -C "$RT" add -A && git -C "$RT" commit -q -m init >/dev/null

cat >"$RT/fake-bin/fake-lane-active.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"active":true,"server_id":"165449166"}'
EOF
cat >"$RT/fake-bin/fake-lane-inactive.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"active":false}'
EOF
chmod +x "$RT/fake-bin/fake-lane-active.sh" "$RT/fake-bin/fake-lane-inactive.sh"
cat >"$RT/fake-bin/parity" <<'EOF'
#!/usr/bin/env bash
echo "parity ok: 0 diffs for $1"
exit 0
EOF
cat >"$RT/fake-bin/parity-fail" <<'EOF'
#!/usr/bin/env bash
echo "parity FAIL: checkcompat_ac02_ac03 differs"
exit 1
EOF
chmod +x "$RT/fake-bin/parity" "$RT/fake-bin/parity-fail"

# reality AC1 (PRD AC1): plan lists the substrate-naming AC with its
# literal command and lists the substrate-mention-with-no-command AC as
# manual, naming a reason — never silently dropped.
plan_out="$("$RC" plan "$RT/built-prds/PRD-realityfix.md")"
block_start "reality"
expect "reality AC1: plan lists AC1 kind=box with the literal parity command" \
  "printf '%s' \"\$plan_out\" | python3 -c \"import json,sys; d=json.load(sys.stdin); a=[x for x in d if x['ac']==1][0]; assert a['kind']=='box' and a['command']=='parity ~/wintermute/mcphost', a\""
expect "reality AC1: AC2 (casper, no derivable command) is listed manual with a reason" \
  "printf '%s' \"\$plan_out\" | python3 -c \"import json,sys; d=json.load(sys.stdin); a=[x for x in d if x['ac']==2][0]; assert a['kind']=='manual' and a['reason'], a\""

# reality AC2 (PRD AC2): a fake lane reporting an active session -> `run`
# executes the fake command, frontmatter gains reality: ok + reality_receipt:,
# and the journal has `reality  <slug>  ok`.
cp "$RT/built-prds/PRD-realityfix.md" "$RT/built-prds/PRD-realityfix.md.orig"
PATH="$RT/fake-bin:$PATH" REALITY_CHECK_BURST_LANE="$RT/fake-bin/fake-lane-active.sh" \
  BUILD_JOURNAL_DIR="$RT/journal" BUILD_RECEIPTS_DIR="$RT/journal/receipts" \
  "$RC" run "$RT/built-prds/PRD-realityfix.md" --no-push >/dev/null 2>"$RT/run-ok.err"
expect "reality AC2: reachable+passing run exit 0" "[ $? -eq 0 ] || true; grep -q '^- reality: ok' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC2: reality_receipt frontmatter present and file exists" \
  "recpt=\$(grep '^- reality_receipt:' \"$RT/built-prds/PRD-realityfix.md\" | sed 's/^- reality_receipt: //'); [ -f \"\$recpt\" ]"
expect "reality AC2: journal has 'reality  realityfix  ok'" \
  "grep -q 'reality  realityfix  ok' \"$RT/journal/$(date -u +%F).md\""

# reality AC3 (PRD AC2/AC10, 2026-09-12 revision — supersedes the
# pre-revision "unreachable, no follow-up" outcome this case originally
# asserted): AC1's `parity ~/wintermute/mcphost` is tagged box-only (it
# inherently diffs against the real box's own disk state — a container has
# none to compare, see reality-check.sh's BOX_ONLY_RE comment), so a lane
# reporting inactive on BOTH of two spaced probes registers it pending
# instead of a bare unreachable, and still drafts no follow-up (pending is
# not a failure).
cp "$RT/built-prds/PRD-realityfix.md.orig" "$RT/built-prds/PRD-realityfix.md"
rm -rf "$RT/journal" "$RT/reality-pending"; mkdir -p "$RT/reality-pending"
PATH="$RT/fake-bin:$PATH" REALITY_CHECK_BURST_LANE="$RT/fake-bin/fake-lane-inactive.sh" REALITY_CHECK_PROBE_SPACING=0 \
  BUILD_JOURNAL_DIR="$RT/journal" BUILD_RECEIPTS_DIR="$RT/journal/receipts" REALITY_CHECK_PENDING_DIR="$RT/reality-pending" \
  "$RC" run "$RT/built-prds/PRD-realityfix.md" --no-push >/dev/null 2>&1
expect "reality AC3: unreachable box-only lane on two probes -> reality: pending (not a bare unreachable)" \
  "grep -q '^- reality: pending' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC3: registration timestamp recorded on the parent" \
  "grep -qE '^- reality_pending_since: ' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC3: pending registration file exists" \
  "[ -f \"$RT/reality-pending/realityfix-ac1.json\" ]"
expect "reality AC3: no follow-up drafted when pending" "[ ! -e \"$RT/build-queue/PRD-realityfix-reality-1.md\" ]"

# reality AC4 (PRD AC4): deferral-premise-false, naming the session id, when
# a deferred AC's justification claims unreachability but the fake lane
# reports an active session.
cat >"$RT/built-prds/PRD-realitydefer.md" <<'EOF'
# PRD — realitydefer: a fixture PRD with a deferred AC to premise-check

- Status: built
- build_target: shell
- Vision: visions/fixture.md
- deferred_acs: [4]
- mock_justifications:
  - "AC4 needs a real box, which is not reachable/authorized from this sandboxed build session."

## Acceptance criteria

1. P0 — Given a thing, When it runs, Then it works.
2. P0 — Given a thing, When it runs, Then it works.
3. P0 — Given a thing, When it runs, Then it works.
4. P0 — Given a thing, When it runs, Then it works.
EOF
premise_out="$(VC_BURST_LANE="$RT/fake-bin/fake-lane-active.sh" "$VC" "$RT/built-prds/PRD-realitydefer.md" --check-deferral-premises 2>"$RT/premise-false.err")"
expect "reality AC4: deferral-premise-false exits 1" "[ $? -ne 0 ]"
expect "reality AC4: names AC4 and the session id" "grep -q 'deferral-premise-false: AC4' \"$RT/premise-false.err\" && grep -q '165449166' \"$RT/premise-false.err\""
VC_BURST_LANE="$RT/fake-bin/fake-lane-inactive.sh" "$VC" "$RT/built-prds/PRD-realitydefer.md" --check-deferral-premises >/dev/null 2>"$RT/premise-true.err"
expect "reality AC4 (true premise): a genuinely unreachable box exits 0" "[ $? -eq 0 ]"

# reality AC5: receipt-claim-mismatch names both counts; a matching claim
# exits 0.
cat >"$RT/fake-bin/fake-251.sh" <<'EOF'
#!/usr/bin/env bash
echo "251/251 ok, 0 FAIL"
EOF
cat >"$RT/fake-bin/fake-245.sh" <<'EOF'
#!/usr/bin/env bash
echo "245/251 ok, 6 FAIL"
exit 1
EOF
chmod +x "$RT/fake-bin/fake-251.sh" "$RT/fake-bin/fake-245.sh"
"$VC" "$RT/built-prds/PRD-realityfix.md" --check-receipt-claim \
  --receipt-text "some-selftest.sh 251/251 ok; 0 FAIL" --receipt-script "$RT/fake-bin/fake-251.sh" >/dev/null 2>&1
expect "reality AC5: matching receipt claim exits 0" "[ $? -eq 0 ]"
"$VC" "$RT/built-prds/PRD-realityfix.md" --check-receipt-claim \
  --receipt-text "some-selftest.sh 251/251 ok; 0 FAIL" --receipt-script "$RT/fake-bin/fake-245.sh" >/dev/null 2>"$RT/mismatch.err"
expect "reality AC5: mismatched receipt claim exits 1 naming both counts" \
  "[ $? -ne 0 ] && grep -q '251/251' \"$RT/mismatch.err\" && grep -q '245/251' \"$RT/mismatch.err\""

# reality AC6: a `failed` result drafts a lint-clean follow-up naming the
# failing command, an excerpt, and one P0 line per failed AC; parent gains
# reality_followup:.
cp "$RT/built-prds/PRD-realityfix.md.orig" "$RT/built-prds/PRD-realityfix.md"
rm -rf "$RT/journal" "$RT/build-queue"/PRD-realityfix-reality-*.md
PATH="$RT/fake-bin:$PATH" REALITY_CHECK_BURST_LANE="$RT/fake-bin/fake-lane-active.sh" \
  BUILD_JOURNAL_DIR="$RT/journal" BUILD_RECEIPTS_DIR="$RT/journal/receipts" \
  bash -c "cp \"$RT/fake-bin/parity-fail\" \"$RT/fake-bin/parity\"; \"$RC\" run \"$RT/built-prds/PRD-realityfix.md\" --no-push" >/dev/null 2>&1
expect "reality AC6: reality: failed" "grep -q '^- reality: failed' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC6: reality_followup: set on the parent" "grep -q '^- reality_followup: PRD-realityfix-reality-1.md' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC6: follow-up file exists" "[ -f \"$RT/build-queue/PRD-realityfix-reality-1.md\" ]"
expect "reality AC6: follow-up passes prd-lint.sh" "\"$PL\" \"$RT/build-queue/PRD-realityfix-reality-1.md\" >/dev/null 2>&1"
expect "reality AC6: follow-up names the failing command and a P0 line" \
  "grep -q 'parity ~/wintermute/mcphost' \"$RT/build-queue/PRD-realityfix-reality-1.md\" && grep -qE '^1\\. P0 —' \"$RT/build-queue/PRD-realityfix-reality-1.md\""
expect "reality AC6: journal has 'reality  follow-up  drafted'" "grep -q 'reality  follow-up  drafted' \"$RT/journal/$(date -u +%F).md\""

# reality AC7 (fixture negative-case rule): prd-lint warns on a positive-
# only selftest mention; verified-completed --check-fixture-negative-case
# blocks a shipped diff whose only new selftest case is a success path.
cat >"$RT/built-prds/PRD-realitypositive.md" <<'EOF'
# PRD — realitypositive: a fixture with a happy-path-only selftest mention

- Status: queued
- build_target: shell
- Vision: visions/fixture.md

## Acceptance criteria

1. P0 — Given the selftest fixture set, When `foo-selftest.sh` runs, Then it exits 0 and all cases pass and match.
EOF
"$PL" "$RT/built-prds/PRD-realitypositive.md" >"$RT/lint-positive.out" 2>&1
expect "reality AC7: prd-lint warns selftest-no-negative-case on a happy-path-only mention" \
  "grep -q selftest-no-negative-case \"$RT/lint-positive.out\""

FR="$RT/fnc-repo"
mkdir -p "$FR"
git init -q "$FR" >/dev/null 2>&1
git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
cat >"$FR/thing-selftest.sh" <<'EOF'
echo "== base case =="
EOF
git -C "$FR" add -A && git -C "$FR" commit -q -m init >/dev/null
git -C "$FR" tag v0.1.0
cat >"$FR/PRD-fnc.md" <<EOF
# PRD — fnc

- Status: built
- build_target: shell
- build_into: $FR
- Vision: visions/fixture.md

## Acceptance criteria

1. P0 — Given a thing, When it runs, Then it works.
EOF
cp "$RT/visions/fixture.md" "$FR/../visions/fixture.md" 2>/dev/null || true
mkdir -p "$(dirname "$FR")/visions"; touch "$(dirname "$FR")/visions/fixture.md"
echo 'echo "== new happy path =="' >>"$FR/thing-selftest.sh"
git -C "$FR" add -A && git -C "$FR" commit -q -m "add success-only case" >/dev/null
"$VC" "$FR/PRD-fnc.md" --check-fixture-negative-case >/dev/null 2>"$RT/fnc-block.err"
expect "reality AC7: verified-completed --check-fixture-negative-case blocks a success-only diff" \
  "[ $? -ne 0 ] && grep -q 'fixture-negative-case-missing' \"$RT/fnc-block.err\""

# reality requirement 8's interim status surface (`open` — no dedicated
# numbered AC, same as gate-debt.sh's own `open`): a closed follow-up
# (already archived) is excluded, an open one (still in build-queue/) is
# listed, in both text and --format json.
OR="$(mktemp -d "${TMPDIR:-/tmp}/reality-open-selftest.XXXXXX")"
ALL_TMPDIRS+=("$OR")
mkdir -p "$OR/built-prds" "$OR/build-queue"
cat >"$OR/built-prds/PRD-openreq8-closed.md" <<'EOF'
- Status: built
- reality: failed
- reality_followup: PRD-openreq8-closed-reality-1.md
EOF
cat >"$OR/built-prds/PRD-openreq8-closed-reality-1.md" <<'EOF'
- Status: built
EOF
cat >"$OR/built-prds/PRD-openreq8-open.md" <<'EOF'
- Status: built
- reality: failed
- reality_followup: PRD-openreq8-open-reality-1.md
EOF
cat >"$OR/build-queue/PRD-openreq8-open-reality-1.md" <<'EOF'
- Status: queued
EOF
or_out="$("$RC" open --prd-dir "$OR" 2>&1)"; or_rc=$?
expect "reality open: exits 0" "[ $or_rc -eq 0 ]"
expect "reality open: lists the still-open follow-up" \
  "grep -qF 'PRD-openreq8-open.md -> PRD-openreq8-open-reality-1.md' <<<\"$or_out\""
expect "reality open: excludes the already-archived (closed) follow-up" \
  "! grep -qF 'PRD-openreq8-closed.md' <<<\"$or_out\""
or_json="$("$RC" open --prd-dir "$OR" --format json 2>&1)"; or_json_rc=0
python3 -c "
import json
d = json.loads('''$or_json''')
rows = d['reality_open']
assert len(rows) == 1, rows
assert rows[0] == {'parent': 'PRD-openreq8-open.md', 'followup': 'PRD-openreq8-open-reality-1.md'}, rows
" || or_json_rc=1
expect "reality open --format json: shape matches {parent, followup} for the open row only" "[ $or_json_rc -eq 0 ]"

# reality AC9: this fixture set exits 0 and names the reality cases —
# checked here as an explicit, in-band assertion, matching every sibling
# AC's own convention (see burstuser AC7 / parityr AC6 above).
expect_block_green "reality" "reality AC9: every reality case above ran green"
# ================================================================
# isolate AC1-6 (PRD-build-burst-selftest-isolation) — every fixture in
# this section is fully self-contained (its own tmpdir "fake home" or
# fixture paths, never the real live tree) EXCEPT the top-of-file/
# bottom-of-file live audit wrap, which deliberately targets the real
# $HOME/.claude/skills/build/state/burst-lane + $HOME/brain/journal/build/
# burst-lane.log — the whole point being that THIS suite's own extensive
# fixture-based work above never moved a single byte there.
# ================================================================

# ---- isolate AC1: sentinel + a forgotten override -> exit 9, zero side
# effect (PRD requirement 2, AC1). Built against a scratch "fake home" with
# burst-lane.sh + isolation-guard.sh copied into the SAME relative layout
# real production uses ($FAKEHOME/.claude/skills/build/scripts/) so
# STATE_DIR's own $SKILL_DIR-derived default and isolation-guard.sh's
# hardcoded $HOME-derived live root coincide exactly the way they do once
# this repo is installed at ~/.claude/skills/build (the real symlink
# target) — independent of whether THIS invocation happens to be running
# from a development worktree or the real install.
iso_fakehome="$(mktemp -d "${TMPDIR:-/tmp}/bl-iso-fakehome.XXXXXX")"
ALL_TMPDIRS+=("$iso_fakehome")
mkdir -p "$iso_fakehome/.claude/skills/build/scripts" "$iso_fakehome/brain/journal/build"
cp "$HERE/burst-lane.sh" "$HERE/isolation-guard.sh" "$iso_fakehome/.claude/skills/build/scripts/"
iso_fake_bl="$iso_fakehome/.claude/skills/build/scripts/burst-lane.sh"
iso_fake_session="$iso_fakehome/.claude/skills/build/state/burst-lane/session.json"
mkdir -p "$(dirname "$iso_fake_session")"
printf '{}' > "$iso_fake_session"
iso_ac1_before="$(stat -c %Y "$iso_fake_session" 2>/dev/null || stat -f %m "$iso_fake_session" 2>/dev/null)"
iso_ac1_out="$(env -i HOME="$iso_fakehome" PATH="/usr/bin:/bin" BURST_LANE_TEST=1 "$iso_fake_bl" status 2>&1)"; iso_ac1_rc=$?
iso_ac1_after="$(stat -c %Y "$iso_fake_session" 2>/dev/null || stat -f %m "$iso_fake_session" 2>/dev/null)"
block_start "isolate"
expect "isolate AC1: burst-lane.sh status exits 9 under the sentinel with no overrides" "[ $iso_ac1_rc -eq 9 ]"
expect "isolate AC1: refusal names the live state path" "grep -qE 'test-isolation: live path .*state/burst-lane' <<<\"\$iso_ac1_out\""
expect "isolate AC1: the live session file's mtime is unchanged" "[ \"\$iso_ac1_before\" = \"\$iso_ac1_after\" ]"

# ---- isolate AC3: the audit mechanism itself catches a planted change to
# a "live" journal, mid-run — exercised against a disposable fixture pair
# (never the real live tree) so proving the DETECTOR works never itself
# requires touching production.
iso_ac3_state="$(mktemp -d "${TMPDIR:-/tmp}/bl-iso-ac3-state.XXXXXX")"
iso_ac3_journal="$(mktemp "${TMPDIR:-/tmp}/bl-iso-ac3-journal.XXXXXX")"
ALL_TMPDIRS+=("$iso_ac3_state")
printf 'line one\nline two\n' > "$iso_ac3_journal"
iso_ac3_before="$(mktemp "${TMPDIR:-/tmp}/bl-iso-ac3-before.XXXXXX")"
iso_ac3_after="$(mktemp "${TMPDIR:-/tmp}/bl-iso-ac3-after.XXXXXX")"
ALL_TMPDIRS+=("$iso_ac3_before" "$iso_ac3_after")
audit_snapshot "$iso_ac3_state" "$iso_ac3_journal" > "$iso_ac3_before"
printf 'X' >> "$iso_ac3_journal"   # the "one byte, mid-run" plant
audit_snapshot "$iso_ac3_state" "$iso_ac3_journal" > "$iso_ac3_after"
iso_ac3_out="$(audit_diff "$iso_ac3_before" "$iso_ac3_after" 2>&1)"; iso_ac3_rc=$?
expect "isolate AC3: the audit detects a one-byte planted change (nonzero exit)" "[ $iso_ac3_rc -ne 0 ]"
expect "isolate AC3: it reports isolation-breach naming the journal" "grep -q 'isolation-breach:' <<<\"\$iso_ac3_out\""
rm -f "$iso_ac3_journal"

# ---- isolate AC4: the live-side counter — a caller that exports
# BURST_LANE_TEST=1 "by mistake" (every other override left at its live
# default) is refused, the refusal is journaled, and the daily rollup's
# isolation_refusals field counts it (requirement 4). Same fakehome
# technique as isolate AC1 so this never touches the REAL live journal.
iso_ac4_fakehome="$(mktemp -d "${TMPDIR:-/tmp}/bl-iso-ac4-fakehome.XXXXXX")"
ALL_TMPDIRS+=("$iso_ac4_fakehome")
mkdir -p "$iso_ac4_fakehome/.claude/skills/build/scripts" "$iso_ac4_fakehome/brain/journal/build"
cp "$HERE/burst-lane.sh" "$HERE/isolation-guard.sh" "$iso_ac4_fakehome/.claude/skills/build/scripts/"
iso_ac4_bl="$iso_ac4_fakehome/.claude/skills/build/scripts/burst-lane.sh"
iso_ac4_journal="$iso_ac4_fakehome/brain/journal/build/burst-lane.log"
iso_ac4_state="$iso_ac4_fakehome/.claude/skills/build/state/burst-lane"

env -i HOME="$iso_ac4_fakehome" PATH="/usr/bin:/bin" BURST_LANE_TEST=1 \
  "$iso_ac4_bl" run /tmp -- bash -c true >/dev/null 2>&1
iso_ac4_rc=$?
expect "isolate AC4: a mistaken sentinel on run refuses (exit 9)" "[ $iso_ac4_rc -eq 9 ]"
expect "isolate AC4: the refusal is journaled (isolation  refused)" "grep -q 'isolation  refused' \"$iso_ac4_journal\""

# Give the daily rollup something to fire on (a same-day cost row — its
# real-world trigger is a leak attempt during otherwise-normal burst-lane
# use, not an idle day), then invoke `down` (sentinel OFF for this call —
# it's the ordinary live path, exactly like the real rollup caller) so
# maybe_daily_rollup runs and folds in the refusal count from the journal
# line just written above.
today="$(date -u +%Y-%m-%d)"
# The refused call above has NO side effect by design (that's AC1's own
# point), so $iso_ac4_state was never created — make it now. cost.jsonl
# is a per-box path (PRD-build-burst-state-keyed-by-server-v2 requirement
# 1) reached via $BOX_STATE_DIR == $BURST_LANE_STATE_DIR/current, so the
# fixture row must land there or maybe_daily_rollup's `[ -f "$COST_LEDGER" ]`
# guard sees no file and returns before ever computing the rollup line.
mkdir -p "$iso_ac4_state/current"
printf '{"date":"%sT00:00:00Z","kind":"slug","slug":"isolate-ac4","eur":0.01}\n' "$today" > "$iso_ac4_state/current/cost.jsonl"
env -i HOME="$iso_ac4_fakehome" PATH="/usr/bin:/bin" \
  BURST_LANE_STATE_DIR="$iso_ac4_state" BURST_LANE_TICK_JOURNAL_DIR="$iso_ac4_fakehome/tick-journal" \
  "$iso_ac4_bl" down >/dev/null 2>&1
iso_ac4_rollup_file="$iso_ac4_fakehome/tick-journal/$today.md"
expect "isolate AC4: the daily rollup line carries isolation_refusals>=1" \
  "grep -qE 'isolation_refusals=[1-9]' \"$iso_ac4_rollup_file\" 2>/dev/null"

# ---- isolate AC5: a fixture-named directory on the box fails the check
# while a session is active. Exercises box_isolation_check() end-to-end
# against the fake ssh/hcloud fixtures already used above (fresh_env),
# with one extra fixture-named dir seeded into the fake remote root.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
"$BL" up >/dev/null
# The fake ssh fixture resolves its "remote root" onto this machine's own
# filesystem (per its own header — see fresh_env's BURST_LANE_REMOTE_ROOT);
# seed the fixture-named directory it should now flag.
mkdir -p "$BURST_LANE_REMOTE_ROOT/gb-ac3.deadbe"
iso_ac5_out="$("$BL" box-isolation-check 2>&1)"; iso_ac5_rc=$?
expect "isolate AC5: box-isolation-check fails with a fixture-named box dir present" "[ $iso_ac5_rc -ne 0 ]"
expect "isolate AC5: it names the offending directory" "grep -q 'isolation-breach: box dir gb-ac3.deadbe' <<<\"\$iso_ac5_out\""
rm -rf "$BURST_LANE_REMOTE_ROOT/gb-ac3.deadbe"
iso_ac5b_out="$("$BL" box-isolation-check 2>&1)"; iso_ac5b_rc=$?
expect "isolate AC5: clean once the fixture-named dir is gone" "[ $iso_ac5b_rc -eq 0 ]"

# ---- isolate AC6 (P1): this fixture set exits 0 and names the isolate
# cases — matching every sibling AC's own "does the suite name its own
# coverage" convention (parityr AC6, burstuser AC7 above).
expect_block_green "isolate" "isolate AC6: every isolate case above ran green"

# ==============================================================================
# paritycad AC1-AC6 (PRD-build-burst-parity-cadence): a parity receipt is
# valid for a box SESSION + TOOLCHAIN FINGERPRINT (not a single HEAD), the
# local half is load-gated and cargo-budget-wrapped, and a per-repo
# `.burst-lane.toml` can mark a suite host-sensitive without blocking
# routing.
# ==============================================================================

# cargo-budget.sh is a separate script with no isolation-guard.sh of its own
# (unlike burst-lane.sh's own state/journal) — every case below that reaches
# cmd_parity's LOCAL half must explicitly scope cargo-budget's state/
# journal/meminfo/loadavg/hostname under $T (same convention as cargo-
# budget-selftest.sh's own common_env()), or a real invocation here would
# write into this host's REAL cargo-budget ledger/journal and could contend
# a REAL production slot lock.
paritycad_cargo_budget_env() {
  local dir="$1"
  export CARGO_BUDGET_STATE_DIR="$dir/cb-state"
  export CARGO_BUDGET_JOURNAL="$dir/cb-journal.md"
  export CARGO_BUDGET_HOSTNAME="paritycad-not-redbaron"
  printf '0.10 0.05 0.01 1/200 12345\n' > "$dir/cb-loadavg"
  export CARGO_BUDGET_LOADAVG="$dir/cb-loadavg"
  cat > "$dir/cb-meminfo" <<'EOF'
MemTotal:       31000000 kB
MemFree:        20000000 kB
MemAvailable:   25000000 kB
EOF
  export CARGO_BUDGET_MEMINFO="$dir/cb-meminfo"
}

# ---- paritycad AC1: a receipt valid for the ACTIVE session + toolchain
# fingerprint routes `gate` at a NEW head without re-running parity —
# head_sha is never compared any more (requirement 1).
fresh_env
paritycad_cargo_budget_env "$T"
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
sid_pc1="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
WT_PC1="$T/paritycad-repo1"; mkdir -p "$WT_PC1"
( cd "$WT_PC1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PC1="$T/fakebin-paritycad1"; mkdir -p "$FAKEBIN_PC1"
export PARITYCAD1_CARGO_CALLS="$T/paritycad1-cargo-calls"
cat > "$FAKEBIN_PC1/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local; echo run >> "$PARITYCAD1_CARGO_CALLS" ;;
  esac
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity::a": {}, "parity::b": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    echo "        PASS [   0.001s] (1/2) parity::a test_a"
    echo "        PASS [   0.001s] (2/2) parity::b test_b"
    exit 0
  fi
fi
echo "fake-cargo(paritycad1): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PC1/cargo"

pc1_parity_out="$(PATH="$FAKEBIN_PC1:$PATH" "$BL" parity "$WT_PC1" 2>&1)"; pc1_parity_rc=$?
block_start "paritycad"
expect "paritycad AC1: initial parity exits 0 with a clean diff" "[ $pc1_parity_rc -eq 0 ] && grep -q 'diff=0' <<<\"\$pc1_parity_out\""
pc1_receipt="$WT_PC1/target/autobuilder/receipts/box-parity.json"
pc1_fields_rc=0
python3 -c "
import json
d = json.load(open('$pc1_receipt'))
assert d.get('session_id') == '$sid_pc1', d.get('session_id')
assert d.get('toolchain_fp'), d
assert d.get('diff') == [], d
" || pc1_fields_rc=1
expect "paritycad AC1: receipt carries session_id + toolchain_fp" "[ $pc1_fields_rc -eq 0 ]"

head_a_pc1="$(git -C "$WT_PC1" rev-parse HEAD)"
( cd "$WT_PC1" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "moves head" )
head_b_pc1="$(git -C "$WT_PC1" rev-parse HEAD)"

FAKE_EG_CALLLOG_PC1="$T/paritycad1-extend-gate-calls.log"
cat > "$FAKEBIN_PC1/extend-gate.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE_EG_CALLLOG_PC1"
mkdir -p target/autobuilder/receipts
echo '{"pass": 25, "block": 0}' > target/autobuilder/last-verdict.json
exit 0
EOF
chmod +x "$FAKEBIN_PC1/extend-gate.sh"
reproof_before_pc1="$(grep -c 'burst-lane  parity  reproof' "$BURST_LANE_JOURNAL" 2>/dev/null || echo 0)"
gate1_out="$(PATH="$FAKEBIN_PC1:$PATH" "$BL" gate "$WT_PC1" --head "$head_b_pc1" 2>&1)"; gate1_rc=$?
reproof_after_pc1="$(grep -c 'burst-lane  parity  reproof' "$BURST_LANE_JOURNAL" 2>/dev/null || echo 0)"
expect "paritycad AC1: gate at a NEW head routes (invokes extend-gate.sh, not a parity fallback)" \
  "[ $gate1_rc -eq 0 ] && [ \"\$(wc -l < \"$FAKE_EG_CALLLOG_PC1\")\" -eq 1 ] && [ \"$head_a_pc1\" != \"$head_b_pc1\" ]"
expect "paritycad AC1: gate never falls back on the receipt's stale head_sha" "! grep -q '^fallback:' <<<\"$gate1_out\""
expect "paritycad AC1: no re-proof happened (session+toolchain both still match)" "[ \"$reproof_before_pc1\" = \"$reproof_after_pc1\" ]"

# ---- paritycad AC2: a receipt whose session_id no longer matches the
# ACTIVE session triggers exactly one re-proof (journaled with its cause),
# and gate's routing follows that re-proof's own result.
fresh_env
paritycad_cargo_budget_env "$T"
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
sid_pc2="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
WT_PC2="$T/paritycad-repo2"; mkdir -p "$WT_PC2"
( cd "$WT_PC2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PC2="$T/fakebin-paritycad2"; mkdir -p "$FAKEBIN_PC2"
export PARITYCAD2_CARGO_CALLS="$T/paritycad2-cargo-calls"
cat > "$FAKEBIN_PC2/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local ;;
  esac
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity::a": {}, "parity::b": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    # Count only actual TEST RUNS (not the cheap `list` metadata call) on
    # the local side — this is what "the re-proof re-ran the local test"
    # means to paritycad AC2.
    [ "$side" = "local" ] && echo run >> "$PARITYCAD2_CARGO_CALLS"
    echo "        PASS [   0.001s] (1/2) parity::a test_a"
    echo "        PASS [   0.001s] (2/2) parity::b test_b"
    exit 0
  fi
fi
echo "fake-cargo(paritycad2): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PC2/cargo"
cat > "$FAKEBIN_PC2/extend-gate.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p target/autobuilder/receipts
echo '{"pass": 25, "block": 0}' > target/autobuilder/last-verdict.json
exit 0
EOF
chmod +x "$FAKEBIN_PC2/extend-gate.sh"

pc2_parity_out="$(PATH="$FAKEBIN_PC2:$PATH" "$BL" parity "$WT_PC2" 2>&1)"; pc2_parity_rc=$?
expect "paritycad AC2: initial parity exits 0 with a clean diff" "[ $pc2_parity_rc -eq 0 ]"
pc2_receipt="$WT_PC2/target/autobuilder/receipts/box-parity.json"
head_pc2="$(git -C "$WT_PC2" rev-parse HEAD)"

# Simulate "a new session": forge the receipt's session_id to a foreign
# value — the ACTIVE session is unchanged, only the receipt now claims a
# different one, isolating this case to the session-mismatch path alone.
python3 -c "
import json
p = '$pc2_receipt'
d = json.load(open(p))
d['session_id'] = 'some-other-session-999'
json.dump(d, open(p, 'w'))
"

cargo_calls_before_pc2="$(wc -l < "$PARITYCAD2_CARGO_CALLS" 2>/dev/null || echo 0)"
gate2_out="$(PATH="$FAKEBIN_PC2:$PATH" "$BL" gate "$WT_PC2" --head "$head_pc2" 2>&1)"; gate2_rc=$?
cargo_calls_after_pc2="$(wc -l < "$PARITYCAD2_CARGO_CALLS" 2>/dev/null || echo 0)"

expect "paritycad AC2: exactly one re-proof journaled with cause=session" \
  "[ \"\$(grep -c 'burst-lane  parity  reproof  (cause=session' \"$BURST_LANE_JOURNAL\")\" = 1 ]"
expect "paritycad AC2: the re-proof actually re-ran the local test exactly once" \
  "[ $((cargo_calls_after_pc2 - cargo_calls_before_pc2)) -eq 1 ]"
expect "paritycad AC2: routing follows the re-proof's result (gate proceeds, exit 0)" "[ $gate2_rc -eq 0 ]"
pc2_session_fixed_rc=0
python3 -c "
import json
d = json.load(open('$pc2_receipt'))
assert d.get('session_id') == '$sid_pc2', d.get('session_id')
" || pc2_session_fixed_rc=1
expect "paritycad AC2: the re-proof rewrote the receipt with the real active session_id" "[ $pc2_session_fixed_rc -eq 0 ]"

# ---- paritycad AC3: RedBaron's load never rises because of parity — a load
# above CARGO_BUDGET_MAX_LOAD defers the WHOLE attempt (no box, no local, no
# `up`) and journals the cause (requirement 2).
fresh_env
export CARGO_BUDGET_HOSTNAME="redbaron"
printf '999.0 999.0 999.0 1/500 99999\n' > "$T/pc3-loadavg"
export CARGO_BUDGET_LOADAVG="$T/pc3-loadavg"
export PARITY_LOAD_WAIT_S=0
WT_PC3="$T/paritycad-repo3"; mkdir -p "$WT_PC3"
( cd "$WT_PC3" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
pc3_out="$("$BL" parity "$WT_PC3" 2>&1)"; pc3_rc=$?
expect "paritycad AC3: parity exits 3 when RedBaron's load exceeds the cap" "[ $pc3_rc -eq 3 ]"
expect "paritycad AC3: parity prints fallback: load" "grep -q '^fallback: load$' <<<\"$pc3_out\""
expect "paritycad AC3: journal records the deferral with cause=load" \
  "grep -q 'burst-lane  parity  deferred  (cause=load' \"$BURST_LANE_JOURNAL\""
expect "paritycad AC3: no session was ever brought up (neither side ran)" "[ ! -f \"$BURST_LANE_STATE_DIR/current/session.json\" ]"
expect "paritycad AC3: no local test baseline was written" "[ ! -e \"$WT_PC3/target/autobuilder/test-output.txt\" ]"
expect "paritycad AC3: no parity receipt was written" "[ ! -e \"$WT_PC3/target/autobuilder/receipts/box-parity.json\" ]"
unset CARGO_BUDGET_HOSTNAME CARGO_BUDGET_LOADAVG PARITY_LOAD_WAIT_S

# ---- paritycad AC4: a suite named in .burst-lane.toml's parity_exclude is
# still run and recorded on both sides, but never counted as a parity diff
# — reported under host_sensitive instead — and gate still routes
# (requirement 4).
fresh_env
paritycad_cargo_budget_env "$T"
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
WT_PC4="$T/paritycad-repo4"; mkdir -p "$WT_PC4"
( cd "$WT_PC4" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cat > "$WT_PC4/.burst-lane.toml" <<'EOF'
parity_exclude = ["parity::flaky_host"]
EOF
FAKEBIN_PC4="$T/fakebin-paritycad4"; mkdir -p "$FAKEBIN_PC4"
cat > "$FAKEBIN_PC4/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local ;;
  esac
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity::steady": {}, "parity::flaky_host": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    if [ "$side" = "box" ]; then
      echo "        FAIL [   0.010s] (1/2) parity::flaky_host test_x"
      echo "        PASS [   0.001s] (2/2) parity::steady test_s"
    else
      echo "        PASS [   0.010s] (1/2) parity::flaky_host test_x"
      echo "        PASS [   0.001s] (2/2) parity::steady test_s"
    fi
    exit 0
  fi
fi
echo "fake-cargo(paritycad4): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PC4/cargo"
pc4_out="$(PATH="$FAKEBIN_PC4:$PATH" "$BL" parity "$WT_PC4" 2>&1)"; pc4_rc=$?
expect "paritycad AC4: parity exits 0" "[ $pc4_rc -eq 0 ]"
expect "paritycad AC4: diff stays empty (the only disagreement is excluded)" "grep -q 'diff=0' <<<\"$pc4_out\""
pc4_receipt="$WT_PC4/target/autobuilder/receipts/box-parity.json"
pc4_json_rc=0
python3 -c "
import json
d = json.load(open('$pc4_receipt'))
assert d['diff'] == [], d['diff']
assert d['host_sensitive'] == ['parity::flaky_host'], d['host_sensitive']
assert d['suites']['parity::flaky_host'] == {'box': 'FAILED', 'local': 'ok', 'status': 'host-sensitive'}, d['suites']['parity::flaky_host']
" || pc4_json_rc=1
expect "paritycad AC4: box-parity.json lists the excluded suite under host_sensitive with both results" "[ $pc4_json_rc -eq 0 ]"

head_pc4="$(git -C "$WT_PC4" rev-parse HEAD)"
cat > "$FAKEBIN_PC4/extend-gate.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p target/autobuilder/receipts
echo '{"pass": 25, "block": 0}' > target/autobuilder/last-verdict.json
exit 0
EOF
chmod +x "$FAKEBIN_PC4/extend-gate.sh"
gate4_out="$(PATH="$FAKEBIN_PC4:$PATH" "$BL" gate "$WT_PC4" --head "$head_pc4" 2>&1)"; gate4_rc=$?
expect "paritycad AC4: gate routes despite the host-sensitive suite (not blocked by it)" "[ $gate4_rc -eq 0 ]"

# ---- paritycad AC5: parity's local half runs through cargo-budget.sh (nice
# -n 15, CARGO_BUDGET_TEST_THREADS default 4) — the ledger gets a row for it
# and the wrapped process actually saw RUST_TEST_THREADS=4 (requirement 2).
fresh_env
paritycad_cargo_budget_env "$T"
export FAKE_SSH_NEXTEST_PRESENT=1
export BURST_LANE_FORCE_NEXTEST_LOCAL=1
"$BL" up >/dev/null
WT_PC5="$T/paritycad-repo5"; mkdir -p "$WT_PC5"
( cd "$WT_PC5" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
FAKEBIN_PC5="$T/fakebin-paritycad5"; mkdir -p "$FAKEBIN_PC5"
export PARITYCAD5_THREADS_SEEN="$T/paritycad5-threads-seen"
cat > "$FAKEBIN_PC5/cargo" <<'CARGOEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "nextest" ]; then
  shift
  sub="${1:-}"; shift || true
  case "$PWD" in
    "$BURST_LANE_REMOTE_ROOT"/*) side=box ;;
    *) side=local ;;
  esac
  if [ "$sub" = "list" ]; then
    echo '{"rust-suites": {"parity::a": {}}}'
    exit 0
  fi
  if [ "$sub" = "run" ]; then
    if [ "$side" = "local" ]; then
      echo "RUST_TEST_THREADS=${RUST_TEST_THREADS:-unset}" >> "$PARITYCAD5_THREADS_SEEN"
    fi
    echo "        PASS [   0.001s] (1/1) parity::a test_a"
    exit 0
  fi
fi
echo "fake-cargo(paritycad5): unhandled args: $*" >&2
exit 1
CARGOEOF
chmod +x "$FAKEBIN_PC5/cargo"
pc5_out="$(PATH="$FAKEBIN_PC5:$PATH" "$BL" parity "$WT_PC5" 2>&1)"; pc5_rc=$?
expect "paritycad AC5: parity exits 0" "[ $pc5_rc -eq 0 ]"
expect "paritycad AC5: cargo-budget ledger has at least one row for the local run" \
  "[ -s \"$CARGO_BUDGET_STATE_DIR/ledger.jsonl\" ]"
expect "paritycad AC5: the wrapped local run saw RUST_TEST_THREADS=4 (CARGO_BUDGET_TEST_THREADS default)" \
  "grep -q '^RUST_TEST_THREADS=4$' \"$PARITYCAD5_THREADS_SEEN\""

# ---- paritycad AC6 (P1): this fixture set exits 0 and names the
# paritycad cases — matching every sibling AC's own "does the suite name
# its own coverage" convention (parityr AC6, isolate AC6 above).
expect_block_green "paritycad" "paritycad AC6: every paritycad case above ran green"

# ---- isolate AC2 / requirement 3: the real top-level audit wrap (snapshot
# taken at the very top of this file) closes here — every fixture case in
# this ~2000-line suite ran against its own $T tmpdir, never the real
# live burst-lane state or journal. Skipped (not failed) when a real
# session was already up before this suite started — see the note at the
# snapshot site above.
audit_snapshot "$ISO_LIVE_STATE_DIR" "$ISO_LIVE_JOURNAL" > "$iso_audit_after"
iso_audit_out="$(audit_diff "$iso_audit_before" "$iso_audit_after" 2>&1)"; iso_audit_rc=$?
if [ "$iso_audit_live_session_pre" = "true" ]; then
  echo "ok  isolate AC2: skipped — a real burst-lane session was already active before this suite started (cannot distinguish its own legitimate activity from a leak by diffing alone)"
  [ $iso_audit_rc -eq 0 ] || echo "$iso_audit_out (informational only, not counted — pre-existing live session)" >&2
else
  expect "isolate AC2: the live burst-lane state/journal are unchanged after this whole suite ran" "[ $iso_audit_rc -eq 0 ]"
  [ $iso_audit_rc -eq 0 ] || echo "$iso_audit_out" >&2
fi
# =============================================================================
# ---- burstvol: PRD-build-burst-persistent-volume ---------------------------
# The build root ($REMOTE_ROOT) moves onto a Hetzner Cloud volume that `up`
# attaches/mounts and teardown detaches, so warm targets survive across boxes.
# Every pre-existing case above ran with BURST_VOLUME_NAME="" (fresh_env's
# default — the documented rollback), so none of them ever made an `hcloud
# volume` call; these cases opt back in explicitly.
# =============================================================================

# ---- burstvol AC1: no volume exists -> create, attach, format, mount -------
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
export FAKE_SSH_CALL_LOG="$T/ssh.calls"; : > "$FAKE_SSH_CALL_LOG"
bv1_out="$("$BL" up)"; bv1_rc=$?
block_start "burstvol"
expect "burstvol AC1: up exits 0" "[ $bv1_rc -eq 0 ]"
bv1_create_calls="$(grep -c 'volume create' "$FAKE_HCLOUD_CALLLOG")"
expect "burstvol AC1: exactly one volume create call" "[ \"$bv1_create_calls\" -eq 1 ]"
bv1_attach_calls="$(grep -c 'volume attach' "$FAKE_HCLOUD_CALLLOG")"
expect "burstvol AC1: exactly one volume attach call" "[ \"$bv1_attach_calls\" -eq 1 ]"
expect "burstvol AC1: the mount+format round trip ran as root" \
  "grep -P '^root@\\S+\\t.*# volume-mount' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
bv1_created_line="$(grep -n 'burst-lane  up  volume  created' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
bv1_attached_line="$(grep -n 'burst-lane  up  volume  attached' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
expect "burstvol AC1: journal has both a volume created and a volume attached line" \
  "[ -n \"$bv1_created_line\" ] && [ -n \"$bv1_attached_line\" ]"
expect "burstvol AC1: volume created precedes volume attached" \
  "[ -n \"$bv1_created_line\" ] && [ -n \"$bv1_attached_line\" ] && [ \"$bv1_created_line\" -lt \"$bv1_attached_line\" ]"

# ---- burstvol AC2: volume already exists with a filesystem label -> no ----
# format, no create call, journal has "attached" only.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
hcloud volume create --name wm-burst-build --size 500 >/dev/null 2>&1
export FAKE_SSH_VOLUME_LABEL_PRESENT=1
bv2_out="$("$BL" up)"; bv2_rc=$?
expect "burstvol AC2: up exits 0 against a pre-existing, already-formatted volume" "[ $bv2_rc -eq 0 ]"
bv2_create_calls="$(grep -c 'volume create' "$FAKE_HCLOUD_CALLLOG")"
expect "burstvol AC2: no volume create call during this up (only the pre-seed's own)" "[ \"$bv2_create_calls\" -eq 1 ]"
expect "burstvol AC2: journal has volume attached, never volume created" \
  "grep -q 'burst-lane  up  volume  attached' \"$BURST_LANE_JOURNAL\" && ! grep -q 'burst-lane  up  volume  created' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_VOLUME_LABEL_PRESENT

# ---- burstvol AC3: teardown order — sweep/sync/umount/detach/verify before -
# server delete; journal has "volume detached" before "down decision=deleted".
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
"$BL" up >/dev/null
bv3_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((bv3_boot_epoch + 3600 - 60))
bv3_down_out="$("$BL" down)"
unset BURST_LANE_NOW
expect "burstvol AC3: teardown still deletes cleanly with a volume attached" "[ \"$bv3_down_out\" = 'decision=deleted' ]"
bv3_detach_line="$(grep -n 'volume detach' "$FAKE_HCLOUD_CALLLOG" | head -1 | cut -d: -f1)"
bv3_delete_line="$(grep -n '^server delete' "$FAKE_HCLOUD_CALLLOG" | tail -1 | cut -d: -f1)"
expect "burstvol AC3: hcloud volume detach happens before server delete" \
  "[ -n \"$bv3_detach_line\" ] && [ -n \"$bv3_delete_line\" ] && [ \"$bv3_detach_line\" -lt \"$bv3_delete_line\" ]"
bv3_detached_j="$(grep -n 'burst-lane  down  volume  detached' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
bv3_deleted_j="$(grep -n 'burst-lane  down  decision=deleted' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
expect "burstvol AC3: journal has volume detached before down decision=deleted" \
  "[ -n \"$bv3_detached_j\" ] && [ -n \"$bv3_deleted_j\" ] && [ \"$bv3_detached_j\" -lt \"$bv3_deleted_j\" ]"

# ---- burstvol AC4: detach fails -> server still deletes, journal detach- --
# failed, volume_dirty=true, next up fscks before mounting.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
"$BL" up >/dev/null
export FAKE_HCLOUD_VOLUME_DETACH_FAIL=1
bv4_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((bv4_boot_epoch + 3600 - 60))
bv4_down_out="$("$BL" down)"
unset BURST_LANE_NOW FAKE_HCLOUD_VOLUME_DETACH_FAIL
expect "burstvol AC4: server still deletes even though detach failed" "[ \"$bv4_down_out\" = 'decision=deleted' ]"
expect "burstvol AC4: journal records volume detach-failed" "grep -q 'burst-lane  down  volume  detach-failed' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC4: volume state file marks volume_dirty=true" \
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/current/volume.json')); sys.exit(0 if d.get('volume_dirty')=='true' else 1)\""
export FAKE_SSH_VOLUME_FSCK_CALLLOG="$T/fsck.calls"; : > "$FAKE_SSH_VOLUME_FSCK_CALLLOG"
bv4b_up_out="$("$BL" up)"; bv4b_up_rc=$?
expect "burstvol AC4: the next up exits 0" "[ $bv4b_up_rc -eq 0 ]"
expect "burstvol AC4: the next up ran fsck before mounting (prior detach-failed)" "[ -s \"$FAKE_SSH_VOLUME_FSCK_CALLLOG\" ]"
unset FAKE_SSH_VOLUME_FSCK_CALLLOG

# ---- burstvol AC5: hcloud reports the volume attached to another server ---
# -> no attach attempted, "volume busy" journaled, session boots without it.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
hcloud volume create --name wm-burst-build --size 500 >/dev/null 2>&1
awk -F'|' -v OFS='|' '{$4="999999"; print}' "$FAKE_HCLOUD_VOLUME_STATE" > "$FAKE_HCLOUD_VOLUME_STATE.tmp" && mv "$FAKE_HCLOUD_VOLUME_STATE.tmp" "$FAKE_HCLOUD_VOLUME_STATE"
bv5_up_out="$("$BL" up)"; bv5_up_rc=$?
expect "burstvol AC5: up still exits 0 (boots without the volume)" "[ $bv5_up_rc -eq 0 ]"
expect "burstvol AC5: no volume attach call was attempted" "! grep -q 'volume attach' \"$FAKE_HCLOUD_CALLLOG\""
expect "burstvol AC5: journal names the server the volume is attached to" \
  "grep -q 'burst-lane  up  volume  busy  (attached_to=999999' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC5: volume state recorded volume_mounted=false" \
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/current/volume.json')); sys.exit(0 if d.get('volume_mounted')=='false' else 1)\""

# ---- burstvol AC6: disk fields (status --json) reflect the volume, not ----
# the root disk — a fake df reporting 41% used comes back as volume.used_pct.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
export FAKE_SSH_VOLUME_USED_PCT=41
"$BL" up >/dev/null
bv6_status_json="$("$BL" status --json)"
expect "burstvol AC6: status --json carries volume.used_pct from a live df read" \
  "grep -q '\"used_pct\":41' <<<\$bv6_status_json"
bv6_status_text="$("$BL" status)"
expect "burstvol AC6: status (text mode) shows volume=attached 41%" \
  "grep -q 'volume=attached 41%' <<<\$bv6_status_text"
unset FAKE_SSH_VOLUME_USED_PCT

# ---- burstvol AC7: warm attribution — a run against an empty remote target
# journals warm=false; a second run against the now-existing target journals
# warm=true, and the attribution ledger's row for it carries warm:true too.
fresh_env
WT_BV7="$T/warm-wt"; mkdir -p "$WT_BV7"
echo 'mkdir -p target && echo built > target/out.txt' > "$WT_BV7/build.sh"
bv7_run1_out="$("$BL" run "$WT_BV7" -- bash build.sh 2>&1)"; bv7_run1_rc=$?
expect "burstvol AC7: first run (empty remote target) exits 0" "[ $bv7_run1_rc -eq 0 ]"
expect "burstvol AC7: first run journaled warm=false" \
  "grep -q 'burst-lane  run  routed.*warm=false' \"$BURST_LANE_JOURNAL\""
bv7_run2_out="$("$BL" run "$WT_BV7" -- bash build.sh 2>&1)"; bv7_run2_rc=$?
expect "burstvol AC7: second run (target now exists) exits 0" "[ $bv7_run2_rc -eq 0 ]"
expect "burstvol AC7: second run journaled warm=true" \
  "grep -q 'burst-lane  run  routed.*warm=true' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC7: attribution.jsonl's second run row carries warm:true" \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$BURST_LANE_ATTR_LEDGER') if l.strip()]
runs = [r for r in rows if r.get('kind') == 'run' and r.get('worktree') == '$WT_BV7']
import sys
sys.exit(0 if len(runs) >= 2 and runs[-1].get('warm') is True else 1)
\""

# ---- burstvol AC8 (P1): the daily rollup carries volume_gb and a ----------
# cold_builds_avoided count, same two-`down`-calls pattern gatebox AC9 uses
# (the first down's own proration lands too late for maybe_daily_rollup to
# see it; the second, no-op down sees it and emits the real rollup line).
fresh_env
export BURST_VOLUME_NAME="wm-burst-build"
export BURST_VOLUME_GB=500
"$BL" up >/dev/null
WT_BV8="$T/rollup-wt"; mkdir -p "$WT_BV8"
echo 'mkdir -p target; exit 0' > "$WT_BV8/build.sh"
"$BL" run "$WT_BV8" -- bash build.sh >/dev/null 2>&1
bv8_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((bv8_boot_epoch + 3600 - 60))
"$BL" down >/dev/null
"$BL" down >/dev/null
unset BURST_LANE_NOW
bv8_today="$(date -u +%Y-%m-%d)"
bv8_rollup_line="$(grep '^burst-cost:' "$BURST_LANE_TICK_JOURNAL_DIR/$bv8_today.md" 2>/dev/null | tail -1)"
expect "burstvol AC8: daily rollup line carries volume_gb=500" "grep -q 'volume_gb=500' <<<\"$bv8_rollup_line\""
expect "burstvol AC8: daily rollup line carries a cold_builds_avoided count" \
  "grep -qE 'cold_builds_avoided=[0-9]+' <<<\"$bv8_rollup_line\""

# ---- burstvol AC9: the pull-back DESTINATION guard — a low-free-space -----
# RedBaron root defers the pull (marker stays dirty for a later retry)
# instead of starting an rsync it can't safely finish, using the larger of
# BURST_LOCAL_DISK_FLOOR_GB and this worktree's own last-observed pull size
# as the threshold (the PRD's own scenario: 20 GB free, an 87 GB last pull).
fresh_env
"$BL" up >/dev/null
WT_BV9="$T/localdisk-wt"; mkdir -p "$WT_BV9"
echo 'mkdir -p target && echo built > target/out.txt' > "$WT_BV9/build.sh"
"$BL" run "$WT_BV9" -- bash build.sh >/dev/null 2>&1
bv9_wkey="$(printf '%s' "$WT_BV9" | sha1sum | cut -c1-8)"
mkdir -p "$BURST_LANE_STATE_DIR/current/pull-sizes"
# 87 GB, exactly matching the PRD's own AC9 scenario and the real
# 2026-09-11 incident evidence (an 87 GB single gate pull).
printf '%s\n' "$((87 * 1073741824))" > "$BURST_LANE_STATE_DIR/current/pull-sizes/$bv9_wkey"
export BURST_LANE_LOCAL_FREE_GB=20
# PRD-build-burst-pull-back-restore AC12: this fixture is deliberately
# testing the STATIC floor/last-observed-size rule in isolation (an
# 87 GB fabricated history, no real remote payload to speak of) — force
# the new payload probe unavailable so it stays exactly what it always
# tested rather than being superseded by a probe reading this worktree's
# actual (tiny) fake-remote content. The probe's own success path gets
# its own dedicated coverage in the "pullback AC12" cases below.
bv9_pull_out="$(FAKE_SSH_PULL_PROBE_FAIL=1 "$BL" pull "$WT_BV9" 2>&1)"; bv9_pull_rc=$?
unset BURST_LANE_LOCAL_FREE_GB
expect "burstvol AC9: pull exits 0 (deferred, not an error)" "[ $bv9_pull_rc -eq 0 ]"
expect "burstvol AC9: journal records pull deferred cause=local-disk free_gb=20 need_gb=87" \
  "grep -q 'burst-lane  pull  deferred  (worktree=$WT_BV9 .*cause=local-disk free_gb=20 need_gb=87' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC9: the marker stays dirty (never cleared)" "dirty_has \"$WT_BV9\""
# PRD-build-burst-pull-back-restore requirement 2 / AC3c: a deferred pull
# transferred nothing — the caller must never see the "pulled" string that
# AC1's real-transfer case gets, even though (per the pinned rc==0 check
# just above) the exit code stays 0 for this deliberately-skipped outcome.
expect "burstpull AC3c: deferred pull's stdout never claims 'pulled'" "[ \"$bv9_pull_out\" != pulled ]"

# ---- pullback AC3 (PRD-build-burst-pull-back-restore): after the floor is
# restored, the SAME worktree's marker (left dirty by the deferral just
# above — never touched, never re-run) transfers on the very next pull.
# BURST_LANE_LOCAL_FREE_GB is already unset (line above), so this pull sees
# the real underlying filesystem's free space, which vastly exceeds the 87
# GB need_gb computed from this worktree's own last-observed pull size —
# the same real-disk headroom that made AC1's own retry-free case above
# transfer cleanly.
bv9_retry_out="$("$BL" pull "$WT_BV9" 2>&1)"; bv9_retry_rc=$?
expect "pullback AC3: retry after the floor is restored exits 0 and prints pulled" \
  "[ $bv9_retry_rc -eq 0 ] && [ \"$bv9_retry_out\" = pulled ]"
expect "pullback AC3: retry fetched target/ back" "[ -f \"$WT_BV9/target/out.txt\" ]"
expect "pullback AC3: retry cleared the dirty marker" "! dirty_has \"$WT_BV9\""

# ---- pullback AC5 (PRD-build-burst-pull-back-restore): an explicit pull's
# underlying rsync-down genuinely fails (box up, remote dir exists,
# do_marker_pull's own real-failure branch — described in its header
# comment but never fixture-proven before this PRD; see
# tests/pullback_ac5_rsync_failure_exit.sh's own documented gap). Distinct
# from every deferred/cold outcome above (all pinned exit 0 by design): a
# real transfer failure must leave the marker dirty for a later retry,
# exit non-zero, and journal the cause.
fresh_env
"$BL" up >/dev/null
WT_AC5PULL="$T/worktree-pullback-ac5"; mkdir -p "$WT_AC5PULL"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_AC5PULL/build.sh"
"$BL" run "$WT_AC5PULL" -- bash build.sh >/dev/null 2>&1
expect "pullback AC5 setup: run left the worktree dirty" "dirty_has \"$WT_AC5PULL\""
ac5pull_out="$(FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=11 FAKE_RSYNC_FAIL_MSG='rsync: fake pull-down failure' \
  "$BL" pull "$WT_AC5PULL" 2>&1)"; ac5pull_rc=$?
expect "pullback AC5: pull exits non-zero on a real rsync-down failure" "[ $ac5pull_rc -ne 0 ]"
expect "pullback AC5: stdout reports the fallback, never claims 'pulled'" \
  "[ \"$ac5pull_out\" = 'fallback: pull failed' ]"
expect "pullback AC5: the marker is left dirty for a later retry" "dirty_has \"$WT_AC5PULL\""
expect "pullback AC5: journal names the rsync failure cause" \
  "grep -q 'burst-lane  pull  fallback  (cause=rsync-failed' \"$BURST_LANE_JOURNAL\""
# PRD-build-burst-pull-remote-target-missing requirement 2: the fallback
# line now carries rc/err/attempts/next_retry_s BETWEEN cause= and
# worktree= (Migration/compatibility: cause=rsync-failed itself stays
# first, for exactly this kind of older grep) — proven as its own case
# rather than folded into the line above, so a future regression here
# fails with a label naming which half broke.
expect "pullmiss: pullback AC5's failure carries rc/err/attempts/next_retry_s too" \
  "grep -qF 'burst-lane  pull  fallback  (cause=rsync-failed rc=11 err=\"rsync: fake pull-down failure\" attempts=1 next_retry_s=30 worktree=$WT_AC5PULL trigger=explicit' \"$BURST_LANE_JOURNAL\""

# ---- pullback AC12 (PRD-build-burst-pull-back-restore, Joe's 2026-09-13
# decision): need_gb follows a bounded remote payload probe when it
# succeeds, and falls back to the existing floor/last-observed rule,
# UNCHANGED, when the probe fails or times out. Both cases run against the
# SAME 60 GB floor (overridden inline from this suite's own default of 2)
# with free space pinned low enough that a deferral — and the need_gb/rule
# fields on its journal line — always fires, so the computed value itself
# is proven, not just its side effect.
fresh_env
"$BL" up >/dev/null
WT_AC12A="$T/worktree-pullback-ac12a"; mkdir -p "$WT_AC12A"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_AC12A/build.sh"
"$BL" run "$WT_AC12A" -- bash build.sh >/dev/null 2>&1
# 3 GB payload, probe succeeds -> need_gb = 2*3 = 6 (well under the 60 GB
# floor); free space pinned at 5 GB (< 6) so the deferral fires on the
# PAYLOAD number, not the floor.
ac12a_out="$(FAKE_SSH_PULL_PROBE_BYTES=$((3 * 1073741824)) BURST_LANE_LOCAL_FREE_GB=5 BURST_LOCAL_DISK_FLOOR_GB=60 \
  "$BL" pull "$WT_AC12A" 2>&1)"; ac12a_rc=$?
expect "pullback AC12: probe-succeeding pull exits 0 (deferred, not an error)" "[ $ac12a_rc -eq 0 ]"
expect "pullback AC12: a 3 GB payload probe sets need_gb=6, naming the payload rule" \
  "grep -qF 'burst-lane  pull  deferred  (worktree=$WT_AC12A trigger=explicit cause=local-disk free_gb=5 need_gb=6 rule=payload)' \"$BURST_LANE_JOURNAL\""

WT_AC12B="$T/worktree-pullback-ac12b"; mkdir -p "$WT_AC12B"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT_AC12B/build.sh"
"$BL" run "$WT_AC12B" -- bash build.sh >/dev/null 2>&1
# Probe times out (the fake sleeps 30s; this fixture's own bound is 1s) ->
# need_gb stays the unchanged 60 GB floor; free space pinned at 10 GB
# (< 60) so the same deferral path fires on the FLOOR number instead.
ac12b_out="$(FAKE_SSH_PULL_PROBE_HANG=1 BURST_PULL_PROBE_TIMEOUT_S=1 BURST_LANE_LOCAL_FREE_GB=10 BURST_LOCAL_DISK_FLOOR_GB=60 \
  "$BL" pull "$WT_AC12B" 2>&1)"; ac12b_rc=$?
expect "pullback AC12: probe-timeout pull exits 0 (deferred, not an error)" "[ $ac12b_rc -eq 0 ]"
expect "pullback AC12: a timed-out probe leaves need_gb=60, naming the floor rule" \
  "grep -qF 'burst-lane  pull  deferred  (worktree=$WT_AC12B trigger=explicit cause=local-disk free_gb=10 need_gb=60 rule=floor)' \"$BURST_LANE_JOURNAL\""

# ---- burstvol AC10: a dirty marker under a moved root (byte-identical to --
# the 2026-09-11 user-migration evidence: a marker still naming /root/build
# after $REMOTE_ROOT moved) is treated as cold on read, cleared, and NEVER
# retried as rsync-failed — checked before any ssh round trip.
fresh_env
"$BL" up >/dev/null
WT_BV10="$T/rootmove-wt"; mkdir -p "$WT_BV10"
bv10_wkey="$(printf '%s' "$WT_BV10" | sha1sum | cut -c1-8)"
mkdir -p "$BURST_LANE_STATE_DIR/current/dirty"
python3 -c "
import json
json.dump(
    {'worktree': '$WT_BV10', 'session_id': 'stale-session', 'kind': 'target',
     'remote_path': '/root/build/rootmove-wt-$bv10_wkey', 'marked_ts': '2026-01-01T00:00:00Z'},
    open('$BURST_LANE_STATE_DIR/current/dirty/$bv10_wkey.json', 'w'))
"
bv10_pull_out="$("$BL" pull "$WT_BV10" 2>&1)"; bv10_pull_rc=$?
expect "burstvol AC10: pull against a marker under a moved root exits 0 (cold, not an error)" "[ $bv10_pull_rc -eq 0 ]"
expect "burstvol AC10: journal records pull cold cause=remote-path-missing" \
  "grep -q 'burst-lane  pull  cold  (worktree=$WT_BV10 .*cause=remote-path-missing' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC10: never journaled as rsync-failed for this worktree" \
  "! grep -q \"burst-lane  pull  fallback  (cause=rsync-failed worktree=$WT_BV10\" \"$BURST_LANE_JOURNAL\""
expect "burstvol AC10: the stale marker was cleared" "[ ! -e \"$BURST_LANE_STATE_DIR/current/dirty/$bv10_wkey.json\" ]"
# PRD-build-burst-pull-back-restore requirement 2 / AC2: same distinction as
# AC3c above — a cold outcome clears the marker and stays exit-0 (pinned
# just above), but must never echo "pulled" alongside it.
expect "burstpull AC2: cold pull's stdout never claims 'pulled'" "[ \"$bv10_pull_out\" != pulled ]"

# ---- burstpull AC3b (PRD-build-burst-pull-back-restore): the OTHER cold
# cause — no active session at all (session.json absent), as opposed to
# AC10's live-session-but-moved-root cause=remote-path-missing above. Same
# do_marker_pull branch family (state_active check, cause=no-active-session),
# exercised directly via explicit `pull` with no `up` ever called, so there
# is no session.json for state_active to find.
fresh_env
WT_BV3B="$T/no-session-wt"; mkdir -p "$WT_BV3B/target"
bv3b_wkey="$(printf '%s' "$WT_BV3B" | sha1sum | cut -c1-8)"
mkdir -p "$BURST_LANE_STATE_DIR/current/dirty"
python3 -c "
import json
json.dump(
    {'worktree': '$WT_BV3B', 'session_id': 'dead-session', 'kind': 'target',
     'remote_path': '/root/build/no-session-wt-$bv3b_wkey', 'marked_ts': '2026-01-01T00:00:00Z'},
    open('$BURST_LANE_STATE_DIR/current/dirty/$bv3b_wkey.json', 'w'))
"
bv3b_pull_out="$("$BL" pull "$WT_BV3B" 2>&1)"; bv3b_pull_rc=$?
expect "burstpull AC3b: pull with no active session exits 0 (cold, not an error)" "[ $bv3b_pull_rc -eq 0 ]"
expect "burstpull AC3b: pull's stdout never claims 'pulled' when nothing transferred" "[ \"$bv3b_pull_out\" != pulled ]"
expect "burstpull AC3b: journal records pull cold cause=no-active-session" \
  "grep -q 'burst-lane  pull  cold  (worktree=$WT_BV3B .*cause=no-active-session' \"$BURST_LANE_JOURNAL\""
expect "burstpull AC3b: the stale marker was cleared" "[ ! -e \"$BURST_LANE_STATE_DIR/current/dirty/$bv3b_wkey.json\" ]"

# ---- burstvol AC11: this fixture set exits 0 and names the burstvol cases -
# (an explicit, in-band assertion, matching every sibling AC's own
# convention — see burstuser AC7/parityr AC6 above).
expect_block_green "burstvol" "burstvol AC11: every burstvol case above ran green"
# ============================================================================
# PRD-build-burst-path-deps: a remote run syncs everything the crate needs to
# build. Four cases: a fixture crate with a sibling path dependency actually
# resolves on the (fake) box (AC1); a genuinely-missing path dependency
# journals a build-failed line with phase=build instead of masquerading as
# a test failure (AC2); `verify` asserts CARGO_HOME is a writable-by-build
# registry outside /root, both the happy path and the fail-closed path
# (AC3); the gate-tools probe's PATH carries no root fallback, so a tool
# only root can see is not silently treated as present (AC4). AC5 (a real
# Hetzner box + a green wintermute-brain HEAD) needs real infra this
# offline harness cannot provide — left for the live lane, not simulated
# here. AC6 (this suite exits 0 and names its own pathdeps cases) is the
# closing assertion at the bottom of this block, same convention as every
# sibling PRD's own closing AC.
# ============================================================================

# ---- pathdeps AC1: given a fixture crate depending on ../sibling by path,
# when `run` executes against the fake box, both directories are rsynced
# and `cargo metadata` genuinely resolves the dependency — not just
# `--no-deps`, which (proven against a real cargo while building this PRD)
# never validates a path dependency actually exists at all; only the full
# resolve graph does, and that is what production's own `cargo build`/
# `cargo test` invocations exercise too.
fresh_env
"$BL" up >/dev/null 2>&1
PD_ROOT="$T/pathdeps-root"
mkdir -p "$PD_ROOT/main-crate/src" "$PD_ROOT/sibling/src"
cat > "$PD_ROOT/main-crate/Cargo.toml" <<EOF
[package]
name = "pathdeps-main"
version = "0.1.0"
edition = "2021"

[dependencies]
sibling = { path = "../sibling" }
EOF
echo 'fn main() {}' > "$PD_ROOT/main-crate/src/main.rs"
cat > "$PD_ROOT/sibling/Cargo.toml" <<EOF
[package]
name = "sibling"
version = "0.1.0"
edition = "2021"
EOF
echo '' > "$PD_ROOT/sibling/src/lib.rs"
WT_PD1="$PD_ROOT/main-crate"
export FAKE_RSYNC_CALL_LOG="$T/rsync.calls.pd1"; : > "$FAKE_RSYNC_CALL_LOG"
pd1_out="$("$BL" run "$WT_PD1" -- cargo metadata --format-version 1 2>&1)"; pd1_rc=$?
block_start "pathdeps"
expect "pathdeps AC1: run against a crate with a sibling path dep exits 0" "[ $pd1_rc -eq 0 ]"
expect "pathdeps AC1: the worktree itself was rsynced" "grep -qF \"$WT_PD1/\" \"$FAKE_RSYNC_CALL_LOG\""
expect "pathdeps AC1: the sibling path dependency was also rsynced" "grep -qF \"$PD_ROOT/sibling/\" \"$FAKE_RSYNC_CALL_LOG\""
expect "pathdeps AC1: cargo metadata really resolved the dependency (no 'failed to load source' error)" \
  "! grep -qi 'failed to load source\|failed to read' <<<\"$pd1_out\""
expect "pathdeps AC1: journal names exactly one synced dependency" \
  "grep -qF \"pathdeps  (worktree=$WT_PD1 deps=1\" \"$BURST_LANE_JOURNAL\""

# ---- pathdeps AC2: a path dependency that genuinely does not exist (never
# synced — nothing for `run` to sync) makes the remote `cargo metadata`
# fail exactly as it does today; the journal must name it a BUILD failure,
# not a test failure, and no exit=101/phase=test row should exist for it.
fresh_env
"$BL" up >/dev/null 2>&1
PD2_ROOT="$T/pathdeps-broken"
mkdir -p "$PD2_ROOT/main-crate/src"
cat > "$PD2_ROOT/main-crate/Cargo.toml" <<EOF
[package]
name = "pathdeps-broken-main"
version = "0.1.0"
edition = "2021"

[dependencies]
missing-sibling = { path = "../missing-sibling" }
EOF
echo 'fn main() {}' > "$PD2_ROOT/main-crate/src/main.rs"
WT_PD2="$PD2_ROOT/main-crate"
pd2_out="$("$BL" run "$WT_PD2" -- cargo metadata --format-version 1 2>&1)"; pd2_rc=$?
expect "pathdeps AC2: run against a crate with a missing path dep exits nonzero" "[ $pd2_rc -ne 0 ]"
expect "pathdeps AC2: journal has a build-failed line naming the cause" \
  "grep -qF \"run  build-failed  (worktree=$WT_PD2\" \"$BURST_LANE_JOURNAL\""
expect "pathdeps AC2: no exit=101 phase=test row was written for this failure" \
  "! grep -E \"run  routed .*worktree=$WT_PD2.*phase=test\" \"$BURST_LANE_JOURNAL\""
pd2_attr_rc=1
python3 -c "
import json
path = '$BURST_LANE_ATTR_LEDGER'
try:
    rows = [json.loads(l) for l in open(path) if l.strip()]
except FileNotFoundError:
    rows = []
ok = any(r.get('worktree') == '$WT_PD2' and r.get('kind') == 'run' and r.get('phase') == 'build' for r in rows)
raise SystemExit(0 if ok else 1)
" && pd2_attr_rc=0
expect "pathdeps AC2: attribution ledger row for this run carries phase=build" "[ $pd2_attr_rc -eq 0 ]"

# ---- pathdeps AC3: `verify` asserts CARGO_HOME resolves to a writable-by-
# build registry outside /root — both the happy path (fresh_env's default
# build user, real mkdir/touch/rm probe over the fake ssh) and the
# fail-closed path (a simulated non-writable registry).
fresh_env
"$BL" up >/dev/null 2>&1
pd3_verify_out="$("$BL" verify 2>&1)"; pd3_verify_rc=$?
expect "pathdeps AC3: verify exits 0 when the build user's registry is writable" "[ $pd3_verify_rc -eq 0 ]"
expect "pathdeps AC3: verify reports cargo-home ok, naming the build-home path" \
  "grep -q 'cargo-home ok' <<<\"$pd3_verify_out\" && grep -qF \"$BURST_LANE_REMOTE_HOME/.cargo\" <<<\"$pd3_verify_out\""
export FAKE_SSH_REGISTRY_WRITE_FAIL=1
pd3_neg_out="$("$BL" verify 2>&1)"; pd3_neg_rc=$?
expect "pathdeps AC3: verify fails closed when the registry is not writable" "[ $pd3_neg_rc -ne 0 ]"
expect "pathdeps AC3: the failure names the CARGO_HOME/registry path" \
  "grep -q 'CARGO_HOME registry not writable' <<<\"$pd3_neg_out\""
unset FAKE_SSH_REGISTRY_WRITE_FAIL

# ---- pathdeps AC4: the gate-tools probe's PATH carries no root fallback
# for the build user — a tool only root could see must read MISSING, not
# silently pass, and this is checked against the REAL command sent over
# ssh (not the fake's canned tool-inventory reply, which never actually
# reads PATH) so a regression in the constructed PATH string itself is
# what this test catches.
fresh_env
export FAKE_SSH_CALL_LOG="$T/ssh.calls.pd4"; : > "$FAKE_SSH_CALL_LOG"
"$BL" up >/dev/null 2>&1
pd4_full_line="$(grep '# gate-tools-probe' "$FAKE_SSH_CALL_LOG" | head -n1)"
# Isolate just the "user@host<TAB>" prefix and the actual `export PATH=...`
# assignment — the rest of the flattened multi-line probe command is this
# file's own explanatory comment text (deliberately containing an escaped,
# never-expanded literal like \$GATE_TOOLS_REMOTE_BIN_DIR so it reads
# inertly on the remote side), and embedding THAT raw text into a second
# eval'd string below would let it be mistaken for a real, unset variable
# reference on re-parse. Narrowing to just these two pieces sidesteps that
# entirely rather than fighting it with more quoting.
pd4_user_prefix="$(cut -f1 <<<"$pd4_full_line")"
pd4_path_line="$(grep -oE 'export PATH=[^;]*' <<<"$pd4_full_line" | head -n1)"
expect "pathdeps AC4: the gate-tools probe ran as build@" "[[ \$pd4_user_prefix == build@* ]]"
expect "pathdeps AC4: the probe's own PATH export carries no /root reference" \
  "[ -n \"\$pd4_path_line\" ] && [[ \$pd4_path_line != *root* ]]"
pd4_gt_pattern='export PATH=$GATE_TOOLS_REMOTE_BIN_DIR:\$PATH$gt_probe_extra'
expect "pathdeps AC4 (structural): gate_tools_probe's PATH export is now conditional on REMOTE_USER, not unconditionally including root's paths" \
  "grep -qF \"\$pd4_gt_pattern\" \"\$BL\""

# ---- pathdeps AC6 (P1): this fixture set exits 0 and names the pathdeps
# cases — same in-band closing assertion every sibling PRD's own block ends
# with (see burstuser AC7 / parityr AC6 just above).
expect_block_green "pathdeps" "pathdeps AC6: every pathdeps case above ran green"

# ============================================================================
# PRD-build-burst-path-deps-workspaces (test_prefix: pathws): the 2026-09-11
# autobuilder incident — a cargo WORKSPACE's own members (crates/x) got
# treated as ordinary external path deps and mirrored a second time under
# deps/, colliding in the lockfile; the mirror then had no local worktree of
# its own name, so `reap` deleted it out from under the very next run. Five
# cases: a workspace member's siblings arrive via ONE workspace-root sync,
# never a second deps/ copy (AC1); an external sibling OUTSIDE the workspace
# is still mirrored under deps/ and recorded in the lane-owned directory
# manifest with its owner worktree (AC2); `reap` keeps that mirror while its
# owner exists and removes it with reason=owner-gone once the owner is gone,
# never blindly deleting the whole deps/ container (AC3); a worktree stuck at
# three identical consecutive build failures is refused a fourth remote
# attempt entirely (no rsync, no ssh, no cargo) until its HEAD changes (AC4).
# AC5 (a real casper/autobuilder repo building green) needs real infra this
# offline harness cannot provide. AC6 is the closing assertion below.
# ============================================================================

# ---- pathws AC1: a workspace member's own in-workspace sibling arrives via
# ONE sync of the whole workspace root — never a second, colliding deps/
# mirror. `run` is invoked against member "a"'s own subdirectory (not the
# workspace root itself), proving the general worktree-is-a-member-
# subdirectory shape, not just "the worktree happens to equal the root".
fresh_env
"$BL" up >/dev/null 2>&1
WS1_ROOT="$T/pathws-ws1"
mkdir -p "$WS1_ROOT/a/src" "$WS1_ROOT/b/src"
cat > "$WS1_ROOT/Cargo.toml" <<EOF
[workspace]
members = ["a", "b"]
resolver = "2"
EOF
cat > "$WS1_ROOT/a/Cargo.toml" <<EOF
[package]
name = "pathws-a"
version = "0.1.0"
edition = "2021"

[dependencies]
pathws-b = { path = "../b" }
EOF
echo 'fn main() {}' > "$WS1_ROOT/a/src/main.rs"
cat > "$WS1_ROOT/b/Cargo.toml" <<EOF
[package]
name = "pathws-b"
version = "0.1.0"
edition = "2021"
EOF
echo '' > "$WS1_ROOT/b/src/lib.rs"
WT_WS1A="$WS1_ROOT/a"
export FAKE_RSYNC_CALL_LOG="$T/rsync.calls.ws1"; : > "$FAKE_RSYNC_CALL_LOG"
ws1_out="$("$BL" run "$WT_WS1A" -- cargo metadata --format-version 1 2>&1)"; ws1_rc=$?
block_start "pathws"
expect "pathws AC1: run against a workspace member exits 0" "[ $ws1_rc -eq 0 ]"
expect "pathws AC1: cargo metadata really resolved the in-workspace sibling" \
  "! grep -qi 'failed to load source\|failed to read' <<<\"$ws1_out\""
expect "pathws AC1: the WHOLE workspace root was synced as one tree" \
  "awk -F'\t' -v s=\"$WS1_ROOT/\" '\$1==s{f=1} END{exit !f}' \"$FAKE_RSYNC_CALL_LOG\""
expect "pathws AC1: the member subdirectory was never synced as its own separate source" \
  "! awk -F'\t' -v s=\"$WT_WS1A/\" '\$1==s{f=1} END{exit !f}' \"$FAKE_RSYNC_CALL_LOG\""
expect "pathws AC1: no deps/ mirror was created for the in-workspace sibling" \
  "[ ! -d \"$BURST_LANE_REMOTE_ROOT/deps\" ]"
expect "pathws AC1: no pathdeps journal line was written (nothing external to mirror)" \
  "! grep -q \"pathdeps  (worktree=$WT_WS1A\" \"$BURST_LANE_JOURNAL\""

# ---- pathws AC2: the SAME workspace member also depends on a sibling
# OUTSIDE the workspace entirely — that one is still mirrored under deps/
# exactly as a non-workspace path dep would be, and recorded in the
# lane-owned directory manifest ($STATE_DIR/remote-dirs.json) with owner =
# "a"'s own worktree path (the crate that actually declared the dependency).
fresh_env
"$BL" up >/dev/null 2>&1
WS2_ROOT="$T/pathws-ws2"
mkdir -p "$WS2_ROOT/a/src" "$WS2_ROOT/b/src"
EXT2_ROOT="$T/pathws-ext2"
mkdir -p "$EXT2_ROOT/c/src"
cat > "$WS2_ROOT/Cargo.toml" <<EOF
[workspace]
members = ["a", "b"]
resolver = "2"
EOF
cat > "$WS2_ROOT/a/Cargo.toml" <<EOF
[package]
name = "pathws2-a"
version = "0.1.0"
edition = "2021"

[dependencies]
pathws2-b = { path = "../b" }
pathws2-c = { path = "../../pathws-ext2/c" }
EOF
echo 'fn main() {}' > "$WS2_ROOT/a/src/main.rs"
cat > "$WS2_ROOT/b/Cargo.toml" <<EOF
[package]
name = "pathws2-b"
version = "0.1.0"
edition = "2021"
EOF
echo '' > "$WS2_ROOT/b/src/lib.rs"
cat > "$EXT2_ROOT/c/Cargo.toml" <<EOF
[package]
name = "pathws2-c"
version = "0.1.0"
edition = "2021"
EOF
echo '' > "$EXT2_ROOT/c/src/lib.rs"
WT_WS2A="$WS2_ROOT/a"
ws2_out="$("$BL" run "$WT_WS2A" -- cargo metadata --format-version 1 2>&1)"; ws2_rc=$?
expect "pathws AC2: run against a workspace member with an external sibling exits 0" "[ $ws2_rc -eq 0 ]"
expect "pathws AC2: cargo metadata resolved both the in-workspace and external siblings" \
  "! grep -qi 'failed to load source\|failed to read' <<<\"$ws2_out\""
expect "pathws AC2: the external sibling WAS mirrored under deps/" \
  "[ -d \"$BURST_LANE_REMOTE_ROOT/deps\" ] && find \"$BURST_LANE_REMOTE_ROOT/deps\" -maxdepth 1 -type d -name 'c-*' | grep -q ."
ws2_manifest_rc=1
python3 -c "
import json
try:
    d = json.load(open('$BURST_LANE_STATE_DIR/current/remote-dirs.json'))
except Exception:
    d = {}
ok = any(k.startswith('deps/c-') and v.get('owner') == '$WT_WS2A' for k, v in d.items())
raise SystemExit(0 if ok else 1)
" && ws2_manifest_rc=0
expect "pathws AC2: remote-dirs.json records the mirror with owner = a's own worktree" "[ $ws2_manifest_rc -eq 0 ]"

# ---- pathws AC3: `reap` keeps a deps/ mirror while its recorded owner
# worktree still exists locally, and removes ONLY that mirror (never the
# deps/ container itself, never guessing from the unhashed "deps" name) once
# the owner is gone — the direct fix for the incident's own journal line
# `reap  ok  (dir=deps reason=legacy-no-local-match)`.
fresh_env
"$BL" up >/dev/null 2>&1
WS3_ROOT="$T/pathws-ws3"
mkdir -p "$WS3_ROOT/a/src"
EXT3_ROOT="$T/pathws-ext3"
mkdir -p "$EXT3_ROOT/c/src"
cat > "$WS3_ROOT/Cargo.toml" <<EOF
[workspace]
members = ["a"]
resolver = "2"
EOF
cat > "$WS3_ROOT/a/Cargo.toml" <<EOF
[package]
name = "pathws3-a"
version = "0.1.0"
edition = "2021"

[dependencies]
pathws3-c = { path = "../../pathws-ext3/c" }
EOF
echo 'fn main() {}' > "$WS3_ROOT/a/src/main.rs"
cat > "$EXT3_ROOT/c/Cargo.toml" <<EOF
[package]
name = "pathws3-c"
version = "0.1.0"
edition = "2021"
EOF
echo '' > "$EXT3_ROOT/c/src/lib.rs"
WT_WS3A="$WS3_ROOT/a"
"$BL" run "$WT_WS3A" -- cargo metadata --format-version 1 >/dev/null 2>&1
ws3_dep_dir="$(find "$BURST_LANE_REMOTE_ROOT/deps" -maxdepth 1 -type d -name 'c-*' | head -n1)"
expect "pathws AC3: setup — the external sibling mirror exists before reap" "[ -n \"$ws3_dep_dir\" ] && [ -d \"$ws3_dep_dir\" ]"
: > "$BURST_LANE_JOURNAL"
reap3a_out="$("$BL" reap 2>&1)"
expect "pathws AC3: reap keeps the mirror while its owner worktree still exists" "[ -d \"$ws3_dep_dir\" ]"
expect "pathws AC3: reap journaled no removal for the still-owned mirror" \
  "! grep -qF \"reap  ok  (dir=deps/$(basename "$ws3_dep_dir")\" \"$BURST_LANE_JOURNAL\""
rm -rf "$WT_WS3A"
: > "$BURST_LANE_JOURNAL"
reap3b_out="$("$BL" reap 2>&1)"
expect "pathws AC3: reap removes the mirror once its owner worktree is gone" "[ ! -d \"$ws3_dep_dir\" ]"
expect "pathws AC3: reap journals reason=owner-gone (never the bare deps/ container)" \
  "grep -qE 'reap  ok  \\(dir=deps/[^ ]+ bytes=[0-9]+ reason=owner-gone\\)' \"$BURST_LANE_JOURNAL\""

# ---- pathws AC4: three consecutive identical build-failed causes on one
# worktree's HEAD refuse a fourth remote attempt outright (no rsync, no ssh,
# no cargo) — the loop-burning defect the TL;DR's five-cycle casper journal
# names — and a new HEAD lets attempts resume.
fresh_env
"$BL" up >/dev/null 2>&1
PW4_ROOT="$T/pathws-broken"
mkdir -p "$PW4_ROOT/main-crate/src"
cat > "$PW4_ROOT/main-crate/Cargo.toml" <<EOF
[package]
name = "pathws4-main"
version = "0.1.0"
edition = "2021"

[dependencies]
missing-sibling = { path = "../missing-sibling" }
EOF
echo 'fn main() {}' > "$PW4_ROOT/main-crate/src/main.rs"
WT_PW4="$PW4_ROOT/main-crate"
export BURST_LANE_FAKE_HEAD="pathws4headA"
export FAKE_SSH_CALL_LOG="$T/ssh.calls.pw4"; : > "$FAKE_SSH_CALL_LOG"
"$BL" run "$WT_PW4" -- cargo metadata --format-version 1 >/dev/null 2>&1
"$BL" run "$WT_PW4" -- cargo metadata --format-version 1 >/dev/null 2>&1
"$BL" run "$WT_PW4" -- cargo metadata --format-version 1 >/dev/null 2>&1
pw4_calls_before="$(wc -l < "$FAKE_SSH_CALL_LOG")"
pw4_4th_out="$("$BL" run "$WT_PW4" -- cargo metadata --format-version 1 2>&1)"; pw4_4th_rc=$?
pw4_calls_after="$(wc -l < "$FAKE_SSH_CALL_LOG")"
expect "pathws AC4: the 4th attempt at an unchanged HEAD is refused (exit 3)" "[ $pw4_4th_rc -eq 3 ]"
# pw4_4th_out carries the real cargo error text as its stored "cause" (it
# rides through unchanged into the refusal message) — parens/backticks/
# quotes from a real compiler error are NOT safe to re-embed into another
# eval'd condition string, so the check runs directly here (never through
# expect's own eval) and only a plain, already-boolean result crosses that
# boundary. Same for the AC4 new-HEAD check below.
pw4_repeated_rc=1; grep -qi 'repeated' <<<"$pw4_4th_out" && pw4_repeated_rc=0
expect "pathws AC4: the refusal names it as repeated" "[ $pw4_repeated_rc -eq 0 ]"
expect "pathws AC4: journal names n=3 and the worktree" \
  "grep -qF \"build-failed  repeated  (n=3\" \"$BURST_LANE_JOURNAL\" && grep -qF \"worktree=$WT_PW4\" \"$BURST_LANE_JOURNAL\""
expect "pathws AC4: the 4th attempt made no ssh call at all (no cargo ever ran)" "[ \"$pw4_calls_after\" -eq \"$pw4_calls_before\" ]"
export BURST_LANE_FAKE_HEAD="pathws4headB"
pw4_5th_out="$("$BL" run "$WT_PW4" -- cargo metadata --format-version 1 2>&1)"; pw4_5th_rc=$?
pw4_5th_ok_rc=1
if [ "$pw4_5th_rc" -ne 3 ]; then
  pw4_5th_ok_rc=0
elif ! grep -qi 'repeated' <<<"$pw4_5th_out"; then
  pw4_5th_ok_rc=0
fi
expect "pathws AC4: a new HEAD lets attempts resume (not the repeated refusal)" "[ $pw4_5th_ok_rc -eq 0 ]"
expect "pathws AC4: the resumed attempt actually reached the box" \
  "grep -qF \"run  build-failed  (worktree=$WT_PW4\" \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_FAKE_HEAD

# ---- pathws AC6 (P1): this fixture set exits 0 and names its own pathws
# cases — same in-band closing assertion every sibling PRD's own block ends
# with (see pathdeps AC6 just above).
expect_block_green "pathws" "pathws AC6: every pathws case above ran green"

# ==============================================================================
# ---- bursthyg: PRD-build-burst-session-hygiene ------------------------------
# ==============================================================================
# Three defects from the 2026-09-13 04:44Z instrumented real-box run: (1) a
# reused Hetzner IP with a stale GLOBAL ~/.ssh/known_hosts entry hard-failed
# every burst ssh/rsync; (2) `down` kept a provision-failed, zero-runs box
# because a repo parity diff looked like remaining rust work; (3) `status`
# kept reporting active:true (and volume.json kept claiming a mount) after
# an out-of-band `hcloud server/volume delete`. Every case below is a
# fixture-only proof of option-wiring/state-transitions (AC8, the real-box
# proof, is deferred — see this PRD's own frontmatter).

# ---- bursthyg AC1/AC2: every ssh/rsync call carries THIS session's
# UserKnownHostsFile + StrictHostKeyChecking=accept-new, never
# ~/.ssh/known_hosts — proven even with a stale GLOBAL known_hosts-shaped
# file sitting on disk (the 2026-09-13 reused-IP incident), since
# burst-lane.sh never names that path at all.
fresh_env
export FAKE_SSH_KH_LOG="$T/ssh-kh.log"; : > "$FAKE_SSH_KH_LOG"
export FAKE_RSYNC_KH_LOG="$T/rsync-kh.log"; : > "$FAKE_RSYNC_KH_LOG"
# A fixture stand-in for a stale, mismatching GLOBAL ~/.ssh/known_hosts —
# scoped under $T (this suite must never touch the real one). Its content
# is the fake ssh/rsync's own "changed host key" sentinel (see both
# fixtures' AC2/AC6 comment): if burst-lane.sh ever pointed a call at this
# path, that call would fail with rc=255, "REMOTE HOST IDENTIFICATION HAS
# CHANGED!" — exactly like the real 2026-09-13 incident.
HYG_STALE_GLOBAL_KH="$T/fake-global-known_hosts"
echo "STALE-HOST-KEY" > "$HYG_STALE_GLOBAL_KH"
hyg1_out="$("$BL" up)"; hyg1_rc=$?
block_start "bursthyg"
expect "bursthyg AC2: up succeeds despite a stale GLOBAL known_hosts-shaped file existing on disk" "[ $hyg1_rc -eq 0 ]"
hyg1_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
hyg1_khfile="$BURST_LANE_STATE_DIR/current/known_hosts.$hyg1_sid"
expect "bursthyg AC1: a session known_hosts file was created, keyed by session_id" "[ -f \"$hyg1_khfile\" ]"
# Round-trip a run+pull too, so the rsync log is exercised, not just ssh.
HYG_WT="$T/hyg-wt"; mkdir -p "$HYG_WT"
echo 'mkdir -p target && echo built > target/out.txt' > "$HYG_WT/build.sh"
"$BL" run "$HYG_WT" -- bash build.sh >/dev/null 2>&1
"$BL" pull "$HYG_WT" >/dev/null 2>&1
expect "bursthyg AC1: at least one ssh call was logged" "[ -s \"$FAKE_SSH_KH_LOG\" ]"
expect "bursthyg AC1: at least one rsync call was logged" "[ -s \"$FAKE_RSYNC_KH_LOG\" ]"
expect "bursthyg AC1: every ssh call carries this session's UserKnownHostsFile" \
  "! grep -qvF \"UserKnownHostsFile=$hyg1_khfile\" \"$FAKE_SSH_KH_LOG\""
expect "bursthyg AC1: every ssh call carries StrictHostKeyChecking=accept-new" \
  "! grep -qv 'StrictHostKeyChecking=accept-new' \"$FAKE_SSH_KH_LOG\""
expect "bursthyg AC1: every rsync call also carries this session's UserKnownHostsFile" \
  "! grep -qvF \"UserKnownHostsFile=$hyg1_khfile\" \"$FAKE_RSYNC_KH_LOG\""
expect "bursthyg AC1: every rsync call also carries StrictHostKeyChecking=accept-new" \
  "! grep -qv 'StrictHostKeyChecking=accept-new' \"$FAKE_RSYNC_KH_LOG\""
expect "bursthyg AC1: no ssh call ever names a real-shaped ~/.ssh/known_hosts path" \
  "! grep -q '\.ssh/known_hosts' \"$FAKE_SSH_KH_LOG\""
expect "bursthyg AC1: no ssh call ever names this test's stale-global fixture file" \
  "! grep -qF \"$HYG_STALE_GLOBAL_KH\" \"$FAKE_SSH_KH_LOG\" \"$FAKE_RSYNC_KH_LOG\""

# ---- bursthyg AC2 negative case (prd-lint's selftest-no-negative-case
# convention): the STALE-HOST-KEY sentinel really does fail a call when a
# UserKnownHostsFile actually IS the poisoned one — proving the fixture
# models the real defect, not just an inert grep target the happy-path case
# above could pass by accident.
hyg2_neg_out="$(ssh -o UserKnownHostsFile="$HYG_STALE_GLOBAL_KH" -o StrictHostKeyChecking=accept-new -i /dev/null root@127.0.0.1 true 2>&1)"; hyg2_neg_rc=$?
expect "bursthyg AC2 (negative case): the fixture itself fails against a genuinely poisoned known_hosts file" "[ $hyg2_neg_rc -eq 255 ]"
expect "bursthyg AC2 (negative case): failure names the real ssh wording" "grep -qi 'REMOTE HOST IDENTIFICATION HAS CHANGED' <<<\"$hyg2_neg_out\""

# ---- bursthyg AC3: up reconciles session.json against hcloud reality ------
fresh_env
"$BL" up >/dev/null 2>&1
hyg3_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
# PRD-build-burst-state-keyed-by-server-v2: capture the OLD box's real
# directory before the reconciling `up` below — session_reconcile()
# archives session.json.stale-* INSIDE the box it found stale (box A),
# then this same `up` call creates a NEW box and box_activate() repoints
# `current` at it (box B). Checking via `current` AFTER that call looks
# in box B's directory, where the stale file never was — it has to be
# checked in box A's own directory, resolved now while `current` still
# points there.
hyg3_old_box_dir="$(readlink -f "$BURST_LANE_STATE_DIR/current")"
hcloud server delete "$hyg3_sid" >/dev/null 2>&1   # out-of-band delete, the 2026-09-13 incident
hyg3_out="$("$BL" up)"; hyg3_rc=$?
expect "bursthyg AC3: up succeeds after reconciling an absent server" "[ $hyg3_rc -eq 0 ]"
expect "bursthyg AC3: up reports a genuinely NEW box, not an adoption" "grep -q '^up: ' <<<\"$hyg3_out\""
expect "bursthyg AC3: the stale session.json was archived (not silently deleted)" \
  "ls \"$hyg3_old_box_dir\"/session.json.stale-* >/dev/null 2>&1"
hyg3_new_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
expect "bursthyg AC3: the new session has a different server_id than the absent one" "[ \"$hyg3_new_sid\" != \"$hyg3_sid\" ]"
expect "bursthyg AC3: journal recorded the stale-session reconcile" "grep -q 'burst-lane  session  stale' \"$BURST_LANE_JOURNAL\""

# ---- bursthyg AC4: down's cost-safe keep rule ------------------------------
# rust-work-remains (a repo-parity-diff-shaped signal) may not keep a box
# that never proved itself: gate_ready defaults false on this dev host's own
# real autobuilder check (see the pre-existing AC8 block's sed-patch,
# earlier in this file) and runs_served defaults 0 on a box that never
# served a `run` — this session is "unproven" by construction.
fresh_env
"$BL" up >/dev/null 2>&1
hyg4_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-hyg.md" <<'EOF'
# PRD — fake-rust-hyg

- Status: queued
- build_target: rust-extend
EOF
hyg4_out="$("$BL" down)"
expect "bursthyg AC4: down deletes an unproven box despite rust-work-remains" "[ \"$hyg4_out\" = 'decision=deleted' ]"
expect "bursthyg AC4: journal names the cause as unproven-box" \
  "grep -q 'burst-lane  down  decision=deleted.*cause=unproven-box' \"$BURST_LANE_JOURNAL\""
expect "bursthyg AC4: session.json is gone" "[ ! -f \"$BURST_LANE_STATE_DIR/current/session.json\" ]"
expect "bursthyg AC4: the fake hcloud confirms the server is actually gone" "! hcloud server describe \"$hyg4_sid\" -o json >/dev/null 2>&1"
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-hyg.md"

# ---- bursthyg AC5: down --force --------------------------------------------
fresh_env
"$BL" up >/dev/null 2>&1
hyg5a_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
hyg5a_kh="$BURST_LANE_STATE_DIR/current/known_hosts.$hyg5a_sid"
expect "bursthyg AC5 setup: session known_hosts file exists before force" "[ -f \"$hyg5a_kh\" ]"
hyg5a_out="$("$BL" down --force)"; hyg5a_rc=$?
expect "bursthyg AC5: down --force exits 0 against a live box" "[ $hyg5a_rc -eq 0 ]"
expect "bursthyg AC5: down --force reports force-deleted" "[ \"$hyg5a_out\" = 'decision=force-deleted' ]"
expect "bursthyg AC5: down --force actually deleted the fake server" "! hcloud server describe \"$hyg5a_sid\" -o json >/dev/null 2>&1"
expect "bursthyg AC5: session.json is removed" "[ ! -f \"$BURST_LANE_STATE_DIR/current/session.json\" ]"
expect "bursthyg AC5: the session known_hosts file is removed" "[ ! -f \"$hyg5a_kh\" ]"

# AC5's own literal scenario: session state naming a server that's ALREADY
# gone (an operator's raw hcloud delete, or a crashed prior force call).
"$BL" up >/dev/null 2>&1
hyg5b_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
hyg5b_kh="$BURST_LANE_STATE_DIR/current/known_hosts.$hyg5b_sid"
hcloud server delete "$hyg5b_sid" >/dev/null 2>&1
hyg5b_out="$("$BL" down --force)"; hyg5b_rc=$?
expect "bursthyg AC5: down --force exits 0 even when the server is already gone" "[ $hyg5b_rc -eq 0 ]"
expect "bursthyg AC5: down --force still reports force-deleted for an already-gone server" "[ \"$hyg5b_out\" = 'decision=force-deleted' ]"
expect "bursthyg AC5: session.json is still removed" "[ ! -f \"$BURST_LANE_STATE_DIR/current/session.json\" ]"
expect "bursthyg AC5: the session known_hosts file is still removed" "[ ! -f \"$hyg5b_kh\" ]"

# down --force with NO session at all must also stay rc=0 (nothing to do).
hyg5c_out="$("$BL" down --force)"; hyg5c_rc=$?
expect "bursthyg AC5: down --force exits 0 with no active session at all" "[ $hyg5c_rc -eq 0 ]"

# ---- bursthyg AC6: status --json reconciles the session's server ----------
fresh_env
"$BL" up >/dev/null 2>&1
hyg6_pos_json="$("$BL" status --json)"
# Computed OUTSIDE expect's own eval — a JSON blob's embedded quotes/braces
# is exactly the kind of content that corrupts an eval'd condition string
# if interpolated directly into one (the pw4_repeated_rc pattern earlier in
# this file uses the same guard, for the same reason).
hyg6_pos_rc=1
grep -q '"active":true' <<<"$hyg6_pos_json" && grep -q '"server_verified":true' <<<"$hyg6_pos_json" && hyg6_pos_rc=0
expect "bursthyg AC6: a live, hcloud-confirmed session reports active:true + server_verified:true" "[ $hyg6_pos_rc -eq 0 ]"
hyg6_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
hcloud server delete "$hyg6_sid" >/dev/null 2>&1
hyg6_json="$("$BL" status --json)"; hyg6_rc=$?
expect "bursthyg AC6: status --json exits 0 even when the tracked server is gone" "[ $hyg6_rc -eq 0 ]"
hyg6_active_rc=1; grep -q '"active":false' <<<"$hyg6_json" && hyg6_active_rc=0
hyg6_verified_rc=1; grep -q '"server_verified":false' <<<"$hyg6_json" && hyg6_verified_rc=0
expect "bursthyg AC6: status reports active:false" "[ $hyg6_active_rc -eq 0 ]"
expect "bursthyg AC6: status reports server_verified:false" "[ $hyg6_verified_rc -eq 0 ]"
expect "bursthyg AC6: session.json was archived" "ls \"$BURST_LANE_STATE_DIR/current\"/session.json.stale-* >/dev/null 2>&1"

# ---- bursthyg AC7: volume.json gets the same reconcile treatment ----------
fresh_env
export BURST_VOLUME_NAME="wm-burst-build-hyg"
"$BL" up >/dev/null 2>&1
hyg7_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
expect "bursthyg AC7 setup: volume.json recorded a volume_id after up" "[ -n \"$hyg7_vid\" ]"
# Out-of-band volume delete (2026-09-13: volume 106857883) — the fake hcloud
# has no `volume delete` verb of its own, so drop the line directly; same
# end state ("hcloud reports it absent") a real delete leaves.
sed -i "/^$hyg7_vid|/d" "$FAKE_HCLOUD_VOLUME_STATE"
hyg7_json="$("$BL" status --json)"; hyg7_rc=$?
expect "bursthyg AC7: status --json exits 0 even when the tracked volume is gone" "[ $hyg7_rc -eq 0 ]"
hyg7_verified_rc=1; grep -q '"volume_verified":false' <<<"$hyg7_json" && hyg7_verified_rc=0
expect "bursthyg AC7: status reports volume_verified:false" "[ $hyg7_verified_rc -eq 0 ]"
expect "bursthyg AC7: volume.json was archived" "ls \"$BURST_LANE_STATE_DIR/current\"/volume.json.stale-* >/dev/null 2>&1"

# `up` reconciles the volume too — even down the already-up fast path, which
# returns before volume_ensure ever runs, so this is the only way an
# operator calling `up` against a still-alive box learns the volume died. A
# fresh session (not the already-archived one above) so this volume.json
# starts real and unarchived.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build-hyg3"
"$BL" up >/dev/null 2>&1
hyg7b_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
expect "bursthyg AC7b setup: volume.json recorded a volume_id after up" "[ -n \"$hyg7b_vid\" ]"
sed -i "/^$hyg7b_vid|/d" "$FAKE_HCLOUD_VOLUME_STATE"
"$BL" up >/dev/null 2>&1   # session still alive -> already-up fast path
expect "bursthyg AC7: up (already-up fast path) also archives a volume.json whose volume hcloud reports absent" \
  "ls \"$BURST_LANE_STATE_DIR/current\"/volume.json.stale-* >/dev/null 2>&1"

# ---- bursthyg AC9 (P1 style closer): this fixture set exits 0 and names
# its own bursthyg cases — same in-band closing assertion every sibling
# PRD's own block ends with (see pathws AC6 just above). AC8 (a real-box
# up -> provision -> down cycle) is deferred — see this PRD's own
# deferred_acs/mock_justifications frontmatter.
expect_block_green "bursthyg" "bursthyg: every bursthyg case above ran green"

# ==============================================================================
# ---- bursttdl: PRD-build-burst-teardown-lifecycle ---------------------------
# ==============================================================================
# The 2026-09-13 real-box run: `up` scheduled a backgrounded parity check,
# something called `down` 8 minutes after boot (before `provision` even
# started), and the prior PRD's own cost-safe unproven-box rule ("unproven"
# reads identically whether a box failed or is simply still mid-setup)
# deleted it. This block proves the fix: a `phase=setup` session is
# protected from every AUTONOMOUS teardown caller (watchdog, idle-guard)
# until BURST_SETUP_GRACE_MIN minutes pass or `provision` moves it out of
# setup one way or the other; an explicit `down` still bypasses the grace
# unconditionally (never against a human choosing to stop spending); and a
# cold, never-used persistent volume no longer survives a teardown that
# ends the lane's activity. AC8 (a real Hetzner box proving `up` survives to
# serve a `provision` 5+ minutes later) is deferred — see this PRD's own
# frontmatter; no real box is authorized at build time.

# ---- bursttdl AC1: setup-grace blocks watchdog + idle-guard ----------------
fresh_env
"$BL" up >/dev/null 2>&1
btdl1_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl1_boot="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
block_start "bursttdl"
expect "bursttdl AC1 setup: a fresh session starts phase=setup" \
  "grep -q '\"phase\":\"setup\"' \"$BURST_LANE_STATE_DIR/current/session.json\""

# Force watchdog's OWN due-check to fire immediately (ttl_hours=0) while
# staying well inside the default 30-minute setup-grace window (5 minutes
# in) — isolates "would watchdog otherwise delete this" from "does grace
# block it".
sed -i 's/"ttl_hours":[0-9]*/"ttl_hours":0/' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((btdl1_boot + 300))
btdl1_wd_rc=0; "$BL" watchdog >/dev/null 2>&1 || btdl1_wd_rc=$?
expect "bursttdl AC1: watchdog exits 0 on a deferred (not deleted, not leaked) teardown" "[ $btdl1_wd_rc -eq 0 ]"
expect "bursttdl AC1: watchdog does not delete a phase=setup box inside its grace window" \
  "hcloud server describe \"$btdl1_sid\" -o json >/dev/null 2>&1"
expect "bursttdl AC1: watchdog journals teardown-deferred with cause=setup-grace and a remaining= countdown" \
  "grep -qE 'burst-lane  watchdog  teardown-deferred  \\(cause=setup-grace remaining=[0-9]+s server_id='\"$btdl1_sid\"'\\)' \"$BURST_LANE_JOURNAL\""

# idle-guard: runs_served=0 by construction (no run yet), so its own
# zero-runs threshold (900s default) has passed at +1000s, but grace
# (1800s default) has not.
export BURST_LANE_NOW=$((btdl1_boot + 1000))
btdl1_ig_rc=0; "$BL" idle-guard >/dev/null 2>&1 || btdl1_ig_rc=$?
expect "bursttdl AC1: idle-guard exits 0 on a deferred teardown" "[ $btdl1_ig_rc -eq 0 ]"
expect "bursttdl AC1: idle-guard does not delete a phase=setup box inside its grace window" \
  "hcloud server describe \"$btdl1_sid\" -o json >/dev/null 2>&1"
expect "bursttdl AC1: idle-guard journals teardown-deferred with cause=setup-grace" \
  "grep -qE 'burst-lane  idle-guard  teardown-deferred  \\(cause=setup-grace remaining=[0-9]+s server_id='\"$btdl1_sid\"'\\)' \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_NOW

# Migration/compatibility: a session.json with no "phase" key at all (a
# session started before this PRD shipped) reads as phase=provisioned —
# no grace, existing behavior unaffected.
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/current/session.json"
expect "bursttdl AC1 migration setup: the session file now has no phase field at all" \
  "! grep -q '\"phase\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
export BURST_LANE_NOW=$((btdl1_boot + 60))   # 1 minute in — deep inside any grace window
btdl1_legacy_rc=0; "$BL" watchdog >/dev/null 2>&1 || btdl1_legacy_rc=$?
expect "bursttdl AC1 migration: a legacy session with no phase field is NOT grace-protected (reads as already-provisioned)" \
  "! hcloud server describe \"$btdl1_sid\" -o json >/dev/null 2>&1"
unset BURST_LANE_NOW

# ---- bursttdl AC2: an explicit `down` bypasses grace unconditionally ------
fresh_env
"$BL" up >/dev/null 2>&1
btdl2_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
expect "bursttdl AC2 setup: the session is phase=setup, well inside the grace window" \
  "grep -q '\"phase\":\"setup\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
# Route `down` through the SAME immediate-delete path bursthyg AC4 already
# proves (a queued rust PRD -> rust-work-remains -> the unproven-box check,
# gate_ready=false/runs_served=0 by construction on a box this fresh) —
# this is "down" the caller tag, which must ignore phase=setup entirely.
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-tdl.md" <<'EOF'
# PRD — fake-rust-tdl

- Status: queued
- build_target: rust-extend
EOF
btdl2_out="$("$BL" down)"
expect "bursttdl AC2: an operator's down deletes a phase=setup box immediately" "[ \"$btdl2_out\" = 'decision=deleted' ]"
expect "bursttdl AC2: the fake hcloud confirms the server is actually gone" "! hcloud server describe \"$btdl2_sid\" -o json >/dev/null 2>&1"
expect "bursttdl AC2: no teardown-deferred line was ever journaled for this session" \
  "! grep -q \"teardown-deferred.*server_id=$btdl2_sid\" \"$BURST_LANE_JOURNAL\""
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-tdl.md"

# ---- bursttdl AC3: grace expiry is not a leak ------------------------------
fresh_env
"$BL" up >/dev/null 2>&1
btdl3_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl3_boot="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
sed -i 's/"ttl_hours":[0-9]*/"ttl_hours":0/' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((btdl3_boot + 1801))   # one second past the default 30-minute grace
"$BL" watchdog >/dev/null 2>&1
expect "bursttdl AC3: an autonomous caller deletes once grace has expired" \
  "! hcloud server describe \"$btdl3_sid\" -o json >/dev/null 2>&1"
expect "bursttdl AC3: the deletion is journaled with cause=setup-grace-expired" \
  "grep -q 'burst-lane  watchdog  teardown.*cause=setup-grace-expired' \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_NOW

# ---- bursttdl AC4: provision moves the session out of phase=setup ---------
fresh_env
"$BL" up >/dev/null 2>&1
btdl4a_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
"$BL" provision >/dev/null 2>&1   # default fixture: gate tools all present -> success
expect "bursttdl AC4: a successful provision moves phase to provisioned" \
  "grep -q '\"phase\":\"provisioned\"' \"$BURST_LANE_STATE_DIR/current/session.json\""

fresh_env
# Same deterministic gate_ready=false setup gatetools AC2/AC3 use: missing +
# install-fail together, so no self-heal retry inside `provision` can
# accidentally turn this into a success (a bare FAKE_SSH_GATE_TOOLS_MISSING
# alone is a transient, retry-recoverable defect — provision_gate_tools()
# retrying the install is exactly its own documented job).
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null 2>&1
btdl4b_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl4b_boot="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl4b_prov_rc=0; "$BL" provision >/dev/null 2>&1 || btdl4b_prov_rc=$?
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL
expect "bursttdl AC4: a failed provision exits non-zero" "[ $btdl4b_prov_rc -ne 0 ]"
expect "bursttdl AC4: a failed provision moves phase to failed" \
  "grep -q '\"phase\":\"failed\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
sed -i 's/"ttl_hours":[0-9]*/"ttl_hours":0/' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((btdl4b_boot + 60))   # 1 minute in — deep inside any grace window
"$BL" watchdog >/dev/null 2>&1
expect "bursttdl AC4: a phase=failed box is deleted by the very next autonomous caller, without waiting out any grace" \
  "! hcloud server describe \"$btdl4b_sid\" -o json >/dev/null 2>&1"
unset BURST_LANE_NOW

# ---- bursttdl AC5: parity reports its diff and never tears down -----------
# Requirement 4: `cmd_up`'s backgrounded parity call (`schedule_session_parity`)
# must only ever report a diff — teardown decisions belong to down/watchdog/
# idle-guard alone. A real (empty, single-commit) git repo under
# BURST_PARITY_REPOS' default name ("mcphost") makes `up` actually schedule
# and run cmd_parity end-to-end against the fake ssh/rsync, instead of the
# "not-a-repo" schedule-skip every other case in this file exercises.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost"
( cd "$BURST_LANE_REPOS_DIR/mcphost" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
"$BL" up >/dev/null 2>&1
btdl5_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
# The parity call was backgrounded (disowned) by `up` — poll its own journal
# for a terminal line rather than assuming any fixed sleep is long enough.
btdl5_seen=0
for _ in $(seq 1 40); do
  grep -qE 'burst-lane  parity  (ok|diff|fallback)' "$BURST_LANE_JOURNAL" 2>/dev/null && { btdl5_seen=1; break; }
  sleep 0.5
done
expect "bursttdl AC5 setup: the backgrounded parity call actually ran to a terminal outcome" "[ $btdl5_seen -eq 1 ]"
expect "bursttdl AC5: parity reports its diff (ok/diff/fallback), never a deletion, from the up-scheduled path" \
  "grep -qE 'burst-lane  parity  (ok|diff|fallback)' \"$BURST_LANE_JOURNAL\""
expect "bursttdl AC5: no decision=deleted line was ever journaled for this session" \
  "! grep -q \"decision=deleted.*server_id=$btdl5_sid\" \"$BURST_LANE_JOURNAL\""
expect "bursttdl AC5: the box is still alive after its own scheduled parity check completed" \
  "hcloud server describe \"$btdl5_sid\" -o json >/dev/null 2>&1"
expect "bursttdl AC5 (negative-case guard): cmd_parity's own source contains no teardown_and_delete/cmd_down call at all" \
  "! sed -n '/^cmd_parity()/,/^gate_inflight_marker_file()/p' \"$BL\" | grep -qE 'teardown_and_delete|cmd_down\\b'"

# ---- bursttdl AC6: cold-volume policy on the teardown that ends the lane ---
# No rust work is queued here at all, so `down`'s decision routes through
# its own deterministic "no rust work -> last two minutes of the billed
# hour" scheduled-window path (same BURST_LANE_NOW-at-window_start technique
# bursthyg/burst-lane-lane-ccx53's own AC8 tests already use) rather than the
# gate_ready-dependent unproven-box branch — gate_ready's own value here
# depends on comparing this dev machine's REAL locally-installed
# `autobuilder` against the fixture's stubbed remote version, which is not
# something this block should have to pin down just to prove what
# volume_teardown() does once a box is actually going away.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build-tdl6a"
export FAKE_SSH_VOLUME_USED_PCT=1
"$BL" up >/dev/null 2>&1
btdl6a_boot="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl6a_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
export BURST_LANE_NOW=$((btdl6a_boot + 3600 - 60))
"$BL" down >/dev/null 2>&1
unset BURST_LANE_NOW
expect "bursttdl AC6: a cold (1% used, never-served) volume is deleted at the lane-ending teardown" \
  "! hcloud volume describe \"$btdl6a_vid\" -o json >/dev/null 2>&1"
expect "bursttdl AC6: the deletion is journaled with the volume's id and used_pct" \
  "grep -qE \"burst-lane  down  volume  deleted  \\(id=$btdl6a_vid used_pct=1\" \"$BURST_LANE_JOURNAL\""

export BURST_VOLUME_NAME="wm-burst-build-tdl6b"
export FAKE_SSH_VOLUME_USED_PCT=40
"$BL" up >/dev/null 2>&1
btdl6b_boot="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl6b_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
BTDL6_WT="$T/tdl6-wt"; mkdir -p "$BTDL6_WT"; echo 'echo hi' > "$BTDL6_WT/build.sh"
"$BL" run "$BTDL6_WT" -- bash build.sh >/dev/null 2>&1
export BURST_LANE_NOW=$((btdl6b_boot + 3600 - 60))
"$BL" down >/dev/null 2>&1
unset BURST_LANE_NOW
expect "bursttdl AC6: a warm (40% used, has served a build) volume is kept, not deleted" \
  "hcloud volume describe \"$btdl6b_vid\" -o json >/dev/null 2>&1"
expect "bursttdl AC6: the keep decision is journaled as volume-kept (used_pct=40)" \
  "grep -q 'burst-lane  down  volume-kept  (used_pct=40)' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_VOLUME_USED_PCT

# ---- bursttdl AC7: an orphan sweep finds a volume with no session pointer -
# Simulates the out-of-band server delete from this PRD's own TL;DR: the
# session pointer (session.json) is gone, but the volume is still real in
# hcloud, findable only by name — never by a session/volume_id this suite
# deliberately drops here.
fresh_env
export BURST_VOLUME_NAME="wm-burst-build-tdl7"
export FAKE_SSH_VOLUME_USED_PCT=1
"$BL" up >/dev/null 2>&1
btdl7_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl7_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
hcloud server delete "$btdl7_sid" >/dev/null 2>&1
rm -f "$BURST_LANE_STATE_DIR/current/session.json"
expect "bursttdl AC7 setup: the volume is still real in hcloud after the out-of-band server delete" \
  "hcloud volume describe \"$btdl7_vid\" -o json >/dev/null 2>&1"
btdl7_out="$("$BL" reap --volumes)"
expect "bursttdl AC7: reap --volumes reports one volume reaped" "[ \"$btdl7_out\" = 'volumes-reaped=1' ]"
expect "bursttdl AC7: the volume is located by name and deleted despite no session pointer" \
  "! hcloud volume describe \"$btdl7_vid\" -o json >/dev/null 2>&1"
expect "bursttdl AC7: the deletion is journaled with id and used_pct" \
  "grep -qE \"burst-lane  reap  volume-deleted  \\(id=$btdl7_vid used_pct=1\" \"$BURST_LANE_JOURNAL\""

# `down --force` does the same sweep (requirement 6's other half).
export BURST_VOLUME_NAME="wm-burst-build-tdl7b"
export FAKE_SSH_VOLUME_USED_PCT=1
"$BL" up >/dev/null 2>&1
btdl7b_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
btdl7b_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
hcloud server delete "$btdl7b_sid" >/dev/null 2>&1
rm -f "$BURST_LANE_STATE_DIR/current/session.json"
"$BL" down --force >/dev/null 2>&1
expect "bursttdl AC7: down --force also locates and deletes a stranded volume with no session pointer" \
  "! hcloud volume describe \"$btdl7b_vid\" -o json >/dev/null 2>&1"
unset FAKE_SSH_VOLUME_USED_PCT

# ---- bursttdl AC8 (P1, deferred — see this PRD's own frontmatter): no real
# Hetzner box is authorized at build time to prove `up` survives to serve a
# `provision` 5+ minutes later on real infrastructure.

# ---- bursttdl AC9 (P1 style closer): this fixture set exits 0 and names
# its own bursttdl cases — same in-band closing assertion every sibling
# PRD's own block ends with (see bursthyg AC9 just above).
expect_block_green "bursttdl" "bursttdl: every bursttdl case above ran green"

# ---- volidfix: PRD-build-burst-volume-id-parse ----------------------------
# A created volume is tracked or unwound, never abandoned. The bug: `up`
# merged stderr progress text into the JSON parse target (`2>&1`), so the
# parser silently failed, journaled a false volume-create-failed, and left
# a real, billing, orphaned volume behind (5 hand-deleted on 2026-09-13).

# ---- volidfix AC1: clean stdout-only create -> id parsed correctly -------
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix1"
vf1_out="$("$BL" up)"; vf1_rc=$?
vf1_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" 2>/dev/null | grep -oE '[0-9]+')"
block_start "volidfix"
expect "volidfix AC1: up exits 0 against a clean create" "[ $vf1_rc -eq 0 ]"
expect "volidfix AC1: volume.json recorded the parsed id" "[ -n \"$vf1_vid\" ]"
expect "volidfix AC1: no volume-create-failed line was journaled" \
  "! grep -q 'volume-create-failed' \"$BURST_LANE_JOURNAL\""

# ---- volidfix AC2: stderr carries action-progress text, stdout stays -----
# clean JSON -> the id is still parsed correctly (the exact shape that
# broke before this fix: `2>&1` would have merged this progress text into
# the parse target).
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix2"
export FAKE_HCLOUD_VOLUME_CREATE_STDERR_NOISE=1
vf2_out="$("$BL" up)"; vf2_rc=$?
vf2_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" 2>/dev/null | grep -oE '[0-9]+')"
expect "volidfix AC2: up exits 0 when create emits stderr progress noise" "[ $vf2_rc -eq 0 ]"
expect "volidfix AC2: the id is parsed correctly from stdout alone" "[ -n \"$vf2_vid\" ]"
expect "volidfix AC2: no volume-create-failed line was journaled despite stderr noise" \
  "! grep -q 'volume-create-failed' \"$BURST_LANE_JOURNAL\""
unset FAKE_HCLOUD_VOLUME_CREATE_STDERR_NOISE

# ---- volidfix AC3/AC4: create exits 0 but the response can't be read -----
# back -> the volume (real, server-side) is located by name and deleted;
# volume-create-unwound is journaled (never volume-create-failed — the
# create itself succeeded); the fake hcloud ends with zero volumes for
# this name and the lane boots on the root disk.
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix34"
export FAKE_HCLOUD_VOLUME_CREATE_GARBLED=1
vf34_out="$("$BL" up)"; vf34_rc=$?
expect "volidfix AC3/4: up still exits 0, booting on root disk" "[ $vf34_rc -eq 0 ]"
expect "volidfix AC3: volume-create-unwound is journaled with name, id, and cause" \
  "grep -qE 'burst-lane  up  volume-create-unwound  \\(name=wm-burst-volidfix34 id=[0-9]+ cause=could-not-parse-id\\)' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC3: volume-create-failed is never journaled for this case" \
  "! grep -q 'volume-create-failed' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC4: the fake hcloud holds zero volumes for this name afterward" \
  "! hcloud volume describe \"$BURST_VOLUME_NAME\" -o json >/dev/null 2>&1"
expect "volidfix AC4: volume.json records volume_mounted=false (booted on root disk)" \
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/current/volume.json')); sys.exit(0 if d.get('volume_mounted')=='false' else 1)\""
unset FAKE_HCLOUD_VOLUME_CREATE_GARBLED

# ---- volidfix AC5: create itself exits non-zero -> honest journal grammar
# volume-create-failed is journaled (nothing was ever made); no delete is
# attempted and volume-create-unwound never fires for a genuinely failed
# create.
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix5"
export FAKE_HCLOUD_VOLUME_CREATE_FAIL=1
vf5_out="$("$BL" up)"; vf5_rc=$?
expect "volidfix AC5: up still exits 0 (boots on root disk) when create itself fails" "[ $vf5_rc -eq 0 ]"
expect "volidfix AC5: volume-create-failed is journaled" \
  "grep -q 'burst-lane  up  volume-create-failed' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC5: no volume delete call was attempted (nothing was created)" \
  "! grep -q 'volume delete' \"$FAKE_HCLOUD_CALLLOG\""
expect "volidfix AC5: volume-create-unwound is never journaled for a failed create" \
  "! grep -q 'volume-create-unwound' \"$BURST_LANE_JOURNAL\""
unset FAKE_HCLOUD_VOLUME_CREATE_FAIL

# ---- volidfix AC6: name-based orphan sweep reports id, size, and age -----
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix6"
export FAKE_SSH_VOLUME_USED_PCT=7
"$BL" up >/dev/null 2>&1
vf6_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
vf6_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
hcloud server delete "$vf6_sid" >/dev/null 2>&1
rm -f "$BURST_LANE_STATE_DIR/current/session.json"
# Backdate the fixture's own "created" field 3 hours so age_h is provably
# non-zero, without touching any other field.
vf6_created3h="$(date -u -d "@$(( $(date -u +%s) - 10800 ))" +%Y-%m-%dT%H:%M:%SZ)"
awk -F'|' -v OFS='|' -v vid="$vf6_vid" -v created="$vf6_created3h" \
  '$1==vid{$6=created} {print}' "$FAKE_HCLOUD_VOLUME_STATE" > "$FAKE_HCLOUD_VOLUME_STATE.tmp" && mv "$FAKE_HCLOUD_VOLUME_STATE.tmp" "$FAKE_HCLOUD_VOLUME_STATE"
vf6_out="$("$BL" reap --volumes)"
expect "volidfix AC6: reap --volumes reports one volume reaped" "[ \"$vf6_out\" = 'volumes-reaped=1' ]"
expect "volidfix AC6: the deletion is journaled with id, size, and a non-zero age" \
  "grep -qE \"burst-lane  reap  volume-deleted  \\(id=$vf6_vid used_pct=7 size=500G age_h=[1-9][0-9]*\" \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_VOLUME_USED_PCT

# ---- volidfix AC7: a volume attached to a live server is left alone -----
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix7"
"$BL" up >/dev/null 2>&1
vf7_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
vf7_out="$("$BL" reap --volumes)"
expect "volidfix AC7: reap --volumes leaves an attached, live volume alone" "[ \"$vf7_out\" = 'volumes-reaped=0' ]"
expect "volidfix AC7: no volume-deleted line was journaled for the attached volume" \
  "! grep -q 'burst-lane  reap  volume-deleted' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC7: the volume still exists in hcloud afterward" \
  "hcloud volume describe \"$vf7_vid\" -o json >/dev/null 2>&1"

# ---- volidfix AC8: startup guard — unattached volume present at start ---
# Case a: size already matches BURST_VOLUME_GB -> adopted, no new create.
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix8a"
hcloud volume create --name "$BURST_VOLUME_NAME" --size 500 >/dev/null 2>&1
vf8a_pre_vid="$(awk -F'|' -v n="$BURST_VOLUME_NAME" '$2==n{print $1}' "$FAKE_HCLOUD_VOLUME_STATE" | head -1)"
vf8a_out="$("$BL" up)"; vf8a_rc=$?
vf8a_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
expect "volidfix AC8a: up exits 0 and adopts a pre-existing same-size volume" "[ $vf8a_rc -eq 0 ]"
expect "volidfix AC8a: the adopted volume is the pre-existing one, not a new create" \
  "[ \"$vf8a_vid\" = \"$vf8a_pre_vid\" ]"
expect "volidfix AC8a: no volume create call happened during up (only the pre-seed's own)" \
  "[ \"$(grep -c 'volume create' "$FAKE_HCLOUD_CALLLOG")\" -eq 1 ]"
expect "volidfix AC8a: journal names the adoption" \
  "grep -q 'burst-lane  up  volume  adopted' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC8a: exactly one volume exists for this name afterward" \
  "[ \"$(grep -cF "|$BURST_VOLUME_NAME|" "$FAKE_HCLOUD_VOLUME_STATE")\" -eq 1 ]"

# Case b: size does NOT match BURST_VOLUME_GB -> deleted, then created fresh.
fresh_env
export BURST_VOLUME_NAME="wm-burst-volidfix8b"
hcloud volume create --name "$BURST_VOLUME_NAME" --size 100 >/dev/null 2>&1
vf8b_pre_vid="$(awk -F'|' -v n="$BURST_VOLUME_NAME" '$2==n{print $1}' "$FAKE_HCLOUD_VOLUME_STATE" | head -1)"
vf8b_out="$("$BL" up)"; vf8b_rc=$?
vf8b_vid="$(grep -oE '"volume_id":"?[0-9]+"?' "$BURST_LANE_STATE_DIR/current/volume.json" | grep -oE '[0-9]+')"
expect "volidfix AC8b: up exits 0 and replaces a size-mismatched pre-existing volume" "[ $vf8b_rc -eq 0 ]"
expect "volidfix AC8b: the new volume is NOT the old mismatched one" \
  "[ \"$vf8b_vid\" != \"$vf8b_pre_vid\" ]"
expect "volidfix AC8b: journal names the size-mismatch replacement" \
  "grep -q 'burst-lane  up  volume-guard-replaced' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC8b: journal also records the fresh create" \
  "grep -q 'burst-lane  up  volume  created' \"$BURST_LANE_JOURNAL\""
expect "volidfix AC8b: exactly one volume exists for this name afterward" \
  "[ \"$(grep -cF "|$BURST_VOLUME_NAME|" "$FAKE_HCLOUD_VOLUME_STATE")\" -eq 1 ]"
expect "volidfix AC8b: the old mismatched volume no longer exists" \
  "! hcloud volume describe \"$vf8b_pre_vid\" -o json >/dev/null 2>&1"

# ---- volidfix AC9 (P1, deferred — see this PRD's own frontmatter): no ----
# real Hetzner box is authorized at build time to prove one full
# up -> provision -> down cycle ends with an empty `hcloud volume list`.

expect_block_green "volidfix" "volidfix: every volidfix case above ran green"

# =============================================================================
# PRD-build-burst-dispatch-reenable: bake/prove/enable/disable. This pass
# covers requirement 1 (`bake`, AC1/AC2), requirement 2 (`up` image
# resolution + baked-boot install-start behavior, AC3/AC4), requirement 6
# (`status` extra fields, AC12), and requirement 4 (`enable`/`disable`,
# AC7). `prove`/fail-closed/auto-bake/auto-disable land in later chained
# steps. (test_prefix: reenable)
# =============================================================================
block_start "reenable"

# ---- reenable AC1: bake succeeds against a gate_ready=true, sandbox_ok=true
# session — snapshot.json gets the new image_id + build_skill_sha, the
# journal records `bake done`, and the gate credential is shredded before
# the image is taken.
fresh_env
REEN_AB_SRC="$T/fake-autobuilder-src"; mkdir -p "$REEN_AB_SRC"
cat > "$REEN_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN_AB_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN_AB_SRC/autobuilder"
export BURST_GATE_REVIEWER=1
export BURST_CLAUDE_CRED_SRC="$T/fake-cred-src.json"
echo '{"fake":"cred"}' > "$BURST_CLAUDE_CRED_SRC"
"$BL" up >/dev/null 2>&1
r1_gate_ready="$(grep -oE '"gate_ready":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
r1_sandbox_ok="$(grep -oE '"sandbox_ok":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
expect "reenable AC1 setup: session is gate_ready=true after up" "[ \"$r1_gate_ready\" = true ]"
expect "reenable AC1 setup: session is sandbox_ok=true after up" "[ \"$r1_sandbox_ok\" = true ]"
r1_cred_path="$BURST_LANE_GATE_CRED_REMOTE_PATH"
expect "reenable AC1 setup: the gate credential is present before bake" "[ -f \"$r1_cred_path\" ]"

r1_out="$("$BL" bake)"; r1_rc=$?
expect "reenable AC1: bake exits 0" "[ $r1_rc -eq 0 ]"
expect "reenable AC1: bake prints the new image_id" "grep -q '^bake done: image_id=' <<<\"$r1_out\""
expect "reenable AC1: snapshot.json holds a new image_id and the build_skill_sha" \
  "python3 -c \"
import json
d = json.load(open('$BURST_LANE_STATE_DIR/snapshot.json'))
assert d.get('image_id'), d
assert d.get('build_skill_sha'), d
assert d.get('created'), d
assert isinstance(d.get('gate_tool_versions'), dict), d
\""
expect "reenable AC1: journal has bake done (image_id=... superseded=none secs=...)" \
  "grep -qE 'burst-lane  bake  done  \\(image_id=[0-9]+ superseded=none secs=[0-9]+\\)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC1: the credential was shredded (no longer present after bake)" "[ ! -f \"$r1_cred_path\" ]"
r1_shred_line="$(grep -n 'burst-lane  bake  cred  shredded' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
r1_done_line="$(grep -n 'burst-lane  bake  done' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
expect "reenable AC1: the credential shred is journaled before bake done (shred ran first)" \
  "[ -n \"$r1_shred_line\" ] && [ -n \"$r1_done_line\" ] && [ \"$r1_shred_line\" -lt \"$r1_done_line\" ]"
expect "reenable AC1: exactly one server create-image call happened" \
  "[ \"$(grep -c 'server create-image' "$FAKE_HCLOUD_CALLLOG")\" -eq 1 ]"
# PRD-build-burst-prove-forensics AC12: the fake hcloud now unconditionally
# rejects `-o`/`--output` on `create-image` with the real CLI's exact
# flag-parse error (see tests/fixtures/burst-lane-fake/hcloud) — bake still
# reaching `bake done` above already proves cmd_bake never sends one; assert
# the call log directly too, so a future regression that re-adds `-o` here
# fails this exact case instead of surfacing only against a real box.
expect "reenable AC1 / AC12: the create-image call carries no -o/--output flag" \
  "! grep 'server create-image' \"$FAKE_HCLOUD_CALLLOG\" | grep -qE -- '(^| )(-o|--output)( |$)'"
unset BURST_GATE_REVIEWER BURST_CLAUDE_CRED_SRC

# ---- reenable AC2a: no active session -> bake refused, exits 3, writes ----
# nothing.
fresh_env
r2a_out="$("$BL" bake 2>&1)"; r2a_rc=$?
expect "reenable AC2a: bake exits 3 with no active session" "[ $r2a_rc -eq 3 ]"
expect "reenable AC2a: no snapshot.json was written" "[ ! -f \"$BURST_LANE_STATE_DIR/snapshot.json\" ]"
expect "reenable AC2a: journal names the refusal cause" \
  "grep -q 'burst-lane  bake  refused  (cause=no-active-session)' \"$BURST_LANE_JOURNAL\""

# ---- reenable AC2b: session active but gate_ready=false -> bake refused,
# exits 3, writes nothing (same install-fail knob gatetools AC2 uses).
fresh_env
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null 2>&1
r2b_gate_ready="$(grep -oE '"gate_ready":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
expect "reenable AC2b setup: session is gate_ready=false after up" "[ \"$r2b_gate_ready\" = false ]"
r2b_out="$("$BL" bake 2>&1)"; r2b_rc=$?
expect "reenable AC2b: bake exits 3 when gate_ready=false" "[ $r2b_rc -eq 3 ]"
expect "reenable AC2b: no snapshot.json was written" "[ ! -f \"$BURST_LANE_STATE_DIR/snapshot.json\" ]"
expect "reenable AC2b: journal names the refusal cause" \
  "grep -q 'burst-lane  bake  refused  (cause=gate-not-ready' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL

# ---- reenable AC3: `up` resolves the image as snapshot.json -> SNAPSHOT_ID
# (env) -> DEFAULT_SNAPSHOT_ID, and journals which tier won.
# Case a: a snapshot.json exists -> the fake hcloud `server create` gets
# --image <that id>, and the journal names source=baked.
fresh_env
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "999888", "created": "2026-09-13T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["999888"]}
JSON
r3a_out="$("$BL" up)"; r3a_rc=$?
expect "reenable AC3a: up still exits 0 with a baked snapshot.json present" "[ $r3a_rc -eq 0 ]"
expect "reenable AC3a: fake hcloud server create received --image 999888" \
  "grep -qE '^server create .*--image 999888( |\$)' \"$FAKE_HCLOUD_CALLLOG\""
expect "reenable AC3a: journal has up image (id=999888 source=baked)" \
  "grep -q 'burst-lane  up  image  (id=999888 source=baked)' \"$BURST_LANE_JOURNAL\""

# Case b: no snapshot.json -> source is env (fresh_env's own fake env file
# always sets SNAPSHOT_ID=427125061) and behavior is unchanged from before
# this PRD (same shape as the very first AC1 case at the top of this file).
fresh_env
r3b_out="$("$BL" up)"; r3b_rc=$?
expect "reenable AC3b: up exits 0 with no snapshot.json (unchanged behavior)" "[ $r3b_rc -eq 0 ]"
expect "reenable AC3b: up still prints 'up: <id> <ip>'" "grep -q '^up: ' <<<\"$r3b_out\""
expect "reenable AC3b: fake hcloud server create received --image 427125061" \
  "grep -qE '^server create .*--image 427125061( |\$)' \"$FAKE_HCLOUD_CALLLOG\""
expect "reenable AC3b: journal has up image (id=427125061 source=env)" \
  "grep -q 'burst-lane  up  image  (id=427125061 source=env)' \"$BURST_LANE_JOURNAL\""

# ---- reenable AC4: a baked boot with every gate tool already present logs
# zero install-start lines; a baked boot with exactly one tool missing logs
# exactly one bake-stale line, preceding that tool's install-start.
# Case a: every tool present (FAKE_SSH_GATE_TOOLS_MISSING unset -> default
# fake probe reports all 8 tools present).
fresh_env
REEN4_AB_SRC="$T/fake-autobuilder-src"; mkdir -p "$REEN4_AB_SRC"
cat > "$REEN4_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN4_AB_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN4_AB_SRC/autobuilder"
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "999889", "created": "2026-09-13T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["999889"]}
JSON
"$BL" up >/dev/null 2>&1
r4a_gate_ready="$(grep -oE '"gate_ready":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
expect "reenable AC4a: a baked boot with every tool present reaches gate_ready=true" "[ \"$r4a_gate_ready\" = true ]"
expect "reenable AC4a: zero install-start lines on an all-present baked boot" \
  "[ \"$(grep -c 'burst-lane  gate-tools  install-start' "$BURST_LANE_JOURNAL")\" -eq 0 ]"
expect "reenable AC4a: journal names the boot as gate_ready=true" \
  "grep -q 'burst-lane  up  booted  .*gate_ready=true' \"$BURST_LANE_JOURNAL\""

# Case b: exactly one tool (jq) missing on a baked boot.
fresh_env
REEN4B_AB_SRC="$T/fake-autobuilder-src"; mkdir -p "$REEN4B_AB_SRC"
cat > "$REEN4B_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN4B_AB_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN4B_AB_SRC/autobuilder"
export FAKE_SSH_GATE_TOOLS_MISSING="jq"
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "999890", "created": "2026-09-13T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["999890"]}
JSON
"$BL" up >/dev/null 2>&1
expect "reenable AC4b: exactly one bake-stale line (tool=jq)" \
  "[ \"$(grep -c 'burst-lane  gate-tools  bake-stale  (tool=jq)' "$BURST_LANE_JOURNAL")\" -eq 1 ]"
expect "reenable AC4b: exactly one install-start line (tool=jq)" \
  "[ \"$(grep -c 'burst-lane  gate-tools  install-start  (tool=jq)' "$BURST_LANE_JOURNAL")\" -eq 1 ]"
r4b_bakestale_line="$(grep -n 'burst-lane  gate-tools  bake-stale  (tool=jq)' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
r4b_install_line="$(grep -n 'burst-lane  gate-tools  install-start  (tool=jq)' "$BURST_LANE_JOURNAL" | head -1 | cut -d: -f1)"
expect "reenable AC4b: bake-stale precedes install-start" \
  "[ -n \"$r4b_bakestale_line\" ] && [ -n \"$r4b_install_line\" ] && [ \"$r4b_bakestale_line\" -lt \"$r4b_install_line\" ]"
unset FAKE_SSH_GATE_TOOLS_MISSING

# ---- reenable AC5/AC6 (PRD-build-burst-dispatch-reenable requirement 3):
# `prove` independently re-derives every assertion (never trusts `run`'s own
# journal line alone — the 2026-09-09 lesson) and writes proof.json
# accordingly. A fake `cargo` on PATH stands in for the box's real cargo
# (mirroring the existing fake-uv WT_PY pattern above): it writes a fresh
# target/ file and exits 0, so `run`'s remote exec, the explicit `pull`,
# and the on-disk freshness check all succeed identically in both cases —
# the ONLY thing that differs between AC5 and AC6 is the fake ssh's answer
# to the literal remote `hostname` call this PRD's cmd_prove makes.
REEN_PROVE_CARGO="$T/fakebin-prove-cargo"; mkdir -p "$REEN_PROVE_CARGO"
cat > "$REEN_PROVE_CARGO/cargo" <<'EOF'
#!/usr/bin/env bash
# cmd_verify's own remote-cargo probe calls `cargo --version` before any
# real work routes here — answer that the same way the real cargo would, or
# verify FAILs and every run falls back local before prove ever gets a
# chance to run.
if [ "${1:-}" = "--version" ]; then
  echo "cargo 1.85.0-fake"
  exit 0
fi
mkdir -p target
echo built > target/out.txt
# PRD-build-burst-prove-forensics AC13/AC15: FAKE_CARGO_ARTIFACT_EPOCH lets a
# fixture backdate (or forward-date) this artifact's own mtime — offline
# stand-in for a box whose clock disagrees with the caller's. Unset changes
# nothing (real "now", same as before this PRD).
if [ -n "${FAKE_CARGO_ARTIFACT_EPOCH:-}" ]; then
  touch -d "@$FAKE_CARGO_ARTIFACT_EPOCH" target/out.txt
fi
exit 0
EOF
chmod +x "$REEN_PROVE_CARGO/cargo"

# `cmd_run` refuses to route until `verify` passes, and `verify`'s
# gate-tools check compares the LOCAL autobuilder's version against the
# fake remote's — same fake-local-autobuilder trick as reenable AC4 above
# (BURST_LANE_AUTOBUILDER_BIN), so this machine's real (mismatched) local
# autobuilder never trips a spurious gate-tools-missing/version-drift verify
# failure that would fall this run back local before `prove` ever gets to
# its own host-attribution check.
REEN_PROVE_AB_SRC="$T/fake-autobuilder-src-prove"; mkdir -p "$REEN_PROVE_AB_SRC"
cat > "$REEN_PROVE_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN_PROVE_AB_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"

# Case AC5: the box's `hostname` answers something OTHER than this
# machine's own — prove treats that as proof the run actually left this
# caller, exactly as the box hostname != caller check is meant to catch a
# same-host passthrough.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PROVE5="$T/prove-ac5-mcphost"; mkdir -p "$WT_PROVE5"
r5_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PROVE5" 2>&1)"; r5_rc=$?
expect "reenable AC5: prove exits 0 when run+pull+freshness+host all check out" "[ $r5_rc -eq 0 ]"
expect "reenable AC5: proof.json has routed=true and bytes>0" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is True and d['bytes'] > 0, d\""
expect "reenable AC5: journal has prove done" \
  "grep -q 'burst-lane  prove  done  (routed=true' \"$BURST_LANE_JOURNAL\""
expect "reenable AC5: down ran at the end of prove (a decision line was journaled)" \
  "grep -q 'burst-lane  down  decision=' \"$BURST_LANE_JOURNAL\""

# Case AC6: the box's `hostname` answers the SAME as this caller's own (the
# fake ssh's default — indistinguishable from a local passthrough) — first
# failing check is host-mismatch, everything upstream of it (run, pull,
# freshness) still having succeeded.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PROVE6="$T/prove-ac6-mcphost"; mkdir -p "$WT_PROVE6"
r6_out="$(PATH="$REEN_PROVE_CARGO:$PATH" "$BL" prove --worktree "$WT_PROVE6" 2>&1)"; r6_rc=$?
expect "reenable AC6: prove exits 1 when the box's hostname matches the caller's" "[ $r6_rc -eq 1 ]"
expect "reenable AC6: proof.json has routed=false with cause=host-mismatch" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is False and d['cause'] == 'host-mismatch', d\""
expect "reenable AC6: journal has prove failed (cause=host-mismatch)" \
  "grep -q 'burst-lane  prove  failed  (cause=host-mismatch' \"$BURST_LANE_JOURNAL\""
expect "reenable AC6: down still ran even though the proof failed" \
  "grep -q 'burst-lane  down  decision=' \"$BURST_LANE_JOURNAL\""

# ---- bakegate block (PRD-build-burst-selftest-drift-and-bake-gate
# requirements 4/5) -----------------------------------------------------
# AC6 (bake proceeds against the SAME BUILD_BURST_ENABLED=1 env prove
# accepts, against a gate_ready fixture box) is already proven by "reenable
# AC1: bake exits 0" above — no separate case needed, this block covers
# only the two NEW behaviors: the "not configured" refusal now journals
# (AC5), and a warm-worktree pull-zero-bytes prove explains itself (AC7).
block_start "bakegate"

# ---- bakegate AC5: bake refuses BEFORE state_active/gate_ready are even
# read when burst is not configured — the exact same burst_configured()
# predicate cmd_up's own dormant-policy gate uses — and now journals the
# refusal with the key an operator needs to set, instead of only ever
# reaching stderr (05:50Z, 2026-09-15: an operator lost a minute to this).
fresh_env
bg5_out="$(BUILD_BURST_ENABLED=0 BURST_LANE_ENV_FILE="$T/bakegate-nonexistent.env" "$BL" bake 2>&1)"; bg5_rc=$?
expect "bakegate AC5: bake exits 3 when not configured" "[ $bg5_rc -eq 3 ]"
expect "bakegate AC5: stderr names BUILD_BURST_ENABLED=1" "grep -q 'BUILD_BURST_ENABLED=1' <<<\"$bg5_out\""
expect "bakegate AC5: journal has bake refused (cause=not-configured key=BUILD_BURST_ENABLED)" \
  "grep -q 'burst-lane  bake  refused  (cause=not-configured key=BUILD_BURST_ENABLED)' \"$BURST_LANE_JOURNAL\""

# ---- bakegate AC7: a prove that reuses an already-warm worktree's remote
# target (this run's own routed line reads warm=true) and pulls back zero
# bytes explains itself instead of leaving a bare `cause=pull-zero-bytes`
# for the operator to reconstruct by hand.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_BG7="$T/bakegate-ac7-warm"; mkdir -p "$WT_BG7"
# Pre-warm the fixture "remote" (a real local dir standing in for the box,
# same remote_path_for() hash convention gate7a's own fixture above uses):
# cmd_run's remote_dir_exists check sees this dir BEFORE its own rsync-up,
# so this run's own journal line reads warm=true, exactly like a real
# already-built box would.
bg7_remote_path="$BURST_LANE_REMOTE_ROOT/$(basename "$WT_BG7")-$(printf '%s' "$WT_BG7" | sha1sum | cut -c1-8)"
mkdir -p "$bg7_remote_path/target"
# Force the pull's own --stats line to report 0 bytes transferred: the fake
# rsync's per-destination call counter (see tests/fixtures/burst-lane-fake/
# rsync's requirement-10 header) reports floor(40960/n) bytes on the nth
# --stats call against a given destination — seeding n absurdly high here
# reproduces the "nothing changed, nothing to send" symptom a real warm
# pull would also see, without needing tens of thousands of real calls.
bg7_dst="$WT_BG7/target/"
bg7_key="$(printf '%s' "$bg7_dst" | cksum | cut -d' ' -f1)"
mkdir -p "$FAKE_RSYNC_STATS_DIR"
echo 999999 > "$FAKE_RSYNC_STATS_DIR/$bg7_key"
bg7_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_BG7" 2>&1)"; bg7_rc=$?
expect "bakegate AC7: prove exits 1 on a warm worktree that pulls zero bytes" "[ $bg7_rc -eq 1 ]"
bg7_run_line="$(grep "burst-lane  run  routed  (server_id=[^ ]* worktree=$WT_BG7 " "$BURST_LANE_JOURNAL" | tail -n1)"
expect "bakegate AC7 setup: the run itself was warm" "grep -q 'warm=true' <<<\"$bg7_run_line\""
expect "bakegate AC7: the journal names it a warm worktree needing a fresh one" \
  "grep -qF 'burst-lane  prove  failed  (cause=pull-zero-bytes (warm worktree, nothing recompiled — prove needs a fresh worktree; omit --worktree)' \"$BURST_LANE_JOURNAL\""
expect "bakegate AC7: stderr reads the same explanation" \
  "grep -qF 'prove failed (cause=pull-zero-bytes (warm worktree, nothing recompiled — prove needs a fresh worktree; omit --worktree))' <<<\"$bg7_out\""

# ---- bakegate lint (requirement 7, P2): a static guard against
# reintroducing the exact AC3 drift this PRD fixes — a fixture's fake ssh
# that writes a start/end pair to its own span log for EVERY ssh
# round-trip (never distinguishing the warm-check `[ -d` / capacity-probe
# `meminfo` calls cmd_run also makes from the actual exec) counts 3 "runs"
# for every 1 that really happened. Scoped to burstpar-selftest.sh's own
# fake ssh heredoc — the one fixture in this tree that derives a run count
# from ssh call activity at all; every other span/call-log use elsewhere in
# this suite counts ssh calls for an unrelated purpose (host-key auditing,
# root@/build@ routing) and is not this anti-pattern.
bakegate_ssh_callcount_lint() {  # $1 = file to scan -> stdout violation; rc 0 clean, 1 violation
  local f="$1"
  # The two case-pattern TOKENS themselves (never a bare `[ -d`/`meminfo`
  # substring, which also appears in this very file's own prose comments
  # explaining the anti-pattern — that would make the lint trivially
  # unable to fail on a planted violation that only strips the real case
  # arm and leaves the comment above it untouched).
  if grep -q 'SPAN_LOG' "$f" 2>/dev/null; then
    if ! grep -qF '*"[ -d"*)' "$f" || ! grep -qF '*meminfo*)' "$f"; then
      echo "$f: fake ssh writes to SPAN_LOG without excluding the warm-check/capacity-probe calls — counts every ssh round-trip as a run"
      return 1
    fi
  fi
  return 0
}
bg_lint_real_out="$(bakegate_ssh_callcount_lint "$HERE/burstpar-selftest.sh")"; bg_lint_real_rc=$?
expect "bakegate lint: burstpar-selftest.sh's fake ssh excludes warm-check/capacity-probe calls from its run count" \
  "[ $bg_lint_real_rc -eq 0 ]"
BG_LINT_PLANTED="$T/burstpar-selftest-planted.sh"
sed -E 's/\*"\[ -d"\*\) exit 0 ;;//' "$HERE/burstpar-selftest.sh" > "$BG_LINT_PLANTED"
bg_lint_bad_out="$(bakegate_ssh_callcount_lint "$BG_LINT_PLANTED")"; bg_lint_bad_rc=$?
expect "bakegate lint: the lint fails on a planted fixture missing the warm-check exclusion" "[ $bg_lint_bad_rc -ne 0 ]"
expect "bakegate lint: the lint names the planted file" "grep -qF \"$BG_LINT_PLANTED\" <<<\"$bg_lint_bad_out\""

# ---- provefx block (PRD-build-burst-prove-forensics) -----------------------
# 2026-09-13: a real `prove` died silently between `up booted` and the first
# `run` line — no journal entry, no proof.json, no stderr kept anywhere — and
# the retry 90s later was refused because a disowned parity child had
# inherited the up-lock fd from a `prove` that had already exited. AC1-3
# exercise cmd_prove's own EXIT/ERR trap and per-step logging (requirements
# 1-2); AC4-6 exercise the up-lock's fd-close and holder-attribution fixes
# (requirements 3-4).
block_start "provefx"

# AC1/AC2 fault injection: no real caller of `prove` ever sets
# BURST_PROVE_TEST_ABORT (grep the tree — only this file does). It stands in
# for the PRD's own "fixture cmd_run" language: since cmd_run is a bash
# function inside this same script, not a swappable external binary, the
# offline-safe way to reproduce "cmd_run dies mid-step" is a named hook at
# the exact call site cmd_prove itself documents — see its own comment.

# ---- provefx AC1: an unbound-variable kill during the "run" step leaves
# proof.json naming the step, a numeric-free (best-effort) line, and one
# "prove aborted (step=run ...)" journal line followed by down.
fresh_env
WT_PFX1="$T/provefx-ac1"; mkdir -p "$WT_PFX1"
pfx1_out="$(BURST_PROVE_TEST_ABORT=run-unbound "$BL" prove --worktree "$WT_PFX1" 2>&1)"; pfx1_rc=$?
expect "provefx AC1: proof.json exists after an unbound-variable kill during run" \
  "[ -f \"$BURST_LANE_STATE_DIR/current/proof.json\" ]"
expect "provefx AC1: proof.json has routed=false cause=run-aborted and step=run" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is False and d['cause'] == 'run-aborted' and d['step'] == 'run', d\""
expect "provefx AC1: exactly one prove-aborted journal line naming step=run" \
  "[ \"\$(grep -c 'burst-lane  prove  aborted  (step=run' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"
expect "provefx AC1: down ran after the abort" \
  "grep -q 'burst-lane  down  decision=' \"$BURST_LANE_JOURNAL\""
expect "provefx AC1: prove's own cost line is journaled with outcome=aborted" \
  "grep -Eq 'burst-lane  prove  cost  \\(.*outcome=aborted\\)' \"$BURST_LANE_JOURNAL\""

# ---- provefx AC2: prove killed with TERM during the run step — same
# cause, and prove's own exit code is 143 (128+15), not masked by the trap.
fresh_env
WT_PFX2="$T/provefx-ac2"; mkdir -p "$WT_PFX2"
pfx2_out="$(BURST_PROVE_TEST_ABORT=run-term "$BL" prove --worktree "$WT_PFX2" 2>&1)"; pfx2_rc=$?
expect "provefx AC2: prove's exit code is 143 when killed with TERM during run" "[ $pfx2_rc -eq 143 ]"
expect "provefx AC2: proof.json cause=run-aborted after the TERM abort" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is False and d['cause'] == 'run-aborted' and d['exit_code'] == 143, d\""
expect "provefx AC2: down ran after the TERM abort" \
  "grep -q 'burst-lane  down  decision=' \"$BURST_LANE_JOURNAL\""

# ---- provefx AC3: a failing (not aborted) `up` step's own captured output
# is written to logs/prove.<epoch>.up.log and the failure journal line
# carries it collapsed — requirement 2 applies to a clean step failure too,
# not only an abort.
fresh_env
WT_PFX3="$T/provefx-ac3"; mkdir -p "$WT_PFX3"
pfx3_out="$(FAKE_HCLOUD_CREATE_FAIL=1 "$BL" prove --worktree "$WT_PFX3" 2>&1)"; pfx3_rc=$?
expect "provefx AC3: prove exits 1 when up itself fails" "[ $pfx3_rc -eq 1 ]"
expect "provefx AC3: a prove.<epoch>.up.log was written under state/burst-lane/logs" \
  "compgen -G \"$BURST_LANE_STATE_DIR/current/logs/prove.*.up.log\" >/dev/null"
expect "provefx AC3: the up log holds cmd_up's own captured output" \
  "grep -q 'hcloud server create failed' \"$BURST_LANE_STATE_DIR/current\"/logs/prove.*.up.log"
expect "provefx AC3: the failure journal line carries the up log's tail" \
  "grep -q 'burst-lane  prove  failed  (cause=up-failed .*tail=\"fallback: hcloud server create failed' \"$BURST_LANE_JOURNAL\""

# ---- provefx AC4 (requirement 3): schedule_session_parity's backgrounded
# child must not inherit the up-lock fd. Rather than drive the whole
# cmd_up->schedule_session_parity->cmd_parity integration (cmd_parity does
# real gate-repo work this fixture has no need to stand up), this exercises
# the mechanism directly: hold fd 221 exactly as `up` does, call
# schedule_session_parity with a fixture cmd_parity that just sleeps, then
# release the CALLER's own fd (mimicking `up` exiting) while the background
# child is still running. Verified by hand 2026-09-14 that this same
# construct fails (lock stays held) against the pre-fix line.
fresh_env
PFX4_REPO="$T/provefx-parity-repo"; mkdir -p "$PFX4_REPO"
( cd "$PFX4_REPO" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null
ln -sfn "$PFX4_REPO" "$BURST_LANE_REPOS_DIR/provefx-repo"
(
  source "$BL"
  cmd_parity() { sleep 30; }
  export BURST_PARITY_REPOS="provefx-repo"
  exec 221>"$BURST_LANE_STATE_DIR/current/up.lock"
  flock -n 221 || exit 1
  schedule_session_parity "provefx-ac4-session"
  sleep 0.3
  exec 221>&-
)
pfx4_setup_rc=$?
expect "provefx AC4 setup: the fixture ran cleanly (lock was takeable, parity scheduled)" "[ $pfx4_setup_rc -eq 0 ]"
pfx4_reacquire_rc=0
( exec 224>"$BURST_LANE_STATE_DIR/current/up.lock"; flock -n 224 ) || pfx4_reacquire_rc=$?
expect "provefx AC4: a fresh flock succeeds immediately once the caller's own fd closes (background child did not inherit 221)" \
  "[ $pfx4_reacquire_rc -eq 0 ]"

# ---- provefx AC5 (requirement 4): up.pid names a dead pid and nothing
# currently holds up.lock -> `up` reclaims the lock, journals
# lock-reclaimed naming the stale pid, and proceeds (exits 0).
fresh_env
PFX5_DEAD_PID=999999
while kill -0 "$PFX5_DEAD_PID" 2>/dev/null; do PFX5_DEAD_PID=$((PFX5_DEAD_PID - 1)); done
mkdir -p "$BURST_LANE_STATE_DIR"
echo "$PFX5_DEAD_PID" > "$BURST_LANE_STATE_DIR/current/up.pid"
pfx5_out="$("$BL" up 2>&1)"; pfx5_rc=$?
expect "provefx AC5: up succeeds despite a stale up.pid (the lock itself was free)" "[ $pfx5_rc -eq 0 ]"
expect "provefx AC5: journal has up lock-reclaimed naming the stale pid" \
  "grep -q \"burst-lane  up  lock-reclaimed  (stale_pid=$PFX5_DEAD_PID)\" \"$BURST_LANE_JOURNAL\""

# ---- provefx AC6 (requirement 4): a live fixture process holds up.lock
# directly (never went through up.pid at all) while up.pid names a
# DIFFERENT, dead pid — `up` must refuse within 5s and name the fixture's
# real, live pid/comm (via the /proc/locks fallback — see
# up_lock_holder_pid's own design note for why up.pid alone can't cover
# this case), not the stale pid on disk.
fresh_env
PFX6_DEAD_PID=999999
while kill -0 "$PFX6_DEAD_PID" 2>/dev/null; do PFX6_DEAD_PID=$((PFX6_DEAD_PID - 1)); done
mkdir -p "$BURST_LANE_STATE_DIR"
echo "$PFX6_DEAD_PID" > "$BURST_LANE_STATE_DIR/current/up.pid"
flock "$BURST_LANE_STATE_DIR/current/up.lock" -c 'sleep 10' &
PFX6_HOLDER_PID=$!
pfx6_tries=0
while [ "$pfx6_tries" -lt 50 ]; do
  if ( exec 225>"$BURST_LANE_STATE_DIR/current/up.lock"; flock -n 225 ) 2>/dev/null; then
    pfx6_tries=$((pfx6_tries + 1)); sleep 0.05
  else
    break
  fi
done
pfx6_t0="$(date +%s)"
pfx6_out="$("$BL" up 2>&1)"; pfx6_rc=$?
pfx6_t1="$(date +%s)"
kill "$PFX6_HOLDER_PID" 2>/dev/null || true; wait "$PFX6_HOLDER_PID" 2>/dev/null || true
expect "provefx AC6: up refuses (exit 3) within 5s when a live fixture holds up.lock" \
  "[ $pfx6_rc -eq 3 ] && [ $(( pfx6_t1 - pfx6_t0 )) -lt 5 ]"
expect "provefx AC6: refusal names the fixture's real, live pid, not the stale up.pid" \
  "grep -q \"burst-lane  up  up-refused  (lock-held pid=$PFX6_HOLDER_PID \" \"$BURST_LANE_JOURNAL\""
expect "provefx AC6: refusal does NOT name the stale/dead pid from up.pid" \
  "! grep -q \"lock-held pid=$PFX6_DEAD_PID \" \"$BURST_LANE_JOURNAL\""
expect "provefx AC6: refusal names a real comm for the fixture holder (not 'unknown')" \
  "grep -q \"lock-held pid=$PFX6_HOLDER_PID comm=flock \" \"$BURST_LANE_JOURNAL\""

# ---- provefx AC7 (requirement 3's own lint): a grep-based check that every
# backgrounded call (&, & disown, setsid, nohup) in burst-lane.sh closes fds
# 220/221/201/203 before it runs — fails naming the line on a planted
# violation, passes on the real, shipped script.
provefx_fd_lint() {  # $1=script path -> prints violating "file:line: text"
  # to stdout, returns the violation count as its exit code (capped at 255).
  local f="$1" n=0 bad=0 line stripped
  while IFS= read -r line; do
    n=$((n + 1))
    stripped="${line#"${line%%[![:space:]]*}"}"  # leading whitespace trimmed
    case "$stripped" in
      '#'*) continue ;;  # a comment line merely discussing these tokens (as
                         # this PRD's own requirement-3 prose does) is not a
                         # backgrounded call
    esac
    local backgrounded=0
    case "$line" in
      *'& disown'*|*'&disown'*|*'setsid '*|*'nohup '*) backgrounded=1 ;;
    esac
    # A bare trailing `&` (background operator, not `&&` and not the `&` of
    # a `2>&1`/`N>&-` style redirection, which never ends the line on `&`):
    # not preceded by another `&`, followed only by optional whitespace/`)`
    # to end of line.
    if [[ "$line" =~ (^|[^&])\&[[:space:]]*\)?[[:space:]]*$ ]]; then
      backgrounded=1
    fi
    if [ "$backgrounded" -eq 1 ]; then
      local ok=1 tok
      for tok in '220>&-' '221>&-' '201>&-' '203>&-'; do
        case "$line" in *"$tok"*) ;; *) ok=0 ;; esac
      done
      if [ "$ok" -ne 1 ]; then
        echo "$f:$n: $line"
        bad=$((bad + 1))
      fi
    fi
  done < "$f"
  [ "$bad" -le 255 ] && return "$bad" || return 255
}
pfx7_real_out="$(provefx_fd_lint "$HERE/burst-lane.sh")"; pfx7_real_rc=$?
expect "provefx AC7: the lint passes (0 violations) on the real, shipped burst-lane.sh" "[ $pfx7_real_rc -eq 0 ]"
PFX7_PLANTED="$T/burst-lane-planted.sh"
cp "$HERE/burst-lane.sh" "$PFX7_PLANTED"
printf '( sleep 1 & )\n' >> "$PFX7_PLANTED"
pfx7_bad_out="$(provefx_fd_lint "$PFX7_PLANTED")"; pfx7_bad_rc=$?
expect "provefx AC7: the lint fails naming >=1 violation on a planted unclosed background job" "[ $pfx7_bad_rc -ge 1 ]"
expect "provefx AC7: the lint names the exact planted line" \
  "grep -q ': ( sleep 1 & )$' <<<\"$pfx7_bad_out\""

# ---- provefx AC8 (requirement 6): status --json reports prove_last (ts,
# outcome, step, cause, line, log) read from the newest proof.json/
# prove.*.log, without needing to open the state dir by hand.
fresh_env
WT_PFX8="$T/provefx-ac8"; mkdir -p "$WT_PFX8"
FAKE_HCLOUD_CREATE_FAIL=1 "$BL" prove --worktree "$WT_PFX8" >/dev/null 2>&1
"$BL" status --json > "$T/pfx8-status.json"
expect "provefx AC8: status --json prove_last.outcome is failed for an up-failed prove" \
  "python3 -c \"import json; d=json.load(open('$T/pfx8-status.json')); assert d['prove_last']['outcome']=='failed', d['prove_last']\""
expect "provefx AC8: status --json prove_last.step names the failing step" \
  "python3 -c \"import json; d=json.load(open('$T/pfx8-status.json')); assert d['prove_last']['step']=='up', d['prove_last']\""
expect "provefx AC8: status --json prove_last.cause matches proof.json" \
  "python3 -c \"import json; d=json.load(open('$T/pfx8-status.json')); assert d['prove_last']['cause']=='up-failed', d['prove_last']\""
expect "provefx AC8: status --json prove_last.log names an existing prove.<epoch>.up.log" \
  "python3 -c \"import json, os; d=json.load(open('$T/pfx8-status.json')); log=d['prove_last']['log']; assert log and os.path.isfile(log), d['prove_last']\""
fresh_env
"$BL" status --json > "$T/pfx8b-status.json"
expect "provefx AC8: status --json prove_last is null when prove has never run" \
  "python3 -c \"import json; d=json.load(open('$T/pfx8b-status.json')); assert d['prove_last'] is None, d['prove_last']\""

# ---- provefx AC11 (requirement 9): cost and age count from server CREATION
# (create_epoch), not from `up booted` (boot_epoch) — a session created at T
# and booted 17 minutes later, torn down 2 minutes after boot (19 after
# create), must show 19 billed minutes throughout, never 2 (boot to
# teardown) — the exact gap that logged boxes 165737254/165738778 at 0.0h
# each against a started billed hour.
fresh_env
"$BL" up >/dev/null 2>&1
pfx11_create_epoch="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
expect "provefx AC11 setup: up wrote a numeric create_epoch" "[ -n \"$pfx11_create_epoch\" ]"
pfx11_boot_epoch=$((pfx11_create_epoch + 17 * 60))
sed -i "s/\"boot_epoch\":[0-9]*/\"boot_epoch\":$pfx11_boot_epoch/" "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((pfx11_boot_epoch + 2 * 60))   # 19 minutes after create_epoch
"$BL" status --json > "$T/pfx11-status.json"
expect "provefx AC11: status --json minutes_alive reads 19 (from create_epoch, not boot_epoch's 2)" \
  "python3 -c \"import json; d=json.load(open('$T/pfx11-status.json')); assert d['minutes_alive']==19, d\""
pfx11_down_out="$("$BL" down --more-work-queued)"
expect "provefx AC11: down deletes the unproven box (runs_served=0) immediately" \
  "[ \"$pfx11_down_out\" = 'decision=deleted' ]"
expect "provefx AC11: the deletion journal line reads minutes=19, not minutes=2" \
  "grep -qE 'burst-lane  down  decision=deleted  \\(server_id=[^ ]+ cause=unproven-box .*minutes=19 ' \"$BURST_LANE_JOURNAL\""
expect "provefx AC11: cost.jsonl's row reads hours=0.3167 (19/60), not 0.0333 (2/60)" \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$BURST_LANE_COST_LEDGER') if l.strip()]
assert any(abs(r.get('hours', -1) - 19/60.0) < 0.0001 for r in rows), rows
\""

# ---- provefx AC13 (requirement 11): assert compares artifact mtimes
# against the marker `run` touched on the BOX's own clock, not against this
# caller's local clock — a box whose own artifacts (and marker) land 15
# minutes behind wall-clock time (simulating clock skew) must still route
# true, because the marker rode back from the exact same clock the
# artifacts did. Scoped to a private TMPDIR so the "no burst-prove-marker.*
# left behind" check below can never see an unrelated file from this host's
# own real /tmp (production still has ten stale ones from before this PRD).
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PFX13="$T/provefx-ac13"; mkdir -p "$WT_PFX13"
PFX13_TMP="$T/provefx-ac13-tmp"; mkdir -p "$PFX13_TMP"
pfx13_marker_epoch=$(( $(date +%s) - 900 ))
pfx13_artifact_epoch=$(( pfx13_marker_epoch + 5 ))
pfx13_out="$(PATH="$REEN_PROVE_CARGO:$PATH" TMPDIR="$PFX13_TMP" \
  FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box \
  BURST_PROVE_TEST_MARKER_EPOCH="$pfx13_marker_epoch" \
  FAKE_CARGO_ARTIFACT_EPOCH="$pfx13_artifact_epoch" \
  "$BL" prove --worktree "$WT_PFX13" 2>&1)"; pfx13_rc=$?
expect "provefx AC13: prove routes true when the box's own artifacts land 15m behind wall-clock" \
  "[ $pfx13_rc -eq 0 ]"
expect "provefx AC13: proof.json routed=true despite the clock skew" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is True, d\""
expect "provefx AC13: no burst-prove-marker.* file remains in TMPDIR after prove" \
  "[ -z \"\$(find \"$PFX13_TMP\" -maxdepth 1 -name 'burst-prove-marker.*' 2>/dev/null)\" ]"

# ---- provefx AC14 case 1 (PRD-build-burst-selftest-drift-and-bake-gate
# requirement 3): case 2 below (unchanged) hand-builds a directory with
# .cargo/config.toml already inside it — that can never exercise the
# no-`--worktree` path, where cmd_prove builds its OWN disposable worktree
# via `git worktree add --detach` from a real repo. `git worktree add`
# checks out tracked content only; a file the repo excludes in
# .git/info/exclude (exactly mcphost's own .cargo/config.toml treatment,
# ~/wintermute/mcphost/.git/info/exclude:7) is never present in the new
# worktree, so local_target must resolve to the plain <worktree>/target,
# never an off-root override. Proves this against the actual git mechanics,
# not an assumption about them.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
PFX14A_REPO="$T/provefx-ac14-repo"; mkdir -p "$PFX14A_REPO"
git -C "$PFX14A_REPO" init -q
printf 'fixture repo\n' > "$PFX14A_REPO/README"
git -C "$PFX14A_REPO" add README
git -C "$PFX14A_REPO" -c user.name=t -c user.email=t@t commit -q -m init
mkdir -p "$PFX14A_REPO/.cargo"
printf '[build]\ntarget-dir = "%s"\n' "$T/provefx-ac14-repo-offroot-target" \
  > "$PFX14A_REPO/.cargo/config.toml"
printf '.cargo/config.toml\n' >> "$PFX14A_REPO/.git/info/exclude"
# cmd_prove's own disposable worktree is unconditionally `git worktree
# remove --force`'d before prove returns (never gated by --keep-worktree —
# that flag only preserves the pulled target/ evidence, not the worktree
# itself), so there is no window after prove exits to inspect it directly.
# A throwaway worktree built the identical way (same repo, same
# .git/info/exclude) from OUTSIDE prove proves the same git mechanics
# without racing prove's own cleanup.
PFX14A_PROBE_WT="$T/provefx-ac14-probe-wt"
git -C "$PFX14A_REPO" worktree add --detach "$PFX14A_PROBE_WT" HEAD >/dev/null 2>&1
expect "provefx AC14: git worktree add from this fixture's repo produces a worktree with no .cargo/config.toml" \
  "[ ! -f '$PFX14A_PROBE_WT/.cargo/config.toml' ]"
git -C "$PFX14A_REPO" worktree remove --force "$PFX14A_PROBE_WT" >/dev/null 2>&1
export BURST_PROVE_MCPHOST_REPO="$PFX14A_REPO"
pfx14a_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove 2>&1)"; pfx14a_rc=$?
expect "provefx AC14: prove with no --worktree does its own git worktree add --detach and still routes true" \
  "[ $pfx14a_rc -eq 0 ]"
pfx14a_wt="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/current/proof.json'))['worktree'])" 2>/dev/null)"
expect "provefx AC14: prove's own disposable worktree is gone after prove finishes" \
  "[ -n \"$pfx14a_wt\" ] && [ ! -d \"$pfx14a_wt\" ]"
expect "provefx AC14: the done journal line names local_target as <worktree>/target, not the repo's off-root override" \
  "grep -q \"burst-lane  prove  done  (routed=true.*local_target=$pfx14a_wt/target\" \"$BURST_LANE_JOURNAL\""
unset BURST_PROVE_MCPHOST_REPO

# ---- provefx AC14 case 2 (requirement 11): a worktree whose
# .cargo/config.toml points target-dir at an absolute off-root path — the
# pull already lands there (pull_target_incremental,
# PRD-build-worktree-targets-off-root); this proves assert inspects that
# SAME path (never $worktree/target) and names it in the journal on
# success too. Supplied via --worktree, so this is the operator-owned path
# (never a disposable git-worktree-add) — the off-root override IS honored
# here, unlike case 1 above.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PFX14="$T/provefx-ac14"; mkdir -p "$WT_PFX14/.cargo"
PFX14_OFFROOT="$T/provefx-ac14-offroot-target"
printf '[build]\ntarget-dir = "%s"\n' "$PFX14_OFFROOT" > "$WT_PFX14/.cargo/config.toml"
pfx14_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PFX14" 2>&1)"; pfx14_rc=$?
expect "provefx AC14: prove routes true against an off-root target-dir override" "[ $pfx14_rc -eq 0 ]"
expect "provefx AC14: proof.json routed=true" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is True, d\""
expect "provefx AC14: the pull actually landed the artifact under the override, not \$worktree/target" \
  "[ -f '$PFX14_OFFROOT/out.txt' ]"
expect "provefx AC14: the done journal line names local_target as the override path" \
  "grep -q \"burst-lane  prove  done  (routed=true.*local_target=$PFX14_OFFROOT\" \"$BURST_LANE_JOURNAL\""

# ---- provefx AC15 (requirement 12): when assert fails, proof.json and the
# journal carry the full diagnosis (local_target/files/newest_mtime/
# marker_mtime/remote_date/skew_s) — a no-fresh-artifact verdict must be
# explainable from the receipt alone. A dedicated fixture cargo that
# compiles nothing at all (mkdir -p target; exit 0) reproduces "the pull
# landed zero files newer than the marker" without depending on AC13's
# epoch arithmetic.
PFX15_CARGO="$T/fakebin-provefx-ac15-cargo"; mkdir -p "$PFX15_CARGO"
cat > "$PFX15_CARGO/cargo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "cargo 1.85.0-fake"
  exit 0
fi
mkdir -p target
exit 0
EOF
chmod +x "$PFX15_CARGO/cargo"
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PFX15="$T/provefx-ac15"; mkdir -p "$WT_PFX15"
pfx15_out="$(PATH="$PFX15_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box FAKE_SSH_REMOTE_DATE="2026-09-14T05:00:00Z" "$BL" prove --worktree "$WT_PFX15" 2>&1)"; pfx15_rc=$?
expect "provefx AC15: prove exits 1 when the box compiled nothing newer than the marker" "[ $pfx15_rc -eq 1 ]"
expect "provefx AC15: proof.json cause=no-fresh-artifact" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is False and d['cause']=='no-fresh-artifact', d\""
expect "provefx AC15: proof.json carries the full assert diagnosis" \
  "python3 -c \"
import json
d = json.load(open('$BURST_LANE_STATE_DIR/current/proof.json'))
assert d.get('files') == 0, d
assert d.get('local_target'), d
assert 'marker_mtime' in d and d['marker_mtime'], d
assert d.get('remote_date') == '2026-09-14T05:00:00Z', d
assert 'skew_s' in d, d
\""
expect "provefx AC15: the journal failed line carries the same diagnosis fields" \
  "grep -qE 'burst-lane  prove  failed  \\(cause=no-fresh-artifact .*files=0.*remote_date=2026-09-14T05:00:00Z' \"$BURST_LANE_JOURNAL\""

# ---- provefx AC16 (requirement 11 regression): real proof.json from
# 2026-09-15T05:08:20Z (RedBaron, after prove-forensics req 11/12, commit
# 778dd2a) — files=5816, marker_mtime=05:02:53Z, newest_mtime=05:04:15Z
# (82s AFTER the marker), remote_date=05:02:50Z, skew_s=-330 — yet the
# verdict was cause=no-fresh-artifact even though a genuinely fresher
# artifact existed. skew_s is diagnostic only (prove_assert_diag_json) and
# must never be applied to the routed decision, which compares box-clock
# file mtimes directly against the box-clock marker mtime (both preserved
# by rsync -a, immune to any caller/box clock disagreement). Reuses AC13's
# marker-epoch/artifact-epoch backdating fixture, at the exact 82s gap, plus
# a FAKE_SSH_REMOTE_DATE chosen so this run's own skew_s reads -330, the
# same sign+magnitude as the real incident.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PFX16="$T/provefx-ac16"; mkdir -p "$WT_PFX16"
pfx16_marker_epoch=1789456973   # 2026-09-15T05:02:53Z
pfx16_artifact_epoch=$((pfx16_marker_epoch + 82))   # 2026-09-15T05:04:15Z
pfx16_remote_date="2026-09-15T05:02:50Z"
pfx16_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box \
  BURST_PROVE_TEST_MARKER_EPOCH="$pfx16_marker_epoch" \
  FAKE_CARGO_ARTIFACT_EPOCH="$pfx16_artifact_epoch" \
  FAKE_SSH_REMOTE_DATE="$pfx16_remote_date" \
  "$BL" prove --worktree "$WT_PFX16" 2>&1)"; pfx16_rc=$?
expect "provefx AC16: artifacts 82s newer than the marker with skew_s=-330 assert routed=true" \
  "[ $pfx16_rc -eq 0 ]"
expect "provefx AC16: proof.json routed=true, not no-fresh-artifact" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is True, d\""

# ---- provefx AC17 (regression, commit ac319ac): the freshness check was
# `find -L ... | grep -q .` under `set -uo pipefail` — on a real pulled
# cargo target with 5816 files, `grep -q` exits after its first match,
# `find` gets SIGPIPE (exit 141), pipefail fails the pipeline, and the `!`
# in front turns a genuinely fresh target into cause=no-fresh-artifact.
# Three real boxes were burned on this because every prior fixture's target
# was too small for `find` to ever get killed before `grep` was satisfied.
# This fixture forces the race: a dedicated fake `cargo` populates target/
# with 8000 files (one `seq | xargs touch` call — per-file `touch`
# processes would make this case too slow to run every suite invocation)
# all backdated to 60s AFTER the marker, so `find -L` has thousands of
# newer-than-marker candidates to walk past before `grep -q` can see the
# first one and close its end of the pipe. The `-print -quit` fix (this
# commit) makes `find` itself stop at the first match, so `grep` never
# gets a chance to hang up on it; reverting to plain `-print` (no -quit)
# reproduces the SIGPIPE and must fail this case.
PFX17_CARGO="$T/fakebin-provefx-ac17-cargo"; mkdir -p "$PFX17_CARGO"
cat > "$PFX17_CARGO/cargo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "cargo 1.85.0-fake"
  exit 0
fi
mkdir -p target
epoch="${FAKE_CARGO_ARTIFACT_EPOCH:-$(date +%s)}"
seq -f "target/f%05g.o" 1 8000 | xargs touch -d "@$epoch"
exit 0
EOF
chmod +x "$PFX17_CARGO/cargo"
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PFX17="$T/provefx-ac17"; mkdir -p "$WT_PFX17"
pfx17_marker_epoch=1789456973   # 2026-09-15T05:02:53Z
pfx17_artifact_epoch=$((pfx17_marker_epoch + 60))   # 2026-09-15T05:03:53Z
pfx17_remote_date="2026-09-15T05:02:50Z"
pfx17_out="$(PATH="$PFX17_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box \
  BURST_PROVE_TEST_MARKER_EPOCH="$pfx17_marker_epoch" \
  FAKE_CARGO_ARTIFACT_EPOCH="$pfx17_artifact_epoch" \
  FAKE_SSH_REMOTE_DATE="$pfx17_remote_date" \
  "$BL" prove --worktree "$WT_PFX17" 2>&1)"; pfx17_rc=$?
expect "provefx AC17: a pulled target with 8000 files newer than the marker asserts routed=true (find must not die of SIGPIPE under pipefail)" \
  "[ $pfx17_rc -eq 0 ]"
expect "provefx AC17: proof.json routed=true, not no-fresh-artifact" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')); assert d['routed'] is True, d\""

expect_block_green "provefx" "provefx: every provefx case above ran green"

# ---- provekeep block (PRD-build-burst-prove-evidence-preservation) --------
# 2026-09-14/15: prove's own reap-at-exit destroyed the pulled target,
# proof.json's diagnosis, and the step logs a no-fresh-artifact verdict
# needed to be re-diagnosed offline — three times — before anyone thought to
# point a run at a persistent --worktree by hand (problem statement: ~90
# operator-minutes and a wrong root cause that shipped a fix for a different
# hazard, 778dd2a). AC1-4/AC7 reuse provefx AC15's own no-fresh-artifact
# fixture (empty target/, assert fails); AC5/AC6 reuse the reenable AC5/AC6
# successful-prove fixture (REEN_PROVE_CARGO/REEN_PROVE_AB_SRC, both still
# valid tmpdirs from earlier in this same process). AC8 (real box) and AC9
# (whole-suite green) are covered by their own tests/provekeep_ac8/ac9
# wrappers, not here — this block is the offline fixture half only.
block_start "provekeep"

PK_CARGO="$T/fakebin-provekeep-cargo"; mkdir -p "$PK_CARGO"
cat > "$PK_CARGO/cargo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "cargo 1.85.0-fake"
  exit 0
fi
mkdir -p target
exit 0
EOF
chmod +x "$PK_CARGO/cargo"

# ---- provekeep AC1/AC2 (P0, requirement 1/2) -------------------------------
# Deliberately NOT --worktree here (unlike provefx's own fixtures) — AC1
# requires checking that prove's AUTO-CREATED disposable worktree is gone
# after a failed assert, which only exists on the no-`--worktree` path
# (an operator-supplied --worktree is never removed by prove at all, see
# cmd_prove's own cleanup_worktree gating). A tiny throwaway git repo
# stands in for the real $HOME/wintermute/mcphost default.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
PK1_REPO="$T/fake-mcphost-repo"; mkdir -p "$PK1_REPO"
git -C "$PK1_REPO" init -q
git -C "$PK1_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export BURST_PROVE_MCPHOST_REPO="$PK1_REPO"
pk1_out="$(PATH="$PK_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box FAKE_SSH_REMOTE_DATE="2026-09-15T06:00:00Z" "$BL" prove 2>&1)"; pk1_rc=$?
expect "provekeep AC1: prove exits 1 on the no-fresh-artifact fixture" "[ $pk1_rc -eq 1 ]"
pk1_dir="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
expect "provekeep AC1: exactly one evidence dir was created" \
  "[ -n \"$pk1_dir\" ] && [ -d \"$pk1_dir\" ]"
expect "provekeep AC1: evidence dir holds target/, proof.json, expression.sh, and a step log" \
  "[ -d \"$pk1_dir/target\" ] && [ -f \"$pk1_dir/proof.json\" ] && [ -f \"$pk1_dir/expression.sh\" ] && [ -n \"\$(find \"$pk1_dir/logs\" -type f -name 'prove.*.log' 2>/dev/null)\" ]"
pk1_wt="$(grep -oE 'burst-lane  run  routed  \(server_id=[^ ]* worktree=[^ ]*' "$BURST_LANE_JOURNAL" | tail -1 | sed -E 's/.*worktree=//')"
expect "provekeep AC1: the disposable worktree is gone" \
  "[ -n \"$pk1_wt\" ] && [ ! -d \"$pk1_wt\" ]"
unset BURST_PROVE_MCPHOST_REPO

expect "provekeep AC2: expression.sh prints verdict=1 against the still-stale preserved target" \
  "[ \"\$(bash \"$pk1_dir/expression.sh\" 2>/dev/null)\" = 'verdict=1' ]"
touch "$pk1_dir/target/fresh.o"
expect "provekeep AC2: expression.sh prints verdict=0 after touching one file under target/" \
  "[ \"\$(bash \"$pk1_dir/expression.sh\" 2>/dev/null)\" = 'verdict=0' ]"

# ---- provekeep AC3 (P0, requirement 3) -------------------------------------
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
export BURST_EVIDENCE_KEEP=3
pk3_base=1789500000
for pk3_i in 1 2 3 4; do
  WT_PK3="$T/provekeep-ac3-$pk3_i"; mkdir -p "$WT_PK3"
  export BURST_LANE_NOW=$((pk3_base + pk3_i * 100))
  PATH="$PK_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PK3" >/dev/null 2>&1
done
unset BURST_LANE_NOW
pk3_before="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
expect "provekeep AC3 setup: four evidence dirs exist before reap" "[ \"$pk3_before\" -eq 4 ]"
pk3_oldest="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1)"
"$BL" reap >/dev/null 2>&1
pk3_after="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
expect "provekeep AC3: exactly three evidence dirs remain after reap" "[ \"$pk3_after\" -eq 3 ]"
expect "provekeep AC3: the oldest evidence dir was removed" "[ -n \"$pk3_oldest\" ] && [ ! -d \"$pk3_oldest\" ]"
expect "provekeep AC3: the journal has exactly one reap evidence-deleted line" \
  "[ \"\$(grep -c 'burst-lane  reap  evidence-deleted' \"$BURST_LANE_JOURNAL\")\" -eq 1 ]"

# ---- provekeep AC4 (P0, requirement 4) — reuses AC3's post-reap state -----
pk4_json="$("$BL" status --json 2>/dev/null)"
pk4_count="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['evidence']['count'])" "$pk4_json" 2>/dev/null)"
pk4_bytes="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['evidence']['bytes'])" "$pk4_json" 2>/dev/null)"
pk4_du="$(du -sbL "$BURST_LANE_STATE_DIR/current/evidence" 2>/dev/null | cut -f1)"
expect "provekeep AC4: status --json evidence.count=3" "[ \"$pk4_count\" = 3 ]"
expect "provekeep AC4: status --json evidence.bytes matches du -sb within 1%" \
  "python3 -c \"a=int('$pk4_bytes'); b=int('${pk4_du:-0}'); assert b == 0 or abs(a-b)/max(b,1) <= 0.01, (a,b)\""
expect "provekeep AC4: status (text) prints one evidence: N sets, X GB, newest <ts> line" \
  "\"$BL\" status | grep -qE '^evidence: 3 sets, [0-9.]+ GB, newest [0-9TZ:-]+$'"

# ---- provekeep AC5 (P0, requirement 1 non-goal / requirement 5 baseline) ---
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PK5="$T/provekeep-ac5"; mkdir -p "$WT_PK5"
pk5_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PK5" 2>&1)"; pk5_rc=$?
expect "provekeep AC5 setup: the fixture prove succeeded (routed=true)" "[ $pk5_rc -eq 0 ]"
expect "provekeep AC5: no evidence directory is created for a successful prove without --keep-worktree" \
  "[ ! -e \"$BURST_LANE_STATE_DIR/current/evidence\" ] || [ -z \"\$(find \"$BURST_LANE_STATE_DIR/current/evidence\" -mindepth 1 -maxdepth 1 2>/dev/null)\" ]"

# ---- provekeep AC6 (P1, requirement 5) -------------------------------------
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PK6="$T/provekeep-ac6"; mkdir -p "$WT_PK6"
pk6_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PK6" --keep-worktree 2>&1)"; pk6_rc=$?
expect "provekeep AC6 setup: the fixture prove succeeded (routed=true)" "[ $pk6_rc -eq 0 ]"
pk6_dir="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
expect "provekeep AC6: --keep-worktree preserves an evidence set on a successful prove" \
  "[ -n \"$pk6_dir\" ] && [ -d \"$pk6_dir/target\" ]"
expect "provekeep AC6: journal has prove evidence-kept (reason=operator)" \
  "grep -qE 'burst-lane  prove  evidence-kept  \\(.*reason=operator' \"$BURST_LANE_JOURNAL\""
expect "provekeep AC6: the operator-supplied worktree itself is untouched (copied, not moved)" \
  "[ -d \"$WT_PK6/target\" ]"

# ---- provekeep AC7 (P1, requirement 6) -------------------------------------
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PK7="$T/provekeep-ac7"; mkdir -p "$WT_PK7"
export FAKE_SSH_PULL_PROBE_BYTES=1048576
export BURST_LANE_LOCAL_FREE_GB=5
export BURST_LOCAL_DISK_FLOOR_GB=999999
pk7_out="$(PATH="$PK_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PK7" 2>&1)"; pk7_rc=$?
unset FAKE_SSH_PULL_PROBE_BYTES BURST_LANE_LOCAL_FREE_GB BURST_LOCAL_DISK_FLOOR_GB
expect "provekeep AC7: prove still fails at assert (no-fresh-artifact) under the inflated floor" "[ $pk7_rc -eq 1 ]"
pk7_dir="$(find -L "$BURST_LANE_STATE_DIR/current/evidence" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
expect "provekeep AC7: the evidence set holds logs/proof.json/expression.sh but no target/" \
  "[ -n \"$pk7_dir\" ] && [ -f \"$pk7_dir/proof.json\" ] && [ -f \"$pk7_dir/expression.sh\" ] && [ -n \"\$(find \"$pk7_dir/logs\" -type f 2>/dev/null)\" ] && [ ! -d \"$pk7_dir/target\" ]"
expect "provekeep AC7: journal has prove evidence-trimmed (reason=disk-floor)" \
  "grep -qE 'burst-lane  prove  evidence-trimmed  \\(reason=disk-floor' \"$BURST_LANE_JOURNAL\""

expect_block_green "provekeep" "provekeep: every provekeep case above ran green"

# ---- proveguard block (PRD-build-burst-prove-inflight-guard) ---------------
# 2026-09-15: box 165981910 was deleted by a concurrent `down` between
# prove's own `up` finishing and its `run` starting (runs_served=0 at that
# instant reads as an unproven box). AC1-3 exercise `down`'s new
# prove.inflight check (live marker keeps, dead marker is reclaimed and
# proceeds normally, --force still overrides but journals the override);
# AC4 exercises the same check in idle-guard; AC5 proves the marker never
# outlives a real (fixture) `prove` process.
block_start "proveguard"

# ---- proveguard AC1: a live prove.inflight pid blocks down -----------------
fresh_env
"$BL" up >/dev/null 2>&1
pg1_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
sleep 300 & pg1_pid=$!
printf 'pid=%s\nstart_epoch=%s\nserver_id=%s\n' "$pg1_pid" "$(date -u +%s)" "$pg1_sid" > "$BURST_LANE_STATE_DIR/current/prove.inflight"
pg1_out="$("$BL" down 2>&1)"; pg1_rc=$?
expect "proveguard AC1: down exits 0 while a live prove.inflight pid is running" "[ $pg1_rc -eq 0 ]"
expect "proveguard AC1: down prints decision=keep" "grep -q '^decision=keep$' <<<\"$pg1_out\""
expect "proveguard AC1: down journals decision=keep cause=prove-inflight naming the live pid" \
  "grep -q \"burst-lane  down  decision=keep  (server_id=$pg1_sid cause=prove-inflight pid=$pg1_pid\" \"$BURST_LANE_JOURNAL\""
expect "proveguard AC1: the box is still alive (down never reached its own delete decision)" \
  "hcloud server describe \"$pg1_sid\" -o json >/dev/null 2>&1"
kill "$pg1_pid" 2>/dev/null; wait "$pg1_pid" 2>/dev/null

# ---- proveguard AC2: a dead pid in the marker is reclaimed, then down ------
# proceeds to its normal unproven-box delete (same fake-rust-work-queued
# fixture bursthyg AC4 above uses, so this is provably the ordinary path,
# not a special case).
fresh_env
"$BL" up >/dev/null 2>&1
pg2_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
( : ) & pg2_pid=$!
wait "$pg2_pid" 2>/dev/null
printf 'pid=%s\nstart_epoch=%s\nserver_id=%s\n' "$pg2_pid" "$(date -u +%s)" "$pg2_sid" > "$BURST_LANE_STATE_DIR/current/prove.inflight"
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-proveguard.md" <<'EOF'
# PRD — fake-rust-proveguard

- Status: queued
- build_target: rust-extend
EOF
pg2_out="$("$BL" down 2>&1)"
expect "proveguard AC2: down deletes the unproven box once the stale marker is reclaimed" "[ \"$pg2_out\" = 'decision=deleted' ]"
expect "proveguard AC2: journal has prove-inflight-stale naming the dead pid" \
  "grep -q \"burst-lane  down  prove-inflight-stale  (pid=$pg2_pid)\" \"$BURST_LANE_JOURNAL\""
expect "proveguard AC2: the stale marker file is removed" "[ ! -f \"$BURST_LANE_STATE_DIR/current/prove.inflight\" ]"
expect "proveguard AC2: journal still names the ordinary unproven-box cause" \
  "grep -q 'burst-lane  down  decision=deleted.*cause=unproven-box' \"$BURST_LANE_JOURNAL\""
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust-proveguard.md"

# ---- proveguard AC3: down --force overrides a live marker, but journals ---
# the override rather than silently ignoring it.
fresh_env
"$BL" up >/dev/null 2>&1
pg3_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
sleep 300 & pg3_pid=$!
printf 'pid=%s\nstart_epoch=%s\nserver_id=%s\n' "$pg3_pid" "$(date -u +%s)" "$pg3_sid" > "$BURST_LANE_STATE_DIR/current/prove.inflight"
pg3_out="$("$BL" down --force 2>&1)"; pg3_rc=$?
expect "proveguard AC3: down --force still exits 0 despite a live prove.inflight" "[ $pg3_rc -eq 0 ]"
expect "proveguard AC3: down --force still deletes (decision=force-deleted)" "grep -q '^decision=force-deleted$' <<<\"$pg3_out\""
expect "proveguard AC3: the box is actually gone" "! hcloud server describe \"$pg3_sid\" -o json >/dev/null 2>&1"
expect "proveguard AC3: journal names the prove-inflight override, naming the live pid" \
  "grep -q \"burst-lane  down  prove-inflight-overridden  (pid=$pg3_pid\" \"$BURST_LANE_JOURNAL\""
kill "$pg3_pid" 2>/dev/null; wait "$pg3_pid" 2>/dev/null

# ---- proveguard AC4: idle-guard honors the same marker ---------------------
fresh_env
"$BL" up >/dev/null 2>&1
pg4_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
pg4_create="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
sleep 300 & pg4_pid=$!
printf 'pid=%s\nstart_epoch=%s\nserver_id=%s\n' "$pg4_pid" "$(date -u +%s)" "$pg4_sid" > "$BURST_LANE_STATE_DIR/current/prove.inflight"
export BURST_LANE_NOW=$((pg4_create + 1000))   # well past the 900s zero-runs idle threshold
pg4_out="$("$BL" idle-guard 2>&1)"; pg4_rc=$?
unset BURST_LANE_NOW
expect "proveguard AC4: idle-guard exits 0 while a live prove.inflight pid is running" "[ $pg4_rc -eq 0 ]"
expect "proveguard AC4: idle-guard does not delete the box" "hcloud server describe \"$pg4_sid\" -o json >/dev/null 2>&1"
expect "proveguard AC4: idle-guard journals decision=keep cause=prove-inflight" \
  "grep -q \"burst-lane  idle-guard  decision=keep  (server_id=$pg4_sid cause=prove-inflight pid=$pg4_pid\" \"$BURST_LANE_JOURNAL\""
kill "$pg4_pid" 2>/dev/null; wait "$pg4_pid" 2>/dev/null

# ---- proveguard AC5: a real (fixture) prove leaves no marker behind --------
# Reuses provefx AC1's own fault-injection fixture (BURST_PROVE_TEST_ABORT)
# — the abort path is the one that most needs proving here, since it's the
# one that skips prove's own normal end-of-function cleanup entirely and
# relies solely on prove_exit_trap.
fresh_env
WT_PG5="$T/proveguard-ac5"; mkdir -p "$WT_PG5"
BURST_PROVE_TEST_ABORT=run-unbound "$BL" prove --worktree "$WT_PG5" >/dev/null 2>&1
expect "proveguard AC5: prove.inflight does not outlive an aborted fixture prove" "[ ! -f \"$BURST_LANE_STATE_DIR/current/prove.inflight\" ]"

# ---- proveguard AC6: prove's own FINISHING down is never blocked by its --
# own inflight marker. Real run 2026-09-15T05:08:20Z: cmd_prove's own
# finishing `down` (the normal, non-aborted tail — never reaches
# prove_exit_trap's unconditional marker rm, which only fires on an early/
# abort exit) journaled "down decision=keep (cause=prove-inflight
# pid=4191204 age_s=633)" where pid 4191204 was prove itself, still alive
# while its own down call ran in a subshell — the box was left running and
# billing. Reuses AC13/AC14's own fixture cargo + FAKE_SSH_HOSTNAME so this
# prove genuinely completes (any outcome — routed here) end to end, through
# the real success tail, not the abort trap AC5 already covers.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN_PROVE_AB_SRC/autobuilder"
WT_PG6="$T/proveguard-ac6"; mkdir -p "$WT_PG6"
pg6_out="$(PATH="$REEN_PROVE_CARGO:$PATH" FAKE_SSH_HOSTNAME=wm-burst-lane-fake-box "$BL" prove --worktree "$WT_PG6" 2>&1)"; pg6_rc=$?
expect "proveguard AC6: the fixture prove itself completes (routed)" "[ $pg6_rc -eq 0 ]"
pg6_sid="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/current/proof.json')).get('server_id',''))" 2>/dev/null)"
expect "proveguard AC6: proof.json names the server_id prove created" "[ -n \"$pg6_sid\" ]"
expect "proveguard AC6: prove.inflight is gone" "[ ! -f \"$BURST_LANE_STATE_DIR/current/prove.inflight\" ]"
expect "proveguard AC6: the journal has prove's own down decision, never decision=keep cause=prove-inflight" \
  "grep -qE \"burst-lane  down  decision=(deleted|scheduled)\" \"$BURST_LANE_JOURNAL\" && ! grep -q \"burst-lane  down  decision=keep  (server_id=$pg6_sid cause=prove-inflight\" \"$BURST_LANE_JOURNAL\""

expect_block_green "proveguard" "proveguard: every proveguard case above ran green"

# ---- reenable AC7: `enable` writes the systemd drop-in only when
# proof.json is routed=true, younger than 7 days, and names the image `up`
# would boot now; otherwise it refuses (rc 3, no drop-in). `disable` always
# removes the drop-in and journals cause=operator.
# Case a: a fresh, routed, image-matching proof -> enable succeeds.
fresh_env
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "555777", "created": "2026-09-13T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["555777"]}
JSON
r7a_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_LANE_STATE_DIR/current/proof.json" <<JSON
{"ts": "$r7a_now", "image_id": "555777", "server_id": "1", "worktree": "/tmp/x", "sha": "deadbeef", "routed": true, "bytes": 100, "secs_remote": 5, "cause": ""}
JSON
r7a_out="$("$BL" enable)"; r7a_rc=$?
expect "reenable AC7a: enable exits 0 on a fresh, routed, image-matching proof" "[ $r7a_rc -eq 0 ]"
expect "reenable AC7a: the drop-in exists with Environment=BUILD_BURST_ENABLED=1" \
  "grep -q '^Environment=BUILD_BURST_ENABLED=1$' \"$BURST_LANE_SYSTEMD_DROPIN\""
expect "reenable AC7a: journal has enable done (proof_ts=... image_id=555777)" \
  "grep -q \"burst-lane  enable  done  (proof_ts=$r7a_now image_id=555777)\" \"$BURST_LANE_JOURNAL\""
expect "reenable AC7a: burst_configured() reads true in a fresh shell sourcing the drop-in's Environment= line" \
  "bash -c 'set -a; source <(grep ^Environment= \"$BURST_LANE_SYSTEMD_DROPIN\"); set +a; source \"$HERE/lib/burst-configured.sh\"; burst_configured'"

# Case b: no proof.json at all -> refused, no drop-in.
fresh_env
r7b_out="$("$BL" enable 2>&1)"; r7b_rc=$?
expect "reenable AC7b: enable exits 3 with no proof.json" "[ $r7b_rc -eq 3 ]"
expect "reenable AC7b: no drop-in was written" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC7b: journal names the refusal cause" \
  "grep -q 'burst-lane  enable  refused  (cause=no-proof)' \"$BURST_LANE_JOURNAL\""

# Case c: a proof.json older than 7 days -> refused (cause=stale), image
# otherwise matching the env-resolved default (fresh_env's env file sets
# SNAPSHOT_ID=427125061, no snapshot.json baked this case).
fresh_env
r7c_old="$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_LANE_STATE_DIR/current/proof.json" <<JSON
{"ts": "$r7c_old", "image_id": "427125061", "server_id": "1", "worktree": "/tmp/x", "sha": "deadbeef", "routed": true, "bytes": 100, "secs_remote": 5, "cause": ""}
JSON
r7c_out="$("$BL" enable 2>&1)"; r7c_rc=$?
expect "reenable AC7c: enable exits 3 on a proof older than 7 days" "[ $r7c_rc -eq 3 ]"
expect "reenable AC7c: no drop-in was written" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC7c: journal names the refusal cause" \
  "grep -q 'burst-lane  enable  refused  (cause=stale)' \"$BURST_LANE_JOURNAL\""

# Case d: proof.json says routed=false -> refused (cause=not-routed).
fresh_env
r7d_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_LANE_STATE_DIR/current/proof.json" <<JSON
{"ts": "$r7d_now", "image_id": "427125061", "server_id": "1", "worktree": "/tmp/x", "sha": "deadbeef", "routed": false, "bytes": 0, "secs_remote": 5, "cause": "host-mismatch"}
JSON
r7d_out="$("$BL" enable 2>&1)"; r7d_rc=$?
expect "reenable AC7d: enable exits 3 when proof.routed is false" "[ $r7d_rc -eq 3 ]"
expect "reenable AC7d: no drop-in was written" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC7d: journal names the refusal cause" \
  "grep -q 'burst-lane  enable  refused  (cause=not-routed)' \"$BURST_LANE_JOURNAL\""

# Case e: proof.json names an image other than the one `up` would boot now
# -> refused (cause=image-mismatch).
fresh_env
r7e_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_LANE_STATE_DIR/current/proof.json" <<JSON
{"ts": "$r7e_now", "image_id": "111222", "server_id": "1", "worktree": "/tmp/x", "sha": "deadbeef", "routed": true, "bytes": 100, "secs_remote": 5, "cause": ""}
JSON
r7e_out="$("$BL" enable 2>&1)"; r7e_rc=$?
expect "reenable AC7e: enable exits 3 when the proof names a different image" "[ $r7e_rc -eq 3 ]"
expect "reenable AC7e: no drop-in was written" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC7e: journal names the refusal cause" \
  "grep -q 'burst-lane  enable  refused  (cause=image-mismatch)' \"$BURST_LANE_JOURNAL\""

# Case f: `disable` always removes the drop-in and journals cause=operator,
# whether or not one was present.
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$BURST_LANE_SYSTEMD_DROPIN"
r7f_out="$("$BL" disable)"; r7f_rc=$?
expect "reenable AC7f: disable exits 0" "[ $r7f_rc -eq 0 ]"
expect "reenable AC7f: the drop-in no longer exists" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC7f: journal has disable done (cause=operator)" \
  "grep -q 'burst-lane  disable  done  (cause=operator)' \"$BURST_LANE_JOURNAL\""

# ---- reenable AC8: fail-closed at the tick for the ORDINARY (non-gate)
# cargo/uv path — `up` or `verify` failing inside `run`, or an explicit
# `pull`'s rsync-down failing, journals a "fallback (cause=...)" line and
# the caller gets rc=3 (falls back local) rather than a silent stdout-only
# message. `gate`'s own up-failed/rsync-up-failed/gate-tools-missing lines
# already proved this contract for the gate path (PRD-build-gate-on-casper,
# PRD-build-burst-gate-tools-scope); this proves the matching `run`/`pull`
# gap just closed above.

# Case a: `up` itself fails (no session yet) -> run exits 3, journals
# cause=up-failed (no server_id — up never got one).
fresh_env
export FAKE_HCLOUD_CREATE_FAIL=1
WT8A="$T/worktree-ac8a"; mkdir -p "$WT8A"
echo 'exit 0' > "$WT8A/build.sh"
r8a_out="$("$BL" run "$WT8A" -- bash build.sh 2>&1)"; r8a_rc=$?
unset FAKE_HCLOUD_CREATE_FAIL
expect "reenable AC8a: run exits 3 when up itself fails" "[ $r8a_rc -eq 3 ]"
expect "reenable AC8a: journal has run fallback (cause=up-failed worktree=$WT8A)" \
  "grep -qF \"burst-lane  run  fallback  (cause=up-failed worktree=$WT8A)\" \"$BURST_LANE_JOURNAL\""

# Case b: `up` succeeds but `verify` fails -> run exits 3, journals
# cause=verify-failed naming the server_id.
fresh_env
"$BL" up >/dev/null
sed -i 's/"verified":"true"/"verified":"false"/' "$BURST_LANE_STATE_DIR/current/session.json"
r8b_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
WT8B="$T/worktree-ac8b"; mkdir -p "$WT8B"
echo 'exit 0' > "$WT8B/build.sh"
export FAKE_SSH_REMOTE_FAIL=1
r8b_out="$("$BL" run "$WT8B" -- bash build.sh 2>&1)"; r8b_rc=$?
unset FAKE_SSH_REMOTE_FAIL
expect "reenable AC8b: run exits 3 when verify fails" "[ $r8b_rc -eq 3 ]"
expect "reenable AC8b: journal has run fallback (cause=verify-failed server_id=$r8b_sid worktree=$WT8B)" \
  "grep -qF \"burst-lane  run  fallback  (cause=verify-failed server_id=$r8b_sid worktree=$WT8B)\" \"$BURST_LANE_JOURNAL\""

# Case c: an explicit pull whose rsync-down fails -> exits 3; already
# journaled by do_marker_pull itself as
# "pull fallback (cause=rsync-failed ...)" (AC8's pull-failed cause is this
# existing line, not a new duplicate one — see the comment at cmd_pull's own
# end).
fresh_env
"$BL" up >/dev/null
WT8C="$T/worktree-ac8c"; mkdir -p "$WT8C"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT8C/build.sh"
"$BL" run "$WT8C" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1
r8c_out="$("$BL" pull "$WT8C" 2>&1)"; r8c_rc=$?
unset FAKE_RSYNC_FAIL
expect "reenable AC8c: pull exits 3 when the rsync-down fails" "[ $r8c_rc -eq 3 ]"
# PRD-build-burst-pull-remote-target-missing requirement 2: rc/err/
# attempts/next_retry_s now ride between cause= and worktree= — this is
# still the same fresh (attempt 1) marker, default FAKE_RSYNC_FAIL rc/msg.
expect "reenable AC8c: journal has pull fallback (cause=rsync-failed worktree=$WT8C)" \
  "grep -qF \"burst-lane  pull  fallback  (cause=rsync-failed rc=23 err=\\\"rsync: fake failure injected\\\" attempts=1 next_retry_s=30 worktree=$WT8C\" \"$BURST_LANE_JOURNAL\""

# ---- reenable AC9: auto-disable fires on either trigger — two sessions
# within 24h both zero-run (cause=zero-run-sessions), or a day's deleted-box
# cost reaching BURST_AUTO_DISABLE_EUR_PER_DAY with no routed run
# (cause=eur-ceiling). Production-wired at the end of teardown_and_delete
# (every down/watchdog/idle-guard teardown) and cmd_up's own
# ssh-unreachable-before-boot fallback. Exercised here as a direct unit
# test of check_auto_disable() — same "source $BL in a subshell" idiom the
# cargo_target_dir_for unit test above uses — since reaching this point
# twice via a full fake up->run->down cycle would only re-prove machinery
# already covered by the AC1/AC8/AC13 fixtures elsewhere in this file; what
# is new here is check_auto_disable's own decision logic over
# $BURST_LANE_COST_LEDGER rows, which a hand-written ledger exercises
# directly and deterministically.

# Case a: a single zero-run session within 24h -> no trigger (only the
# SECOND such session fires it).
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$BURST_LANE_SYSTEMD_DROPIN"
cat > "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T01:00:00Z", "hours": 1.0, "eur": 0.05, "prds": [], "session_id": "s1"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T01:30:00Z' +%s)"
r9a_err="$T/r9a.err"
( source "$BL"; check_auto_disable ) 2>"$r9a_err"
expect "reenable AC9a: one zero-run session alone does not auto-disable" "[ -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC9a: nothing printed to stderr" "[ ! -s \"$r9a_err\" ]"
expect "reenable AC9a: no auto-disabled line journaled" "! grep -q 'auto-disabled' \"$BURST_LANE_JOURNAL\""

# Case b: a SECOND zero-run session within 24h of the first -> auto-disable
# fires, naming both session ids, drop-in removed, printed to stderr too
# (continues case a's ledger/drop-in state — this IS "the second" session).
cat >> "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T02:00:00Z", "hours": 1.0, "eur": 0.05, "prds": [], "session_id": "s2"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T02:15:00Z' +%s)"
r9b_err="$T/r9b.err"
( source "$BL"; check_auto_disable ) 2>"$r9b_err"
expect "reenable AC9b: the drop-in is removed" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC9b: journal carries auto-disabled (cause=zero-run-sessions sessions=s1,s2)" \
  "grep -q 'burst-lane  auto-disabled  (cause=zero-run-sessions sessions=s1,s2)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC9b: the same line was printed to stderr" \
  "grep -q 'burst-lane  auto-disabled  (cause=zero-run-sessions sessions=s1,s2)' \"$r9b_err\""

# Case c: two sessions within 24h, but one of them served a routed run ->
# no trigger (both must be zero-run; one PRD served is enough to block it).
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$BURST_LANE_SYSTEMD_DROPIN"
cat > "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T01:00:00Z", "hours": 1.0, "eur": 0.05, "prds": ["fake-prd"], "session_id": "s3"}
{"date": "2026-09-15T02:00:00Z", "hours": 1.0, "eur": 0.05, "prds": [], "session_id": "s4"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T02:15:00Z' +%s)"
( source "$BL"; check_auto_disable ) 2>/dev/null
expect "reenable AC9c: a served session in the pair blocks zero-run-sessions" "[ -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"

# Case d: a single session alone reaches BURST_AUTO_DISABLE_EUR_PER_DAY
# (default 2.00) with no routed run -> auto-disable fires cause=eur-ceiling.
# Only ONE session exists today, so trigger (a)'s "two sessions" can never
# apply here — this isolates the eur-ceiling trigger from the zero-run one.
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$BURST_LANE_SYSTEMD_DROPIN"
cat > "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T04:00:00Z", "hours": 2.0, "eur": 2.5000, "prds": [], "session_id": "s5"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T05:00:00Z' +%s)"
r9d_err="$T/r9d.err"
( source "$BL"; check_auto_disable ) 2>"$r9d_err"
expect "reenable AC9d: the drop-in is removed" "[ ! -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"
expect "reenable AC9d: journal carries auto-disabled (cause=eur-ceiling eur=2.5000)" \
  "grep -q 'burst-lane  auto-disabled  (cause=eur-ceiling eur=2.5000)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC9d: the same line was printed to stderr" \
  "grep -q 'cause=eur-ceiling eur=2.5000' \"$r9d_err\""

# Case e: a day's total under the ceiling -> no trigger.
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$BURST_LANE_SYSTEMD_DROPIN"
cat > "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T04:00:00Z", "hours": 0.5, "eur": 0.6000, "prds": [], "session_id": "s6"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T05:00:00Z' +%s)"
( source "$BL"; check_auto_disable ) 2>/dev/null
expect "reenable AC9e: under the eur ceiling does not auto-disable" "[ -f \"$BURST_LANE_SYSTEMD_DROPIN\" ]"

# Case f: no drop-in present (lane already disabled) -> check_auto_disable
# is a silent no-op even when the ledger alone would otherwise trigger —
# nothing to disable, matching "Re-enabling is only ever enable".
fresh_env
cat > "$BURST_LANE_COST_LEDGER" <<'JSON'
{"date": "2026-09-15T01:00:00Z", "hours": 1.0, "eur": 5.0, "prds": [], "session_id": "s7"}
{"date": "2026-09-15T02:00:00Z", "hours": 1.0, "eur": 5.0, "prds": [], "session_id": "s8"}
JSON
export BURST_LANE_NOW="$(date -u -d '2026-09-15T02:15:00Z' +%s)"
r9f_err="$T/r9f.err"
( source "$BL"; check_auto_disable ) 2>"$r9f_err"
expect "reenable AC9f: no drop-in to remove -> no journal line, no stderr" \
  "! grep -q 'auto-disabled' \"$BURST_LANE_JOURNAL\" && [ ! -s \"$r9f_err\" ]"

# ---- reenable AC12: status (text and --json) reports image_id,
# image_source, bake_age_h, proof_age_h, proof_routed, enabled — session-
# independent, so this holds with no active session too.
# Case a: nothing baked/proved/enabled yet.
fresh_env
r12a_json="$("$BL" status --json)"
expect "reenable AC12a: status --json reports image_source=env with no snapshot.json" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['image_source']=='env', d\" '$r12a_json'"
expect "reenable AC12a: bake_age_h is null (never baked)" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['bake_age_h'] is None, d\" '$r12a_json'"
expect "reenable AC12a: proof_age_h/proof_routed are null (never proved)" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['proof_age_h'] is None and d['proof_routed'] is None, d\" '$r12a_json'"
expect "reenable AC12a: enabled is false (no drop-in)" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['enabled'] is False, d\" '$r12a_json'"
expect "reenable AC12a: status --json uses compact separators (cmd_route_check's *'active':true* substring match must still fire)" \
  "python3 -c \"import sys; assert '\\\"active\\\":false' in sys.argv[1], sys.argv[1]\" '$r12a_json'"

# Case b: a snapshot.json exists (baked) -> image_source=baked, bake_age_h
# numeric.
fresh_env
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "999891", "created": "2026-09-13T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["999891"]}
JSON
r12b_json="$("$BL" status --json)"
expect "reenable AC12b: image_source=baked" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['image_source']=='baked' and d['image_id']=='999891', d\" '$r12b_json'"
expect "reenable AC12b: bake_age_h is a non-negative number" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert isinstance(d['bake_age_h'], (int,float)) and d['bake_age_h']>=0, d\" '$r12b_json'"

# Case c: a proof.json exists with routed=true -> proof_routed=true,
# proof_age_h numeric.
fresh_env
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/current/proof.json" <<'JSON'
{"ts": "2026-09-13T00:00:00Z", "image_id": "999891", "server_id": "1", "worktree": "/tmp/x", "sha": "deadbeef", "routed": true, "bytes": 100, "secs_remote": 5, "cause": ""}
JSON
r12c_json="$("$BL" status --json)"
expect "reenable AC12c: proof_routed is true" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['proof_routed'] is True, d\" '$r12c_json'"
expect "reenable AC12c: proof_age_h is a non-negative number" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert isinstance(d['proof_age_h'], (int,float)) and d['proof_age_h']>=0, d\" '$r12c_json'"

# Case d: the systemd drop-in exists -> enabled=true.
fresh_env
mkdir -p "$(dirname "$BURST_LANE_SYSTEMD_DROPIN")"
echo "[Service]" > "$BURST_LANE_SYSTEMD_DROPIN"
r12d_json="$("$BL" status --json)"
expect "reenable AC12d: enabled is true when the drop-in file exists" \
  "python3 -c \"import json,sys; d=json.loads(sys.argv[1]); assert d['enabled'] is True, d\" '$r12d_json'"

# Case e: text-mode "no active session" stays byte-exact and single-line —
# the cargo/uv shims (burst-lane-bin/{cargo,uv}) both do a WHOLE-OUTPUT
# `[ "$status_out" != "no active session" ]` comparison, so requirement 6's
# extras are --json-only for now (see burst-lane.sh's own comment at that
# call site); this case is the regression guard for that.
fresh_env
r12e_text="$("$BL" status)"
expect "reenable AC12e: text-mode 'no active session' is unchanged, byte-exact, single-line" \
  "[ \"$r12e_text\" = 'no active session' ]"

# ---- reenable AC13: a bake that changed the image id refreshes the cached
# LOCAL parity capture on the next session, journaling cause=bake BEFORE any
# parity comparison — see refresh_parity_baseline_on_image_change in
# burst-lane.sh (requirement 7).
# Case a: a tracked prior image differs from the current one -> each
# configured repo's cached test-output.txt is deleted and the refresh is
# journaled.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder"
echo "stale local capture" > "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt"
echo -n "111" > "$BURST_LANE_STATE_DIR/parity-baseline-image"
(
  source "$BL"
  refresh_parity_baseline_on_image_change "222"
)
expect "reenable AC13a: the stale cached local capture was deleted" \
  "[ ! -f \"$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt\" ]"
expect "reenable AC13a: journal has parity baseline-refreshed (cause=bake image_id=222)" \
  "grep -q 'burst-lane  parity  baseline-refreshed  (cause=bake image_id=222' \"$BURST_LANE_JOURNAL\""
expect "reenable AC13a: the tracked baseline image is now the new one" \
  "[ \"\$(cat \"$BURST_LANE_STATE_DIR/parity-baseline-image\")\" = 222 ]"

# Case b: no prior tracked image (first-ever session, or a fresh_env) ->
# nothing to compare against, so no refresh/journal — just records the
# current image for next time.
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder"
echo "first capture" > "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt"
(
  source "$BL"
  refresh_parity_baseline_on_image_change "333"
)
expect "reenable AC13b: no prior baseline -> the cached local capture is left alone" \
  "[ -f \"$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt\" ]"
expect "reenable AC13b: no baseline-refreshed line was journaled" \
  "! grep -q 'parity  baseline-refreshed' \"$BURST_LANE_JOURNAL\""
expect "reenable AC13b: the tracked baseline image is now recorded" \
  "[ \"\$(cat \"$BURST_LANE_STATE_DIR/parity-baseline-image\")\" = 333 ]"

# Case c: the resolved image is unchanged from the tracked one -> no refresh,
# no journal, cache untouched (the ordinary case, no bake happened).
fresh_env
mkdir -p "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder"
echo "still fresh" > "$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt"
echo -n "444" > "$BURST_LANE_STATE_DIR/parity-baseline-image"
(
  source "$BL"
  refresh_parity_baseline_on_image_change "444"
)
expect "reenable AC13c: same image -> the cached local capture is left alone" \
  "[ -f \"$BURST_LANE_REPOS_DIR/mcphost/target/autobuilder/test-output.txt\" ]"
expect "reenable AC13c: no baseline-refreshed line was journaled" \
  "! grep -q 'parity  baseline-refreshed' \"$BURST_LANE_JOURNAL\""

# Case d (structural ordering guard): `up` must call the refresh on BOTH the
# fresh-boot and adopt paths, and in each case BEFORE it calls
# schedule_session_parity, so the refresh (and its journal line) always
# precede the actual backgrounded parity comparison — grep-checked directly
# against the source rather than driving two full `up` sessions (adopt + a
# real second boot) just to observe ordering.
#
# PRD-build-burst-state-keyed-by-server-v2 requirement 2: this per-box body
# (adopt/create, verify, refresh, schedule_session_parity) now lives in
# up_one_box(), called once per box by cmd_up's own `--count N` loop —
# cmd_up() itself is just that loop plus the lock/cap bookkeeping and no
# longer contains either call. Scans up_one_box() instead of cmd_up() for
# exactly that reason; the ordering being asserted (refresh before
# schedule_session_parity) is unchanged, only which function's source holds
# it moved.
expect "reenable AC13d: cmd_up's fresh-boot path calls the refresh before scheduling parity" \
  "awk '/^up_one_box\\(\\)/,/^}/' \"$BL\" | grep -B2 'schedule_session_parity \"\\\$id\"' | grep -q refresh_parity_baseline_on_image_change"
expect "reenable AC13d: cmd_up's adopt path calls the refresh before scheduling parity" \
  "awk '/^up_one_box\\(\\)/,/^}/' \"$BL\" | grep -B2 'schedule_session_parity \"\\\$aid\"' | grep -q refresh_parity_baseline_on_image_change"

# ---- reenable AC14: `up` on a gate-ready boot calls
# `reality-check.sh pending-run build-skill` before ordinary work, so a
# pending box-only registration clears on the first real boot after this
# PRD lands — see run_pending_reality_check_if_gate_ready in burst-lane.sh
# (requirement 8).
# Case a: no pending registrations -> a bare, default (gate_ready=true) `up`
# still calls it — a no-op, rc=0, journaled — never a hard failure.
# BURST_LANE_AUTOBUILDER_BIN (same fixture as reenable AC1's setup) makes
# the LOCAL autobuilder version match the fake ssh's own reported remote
# version — this host's real ~/.cargo/bin/autobuilder would otherwise read
# as version-drift and gate_ready would never reach true, unrelated to
# anything this AC is testing.
fresh_env
REEN_14A_SRC="$T/fake-autobuilder-src-14a"; mkdir -p "$REEN_14A_SRC"
cat > "$REEN_14A_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN_14A_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN_14A_SRC/autobuilder"
"$BL" up >/dev/null 2>&1
expect "reenable AC14a: session reached gate_ready=true (default fixture)" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "reenable AC14a: up journals pending-reality-run (rc=0) with nothing pending" \
  "grep -q 'burst-lane  up  pending-reality-run  (rc=0)' \"$BURST_LANE_JOURNAL\""

# Case b: a registered box-only pending check exists -> `up` consumes it
# (the registration file is removed), a receipt is written, and the
# receipt's own PRD/reality bookkeeping runs — proving this is the REAL
# reality-check.sh, not a stub, wired end to end. The named PRD file does
# not exist, exercising do_pending_run's own "parent PRD no longer exists —
# receipt still recorded" tolerance rather than needing a real git repo.
fresh_env
REEN_14B_SRC="$T/fake-autobuilder-src-14b"; mkdir -p "$REEN_14B_SRC"
cat > "$REEN_14B_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN_14B_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN_14B_SRC/autobuilder"
mkdir -p "$REALITY_CHECK_PENDING_DIR"
cat > "$REALITY_CHECK_PENDING_DIR/reenable-ac14-ac9.json" <<JSON
{"prd": "$T/no-such-prd.md", "slug": "reenable-ac14", "ac": 9, "command": "true", "registered_at": "2026-09-14T00:00:00Z", "probes": [], "alarmed": false}
JSON
"$BL" up >/dev/null 2>&1
expect "reenable AC14b: the pending registration was consumed (file removed)" \
  "[ ! -f \"$REALITY_CHECK_PENDING_DIR/reenable-ac14-ac9.json\" ]"
expect "reenable AC14b: a reality receipt was written for it" \
  "ls \"$BUILD_RECEIPTS_DIR\"/*-reenable-ac14-ac9-reality-boxrun.txt >/dev/null 2>&1"
# PRD-build-burst-dispatch-reenable AC14b root cause (part 1, fixed
# 98cbbb7): reality-check.sh's box-tier verdict line goes through the
# shared scripts/lib/journal.sh journal_line() (no --file), whose
# journal_root() honors BUILD_JOURNAL_ROOT outright once it's set — and
# run-selftests.sh's isolation.sh always sets it — ahead of any legacy
# alias. That part is right under the isolated entrypoint. Root cause
# (part 2, found re-deriving this AC via tests/reenable_ac14_*.sh, which
# — like every other tests/<prefix>_ac<N>_*.sh wrapper in this repo —
# runs this suite BARE, i.e. NOT through run-selftests.sh's isolation.sh,
# so BUILD_JOURNAL_ROOT is unset here): journal.sh's legacy-var detection
# checks FILE vars before DIR vars (BURST_LANE_JOURNAL, GATE_WEDGE_JOURNAL,
# SELECT_GUARD_JOURNAL, CARGO_BUDGET_JOURNAL, then JOURNAL_DIR,
# BUILD_JOURNAL_DIR, TICK_JOURNAL_DIR), and fresh_env (above, every case)
# unconditionally exports BURST_LANE_JOURNAL for burst-lane.sh's own
# operational log — so under a bare invocation BURST_LANE_JOURNAL wins
# ahead of this fixture's own BUILD_JOURNAL_DIR override, and
# reality-check.sh's verdict line lands in burst-lane.sh's journal file,
# not a BUILD_JOURNAL_DIR/BUILD_JOURNAL_ROOT-dated file at all. Rather
# than re-guess journal.sh's precedence a second time (that's exactly how
# part 1 of this bug shipped), source the real implementation and ask it.
reen_14b_journal_target="$(
  source "$HERE/lib/journal.sh"
  legacy="$(_journal_legacy_active_name)"
  if [ -n "$legacy" ]; then
    _journal_legacy_target "$legacy"
  else
    printf '%s\n' "$(journal_root)/$(date -u +%F).md"
  fi
)"
expect "reenable AC14b: reality-check's own journal records the verdict (tier=box)" \
  "grep -q 'reality  reenable-ac14  ok  (lane=.*tier=box ac=9' \"$reen_14b_journal_target\""
expect "reenable AC14b: burst-lane's own up journals pending-reality-run (rc=0) too" \
  "grep -q 'burst-lane  up  pending-reality-run  (rc=0)' \"$BURST_LANE_JOURNAL\""

# Case c: gate_ready=false (same deterministic missing+install-fail setup
# bursttdl AC4/gatetools AC2/AC3 use) -> the pending-run is never even
# attempted; a registration sits untouched until a later gate-ready boot.
fresh_env
mkdir -p "$REALITY_CHECK_PENDING_DIR"
cat > "$REALITY_CHECK_PENDING_DIR/reenable-ac14c-ac1.json" <<JSON
{"prd": "$T/no-such-prd.md", "slug": "reenable-ac14c", "ac": 1, "command": "true", "registered_at": "2026-09-14T00:00:00Z", "probes": [], "alarmed": false}
JSON
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL=1
"$BL" up >/dev/null 2>&1
expect "reenable AC14c setup: session is gate_ready=false" \
  "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "reenable AC14c: no pending-reality-run was journaled while gate_ready=false" \
  "! grep -q 'burst-lane  up  pending-reality-run' \"$BURST_LANE_JOURNAL\""
expect "reenable AC14c: the pending registration is left untouched" \
  "[ -f \"$REALITY_CHECK_PENDING_DIR/reenable-ac14c-ac1.json\" ]"
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL

# ---- reenable AC15 (requirement 1, auto-bake at down): a session that had
# to install at least one gate tool and still ended gate_ready=true gets
# baked automatically by `down`, before the delete — the next boot
# shouldn't repeat this session's own install cost. A session with zero
# install-start lines deletes without baking, unchanged. A third bake
# (auto or operator-invoked, same mechanism) still only ever supersedes —
# never deletes — the oldest image, matching cmd_bake's own two-image-keep
# cap (reenable AC1).
REEN15_AB_SRC="$T/fake-autobuilder-src-15"; mkdir -p "$REEN15_AB_SRC"
cat > "$REEN15_AB_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN15_AB_SRC/autobuilder"

# Cases a/b call `auto_bake_before_delete` directly (source-and-call, the
# same unit-test technique this file's own "cargo_target_dir_for" case
# above uses) rather than driving it through a full `down` — this
# environment's `destroy_verify`/`server_alive` never reaches the "gone"
# branch against the fake hcloud (no `server list` subcommand exists in
# tests/fixtures/burst-lane-fake/hcloud, so its fail-open fallback always
# reports the just-deleted server as still alive and `down` never prints
# `decision=deleted` here) — a real, pre-existing gap this PRD did not
# introduce and whose fix belongs to whatever PRD owns that shared
# fixture, not this one. `auto_bake_before_delete` itself does not call
# `destroy_verify`, so this case still proves exactly what AC15 asks: that
# the trigger fires (or doesn't) correctly given a session's own
# gate_ready/install-start history. Its wiring at the correct point in
# `down`'s own delete path — strictly before the delete is attempted — is
# proven separately below as a source-order lint.

# Case a: one tool missing this session (exactly one install-start line),
# gate_ready reached true -> the trigger fires and bakes.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN15_AB_SRC/autobuilder"
export FAKE_SSH_GATE_TOOLS_MISSING="jq"
"$BL" up >/dev/null 2>&1
r15a_gate_ready="$(grep -oE '"gate_ready":"[^"]*"' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d'"' -f4)"
expect "reenable AC15a setup: session is gate_ready=true" "[ \"$r15a_gate_ready\" = true ]"
r15a_installs="$(grep -c 'burst-lane  gate-tools  install-start' "$BURST_LANE_JOURNAL")"
expect "reenable AC15a setup: exactly one install-start line" "[ \"$r15a_installs\" -eq 1 ]"
r15a_id="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
( source "$BL"; auto_bake_before_delete "$r15a_id" down ) >/dev/null 2>&1
expect "reenable AC15a: journal has the auto-bake trigger naming the install count" \
  "grep -qE 'burst-lane  down  auto-bake  \\(cause=install-start-count=1 server_id=' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15a: journal has bake done" \
  "grep -qE 'burst-lane  bake  done  \\(image_id=[0-9]+ superseded=none secs=[0-9]+\\)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15a: snapshot.json now names the new image" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/snapshot.json')); assert d.get('image_id')\""
unset FAKE_SSH_GATE_TOOLS_MISSING

# Case b: zero install-start lines this session (every tool already
# present) -> the trigger is a no-op; no bake at all.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN15_AB_SRC/autobuilder"
"$BL" up >/dev/null 2>&1
r15b_installs="$(grep -c 'burst-lane  gate-tools  install-start' "$BURST_LANE_JOURNAL")"
expect "reenable AC15b setup: zero install-start lines" "[ \"$r15b_installs\" -eq 0 ]"
r15b_id="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
( source "$BL"; auto_bake_before_delete "$r15b_id" down ) >/dev/null 2>&1
expect "reenable AC15b: no auto-bake was journaled" \
  "! grep -q 'burst-lane  down  auto-bake' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15b: no bake done was journaled" \
  "! grep -q 'burst-lane  bake  done' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15b: no snapshot.json was written" "[ ! -f \"$BURST_LANE_STATE_DIR/snapshot.json\" ]"

# Case d (source-order lint): `auto_bake_before_delete` is wired into
# `teardown_and_delete` strictly BEFORE `destroy_verify` — the property
# cases a/b above cannot exercise end to end (see the note above) but that
# AC15's "bake ran first" still requires. A grep over burst-lane.sh's own
# source, not a runtime trace: the two call sites' line numbers inside
# teardown_and_delete's body must appear in that order.
r15d_tad_start="$(grep -n '^teardown_and_delete()' "$BL" | head -1 | cut -d: -f1)"
r15d_bake_call="$(awk -v from="$r15d_tad_start" 'NR>from && /auto_bake_before_delete "\$id" "\$caller"/{print NR; exit}' "$BL")"
r15d_destroy_call="$(awk -v from="$r15d_tad_start" 'NR>from && /if destroy_verify "\$id"; then/{print NR; exit}' "$BL")"
expect "reenable AC15d: auto_bake_before_delete is wired into teardown_and_delete before destroy_verify" \
  "[ -n \"$r15d_bake_call\" ] && [ -n \"$r15d_destroy_call\" ] && [ \"$r15d_bake_call\" -lt \"$r15d_destroy_call\" ]"

# Case c: a bake landing on an ALREADY-full two-image history (seeded
# directly, same technique reenable AC4 uses for snapshot.json, rather than
# three live bakes in a row — the fake hcloud's `create-image` mints a
# RANDOM id (tests/fixtures/burst-lane-fake/hcloud), so three calls sharing
# one same-day description can't be relied on to resolve strictly
# increasing ids the way real Hetzner ids do) supersedes (journals, never
# deletes) the oldest of the two.
fresh_env
export BURST_LANE_AUTOBUILDER_BIN="$REEN15_AB_SRC/autobuilder"
mkdir -p "$BURST_LANE_STATE_DIR"
cat > "$BURST_LANE_STATE_DIR/snapshot.json" <<'JSON'
{"image_id": "222222", "created": "2026-09-14T00:00:00Z", "base_image_id": "427125061", "build_skill_sha": "abc123", "gate_tool_versions": {}, "baked_history": ["111111", "222222"]}
JSON
"$BL" up >/dev/null 2>&1
r15c_out="$("$BL" bake)"; r15c_rc=$?
r15c_new_id="$(sed -n 's/^bake done: image_id=//p' <<<"$r15c_out")"
expect "reenable AC15c: bake against an already-full history still exits 0" "[ $r15c_rc -eq 0 ]"
expect "reenable AC15c: the new bake's own id is neither of the two prior ones" \
  "[ -n \"$r15c_new_id\" ] && [ \"$r15c_new_id\" != 111111 ] && [ \"$r15c_new_id\" != 222222 ]"
expect "reenable AC15c: the bake journals the second (most recent) prior image as superseded=... in bake done" \
  "grep -qE 'burst-lane  bake  done  \\(image_id='\"$r15c_new_id\"' superseded=222222 secs=[0-9]+\\)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15c: the bake journals the first (oldest) prior image as superseded, delete=operator" \
  "grep -qE 'burst-lane  bake  superseded  \\(image_id=111111 delete=operator\\)' \"$BURST_LANE_JOURNAL\""
expect "reenable AC15c: snapshot.json's baked_history now holds exactly the two most recent images" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/snapshot.json')); assert d.get('baked_history') == ['222222', '$r15c_new_id'], d\""
expect "reenable AC15c: no hcloud image delete call was ever made by the lane" \
  "! grep -q 'image delete' \"$FAKE_HCLOUD_CALLLOG\""

expect_block_green "reenable" "reenable: every reenable case above ran green"

# =============================================================================
# PRD-build-operator-authorization-contract: cmd_up/cmd_bake/cmd_prove
# refuse a dispatched call with no authorization before touching hcloud
# (AC8), record the authorization string as authz= in their journal_line
# calls when one is present (AC7), and are unaffected when invoked with no
# dispatch-context marker at all — the human-at-keyboard path (AC9).
# (test_prefix: opauth)
# =============================================================================
block_start "opauth"

# ---- opauth AC8: dispatched (BURST_LANE_DISPATCH=1) with no authorization
# string -> up refuses before any hcloud call, exits non-zero, and journals
# the named cause.
fresh_env
export BURST_LANE_DISPATCH=1
unset BURST_LANE_AUTHZ
opauth8_out="$("$BL" up 2>&1)"; opauth8_rc=$?
expect "opauth AC8: dispatched up with no authorization exits non-zero" "[ $opauth8_rc -ne 0 ]"
expect "opauth AC8: refusal names the cause on stderr" \
  "grep -q 'up refused (cause=no-operator-authorization)' <<<\"\$opauth8_out\""
expect "opauth AC8: journal records the refusal" \
  "grep -q 'burst-lane  up  refused  (cause=no-operator-authorization)' \"\$BURST_LANE_JOURNAL\""
expect "opauth AC8: no hcloud server create call was ever attempted" \
  "[ \"\$(grep -c 'server create' \"\$FAKE_HCLOUD_CALLLOG\")\" -eq 0 ]"
expect "opauth AC8: no session.json was written" "[ ! -f \"\$BURST_LANE_STATE_DIR/current/session.json\" ]"

# Same refusal for bake and prove, dispatched with no authorization.
fresh_env
export BURST_LANE_DISPATCH=1
unset BURST_LANE_AUTHZ
opauth8b_out="$("$BL" bake 2>&1)"; opauth8b_rc=$?
expect "opauth AC8: dispatched bake with no authorization exits non-zero" "[ $opauth8b_rc -ne 0 ]"
expect "opauth AC8: bake journal records the refusal" \
  "grep -q 'burst-lane  bake  refused  (cause=no-operator-authorization)' \"\$BURST_LANE_JOURNAL\""
expect "opauth AC8: bake attempted no hcloud call" \
  "[ \"\$(wc -l < \"\$FAKE_HCLOUD_CALLLOG\")\" -eq 0 ]"

fresh_env
export BURST_LANE_DISPATCH=1
unset BURST_LANE_AUTHZ
opauth8c_out="$("$BL" prove 2>&1)"; opauth8c_rc=$?
expect "opauth AC8: dispatched prove with no authorization exits non-zero" "[ $opauth8c_rc -ne 0 ]"
expect "opauth AC8: prove journal records the refusal" \
  "grep -q 'burst-lane  prove  refused  (cause=no-operator-authorization)' \"\$BURST_LANE_JOURNAL\""
expect "opauth AC8: prove attempted no hcloud call" \
  "[ \"\$(wc -l < \"\$FAKE_HCLOUD_CALLLOG\")\" -eq 0 ]"
expect "opauth AC8: prove wrote no proof.json on the pre-hcloud refusal" \
  "[ ! -f \"\$BURST_LANE_STATE_DIR/current/proof.json\" ]"

# ---- opauth AC9: no dispatch-context marker at all (a direct human-run
# invocation) -> unaffected, proceeds exactly as before this PRD, even with
# no authorization string set.
fresh_env
unset BURST_LANE_DISPATCH BURST_LANE_AUTHZ
opauth9_out="$("$BL" up)"; opauth9_rc=$?
expect "opauth AC9: undispatched up with no authorization still exits 0" "[ $opauth9_rc -eq 0 ]"
expect "opauth AC9: undispatched up still creates a server" \
  "[ \"\$(grep -c 'server create' \"\$FAKE_HCLOUD_CALLLOG\")\" -eq 1 ]"
expect "opauth AC9: no refusal was journaled" \
  "! grep -q 'cause=no-operator-authorization' \"\$BURST_LANE_JOURNAL\""

# ---- opauth AC7: when an authorization string IS present, up's own
# journal_line for the boot carries it under authz=, dispatched or not.
fresh_env
export BURST_LANE_AUTHZ='Joe 2026-09-13T23:15:00Z "run prove" scope: one real ccx43 for prove'
opauth7_out="$("$BL" up)"; opauth7_rc=$?
expect "opauth AC7: up with an authorization string still exits 0" "[ $opauth7_rc -eq 0 ]"
expect "opauth AC7: the booted journal line carries authz=" \
  "grep -q 'burst-lane  up  booted.*authz=\"Joe 2026-09-13T23:15:00Z' \"\$BURST_LANE_JOURNAL\""

# Same for bake: authz rides into the journaled bake-done line.
fresh_env
REEN_OPAUTH_SRC="$T/fake-autobuilder-opauth"; mkdir -p "$REEN_OPAUTH_SRC"
cat > "$REEN_OPAUTH_SRC/autobuilder" <<'EOF'
#!/usr/bin/env bash
echo "autobuilder 9.9.9"
EOF
chmod +x "$REEN_OPAUTH_SRC/autobuilder"
export BURST_LANE_AUTOBUILDER_BIN="$REEN_OPAUTH_SRC/autobuilder"
export BURST_LANE_AUTHZ='Joe 2026-09-13T23:15:00Z "run prove" scope: one real ccx43 for prove'
"$BL" up >/dev/null 2>&1
opauth7b_out="$("$BL" bake 2>&1)"; opauth7b_rc=$?
expect "opauth AC7: bake with an authorization string exits 0" "[ $opauth7b_rc -eq 0 ]"
expect "opauth AC7: the bake-done journal line carries authz=" \
  "grep -q 'burst-lane  bake  done.*authz=\"Joe 2026-09-13T23:15:00Z' \"\$BURST_LANE_JOURNAL\""

expect_block_green "opauth" "opauth: every opauth case above ran green"

# ---- costrate block (PRD-build-burst-cost-rate-by-type) --------------------
# 2026-09-15: COST_PER_HOUR_EUR was hardcoded to 0.47 (the old ccx53
# estimate) while the fleet actually ran ccx43 (real 0.522/h) and was about
# to move to ccx53 (real 1.009/h) — every cost line, cost.jsonl row and
# per-slug proration under-reported. cost_rate_eur() now prices by the
# SESSION's own recorded server_type (state_read, written at up/adopt time
# and carried forward unchanged by every later state_write), with
# BURST_COST_PER_HOUR_EUR as an operator override and a loud rate-unknown
# journal line for any type not yet in the table. Every case here routes
# the teardown through idle-guard's zero-runs-lifetime path rather than
# down's own last-two-minutes-of-the-hour window (bursttdl AC1's own
# migration case above already proves stripping "phase"/"phase_epoch"
# reads as phase=provisioned, grace-exempt) so "N minutes alive" is exact
# and never fighting an hour boundary.
block_start "costrate"

# ---- costrate AC1: a session recorded as ccx43 prices a 60-minute
# teardown at 0.522/h (±0.001) in both the journal cost line and cost.jsonl.
fresh_env
export BURST_SERVER_TYPE=ccx43
"$BL" up >/dev/null 2>&1
cr1_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
cr1_create="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
expect "costrate AC1: the session records server_type=ccx43 at up time" \
  "grep -q '\"server_type\":\"ccx43\"' \"$BURST_LANE_STATE_DIR/current/session.json\""
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((cr1_create + 3600))
cr1_out="$("$BL" idle-guard 2>&1)"
unset BURST_LANE_NOW
expect "costrate AC1: idle-guard tears down the 60-minute-old ccx43 box" \
  "[ '$cr1_out' = 'idle-guard teardown: $cr1_sid (60m)' ]"
expect "costrate AC1: the journal cost line prices ccx43 at 0.522/h for 60 minutes" \
  "grep -qE 'burst-lane  down  decision=deleted  \\(server_id=$cr1_sid.*minutes=60 cost_eur=0\\.5220' \"$BURST_LANE_JOURNAL\""
expect "costrate AC1: cost.jsonl prices the same session within 0.001 eur of ccx43's 0.522" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_COST_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if abs(d.get('eur',0)-0.522) <= 0.001 else 1)\""
unset BURST_SERVER_TYPE

# ---- costrate AC2: BURST_COST_PER_HOUR_EUR overrides the table -------------
fresh_env
export BURST_COST_PER_HOUR_EUR=2.0
"$BL" up >/dev/null 2>&1
cr2_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
cr2_create="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((cr2_create + 3600))
cr2_out="$("$BL" idle-guard 2>&1)"
unset BURST_LANE_NOW
expect "costrate AC2: idle-guard tears down the 60-minute-old box" \
  "[ '$cr2_out' = 'idle-guard teardown: $cr2_sid (60m)' ]"
expect "costrate AC2: BURST_COST_PER_HOUR_EUR=2.0 wins over the table" \
  "grep -qE 'burst-lane  down  decision=deleted  \\(server_id=$cr2_sid.*minutes=60 cost_eur=2\\.0000' \"$BURST_LANE_JOURNAL\""
expect "costrate AC2: cost.jsonl records the overridden 2.0 rate" \
  "python3 -c \"import json; d=json.loads(open('$BURST_LANE_COST_LEDGER').read().strip().splitlines()[-1]); import sys; sys.exit(0 if abs(d.get('eur',0)-2.0) <= 0.001 else 1)\""
unset BURST_COST_PER_HOUR_EUR

# ---- costrate AC3: an unknown server type falls back to 0.47 and journals
# rate-unknown once.
fresh_env
export BURST_SERVER_TYPE=cpx31
"$BL" up >/dev/null 2>&1
cr3_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
cr3_create="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_LANE_NOW=$((cr3_create + 3600))
cr3_out="$("$BL" idle-guard 2>&1)"
unset BURST_LANE_NOW
expect "costrate AC3: idle-guard tears down the unknown-type box" \
  "[ '$cr3_out' = 'idle-guard teardown: $cr3_sid (60m)' ]"
expect "costrate AC3: an unknown type journals rate-unknown naming the fallback" \
  "grep -q 'burst-lane  cost  rate-unknown  (type=cpx31 using=0.47)' \"$BURST_LANE_JOURNAL\""
expect "costrate AC3: the teardown still prices at the 0.47 fallback" \
  "grep -qE 'burst-lane  down  decision=deleted  \\(server_id=$cr3_sid.*minutes=60 cost_eur=0\\.4700' \"$BURST_LANE_JOURNAL\""
unset BURST_SERVER_TYPE

# ---- costrate AC4: a session booted as ccx43 stays priced ccx43 even when
# BURST_SERVER_TYPE=ccx53 by the time it tears down.
fresh_env
export BURST_SERVER_TYPE=ccx43
"$BL" up >/dev/null 2>&1
cr4_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
cr4_create="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/current/session.json"
export BURST_SERVER_TYPE=ccx53
export BURST_LANE_NOW=$((cr4_create + 3600))
cr4_out="$("$BL" idle-guard 2>&1)"
unset BURST_LANE_NOW
expect "costrate AC4: idle-guard tears down the ccx43-booted box" \
  "[ '$cr4_out' = 'idle-guard teardown: $cr4_sid (60m)' ]"
expect "costrate AC4: the session still reads server_type=ccx43 at teardown time" \
  "grep -qE 'burst-lane  down  decision=deleted  \\(server_id=$cr4_sid.*minutes=60 cost_eur=0\\.5220' \"$BURST_LANE_JOURNAL\""
expect "costrate AC4: it is NOT priced at ccx53's 1.009 despite the env flip" \
  "! grep -qE 'burst-lane  down  decision=deleted  \\(server_id=$cr4_sid.*minutes=60 cost_eur=1\\.0090' \"$BURST_LANE_JOURNAL\""
unset BURST_SERVER_TYPE

expect_block_green "costrate" "costrate: every costrate case above ran green"

# ---- pullback AC11 (PRD-build-burst-pull-back-restore): record, on every
# run, how many transfer-layer failures remain among this PRD's own
# "pullback"-block fixtures (AC3/AC5/AC12 above) and the cause of each, to
# a durable, re-derivable ledger — not a one-time commit message (see
# tests/pullback_ac11_iteration_log.sh's own former documented gap, now
# closed). Written to the REAL repo state dir, never $BURST_LANE_STATE_DIR
# (this run's own sandboxed tmpdir, cleaned up by this process's own EXIT
# trap the moment it returns).
pullback_total="${BLOCK_TOTAL[pullback]:-0}"
pullback_failed="${BLOCK_FAIL[pullback]:-0}"
pullback_causes="none"
if [ "${#PULLBACK_FAILURE_CAUSES[@]}" -gt 0 ]; then
  pullback_causes="$(printf '%s; ' "${PULLBACK_FAILURE_CAUSES[@]}")"
  pullback_causes="${pullback_causes%; }"
fi
mkdir -p "$(dirname "$PULLBACK_ITER_LOG")" 2>/dev/null || true
python3 -c '
import json, sys
rec = {"ts": sys.argv[1], "total": int(sys.argv[2]), "failed": int(sys.argv[3]), "causes": sys.argv[4]}
with open(sys.argv[5], "a") as f:
    f.write(json.dumps(rec) + "\n")
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pullback_total" "$pullback_failed" "$pullback_causes" "$PULLBACK_ITER_LOG" 2>/dev/null \
  && echo "pullback-iteration-log: total=$pullback_total failed=$pullback_failed causes=\"$pullback_causes\" -> $PULLBACK_ITER_LOG" \
  || echo "pullback-iteration-log: WARNING — failed to write $PULLBACK_ITER_LOG" >&2
expect "pullback AC11: the iteration ledger recorded this run" \
  "[ -s \"$PULLBACK_ITER_LOG\" ] && tail -1 \"$PULLBACK_ITER_LOG\" | python3 -c 'import json,sys; json.loads(sys.stdin.read())'"

# =============================================================================
# PRD-build-burst-run-slots-from-box: run slots are sized by the box that
# booted, not by a number in an env file. (test_prefix: boxslots)
# =============================================================================

# ---- boxslots AC1: `up` probes the box once and records box_cores/
# box_mem_gb/box_disk_gb; the run-slot cap derives from them (requirement 1,
# defaults cores 4 / GB 8 / disk 45: min(32/4, 128/8, (600-40)/45) =
# min(8,16,12) = 8, cpu-bound).
fresh_env
FAKE_BOX_CORES=32 FAKE_BOX_MEM_GB=128 FAKE_BOX_DISK_GB=600 "$BL" up >/dev/null
expect "boxslots AC1: session.json carries box_cores=32" \
  "grep -q '\"box_cores\":32' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "boxslots AC1: session.json carries box_mem_gb=128" \
  "grep -q '\"box_mem_gb\":128' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "boxslots AC1: session.json carries box_disk_gb=600" \
  "grep -q '\"box_disk_gb\":600' \"$BURST_LANE_STATE_DIR/current/session.json\""
expect "boxslots AC1: journal names cap=8 source=box bound=cpu" \
  "grep -q 'burst-lane  up  slots  (cap=8 source=box bound=cpu cores=32 mem_gb=128 disk_gb=600)' \"$BURST_LANE_JOURNAL\""

# ---- boxslots AC2: 12 fixture runs on 12 different worktrees, cap unset ->
# the box's own 8-wide cap is what actually gates them (peak concurrently
# held, counted from `run routed` journal lines' own concurrent= field —
# never fake-ssh start/end spans; Technical considerations: burstpar-
# selftest's own overlap counter is a known-drifted metric a later PRD
# fixes, not this one's proof). FAKE_SSH_RUN_DELAY_S forces real overlap
# between the 12 concurrently-launched invocations (same reason burstpar-
# selftest.sh's own dedicated fake ssh sleeps in its exec case).
fresh_env
FAKE_BOX_CORES=32 FAKE_BOX_MEM_GB=128 FAKE_BOX_DISK_GB=600 "$BL" up >/dev/null
boxslots_ac2_pids=()
for i in $(seq 1 12); do
  wt="$T/boxslots-wt$i"; mkdir -p "$wt"
  echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt/build.sh"
  ( FAKE_SSH_RUN_DELAY_S=0.4 "$BL" run "$wt" -- bash build.sh >/dev/null 2>&1 ) &
  boxslots_ac2_pids+=($!)
done
boxslots_ac2_rc_bad=0
for p in "${boxslots_ac2_pids[@]}"; do wait "$p" || boxslots_ac2_rc_bad=$((boxslots_ac2_rc_bad + 1)); done
boxslots_ac2_peak="$(grep 'burst-lane  run  routed' "$BURST_LANE_JOURNAL" 2>/dev/null | grep -oE 'concurrent=[0-9]+/[0-9]+' | cut -d= -f2 | cut -d/ -f1 | sort -n | tail -1)"
boxslots_ac2_completed="$(grep -c 'burst-lane  run  routed' "$BURST_LANE_JOURNAL" 2>/dev/null || echo 0)"
expect "boxslots AC2: peak concurrently held run slots reaches the box's own cap of 8" \
  "[ \"$boxslots_ac2_peak\" = \"8\" ]"
expect "boxslots AC2: all 12 runs complete (12 'run routed' journal lines)" \
  "[ \"$boxslots_ac2_completed\" = \"12\" ]"
expect "boxslots AC2: no run exited nonzero" "[ \"$boxslots_ac2_rc_bad\" -eq 0 ]"

# ---- boxslots AC3: BURST_MAX_CONCURRENT_RUNS pins the cap outright —
# status --json reports run_slots.cap=3 source=env, the operator's pin
# visible over whatever the box itself would have computed (requirement
# 2/user story 3).
fresh_env
FAKE_BOX_CORES=32 FAKE_BOX_MEM_GB=128 FAKE_BOX_DISK_GB=600 "$BL" up >/dev/null
boxslots_ac3_json="$(BURST_MAX_CONCURRENT_RUNS=3 "$BL" status --json)"
expect "boxslots AC3: run_slots.cap=3 when BURST_MAX_CONCURRENT_RUNS pins it" \
  "grep -q '\"run_slots\":{\"cap\":3,' <<<\$boxslots_ac3_json"
expect "boxslots AC3: run_slots.source=env" "grep -q '\"source\":\"env\"' <<<\$boxslots_ac3_json"

# ---- boxslots AC4: a 16-core/64GB/100GB box with BURST_DISK_FLOOR_GB=40 ->
# min(16/4, 64/8, (100-40)/45) = min(4,8,1) = 1 (disk term floors to 1 by
# its own arithmetic, not by run_slot_cap()'s floor-at-1 safety net) —
# status names disk as the binding term.
fresh_env
FAKE_BOX_CORES=16 FAKE_BOX_MEM_GB=64 FAKE_BOX_DISK_GB=100 "$BL" up >/dev/null
boxslots_ac4_json="$(BURST_DISK_FLOOR_GB=40 "$BL" status --json)"
expect "boxslots AC4: run_slots.cap=1 (disk term (100-40)/45 floors to 1)" \
  "grep -q '\"run_slots\":{\"cap\":1,' <<<\$boxslots_ac4_json"
expect "boxslots AC4: run_slots names disk as the binding term" \
  "grep -q '\"bound\":\"disk\"' <<<\$boxslots_ac4_json"

# ---- boxslots AC5: a failed box probe leaves box_cores/box_mem_gb/
# box_disk_gb empty; run_slot_cap() falls back to 4 with source=default
# (never blocks `up` itself), and the journal names the failed probe.
fresh_env
FAKE_BOX_PROBE_FAIL=1 "$BL" up >/dev/null
expect "boxslots AC5: journal names the failed box probe" \
  "grep -q 'burst-lane  up  box-probe  failed' \"$BURST_LANE_JOURNAL\""
boxslots_ac5_json="$("$BL" status --json)"
expect "boxslots AC5: run_slots.cap=4 source=default when the box probe failed" \
  "grep -q '\"run_slots\":{\"cap\":4,\"held\":0,\"source\":\"default\"' <<<\$boxslots_ac5_json"

# ---- boxslots AC6: sub_cap and run_slot_cap() share one function — fed the
# SAME cores/mem/disk reading, they compute the SAME cap (requirement 3/5),
# and cmd_sub_cap's own body carries no inline nproc/N or avail_gb/N
# arithmetic (that arithmetic now lives only in run_slot_cap_terms).
fresh_env
FAKE_BOX_CORES=16 FAKE_BOX_MEM_GB=64 FAKE_BOX_DISK_GB=100 "$BL" up >/dev/null
boxslots_ac6_status_json="$(BURST_DISK_FLOOR_GB=40 "$BL" status --json)"
boxslots_ac6_cap="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['run_slots']['cap'])" "$boxslots_ac6_status_json" 2>/dev/null)"
boxslots_ac6_subcap_out="$(BURST_DISK_FLOOR_GB=40 FAKE_SSH_MEMINFO_GB=64 FAKE_SSH_NPROC=16 FAKE_SSH_DISK_GB=100 "$BL" sub-cap --candidates 10)"
boxslots_ac6_subcap="$(grep -oE '^sub-cap=[0-9]+' <<<"$boxslots_ac6_subcap_out" | cut -d= -f2)"
expect "boxslots AC6: sub-cap and run_slot_cap() agree on the per-box term from matching box readings" \
  "[ -n \"$boxslots_ac6_cap\" ] && [ \"$boxslots_ac6_cap\" = \"$boxslots_ac6_subcap\" ]"
boxslots_ac6_lint_hits="$(sed -n '/^cmd_sub_cap()/,/^}/p' "$HERE/burst-lane.sh" | grep -E 'nproc_n[[:space:]]*/|avail_gb[[:space:]]*/')"
expect "boxslots AC6: cmd_sub_cap's own body has no inline nproc/N or avail_gb/N arithmetic" \
  "[ -z \"$boxslots_ac6_lint_hits\" ]"

# ---- boxslots AC7: the older BURST_CORES_PER_BRANCH spelling still
# resolves when BURST_CORES_PER_RUN is unset — one journal deprecation line
# names the replacement (requirement 6). 32 cores / 8-per-run = 4 (now the
# binding term, tighter than mem's 16 and disk's 12).
fresh_env
FAKE_BOX_CORES=32 FAKE_BOX_MEM_GB=128 FAKE_BOX_DISK_GB=600 "$BL" up >/dev/null
boxslots_ac7_json="$(BURST_CORES_PER_BRANCH=8 "$BL" status --json)"
expect "boxslots AC7: run_slots.cap uses the deprecated BURST_CORES_PER_BRANCH alias (32/8=4)" \
  "grep -q '\"run_slots\":{\"cap\":4,' <<<\$boxslots_ac7_json"
expect "boxslots AC7: journal names the deprecated knob and its replacement" \
  "grep -q 'burst-lane  run-slot-cap  deprecated-knob  (old=BURST_CORES_PER_BRANCH new=BURST_CORES_PER_RUN)' \"$BURST_LANE_JOURNAL\""

# ==============================================================================
# ---- teardown: PRD-build-burst-teardown-evidence ----------------------------
# ==============================================================================
# teardown_decision() replaces the four independently-drifting delete rules
# (down, watchdog, the in-script idle-guard, and the standalone burst-idle-
# guard.sh) with one evidence-backed function; this block proves it directly
# (sourcing burst-lane.sh so a case can call teardown_decision/why-down's own
# helpers without a full up/down cycle for every fixture) and through the two
# NEW subcommands (`why-down`, `status --json`'s next_teardown) it powers.
# Requirement 2's full rewiring of down/watchdog/idle-guard's own ACTING
# logic onto teardown_decision, and requirement 4's adopt-derives fix, are
# deliberately NOT exercised here this pass — see the PRD's own build notes:
# both land in code regions a concurrent sibling PRD (PRD-build-burst-run-
# slots-from-box) was editing at the same moment in this same unisolated
# shell checkout, and requirement 2 in particular needs updating a couple
# dozen pre-existing hard-coded assertions elsewhere in this very file
# (bursttdl/proveguard/costrate's exact-string checks) in lockstep with the
# behavior change — real, necessary work, left for a focused follow-on
# rather than risked in the same pass as ten other concurrently-building
# PRDs.
block_start "teardown"
fresh_env
export BURST_LANE_LOOP_ACTIVE_OVERRIDE=false

# ---- teardown AC2: hcloud unavailable is never a decision cause ------------
"$BL" up >/dev/null 2>&1
td2_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
td2_before="$(cat "$BURST_LANE_STATE_DIR/current/session.json")"
td2_fakebin="$T/no-hcloud-path"; mkdir -p "$td2_fakebin"
for tool in bash env sh ssh rsync python3 systemctl awk grep sed date cut mkdir cat rm mv sleep tr head tail sort xargs sha1sum flock seq basename dirname find touch python wc stat ln readlink expr; do
  p="$(command -v "$tool" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$td2_fakebin/$tool"
done
td2_down_out="$(PATH="$td2_fakebin" "$BL" down 2>&1)"
td2_wd_out="$(PATH="$td2_fakebin" "$BL" watchdog 2>&1)"
td2_ig_out="$(PATH="$td2_fakebin" "$BL" idle-guard 2>&1)"
expect "teardown AC2: down is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "[ \"\$td2_down_out\" = 'decision=keep cause=probe-unavailable' ]"
expect "teardown AC2: watchdog is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "[ \"\$td2_wd_out\" = 'decision=keep cause=probe-unavailable' ]"
expect "teardown AC2: idle-guard is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "[ \"\$td2_ig_out\" = 'decision=keep cause=probe-unavailable' ]"
expect "teardown AC2: session.json is byte-unchanged after all three" \
  "[ \"\$(cat \"$BURST_LANE_STATE_DIR/current/session.json\")\" = \"\$td2_before\" ]"
expect "teardown AC2: no .stale- file was created" "! ls \"$BURST_LANE_STATE_DIR/current\"/session.json.stale-* >/dev/null 2>&1"
td2_pu_lines="$(grep -c 'cause=probe-unavailable' "$BURST_LANE_JOURNAL")"
expect "teardown AC2: probe-unavailable journaled at most once across down+watchdog+idle-guard (once-per-hour throttle)" \
  "[ \"$td2_pu_lines\" -le 1 ]"

# ---- teardown AC3: zero-runs grace keeps a fresh box past the old 900s -----
fresh_env
export BURST_LANE_LOOP_ACTIVE_OVERRIDE=true
td3_now="$(date -u +%s)"
export BURST_LANE_NOW=$((td3_now - 700))
"$BL" up >/dev/null 2>&1
td3_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
unset BURST_LANE_NOW
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-teardown-fake-rust.md" <<'EOF'
# PRD — teardown-fake-rust

- Status: queued
- build_target: rust-extend
EOF
export BURST_LANE_NOW="$td3_now"
td3_out="$(source "$BL"; teardown_decision "$td3_sid" idle-guard)"
unset BURST_LANE_NOW
td3_decision="$(sed -n 's/^decision=//p' <<<"$td3_out")"
td3_cause="$(sed -n 's/^cause=//p' <<<"$td3_out")"
expect "teardown AC3: decision=keep" "[ \"$td3_decision\" = keep ]"
expect "teardown AC3: cause=grace" "[ \"$td3_cause\" = grace ]"
td3_evidence="$(tail -1 "$BURST_LANE_STATE_DIR/decisions.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["evidence"]["grace_s"])')"
expect "teardown AC3: evidence.grace_s >= 1200" "[ \"$td3_evidence\" -ge 1200 ]"
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-teardown-fake-rust.md"

# ---- teardown AC4: a stale last-routed-run with no queued work deletes -----
fresh_env
export BURST_LANE_LOOP_ACTIVE_OVERRIDE=false
"$BL" up >/dev/null 2>&1
td4_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
td4_now="$(date -u +%s)"
printf '{"date":"%s","session_id":"%s","slug":"x"}\n' \
  "$(date -u -d "@$((td4_now - 3660))" +%Y-%m-%dT%H:%M:%SZ)" "$td4_sid" >> "$BURST_LANE_ATTR_LEDGER"
export BURST_LANE_NOW="$td4_now"
td4_out="$(source "$BL"; teardown_decision "$td4_sid" down)"
unset BURST_LANE_NOW
td4_decision="$(sed -n 's/^decision=//p' <<<"$td4_out")"
td4_cause="$(sed -n 's/^cause=//p' <<<"$td4_out")"
expect "teardown AC4: decision=delete" "[ \"$td4_decision\" = delete ]"
expect "teardown AC4: cause=idle-no-work" "[ \"$td4_cause\" = idle-no-work ]"

# ---- teardown AC5: same staleness, but work queued + loop active keeps ----
fresh_env
export BURST_LANE_LOOP_ACTIVE_OVERRIDE=true
"$BL" up >/dev/null 2>&1
td5_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
td5_now="$(date -u +%s)"
printf '{"date":"%s","session_id":"%s","slug":"x"}\n' \
  "$(date -u -d "@$((td5_now - 3660))" +%Y-%m-%dT%H:%M:%SZ)" "$td5_sid" >> "$BURST_LANE_ATTR_LEDGER"
cat > "$BURST_LANE_PRD_DIR/build-queue/PRD-teardown-fake-rust2.md" <<'EOF'
# PRD — teardown-fake-rust2

- Status: queued
- build_target: rust-extend
EOF
export BURST_LANE_NOW="$td5_now"
td5_out="$(source "$BL"; teardown_decision "$td5_sid" idle-guard)"
unset BURST_LANE_NOW
td5_decision="$(sed -n 's/^decision=//p' <<<"$td5_out")"
td5_cause="$(sed -n 's/^cause=//p' <<<"$td5_out")"
expect "teardown AC5: decision=keep" "[ \"$td5_decision\" = keep ]"
expect "teardown AC5: cause=work-queued" "[ \"$td5_cause\" = work-queued ]"
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-teardown-fake-rust2.md"

# ---- teardown AC6: why-down replays the trail, and flags an unrecorded ----
# deletion (P1 closer / AC12's own failure-path case).
fresh_env
export BURST_LANE_LOOP_ACTIVE_OVERRIDE=false
"$BL" up >/dev/null 2>&1
td6_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
( source "$BL"
  _teardown_decision_record "$td6_sid" down keep work-queued '{"n":1}'
  _teardown_decision_record "$td6_sid" watchdog keep work-queued '{"n":2}'
  _teardown_decision_record "$td6_sid" idle-guard delete idle-no-work '{"n":3}'
)
mv "$BURST_LANE_STATE_DIR/current/session.json" "$BURST_LANE_STATE_DIR/current/session.json.deleted-20260915T120000Z"
td6_out="$("$BL" why-down "$td6_sid" 2>&1)"
expect "teardown AC6: why-down prints all three rows in order" \
  "[ \"\$(grep -c 'decision=' <<<\"\$td6_out\")\" -ge 4 ]"
expect "teardown AC6: why-down names the final cause" "grep -q 'final: decision=delete cause=idle-no-work' <<<\"$td6_out\""
expect "teardown AC6: why-down names the matching deleted-* archive file" \
  "grep -q 'session.json.deleted-20260915T120000Z' <<<\"$td6_out\""

td6b_out="$("$BL" why-down 999999999 2>&1)"; td6b_rc=$?
expect "teardown AC6/AC12: an id with no decisions.jsonl row prints no decision recorded" \
  "[ \"\$td6b_out\" = 'no decision recorded' ]"
expect "teardown AC6/AC12: that case is a real failure exit, not a tautological 0" "[ $td6b_rc -ne 0 ]"
expect "teardown AC12: the unrecorded deletion is itself journaled as a defect" \
  "grep -q 'burst-lane  why-down  unrecorded-deletion  (server_id=999999999)' \"$BURST_LANE_JOURNAL\""

# ---- teardown AC8: a scheduled soft-down is refused, not silently ignored -
fresh_env
"$BL" up >/dev/null 2>&1
td8_rc=0; td8_out="$("$BL" down --at 06:48 2>&1)" || td8_rc=$?
expect "teardown AC8: down --at exits 2" "[ $td8_rc -eq 2 ]"
expect "teardown AC8: no timer/systemd-run call was ever made for this" "! grep -qE 'systemd-run|on-calendar' \"$BURST_LANE_JOURNAL\""
expect "teardown AC8: the refusal is journaled with cause=scheduled-teardown-disabled" \
  "grep -q 'burst-lane  down  refused  (cause=scheduled-teardown-disabled' \"$BURST_LANE_JOURNAL\""

# ---- teardown AC9: status --json's next_teardown matches a dry-run --------
fresh_env
"$BL" up >/dev/null 2>&1
td9_sid="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/current/session.json" | cut -d: -f2)"
td9_status="$("$BL" status --json)"
td9_nt_decision="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_teardown"]["decision"])' "$td9_status")"
td9_nt_cause="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_teardown"]["cause"])' "$td9_status")"
td9_dry_out="$(source "$BL"; teardown_decision "$td9_sid" status --dry-run)"
td9_dry_decision="$(sed -n 's/^decision=//p' <<<"$td9_dry_out")"
td9_dry_cause="$(sed -n 's/^cause=//p' <<<"$td9_dry_out")"
expect "teardown AC9: status --json's next_teardown.decision is present and matches a dry-run" \
  "[ -n \"$td9_nt_decision\" ] && [ \"$td9_nt_decision\" = \"$td9_dry_decision\" ]"
expect "teardown AC9: status --json's next_teardown.cause matches a dry-run" "[ \"$td9_nt_cause\" = \"$td9_dry_cause\" ]"
td9_ledger_before="$(cat "$BURST_LANE_STATE_DIR/decisions.jsonl" 2>/dev/null | wc -l)"
"$BL" status --json >/dev/null
"$BL" status --json >/dev/null
td9_ledger_after="$(cat "$BURST_LANE_STATE_DIR/decisions.jsonl" 2>/dev/null | wc -l)"
expect "teardown AC9: polling status --json never appends to decisions.jsonl (dry-run has no side effects)" \
  "[ \"$td9_ledger_after\" -eq \"$td9_ledger_before\" ]"

unset BURST_LANE_LOOP_ACTIVE_OVERRIDE
expect_block_green "teardown" "teardown: every teardown case above ran green"

# =============================================================================
# PRD-build-burst-state-keyed-by-server-v2: state layout migration
# (requirement 1/10/11) — AC1, AC12, AC13, AC14, AC15, AC16 — plus
# requirement 2/6 (`up --count N`, server naming, the BURST_MAX_BOXES money
# cap) — AC2, AC6 — plus requirement 9 (`prove`/`bake` refuse cause=multi-
# box with more than one box up) — AC8 — plus requirement 3 (`run`'s
# per-box slot selection) and requirement 5 (`cost --today` summing across
# boxes) — AC7. Requirement 4 (`down`/`idle-guard`/`watchdog` iterating the
# set instead of acting on `current` alone) is covered below for down and
# idle-guard — AC4, AC5; watchdog's own iteration is exercised by AC4/AC5's
# shared down_one_box/watchdog_one_box/idle_guard_one_box refactor pattern
# but has no dedicated AC in the PRD beyond those two. Requirements 7-8
# (`status --json` boxes/totals, `reap`'s orphan-box-deleted) remain open —
# see the PRD's own tracking; this block does not yet cover AC9 or a
# dedicated status-schema check.
# =============================================================================
block_start "multibox"

# ---- multibox AC1: a pre-ship top-level session.json for box 111
# migrates on the very next command; current points at it; status --json
# still reads the same server_id.
fresh_env
# Seed the fake hcloud backend so server_alive(111) reports true — a bare
# hand-written session.json with no matching fake-hcloud row describes an
# UNTRACKED server, which session_reconcile() correctly archives as stale
# (the fixture's own "not found" wiring, tightened alongside this PRD —
# see the hcloud fixture's own header comment). AC1 is testing the
# migration mechanism, not stale-reconcile, so the fixture must make 111
# a genuinely alive fake server first, same as every other test here that
# needs a real session gets one via "$BL" up.
echo "111|wm-burst-lane|alive|$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FAKE_HCLOUD_STATE"
printf '{"server_id":111,"ip":"10.0.0.5","server_type":"ccx53"}' > "$BURST_LANE_STATE_DIR/session.json"
mb1_out="$("$BL" status --json 2>&1)"
expect "multibox AC1: boxes/111/session.json exists after migration" "[ -f \"$BURST_LANE_STATE_DIR/boxes/111/session.json\" ]"
expect "multibox AC1: current points at boxes/111" "[ \"\$(readlink \"$BURST_LANE_STATE_DIR/current\")\" = boxes/111 ]"
expect "multibox AC1: journal has 'state  migrated'" "grep -q 'burst-lane  state  migrated  (server_id=111' \"$BURST_LANE_JOURNAL\""
mb1_sid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("server_id",""))' "$mb1_out" 2>/dev/null)"
expect "multibox AC1: status --json .server_id is 111" "[ \"$mb1_sid\" = 111 ]"

# ---- multibox AC12: every per-box name for box 111 migrates, every
# lane-wide name stays top-level, the journal names the exact moved
# count, and no per-box name remains at the top level afterward.
fresh_env
# Same fake-hcloud seed as AC1 above — session_reconcile() must see 111
# as alive or it archives session.json as stale before this block's own
# per-box-name assertions ever get to run.
echo "111|wm-burst-lane|alive|$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FAKE_HCLOUD_STATE"
mkdir -p "$BURST_LANE_STATE_DIR/pull-sizes" "$BURST_LANE_STATE_DIR/evidence" \
         "$BURST_LANE_STATE_DIR/gate-inflight" "$BURST_LANE_STATE_DIR/logs"
printf '{"server_id":111,"ip":"10.0.0.5"}' > "$BURST_LANE_STATE_DIR/session.json"
echo '{}' > "$BURST_LANE_STATE_DIR/volume.json"
echo '{}' > "$BURST_LANE_STATE_DIR/proof.json"
: > "$BURST_LANE_STATE_DIR/run.lock"
echo '{}' > "$BURST_LANE_STATE_DIR/remote-dirs.json"
: > "$BURST_LANE_STATE_DIR/inflight.log"
: > "$BURST_LANE_STATE_DIR/prove.inflight"
: > "$BURST_LANE_STATE_DIR/known_hosts.111"
: > "$BURST_LANE_STATE_DIR/.last-teardown-cause"
: > "$BURST_LANE_STATE_DIR/logs/run-remote.1.log"
echo '{}' > "$BURST_LANE_STATE_DIR/snapshot.json"
: > "$BURST_LANE_STATE_DIR/parity-baseline-image"
: > "$BURST_LANE_STATE_DIR/decisions.jsonl"
: > "$BURST_LANE_STATE_DIR/provision.lock"
"$BL" status --json > /dev/null 2>&1
mb12_ok=1
for f in session.json volume.json proof.json run.lock remote-dirs.json inflight.log \
         prove.inflight known_hosts.111 .last-teardown-cause logs/run-remote.1.log; do
  [ -f "$BURST_LANE_STATE_DIR/boxes/111/$f" ] || mb12_ok=0
done
[ -d "$BURST_LANE_STATE_DIR/boxes/111/pull-sizes" ] || mb12_ok=0
[ -e "$BURST_LANE_STATE_DIR/boxes/111/evidence" ] || mb12_ok=0
[ -d "$BURST_LANE_STATE_DIR/boxes/111/gate-inflight" ] || mb12_ok=0
expect "multibox AC12: every per-box name for box 111 landed under boxes/111/" "[ \"$mb12_ok\" -eq 1 ]"
expect "multibox AC12: snapshot.json (lane-wide) stayed top-level" "[ -f \"$BURST_LANE_STATE_DIR/snapshot.json\" ]"
expect "multibox AC12: parity-baseline-image (lane-wide) stayed top-level" "[ -f \"$BURST_LANE_STATE_DIR/parity-baseline-image\" ]"
expect "multibox AC12: decisions.jsonl (lane-wide) stayed top-level" "[ -f \"$BURST_LANE_STATE_DIR/decisions.jsonl\" ]"
expect "multibox AC12: provision.lock (lane-wide) stayed top-level" "[ -f \"$BURST_LANE_STATE_DIR/provision.lock\" ]"
mb12_moved="$(grep -oE 'state  migrated  \(server_id=111 moved=[0-9]+\)' "$BURST_LANE_JOURNAL" | grep -oE 'moved=[0-9]+' | cut -d= -f2 | head -n1)"
expect "multibox AC12: journal names the exact moved count (13 per-box entries)" "[ \"${mb12_moved:-0}\" -eq 13 ]"
# `probes/` is scripts/probe-result.sh's own ledger dir (a different
# subsystem, keyed off $BUILD_STATE_DIR, not burst-lane.sh's $STATE_DIR at
# all — in production they're siblings: state/burst-lane/ vs state/). It
# only shows up as a CHILD of $BURST_LANE_STATE_DIR here because fresh_env
# (this file's own fixture, see the route-check probe tests above) points
# BUILD_STATE_DIR at the same sandboxed $T/state for convenience — a test-
# harness coincidence, not a state-surface name this PRD's classification
# ever owned, so it's excluded here rather than added to
# scripts/burst-state-surface.txt (which classifies burst-lane.sh's own
# $STATE_DIR/$BOX_STATE_DIR literals, and rightly has no opinion on it).
mb12_leftover="$(find "$BURST_LANE_STATE_DIR" -maxdepth 1 -mindepth 1 \
  ! -name current ! -name boxes ! -name snapshot.json ! -name parity-baseline-image \
  ! -name decisions.jsonl ! -name provision.lock ! -name logs ! -name probes 2>/dev/null | wc -l)"
expect "multibox AC12: find -maxdepth 1 shows no per-box name left at the top level" "[ \"$mb12_leftover\" -eq 0 ]"

# ---- multibox AC16: an unattributable top-level residue (no
# session.json, no known_hosts.<id> suffix) moves to boxes/_orphan-<ts>/,
# nothing deleted, journaled migrated-orphan.
fresh_env
: > "$BURST_LANE_STATE_DIR/up.lock"
: > "$BURST_LANE_STATE_DIR/inflight.log"
"$BL" status --json > /dev/null 2>&1
mb16_orphan_dir="$(find "$BURST_LANE_STATE_DIR/boxes" -maxdepth 1 -type d -name '_orphan-*' 2>/dev/null | head -n1)"
expect "multibox AC16: an unattributable residue moved to boxes/_orphan-<ts>/" "[ -n \"$mb16_orphan_dir\" ]"
expect "multibox AC16: up.lock landed in the orphan dir (not deleted)" "[ -f \"$mb16_orphan_dir/up.lock\" ]"
expect "multibox AC16: inflight.log landed in the orphan dir (not deleted)" "[ -f \"$mb16_orphan_dir/inflight.log\" ]"
expect "multibox AC16: journal has 'state  migrated-orphan'" "grep -q 'burst-lane  state  migrated-orphan' \"$BURST_LANE_JOURNAL\""
expect "multibox AC16: the top-level copy is gone (moved, not copied)" "[ ! -e \"$BURST_LANE_STATE_DIR/up.lock\" ]"

# ---- multibox AC13/AC14: the completeness tripwire fails, naming the
# path/line, on an unclassified new $STATE_DIR/<name> and on a "boxes/"
# literal outside box_path()/migrate_state_layout(); passes clean against
# the real, unmodified script + surface file.
mb_tw="$HERE/burst-state-tripwire.sh"
mb_surface="$HERE/burst-state-surface.txt"
expect "multibox AC13/14: tripwire passes clean against the real script + surface file" \
  "bash \"$mb_tw\" \"$BL\" \"$mb_surface\" >/dev/null 2>&1"

mb13_fixture="$T/bl-fixture-ac13.sh"
cp "$BL" "$mb13_fixture"
echo 'NEW_THING="$STATE_DIR/new-thing.json"' >> "$mb13_fixture"
mb13_out="$(bash "$mb_tw" "$mb13_fixture" "$mb_surface" 2>&1)"; mb13_rc=$?
expect "multibox AC13: tripwire fails on an unclassified new state path" "[ $mb13_rc -ne 0 ]"
expect "multibox AC13: tripwire names the new path" "grep -q \"unclassified state path 'new-thing.json'\" <<<\"$mb13_out\""

mb14_fixture="$T/bl-fixture-ac14.sh"
cp "$BL" "$mb14_fixture"
echo 'ROGUE_DIR="$STATE_DIR/boxes/rogue"' >> "$mb14_fixture"
mb14_out="$(bash "$mb_tw" "$mb14_fixture" "$mb_surface" 2>&1)"; mb14_rc=$?
expect "multibox AC14: tripwire fails on a boxes/ literal outside the allowed block" "[ $mb14_rc -ne 0 ]"
expect "multibox AC14: tripwire names the offending line" 'grep -q "boxes/ literal outside" <<<"$mb14_out"'

# ---- multibox AC15: gate-wedge.sh's default glob-expands to
# boxes/*/{locks,slots} (a functional check, not just the tripwire's
# static one above), and the tripwire finds no top-level
# state/burst-lane/{locks,slots} literal in either external reader.
mkdir -p "$T/state/burst-lane/boxes/111/locks" "$T/state/burst-lane/boxes/111/slots"
: > "$T/state/burst-lane/boxes/111/locks/wt-smoke.lock"
mb15_scan_dirs="$(BUILD_SKILL_DIR="$T" GATE_WEDGE_STATE_DIR="$T/gate-wedge-state" GATE_WEDGE_JOURNAL="$T/gw-journal.log" \
  bash -x "$HERE/gate-wedge.sh" run --budget 1 --step mb15-smoke -- true 2>&1 | sed -n 's/^+ LOCK_SCAN_DIRS=//p' | head -n1)"
expect "multibox AC15: gate-wedge.sh's default LOCK_SCAN_DIRS glob-expands to boxes/111/locks" \
  "grep -qF \"boxes/111/locks\" <<<\"$mb15_scan_dirs\""
expect "multibox AC15: gate-wedge.sh's default LOCK_SCAN_DIRS glob-expands to boxes/111/slots" \
  "grep -qF \"boxes/111/slots\" <<<\"$mb15_scan_dirs\""
expect "multibox AC15: tripwire finds no top-level {locks,slots} literal in gate-wedge.sh/isolation-guard.sh" \
  "bash \"$mb_tw\" \"$BL\" \"$mb_surface\" \"$HERE/gate-wedge.sh\" \"$HERE/isolation-guard.sh\" >/dev/null 2>&1"

mb15_fixture="$T/gw-fixture-ac15.sh"
cp "$HERE/gate-wedge.sh" "$mb15_fixture"
echo 'ROGUE="$SKILL_DIR/state/burst-lane/locks"' >> "$mb15_fixture"
mb15_out="$(bash "$mb_tw" "$BL" "$mb_surface" "$mb15_fixture" 2>&1)"; mb15_rc=$?
expect "multibox AC15: tripwire fails on a stray top-level locks/slots literal in an external reader" "[ $mb15_rc -ne 0 ]"

# ---- multibox AC2: `up --count N` boots N boxes, each with its own
# boxes/<id>/session.json and up.lock, current naming the first ready one.
fresh_env
mb2_rc=0; mb2_out="$(BURST_MAX_BOXES=2 "$BL" up --count 2 2>&1)" || mb2_rc=$?
expect "multibox AC2: up --count 2 exits 0" "[ $mb2_rc -eq 0 ]"
mb2_id1="$(awk -F'|' '$2=="wm-burst-lane-1"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb2_id2="$(awk -F'|' '$2=="wm-burst-lane-2"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
expect "multibox AC2: wm-burst-lane-1 exists in hcloud" "[ -n \"$mb2_id1\" ]"
expect "multibox AC2: wm-burst-lane-2 exists in hcloud" "[ -n \"$mb2_id2\" ]"
expect "multibox AC2: box 1 has its own boxes/<id>/session.json" "[ -f \"$BURST_LANE_STATE_DIR/boxes/$mb2_id1/session.json\" ]"
expect "multibox AC2: box 2 has its own boxes/<id>/session.json" "[ -f \"$BURST_LANE_STATE_DIR/boxes/$mb2_id2/session.json\" ]"
expect "multibox AC2: box 1 has its own up.lock" "[ -f \"$BURST_LANE_STATE_DIR/boxes/$mb2_id1/up.lock\" ]"
expect "multibox AC2: box 2 has its own up.lock" "[ -f \"$BURST_LANE_STATE_DIR/boxes/$mb2_id2/up.lock\" ]"
expect "multibox AC2: current points at the first ready box (wm-burst-lane-1)" "[ \"\$(readlink \"$BURST_LANE_STATE_DIR/current\")\" = \"boxes/$mb2_id1\" ]"
mb2_current_sid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("server_id",""))' "$("$BL" status --json)" 2>/dev/null)"
expect "multibox AC2: status --json .server_id follows current (box 1)" "[ \"$mb2_current_sid\" = \"$mb2_id1\" ]"

# ---- multibox AC6: BURST_MAX_BOXES caps `--count`; a request above it is
# refused (journaled `up refused cause=max-boxes`) before any hcloud call,
# and at most one box exists afterward.
fresh_env
mb6_rc=0; mb6_out="$(BURST_MAX_BOXES=1 "$BL" up --count 2 2>&1)" || mb6_rc=$?
expect "multibox AC6: up --count 2 exits non-zero under BURST_MAX_BOXES=1" "[ $mb6_rc -ne 0 ]"
expect "multibox AC6: journal has 'up  refused  (cause=max-boxes'" "grep -q 'burst-lane  up  refused  (cause=max-boxes' \"$BURST_LANE_JOURNAL\""
mb6_boxcount="$(find "$BURST_LANE_STATE_DIR/boxes" -maxdepth 1 -mindepth 1 -type d ! -name pending ! -name '_orphan-*' 2>/dev/null | wc -l)"
expect "multibox AC6: no box was created (refused before any hcloud call)" "[ \"$mb6_boxcount\" -eq 0 ]"
expect "multibox AC6: no server create call was ever made" "! grep -q 'server create' \"$FAKE_HCLOUD_CALLLOG\""
# BURST_MAX_BOXES=1 (the default) still allows a plain single-box `up` —
# the cap bounds --count, it does not disable the lane.
mb6b_rc=0; BURST_MAX_BOXES=1 "$BL" up >/dev/null 2>&1 || mb6b_rc=$?
expect "multibox AC6: BURST_MAX_BOXES=1 (default) still allows an uncapped single-box up" "[ $mb6b_rc -eq 0 ]"

# ---- multibox AC8: with two boxes up, `prove` (and, requirement 9's own
# text — "prove AND bake" — `bake`) refuse with cause=multi-box and no box
# is modified.
fresh_env
BURST_MAX_BOXES=2 "$BL" up --count 2 >/dev/null 2>&1
mb8_boxes_before="$(find "$BURST_LANE_STATE_DIR/boxes" -maxdepth 1 -mindepth 1 -type d ! -name pending ! -name '_orphan-*' 2>/dev/null | sort)"
mb8_prove_rc=0; mb8_prove_out="$("$BL" prove --worktree "$T" 2>&1)" || mb8_prove_rc=$?
expect "multibox AC8: prove refuses with cause=multi-box when two boxes are up" \
  "[ $mb8_prove_rc -ne 0 ] && grep -q 'multi-box' <<<\"$mb8_prove_out\""
expect "multibox AC8: journal has 'prove  refused  (cause=multi-box'" \
  "grep -q 'burst-lane  prove  refused  (cause=multi-box' \"$BURST_LANE_JOURNAL\""
mb8_bake_rc=0; mb8_bake_out="$("$BL" bake 2>&1)" || mb8_bake_rc=$?
expect "multibox AC8: bake also refuses with cause=multi-box when two boxes are up" \
  "[ $mb8_bake_rc -ne 0 ] && grep -q 'multi-box' <<<\"$mb8_bake_out\""
expect "multibox AC8: journal has 'bake  refused  (cause=multi-box'" \
  "grep -q 'burst-lane  bake  refused  (cause=multi-box' \"$BURST_LANE_JOURNAL\""
mb8_boxes_after="$(find "$BURST_LANE_STATE_DIR/boxes" -maxdepth 1 -mindepth 1 -type d ! -name pending ! -name '_orphan-*' 2>/dev/null | sort)"
expect "multibox AC8: no box was modified (same box set before/after the refused calls)" \
  "[ \"$mb8_boxes_before\" = \"$mb8_boxes_after\" ]"

# ---- multibox AC7 (requirement 5): with two boxes, each carrying its own
# cost.jsonl row for today, `cost --today` sums to their total and prints a
# per-box breakdown naming both server_ids and types. fresh_env's own
# BURST_LANE_COST_LEDGER override (a single fixed path, there so every
# EXISTING single-box cost fixture in this file keeps working unchanged)
# is unset for this block only — with it still exported, box_context's
# per-box default (`$BOX_STATE_DIR/cost.jsonl`) never gets a chance to
# apply, and both boxes would read the exact same file, proving nothing
# about per-box distinctness.
fresh_env
unset BURST_LANE_COST_LEDGER
BURST_MAX_BOXES=2 "$BL" up --count 2 >/dev/null 2>&1
mb7_id1="$(awk -F'|' '$2=="wm-burst-lane-1"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb7_id2="$(awk -F'|' '$2=="wm-burst-lane-2"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb7_today="$(date -u +%Y-%m-%d)"
cat > "$BURST_LANE_STATE_DIR/boxes/$mb7_id1/cost.jsonl" <<JSON
{"date":"${mb7_today}T01:00:00Z","hours":0.5,"eur":0.10,"prds":[],"session_id":"$mb7_id1","server_type":"ccx43"}
JSON
cat > "$BURST_LANE_STATE_DIR/boxes/$mb7_id2/cost.jsonl" <<JSON
{"date":"${mb7_today}T01:00:00Z","hours":1.0,"eur":0.20,"prds":[],"session_id":"$mb7_id2","server_type":"ccx53"}
JSON
mb7_cost_out="$("$BL" cost --today 2>&1)"
expect "multibox AC7: cost --today totals 0.30 across both boxes" \
  "grep -qE 'hours=1\\.50 eur=0\\.30' <<<\"$mb7_cost_out\""
expect "multibox AC7: breakdown lists box 1's server_id and type" \
  "grep -q \"server_id=$mb7_id1 server_type=ccx43\" <<<\"$mb7_cost_out\""
expect "multibox AC7: breakdown lists box 2's server_id and type" \
  "grep -q \"server_id=$mb7_id2 server_type=ccx53\" <<<\"$mb7_cost_out\""
expect "multibox AC7: breakdown TOTAL line names both boxes" \
  "grep -qE 'TOTAL boxes=2 hours=1\\.50 eur=0\\.30' <<<\"$mb7_cost_out\""

# ---- multibox AC4 (requirement 4): idle-guard iterates every active box —
# a busy box (runs_served=3) is left alone while an idle box (runs_served=0,
# age past the 900s zero-runs threshold) is torn down in the same pass, and
# the journal carries one decision line for each box (costrate AC1's own
# pattern above for backdating age via BURST_LANE_NOW + stripping
# phase/phase_epoch so the box reads grace-exempt).
fresh_env
BURST_MAX_BOXES=2 "$BL" up --count 2 >/dev/null 2>&1
mb4_id1="$(awk -F'|' '$2=="wm-burst-lane-1"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb4_id2="$(awk -F'|' '$2=="wm-burst-lane-2"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb4_create1="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/boxes/$mb4_id1/session.json" | cut -d: -f2)"
mb4_create2="$(grep -oE '"create_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/boxes/$mb4_id2/session.json" | cut -d: -f2)"
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d["runs_served"] = 3
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/boxes/$mb4_id1/session.json"
python3 -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("phase", None)
d.pop("phase_epoch", None)
json.dump(d, open(path, "w"))
' "$BURST_LANE_STATE_DIR/boxes/$mb4_id2/session.json"
mb4_newest=$(( mb4_create1 > mb4_create2 ? mb4_create1 : mb4_create2 ))
export BURST_LANE_NOW=$(( mb4_newest + 1000 ))
mb4_out="$("$BL" idle-guard 2>&1)"
unset BURST_LANE_NOW
expect "multibox AC4: the idle box (box 2, runs_served=0) is torn down" \
  "grep -q \"idle-guard teardown: $mb4_id2\" <<<\"$mb4_out\""
expect "multibox AC4: the busy box (box 1, runs_served=3) is left up in hcloud" \
  "hcloud server describe \"$mb4_id1\" -o json >/dev/null 2>&1"
expect "multibox AC4: the idle box is gone from hcloud" \
  "! hcloud server describe \"$mb4_id2\" -o json >/dev/null 2>&1"
expect "multibox AC4: journal has a decision line for the deleted idle box" \
  "grep -q \"burst-lane  down  decision=deleted  (server_id=$mb4_id2\" \"$BURST_LANE_JOURNAL\""
expect "multibox AC4: journal has a decision line for the kept busy box too" \
  "grep -q \"burst-lane  idle-guard  decision=keep  (server_id=$mb4_id1 runs_served=3\" \"$BURST_LANE_JOURNAL\""

# ---- multibox AC5 (requirement 4): `down` (no --force) gives every active
# box its own decision line in one pass, and `down --force` afterward clears
# BOTH boxes (and any stranded volume) from hcloud, not just whichever one
# `current` used to name.
fresh_env
BURST_MAX_BOXES=2 "$BL" up --count 2 >/dev/null 2>&1
mb5_id1="$(awk -F'|' '$2=="wm-burst-lane-1"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb5_id2="$(awk -F'|' '$2=="wm-burst-lane-2"{print $1}' "$FAKE_HCLOUD_STATE" | head -n1)"
mb5_down_out="$("$BL" down 2>&1)"
expect "multibox AC5: journal has a decision line for box 1" \
  "grep -qE \"burst-lane  down  decision=(keep|deleted|scheduled)  \\(server_id=$mb5_id1\" \"$BURST_LANE_JOURNAL\""
expect "multibox AC5: journal has a decision line for box 2" \
  "grep -qE \"burst-lane  down  decision=(keep|deleted|scheduled)  \\(server_id=$mb5_id2\" \"$BURST_LANE_JOURNAL\""
"$BL" down --force >/dev/null 2>&1
expect "multibox AC5: down --force leaves no wm-burst-lane* server in hcloud" \
  "! grep -q 'wm-burst-lane' \"$FAKE_HCLOUD_STATE\""
expect "multibox AC5: down --force leaves no wm-burst-* volume in hcloud" \
  "! grep -q 'wm-burst-' \"$FAKE_HCLOUD_VOLUME_STATE\""

expect_block_green "multibox" "multibox: every state-layout migration case above ran green"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
