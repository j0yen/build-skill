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

fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

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
  export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$T/journal.log"
  export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$T/remote"
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
  unset FAKE_HCLOUD_AUTH_FAIL FAKE_HCLOUD_CREATE_FAIL FAKE_HCLOUD_DELETE_FAIL FAKE_SSH_REMOTE_FAIL FAKE_SSH_SANDBOX_FAIL FAKE_RSYNC_FAIL BURST_LANE_NOW \
        FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL BURST_GATE_REVIEWER BURST_CLAUDE_CRED_SRC
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
cat > "$WT_GATE/target/autobuilder/receipts/box-parity.json" <<EOF
{"head_sha": "$head_gate", "box_host": "127.0.0.1", "suites": {}, "diff": []}
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

WT_C1="$T/conc1-repo"; mkdir -p "$WT_C1/target/autobuilder/receipts"
( cd "$WT_C1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_c1="$(git -C "$WT_C1" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_c1\", \"box_host\": \"x\", \"suites\": {}, \"diff\": []}" > "$WT_C1/target/autobuilder/receipts/box-parity.json"

WT_C2="$T/conc2-repo"; mkdir -p "$WT_C2/target/autobuilder/receipts"
( cd "$WT_C2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
head_c2="$(git -C "$WT_C2" rev-parse HEAD)"
echo "{\"head_sha\": \"$head_c2\", \"box_host\": \"x\", \"suites\": {}, \"diff\": []}" > "$WT_C2/target/autobuilder/receipts/box-parity.json"

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

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
