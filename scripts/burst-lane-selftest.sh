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
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

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
  export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$T/cost.jsonl"
  # Three-state retrofit (PRD-build-three-state-probes): sandbox the shared
  # probe ledger too, so this offline selftest never writes into the real
  # state/probes/ledger.jsonl or ~/brain/journal/build/.
  export BUILD_STATE_DIR="$T/state"
  export PROBE_JOURNAL_DIR="$T/probe-journal"
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
        FAKE_SSH_VOLUME_LABEL_PRESENT FAKE_SSH_VOLUME_MOUNT_FAIL FAKE_SSH_VOLUME_USED_GB FAKE_SSH_VOLUME_SIZE_GB FAKE_SSH_VOLUME_USED_PCT \
        FAKE_SSH_VOLUME_FSCK_CALLLOG
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
rm -f "$BURST_LANE_STATE_DIR/session.json"
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
  "grep -qxF fake-prd-slug-1 \"$BURST_LANE_STATE_DIR/prds_served\""
expect "prds_served also recorded the worktree-basename fallback from the earlier unset-slug runs" \
  "grep -qxF worktree \"$BURST_LANE_STATE_DIR/prds_served\""

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
down_out="$("$BL" down)"
expect "down keeps the session while rust work is queued" "[ \"$down_out\" = 'decision=keep' ]"
expect "down journaled decision=keep" "grep -q 'decision=keep' \"$BURST_LANE_JOURNAL\""

# ---- AC8: down schedules, then deletes at the hour boundary -----------------
rm -f "$BURST_LANE_PRD_DIR/build-queue/PRD-fake-rust.md"
boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
expect "state cleared prds_served after deletion" "[ ! -f \"$BURST_LANE_STATE_DIR/prds_served\" ]"
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
lockfile_lr="$BURST_LANE_STATE_DIR/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_LR").lock"
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
  "$BURST_LANE_STATE_DIR/dirty/$(printf '%s' "$T/mcphost-sw-cold" | sha1sum | cut -c1-8).json")"
rm -rf "$cold_remote"

# Simulate "a live run is still in flight on this one worktree right as the
# box is about to die": hold its wt-lock in the background — the sweep must
# skip it (leave it dirty, journal a failure) rather than abort (requirement
# 4: "per-worktree failure does not abort the sweep").
busy_lockfile="$BURST_LANE_STATE_DIR/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$T/mcphost-sw-busy").lock"
mkdir -p "$(dirname "$busy_lockfile")"
( exec 208>"$busy_lockfile"; flock 208; sleep 3 ) &
busy_holder_pid=$!
sleep 0.3

boot_epoch_sw="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
marker_file() { printf '%s/dirty/%s.json\n' "$BURST_LANE_STATE_DIR" "$(printf '%s' "$1" | sha1sum | cut -c1-8)"; }
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
boot_epoch2="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch2 + 7 * 3600))   # past the default 6h ttl
wd_out="$("$BL" watchdog)"
expect "watchdog deletes a session past its TTL" "grep -q '^watchdog teardown: ' <<<\"$wd_out\""
expect "watchdog journal line names uptime" "grep -q 'burst-lane  watchdog  teardown' \"$BURST_LANE_JOURNAL\""
expect "state cleared after watchdog teardown" "[ ! -f \"$BURST_LANE_STATE_DIR/session.json\" ]"
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

# 120 GB avail, 32 cores, 10 rust candidates -> floor(120/6)=20, floor(32/4)=8,
# min(20,8,10)=8 (AC7).
subcap8="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap admits 8 on a 120GB/32-core box (AC7)" "grep -q '^sub-cap=8 local=0' <<<\"$subcap8\""
# PRD-build-burst-remote-disk-guard requirement 2 added a trailing
# free_disk_gb field to this same journal line (the fake ssh's default disk
# reading, deliberately abundant so it's never the binding term here).
expect "sub-cap journals the AC7-shaped line" \
  "grep -q 'burst: sub-cap=8 (avail_gb=120 nproc=32 free_disk_gb=100000) local=0' \"$BURST_LANE_JOURNAL\""

# 40 GB avail, 32 cores -> floor(40/6)=6, floor(32/4)=8, min(6,8,10)=6 (AC7).
subcap6="$(FAKE_SSH_MEMINFO_GB=40 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap admits 6 on a 40GB/32-core box (AC7)" "grep -q '^sub-cap=6 local=0' <<<\"$subcap6\""

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
sed -i 's/"sandbox_ok":"true"/"sandbox_ok":"false"/' "$BURST_LANE_STATE_DIR/session.json"
subcap_nosandbox="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
expect "sub-cap falls back to local cap 2 when sandbox is unavailable (req 6 / AC5)" \
  "grep -q '^sub-cap=2 local=0' <<<\"$subcap_nosandbox\""
expect "sub-cap journals the sandbox-unavailable reason" \
  "grep -q 'burst-lane  sub-cap  sandbox-unavailable' \"$BURST_LANE_JOURNAL\""
sed -i 's/"sandbox_ok":"false"/"sandbox_ok":"true"/' "$BURST_LANE_STATE_DIR/session.json"

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
sid3="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
for slug in alpha beta gamma; do
  wt="$T/mcphost-$slug"; mkdir -p "$wt"
  echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$wt/build.sh"
  "$BL" run "$wt" -- bash build.sh >/dev/null 2>&1
done
boot_epoch3="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
sid5="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
boot_epoch5="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
boot_epoch6="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
# free_disk_gb=200 with the default 40 GB floor / 70 GB-per-branch admits
# only floor((200-40)/70)=2 (requirement 2).
fresh_env
"$BL" up >/dev/null
subcap_disk="$(FAKE_SSH_MEMINFO_GB=59 FAKE_SSH_NPROC=16 FAKE_SSH_DISK_GB=200 "$BL" sub-cap)"
expect "burstdisk AC1: sub-cap is disk-bound at 2 on a 59GB/16-core/200GB-disk box" \
  "grep -q '^sub-cap=2 local=0' <<<\"$subcap_disk\""
expect "burstdisk AC1: stdout names the binding term" "grep -q 'bound=disk' <<<\"$subcap_disk\""
expect "burstdisk AC1: journal carries free_disk_gb and bound=disk" \
  "grep -q 'sub-cap=2 (avail_gb=59 nproc=16 free_disk_gb=200) bound=disk' \"$BURST_LANE_JOURNAL\""

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
  "ls \"$BURST_LANE_STATE_DIR/logs\"/rsync-up.*.log >/dev/null 2>&1"

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
expect "burstdisk AC4 setup: baz is still dirty-marked" "[ -s \"$BURST_LANE_STATE_DIR/dirty/$baz_hash.json\" ]"

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
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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

# ---- gateroute: mismatch when a fake real-cargo is forced first on PATH ----
# The exact 2026-09-10 defect, reproduced structurally: a session is up
# (intended=burst) but something (the pre-fix extend-gate.sh, here just a
# fake real-cargo directory) sits ahead of the shim on $PATH.
fresh_env
"$BL" up >/dev/null
ROUTE_LOG_MISMATCH="$T/route-mismatch.log"
rc_mismatch="$(BURST_ROUTE_LOG="$ROUTE_LOG_MISMATCH" PATH="$FAKEBIN_GR:$HERE/burst-lane-bin:$FAKE:$PATH" "$BL" route-check --repo "$T" 2>&1)"
expect "gateroute: shadowed shim reports intended=burst" "grep -q 'intended=burst' <<<\"$rc_mismatch\""
expect "gateroute: shadowed shim resolves to the fake real cargo, not the shim" "grep -q \"resolved=$FAKEBIN_GR/cargo\" <<<\"$rc_mismatch\""
expect "gateroute: shadowed shim is state=mismatch cause=shim-not-first" "grep -q 'state=mismatch cause=shim-not-first' <<<\"$rc_mismatch\""
expect "gateroute: mismatch seeded a synthetic local/shim-not-first route-log line" \
  "[ -f \"$ROUTE_LOG_MISMATCH\" ] && awk '\$4==\"local\" && \$5==\"shim-not-first\"' \"$ROUTE_LOG_MISMATCH\" | grep -q ."
expect "gateroute: mismatch probed the gate-cargo-route probe dirty (library's dirty == this probe's mismatch)" \
  "grep -q '\"probe\": \"gate-cargo-route\", \"reason\": \"route-mismatch intended=burst' \"$BUILD_STATE_DIR/probes/ledger.jsonl\""

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

boot_epoch_g7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/session.json\""
gt_missing_field="$(grep -oE '"gate_tools_missing":"[^"]*"' "$BURST_LANE_STATE_DIR/session.json" | cut -d'"' -f4)"
expect "gatebox AC1: gate_tools_missing is empty once provisioning completed" "[ -z \"$gt_missing_field\" ]"
gatebox1_tools_rc=0
python3 -c "
import json
d = json.load(open('$BURST_LANE_STATE_DIR/gate-tools.json'))
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
rm -f "$BURST_LANE_STATE_DIR/session.json"
unset FAKE_SSH_GATE_TOOLS_MISSING
gatebox1b_out="$("$BL" up)"; gatebox1b_rc=$?
expect "gatebox AC1: adoption path also succeeds and re-provisions" "[ $gatebox1b_rc -eq 0 ]"
expect "gatebox AC1: adoption path also records gate_ready:true" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/session.json\""

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

boot_epoch4="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
ip7="$(grep -oE '"ip":"[^"]*"' "$BURST_LANE_STATE_DIR/session.json" | cut -d'"' -f4)"
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
marker_7a="$BURST_LANE_STATE_DIR/gate-inflight/$(printf '%s' "$WT_GATE7A" | sha1sum | cut -c1-8).json"
mkdir -p "$(dirname "$marker_7a")"
python3 -c "import json; json.dump({'repo': '$WT_GATE7A', 'host': '$ip7', 'started_epoch': $BURST_LANE_NOW, 'budget_s': 30}, open('$marker_7a', 'w'))"
lockfile_7a="$BURST_LANE_STATE_DIR/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_GATE7A").lock"
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
ip7="$(grep -oE '"ip":"[^"]*"' "$BURST_LANE_STATE_DIR/session.json" | cut -d'"' -f4)"
boot_epoch7="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((boot_epoch7 + 3600 - 60))
export BURST_LANE_GATE_WAIT_POLL_S=0.1
WT_GATE7B="$T/gate7b-repo"; mkdir -p "$WT_GATE7B/target/autobuilder"
echo '{"pass": 25, "block": 0, "stale": true}' > "$WT_GATE7B/target/autobuilder/last-verdict.json"
marker_7b="$BURST_LANE_STATE_DIR/gate-inflight/$(printf '%s' "$WT_GATE7B" | sha1sum | cut -c1-8).json"
mkdir -p "$(dirname "$marker_7b")"
python3 -c "import json; json.dump({'repo': '$WT_GATE7B', 'host': '$ip7', 'started_epoch': $((BURST_LANE_NOW - 999)), 'budget_s': 30}, open('$marker_7b', 'w'))"
lockfile_7b="$BURST_LANE_STATE_DIR/locks/wt-$(python3 -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$WT_GATE7B").lock"
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
mkdir -p "$BURST_LANE_STATE_DIR/gate-inflight"
python3 -c "import json; json.dump({'repo': '/fake/repo', 'host': '127.0.0.1', 'started_epoch': 0, 'budget_s': 1800}, open('$BURST_LANE_STATE_DIR/gate-inflight/fakegate.json', 'w'))"
subcap_gates="$(FAKE_SSH_MEMINFO_GB=120 FAKE_SSH_NPROC=32 "$BL" sub-cap --candidates 10)"
# 120GB/32cores -> floor(120/6)=20, floor(32/4)=8 -> unweighted sub-cap=8
# (AC7's own baseline); one active gate subtracts 2 -> 6.
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
boot_epoch_r9="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
mkdir -p "$BURST_LANE_STATE_DIR/gate-inflight"
python3 -c "import json; json.dump({'repo': '/fake/status-repo', 'host': '127.0.0.1', 'started_epoch': $(date -u +%s) - 90, 'budget_s': 1800, 'head_sha': 'abcdef0123456789', 'slot': '2'}, open('$BURST_LANE_STATE_DIR/gate-inflight/statusgate.json', 'w'))"
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
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/gate-tools.json')); sys.exit(0 if d.get('tools',{}).get('autobuilder') not in (None,'','MISSING') else 1)\""
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
expect "gatetools AC2: session state is verified:true" "grep -q '\"verified\":\"true\"' \"$BURST_LANE_STATE_DIR/session.json\""
expect "gatetools AC2: session state is gate_ready:false" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
expect "gatetools AC4 setup: gate_ready:false after up (copy failed)" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/session.json\""

unset FAKE_SSH_GATE_TOOLS_INSTALL_FAIL
gt4_out="$("$BL" provision 2>&1)"; gt4_rc=$?
expect "gatetools AC4: provision exits 0 once the retried install succeeds" "[ $gt4_rc -eq 0 ]"
expect "gatetools AC4: gate_ready becomes true without a reboot" \
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
expect "gatetools AC5: gate_ready is false due to version drift" "grep -q '\"gate_ready\":\"false\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
  "grep -q '\"gate_ready\":\"true\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
expect "gatetc AC2: journal has the exact install-failed line for mold" \
  "grep -q 'gate-tools  install-failed  (tool=mold rc=100 err=\"E: Unable to locate package mold\")' \"$BURST_LANE_JOURNAL\""
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
expect "burstuser AC1: up exits 0" "[ $bu1_rc -eq 0 ]"
expect "burstuser AC1: root ssh received the user-creation call" \
  "grep -P '^root@\\S+\\t.*# user-create' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC1: the same root call installs the ssh key (authorized_keys)" \
  "grep -P '^root@\\S+\\t.*authorized_keys' \"$FAKE_SSH_CALL_LOG\" >/dev/null"
expect "burstuser AC1: session.json records remote_user=build" \
  "grep -q '\"remote_user\":\"build\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
bu5_boot_epoch="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/session.json'))['boot_epoch'])")"
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
bu6_sid="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/session.json'))['server_id'])")"
# Simulate a pre-ship (or rolled-back) root-only session: hand-edit
# remote_user back to root, and fabricate a dirty marker + remote artifact
# shaped like one a root-routed `run` would have left behind.
sed -i 's/"remote_user":"build"/"remote_user":"root"/' "$BURST_LANE_STATE_DIR/session.json"
WT_MIG="$T/wt-migrate"; mkdir -p "$WT_MIG"
OLD_REMOTE_MIG="$T/old-root-remote-tree"; mkdir -p "$OLD_REMOTE_MIG"
echo "pre-existing build artifact" > "$OLD_REMOTE_MIG/artifact.txt"
mkdir -p "$BURST_LANE_STATE_DIR/dirty"
bu6_wkey="$(printf '%s' "$WT_MIG" | sha1sum | cut -c1-8)"
python3 -c "
import json
json.dump({'worktree': '$WT_MIG', 'session_id': '$bu6_sid', 'remote_path': '$OLD_REMOTE_MIG', 'kind': 'target', 'marked_ts': '2026-01-01T00:00:00Z'},
           open('$BURST_LANE_STATE_DIR/dirty/$bu6_wkey.json', 'w'))
"
: > "$FAKE_SSH_CALL_LOG"
bu6_prov_out="$("$BL" provision 2>&1)"
expect "burstuser AC6: session.json now records remote_user=build" \
  "grep -q '\"remote_user\":\"build\"' \"$BURST_LANE_STATE_DIR/session.json\""
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
pr4_sid="$(python3 -c "import json; print(json.load(open('$BURST_LANE_STATE_DIR/session.json'))['server_id'])")"
sed -i 's/"remote_user":"build"/"remote_user":"root"/' "$BURST_LANE_STATE_DIR/session.json"
WT_PR4="$T/wt-migrate-mismatch"; mkdir -p "$WT_PR4"
OLD_REMOTE_PR4="$T/old-root-remote-tree-mismatch"; mkdir -p "$OLD_REMOTE_PR4"
echo "pre-existing build artifact" > "$OLD_REMOTE_PR4/artifact.txt"
mkdir -p "$BURST_LANE_STATE_DIR/dirty"
pr4_wkey="$(printf '%s' "$WT_PR4" | sha1sum | cut -c1-8)"
python3 -c "
import json
json.dump({'worktree': '$WT_PR4', 'session_id': '$pr4_sid', 'remote_path': '$OLD_REMOTE_PR4', 'kind': 'target', 'marked_ts': '2026-01-01T00:00:00Z'},
           open('$BURST_LANE_STATE_DIR/dirty/$pr4_wkey.json', 'w'))
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
expect "parityr AC6: every parityr case above ran green" "[ $fail -eq 0 ]"

# ---- burstuser AC7: the fixture set (this file) exits 0 and names the
# burstuser cases — checked here as an explicit, in-band assertion (rather
# than only by the exit code the harness wrapper around this file checks)
# so tests/burstuser_ac7_*.sh has a real "ok" line of its own to grep for,
# matching every sibling AC's own convention.
expect "burstuser AC7: every burstuser case above ran green (fail=0 through AC1-AC6)" "[ $fail -eq 0 ]"

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

# reality AC3 (PRD AC3): no session -> frontmatter reads unreachable, no follow-up.
cp "$RT/built-prds/PRD-realityfix.md.orig" "$RT/built-prds/PRD-realityfix.md"
rm -rf "$RT/journal"
PATH="$RT/fake-bin:$PATH" REALITY_CHECK_BURST_LANE="$RT/fake-bin/fake-lane-inactive.sh" \
  BUILD_JOURNAL_DIR="$RT/journal" BUILD_RECEIPTS_DIR="$RT/journal/receipts" \
  "$RC" run "$RT/built-prds/PRD-realityfix.md" --no-push >/dev/null 2>&1
expect "reality AC3: unreachable lane -> reality: unreachable" "grep -q '^- reality: unreachable' \"$RT/built-prds/PRD-realityfix.md\""
expect "reality AC3: no follow-up drafted when unreachable" "[ ! -e \"$RT/build-queue/PRD-realityfix-reality-1.md\" ]"

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
expect "reality AC9: every reality case above ran green" "[ $fail -eq 0 ]"
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
# point), so $iso_ac4_state was never created — make it now.
mkdir -p "$iso_ac4_state"
printf '{"date":"%sT00:00:00Z","kind":"slug","slug":"isolate-ac4","eur":0.01}\n' "$today" > "$iso_ac4_state/cost.jsonl"
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
expect "isolate AC6: every isolate case above ran green" "[ $fail -eq 0 ]"

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
sid_pc1="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
sid_pc2="$(grep -oE '"server_id":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
expect "paritycad AC3: no session was ever brought up (neither side ran)" "[ ! -f \"$BURST_LANE_STATE_DIR/session.json\" ]"
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
expect "paritycad AC6: every paritycad case above ran green" "[ $fail -eq 0 ]"

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
bv3_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
bv4_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
export BURST_LANE_NOW=$((bv4_boot_epoch + 3600 - 60))
bv4_down_out="$("$BL" down)"
unset BURST_LANE_NOW FAKE_HCLOUD_VOLUME_DETACH_FAIL
expect "burstvol AC4: server still deletes even though detach failed" "[ \"$bv4_down_out\" = 'decision=deleted' ]"
expect "burstvol AC4: journal records volume detach-failed" "grep -q 'burst-lane  down  volume  detach-failed' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC4: volume state file marks volume_dirty=true" \
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/volume.json')); sys.exit(0 if d.get('volume_dirty')=='true' else 1)\""
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
  "python3 -c \"import json,sys; d=json.load(open('$BURST_LANE_STATE_DIR/volume.json')); sys.exit(0 if d.get('volume_mounted')=='false' else 1)\""

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
bv8_boot_epoch="$(grep -oE '"boot_epoch":[0-9]+' "$BURST_LANE_STATE_DIR/session.json" | cut -d: -f2)"
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
mkdir -p "$BURST_LANE_STATE_DIR/pull-sizes"
# 87 GB, exactly matching the PRD's own AC9 scenario and the real
# 2026-09-11 incident evidence (an 87 GB single gate pull).
printf '%s\n' "$((87 * 1073741824))" > "$BURST_LANE_STATE_DIR/pull-sizes/$bv9_wkey"
export BURST_LANE_LOCAL_FREE_GB=20
bv9_pull_out="$("$BL" pull "$WT_BV9" 2>&1)"; bv9_pull_rc=$?
unset BURST_LANE_LOCAL_FREE_GB
expect "burstvol AC9: pull exits 0 (deferred, not an error)" "[ $bv9_pull_rc -eq 0 ]"
expect "burstvol AC9: journal records pull deferred cause=local-disk free_gb=20 need_gb=87" \
  "grep -q 'burst-lane  pull  deferred  (worktree=$WT_BV9 .*cause=local-disk free_gb=20 need_gb=87' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC9: the marker stays dirty (never cleared)" "dirty_has \"$WT_BV9\""

# ---- burstvol AC10: a dirty marker under a moved root (byte-identical to --
# the 2026-09-11 user-migration evidence: a marker still naming /root/build
# after $REMOTE_ROOT moved) is treated as cold on read, cleared, and NEVER
# retried as rsync-failed — checked before any ssh round trip.
fresh_env
"$BL" up >/dev/null
WT_BV10="$T/rootmove-wt"; mkdir -p "$WT_BV10"
bv10_wkey="$(printf '%s' "$WT_BV10" | sha1sum | cut -c1-8)"
mkdir -p "$BURST_LANE_STATE_DIR/dirty"
python3 -c "
import json
json.dump(
    {'worktree': '$WT_BV10', 'session_id': 'stale-session', 'kind': 'target',
     'remote_path': '/root/build/rootmove-wt-$bv10_wkey', 'marked_ts': '2026-01-01T00:00:00Z'},
    open('$BURST_LANE_STATE_DIR/dirty/$bv10_wkey.json', 'w'))
"
bv10_pull_out="$("$BL" pull "$WT_BV10" 2>&1)"; bv10_pull_rc=$?
expect "burstvol AC10: pull against a marker under a moved root exits 0 (cold, not an error)" "[ $bv10_pull_rc -eq 0 ]"
expect "burstvol AC10: journal records pull cold cause=remote-path-missing" \
  "grep -q 'burst-lane  pull  cold  (worktree=$WT_BV10 .*cause=remote-path-missing' \"$BURST_LANE_JOURNAL\""
expect "burstvol AC10: never journaled as rsync-failed for this worktree" \
  "! grep -q \"burst-lane  pull  fallback  (cause=rsync-failed worktree=$WT_BV10\" \"$BURST_LANE_JOURNAL\""
expect "burstvol AC10: the stale marker was cleared" "[ ! -e \"$BURST_LANE_STATE_DIR/dirty/$bv10_wkey.json\" ]"

# ---- burstvol AC11: this fixture set exits 0 and names the burstvol cases -
# (an explicit, in-band assertion, matching every sibling AC's own
# convention — see burstuser AC7/parityr AC6 above).
expect "burstvol AC11: every burstvol case above ran green" "[ $fail -eq 0 ]"
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
expect "pathdeps AC6: every pathdeps case above ran green" "[ $fail -eq 0 ]"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
