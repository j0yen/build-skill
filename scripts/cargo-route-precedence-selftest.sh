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
pc_active_session_id() { grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2; }
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
  export BURST_LANE_ROOT_RUSTUP_HOME="$HOME/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="$HOME/.cargo"
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
# =============================================================================
# PRD-build-cargo-route-precedence — dedicated coverage for the shared
# cargo_route_path_prefix() helper (lib/cargo-route.sh), the real_cargo()
# burst-redirect it drives in cargo-budget-bin/cargo, and burst-lane.sh
# route-check's self-heal / hard-fail rewrite. Reuses this file's own
# preamble (fresh_env, expect(), FAKE, BL, HERE) verbatim rather than
# hand-duplicating it — same convention burst-lane-selftest.sh's own
# header already documents for its "gateroute" cases.
#
# AC1 (a) — PATH already correctly armed (cargo_route_path_prefix()'s own
#           output) + burst configured: route-check reports state=clean,
#           resolved names cargo-budget-bin/cargo (the chain's outermost,
#           always-first entry — it delegates to burst-lane-bin internally
#           now, so resolving to IT is exactly as correct as resolving
#           straight to burst-lane-bin used to be).
# AC2 (b) — caller PATH has NEITHER shim dir at all, burst configured:
#           route-check self-heals (the shim files genuinely exist on
#           disk, just not on this PATH), reports state=healed, exits 0,
#           and journals "route healed" to the shared burst-lane journal
#           exactly once even across two calls against the same per-gate
#           route log (dedup).
# AC3 (c) — cargo-budget-bin is genuinely ABSENT from disk (an isolated
#           copy of scripts/ with that one directory removed — self-heal
#           cannot invent a shim that was never there), burst configured:
#           route-check reports state=mismatch cause=shim-not-first,
#           journals "route mismatch" to the shared burst-lane journal
#           UNCONDITIONALLY (no $BURST_ROUTE_LOG set at all), and exits 9
#           (its own documented, distinct rc) — never runs cargo itself.
# AC4 (d) — burst not configured at all: route-check is a pure no-op (no
#           journal lines, no probe emission), resolved is whatever real
#           cargo the caller's own PATH already had.
# AC5 (e) — extend-gate.sh's --head now accepts an abbreviated SHA
#           (resolved via `git rev-parse --verify <sha>^{commit}`,
#           compared as FULL SHAs): the correct short SHA is accepted
#           (never refused as a "mismatch"), an unrelated commit's short
#           SHA is refused with BOTH full SHAs named in the message, and
#           a short ref that resolves to nothing is refused too.
# AC6 (f) — replaying the real systemd-unit-shaped service PATH
#           (/home/jsy/.local/bin:/home/jsy/.cargo/bin:/home/jsy/.npm-
#           global/bin:/usr/local/bin:/usr/bin:/bin — no shim dir
#           anywhere on it) with BUILD_BURST_ENABLED=1: extend-gate.sh's
#           own rewritten PATH guard (not just route-check) resolves the
#           very first line to cargo-budget-bin/cargo — the exact
#           2026-09-15 defect (166 route=local vs 49 route=burst that day)
#           replayed end-to-end and shown fixed.
# =============================================================================

EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }

# ---- shared minimal rust-extend fixture builder (mirrors extend-gate-
# cargo-route-selftest.sh's own build_fixture verbatim) ---------------------
build_min_fixture() {  # $1=repo dir $2=crate-name slug
  local repo="$1" slug="$2"
  mkdir -p "$repo/src" "$repo/agent" "$repo/tests" "$repo/scripts"
  cat > "$repo/Cargo.toml" <<EOF
[package]
name = "$slug"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  cat > "$repo/tests/route_precedence.rs" <<EOF
use ${slug}::add;

#[test]
fn returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF
  cat > "$repo/agent/intent-card.json" <<EOF
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "$slug",
  "root_motivation": "Disposable fixture crate for cargo-route-precedence-selftest.sh (PRD-build-cargo-route-precedence) — not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/route_precedence.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none — fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give cargo-route-precedence-selftest.sh a disposable rust-extend fixture"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-15T00:00:00Z"
}
EOF
  cat > "$repo/scripts/run-metrics.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
head_sha="$(git rev-parse HEAD)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p target/autobuilder
jq -n --arg head "$head_sha" --arg ts "$captured_at" '{
  schema: "autobuilder.metrics.v1",
  head_sha: $head,
  scalars: {acceptance_tests_passing_count: 1},
  ac_passing_count: 1,
  ac_total_count: 1,
  audit: {blocking_count: 0, advisory_count: 0},
  clippy_warning_count: 0,
  captured_at: $ts
}' > target/autobuilder/metrics.json
EOF
  chmod +x "$repo/scripts/run-metrics.sh"
  cat > "$repo/.gitignore" <<'EOF'
/target
EOF
  ( cd "$repo" && cargo generate-lockfile >/dev/null 2>&1 ) || true
  git -C "$repo" init -q
  git -C "$repo" -c user.name="cargo-route-precedence-selftest" -c user.email="selftest@example.com" add -A
  git -C "$repo" -c user.name="cargo-route-precedence-selftest" -c user.email="selftest@example.com" commit -q -m "initial"
  git -C "$repo" tag v0.1.0
}

# =========================================================================
# AC1 (a) — correct prefix already on PATH, burst configured -> clean.
# =========================================================================
echo "=== cargoroute AC1 (a): correct prefix on PATH, burst configured -> state=clean ==="
fresh_env
"$BL" up >/dev/null 2>&1
rc_a="$(PATH="$HERE/cargo-budget-bin:$HERE/burst-lane-bin:$PATH" "$BL" route-check --repo "$T" 2>&1)"; rc_a_rc=$?
expect "cargoroute AC1: correct-prefix PATH resolves state=clean" "grep -q 'state=clean' <<<\"$rc_a\""
expect "cargoroute AC1: resolved names cargo-budget-bin/cargo (outermost, always first)" \
  "grep -q \"resolved=$HERE/cargo-budget-bin/cargo\" <<<\"$rc_a\""
expect "cargoroute AC1: intended=burst (session up)" "grep -q 'intended=burst' <<<\"$rc_a\""
expect "cargoroute AC1: route-check exits 0" "[ \"$rc_a_rc\" -eq 0 ]"

# =========================================================================
# AC2 (b) — neither shim dir on PATH, burst configured -> self-heals.
# =========================================================================
echo "=== cargoroute AC2 (b): neither shim dir on PATH, burst configured -> self-heals ==="
fresh_env
"$BL" up >/dev/null 2>&1
REALCARGODIR="$(dirname "$(command -v cargo)")"
ROUTE_LOG_B="$T/route-b.log"
rc_b1="$(BURST_ROUTE_LOG="$ROUTE_LOG_B" PATH="$REALCARGODIR:$PATH" "$BL" route-check --repo "$T" 2>&1)"; rc_b1_rc=$?
expect "cargoroute AC2: PATH-without-either-shim self-heals (state=healed)" "grep -q 'state=healed' <<<\"$rc_b1\""
expect "cargoroute AC2: healed exits 0 (never fatal)" "[ \"$rc_b1_rc\" -eq 0 ]"
expect "cargoroute AC2: healed journals to the shared burst-lane journal" "grep -q '  route  healed  ' \"$BURST_LANE_JOURNAL\""
healed_count_1="$(grep -c '  route  healed  ' "$BURST_LANE_JOURNAL" 2>/dev/null)"; healed_count_1="${healed_count_1:-0}"
rc_b2="$(BURST_ROUTE_LOG="$ROUTE_LOG_B" PATH="$REALCARGODIR:$PATH" "$BL" route-check --repo "$T" 2>&1)"
healed_count_2="$(grep -c '  route  healed  ' "$BURST_LANE_JOURNAL" 2>/dev/null)"; healed_count_2="${healed_count_2:-0}"
expect "cargoroute AC2: a second call against the SAME per-gate route log never double-journals" \
  "[ \"$healed_count_2\" -eq \"$healed_count_1\" ]"

# =========================================================================
# AC3 (c) — cargo-budget-bin genuinely missing on disk -> unhealable
# mismatch, journaled unconditionally, rc=9, no local cargo run.
# =========================================================================
echo "=== cargoroute AC3 (c): cargo-budget-bin absent from disk -> unhealable mismatch, rc=9 ==="
fresh_env
"$BL" up >/dev/null 2>&1
ISO_ROOT="$T/isolated-scripts"
cp -r "$HERE" "$ISO_ROOT"
# Both shim dirs must be gone: self-heal accepts EITHER cargo-budget-bin OR
# burst-lane-bin as "clean" (cargo-budget-bin now chains internally to
# whichever burst-lane-bin it finds), so leaving either one present would
# let this "genuinely missing" case self-heal via the survivor — which is
# correct behavior, just not what this AC is proving.
rm -rf "$ISO_ROOT/cargo-budget-bin" "$ISO_ROOT/burst-lane-bin"
ISO_BL="$ISO_ROOT/burst-lane.sh"
chmod +x "$ISO_BL"
FAKEBIN_C="$T/fakebin-c"; mkdir -p "$FAKEBIN_C"
FAKE_CARGO_MARKER_C="$T/fake-cargo-ran-c"
cat > "$FAKEBIN_C/cargo" <<EOF3
#!/usr/bin/env bash
echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ) \$*" >> "$FAKE_CARGO_MARKER_C"
exit 0
EOF3
chmod +x "$FAKEBIN_C/cargo"
rc_c="$(PATH="$FAKEBIN_C:$PATH" "$ISO_BL" route-check --repo "$T" 2>&1)"; rc_c_rc=$?
expect "cargoroute AC3: unhealable mismatch reports intended=burst" "grep -q 'intended=burst' <<<\"$rc_c\""
expect "cargoroute AC3: unhealable mismatch is state=mismatch cause=shim-not-first" \
  "grep -q 'state=mismatch cause=shim-not-first' <<<\"$rc_c\""
expect "cargoroute AC3: exits 9 (distinct, documented rc)" "[ \"$rc_c_rc\" -eq 9 ]"
expect "cargoroute AC3: journaled to the burst-lane journal UNCONDITIONALLY (no \$BURST_ROUTE_LOG set)" \
  "grep -q '  route  mismatch  (intended=burst .*cause=shim-not-first' \"$BURST_LANE_JOURNAL\""
expect "cargoroute AC3: route-check itself never runs cargo (no fake-cargo marker written)" \
  "[ ! -f \"$FAKE_CARGO_MARKER_C\" ]"

# =========================================================================
# AC4 (d) — burst not configured at all -> route-check is a pure no-op.
# =========================================================================
echo "=== cargoroute AC4 (d): burst not configured -> no route lines at all ==="
fresh_env
REALCARGO="$(command -v cargo)"
rc_d="$(BUILD_BURST_ENABLED=0 PATH="$(dirname "$REALCARGO"):$PATH" "$BL" route-check --repo "$T" 2>&1)"; rc_d_rc=$?
expect "cargoroute AC4: burst-not-configured is state=clean" "grep -q 'state=clean' <<<\"$rc_d\""
expect "cargoroute AC4: burst-not-configured resolved is the real cargo (no shim involved)" \
  "grep -q \"resolved=$REALCARGO\" <<<\"$rc_d\""
expect "cargoroute AC4: route-check exits 0" "[ \"$rc_d_rc\" -eq 0 ]"
expect "cargoroute AC4: no 'route' journal lines at all" "! grep -q '  route  ' \"$BURST_LANE_JOURNAL\" 2>/dev/null"

# =========================================================================
# AC5 (e) — --head accepts an abbreviated SHA; a wrong one refuses with
# both full SHAs named.
# =========================================================================
echo "=== cargoroute AC5 (e): --head accepts abbreviated SHAs, refuses wrong ones with full SHAs ==="
REPO_E="$T/repo-e"
build_min_fixture "$REPO_E" "cargoroute-e"
# A second commit so there is a genuine "wrong but valid" commit to name.
echo "// second commit" >> "$REPO_E/src/lib.rs"
git -C "$REPO_E" -c user.name=t -c user.email=t@t commit -q -am "second commit"
HEAD_E_FULL="$(git -C "$REPO_E" rev-parse HEAD)"
HEAD_E_SHORT="$(git -C "$REPO_E" rev-parse --short HEAD)"
PARENT_E_FULL="$(git -C "$REPO_E" rev-parse HEAD~1)"
PARENT_E_SHORT="$(git -C "$REPO_E" rev-parse --short HEAD~1)"

COMMON_E_ENV=(
  "REVIEWER_PROMPT=/nonexistent/cargo-route-precedence-selftest-reviewer-prompt.md"
  "EXTEND_GATE_JOURNAL=$T/gate-journal-e.md"
)

out_e_wrong="$(env "${COMMON_E_ENV[@]}" timeout -k5 30 "$EXTEND_GATE" "$REPO_E" --head "$PARENT_E_SHORT" --force 2>&1)"; rc_e_wrong=$?
expect "cargoroute AC5: a valid-but-wrong short SHA refuses (exit 5)" "[ \"$rc_e_wrong\" -eq 5 ]"
expect "cargoroute AC5: refusal names actual HEAD's full SHA" "grep -qF \"$HEAD_E_FULL\" <<<\"$out_e_wrong\""
expect "cargoroute AC5: refusal names the given short ref's own full SHA (not the abbreviated form)" \
  "grep -qF \"$PARENT_E_FULL\" <<<\"$out_e_wrong\""

out_e_bogus="$(env "${COMMON_E_ENV[@]}" timeout -k5 30 "$EXTEND_GATE" "$REPO_E" --head "deadbee" --force 2>&1)"; rc_e_bogus=$?
expect "cargoroute AC5: an unresolvable short ref refuses (exit 5)" "[ \"$rc_e_bogus\" -eq 5 ]"
expect "cargoroute AC5: unresolvable-ref message says it does not resolve" "grep -qi 'does not resolve' <<<\"$out_e_bogus\""

out_e_good="$(env "${COMMON_E_ENV[@]}" timeout -k5 90 "$EXTEND_GATE" "$REPO_E" --head "$HEAD_E_SHORT" --force 2>&1)"; rc_e_good=$?
expect "cargoroute AC5: the correct short SHA is accepted (never refused as a head mismatch, exit != 5)" \
  "[ \"$rc_e_good\" -ne 5 ]"

# =========================================================================
# AC6 (f) — replay of the real systemd-unit-shaped service PATH with
# BUILD_BURST_ENABLED=1 -> extend-gate.sh's own guard resolves cargo-
# budget-bin first, end-to-end (no route-check involved — this proves the
# GUARD, not just the probe).
# =========================================================================
echo "=== cargoroute AC6 (f): real service-PATH replay + BUILD_BURST_ENABLED=1 -> guard fixes it end-to-end ==="
REPO_F="$T/repo-f"
build_min_fixture "$REPO_F" "cargoroute-f"
HEAD_F="$(git -C "$REPO_F" rev-parse HEAD)"
SERVICE_PATH="/home/jsy/.local/bin:/home/jsy/.cargo/bin:/home/jsy/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
out_f="$(BUILD_BURST_ENABLED=1 EXTEND_GATE_JOURNAL="$T/gate-journal-f.md" \
  REVIEWER_PROMPT="/nonexistent/cargo-route-precedence-selftest-reviewer-prompt.md" \
  PATH="$SERVICE_PATH" "$EXTEND_GATE" "$REPO_F" --head "$HEAD_F" --dry-run 2>&1)"
first_line_f="$(head -1 <<<"$out_f")"
expect "cargoroute AC6: replaying the real service PATH resolves cargo-budget-bin FIRST (guard fixed it, not just detected it)" \
  "[[ \"\$first_line_f\" == extend-gate:\ cargo=*cargo-budget-bin/cargo ]]"
echo "  first line: $first_line_f"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "cargo-route-precedence-selftest: ALL PASS"
else
  echo "cargo-route-precedence-selftest: assertion(s) FAILED"
fi
for d in "${ALL_TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
exit $fail
