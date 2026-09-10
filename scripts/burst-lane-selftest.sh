#!/usr/bin/env bash
# burst-lane-selftest.sh — offline proof for burst-lane.sh (requirement 9,
# PRD-build-burst-lane-ccx53) using the fake hcloud/ssh/rsync under
# tests/fixtures/burst-lane-fake/. No network calls, no real Hetzner spend.
#
# Covers: single-box refusal + session adoption (AC1), run's exit-code
# passthrough (AC2), the incremental target/ pull-back and its shrinking
# byte count across two consecutive runs on the same worktree (AC11,
# requirement 10), watchdog TTL teardown (AC6), down's keep/scheduled/
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
  unset FAKE_HCLOUD_AUTH_FAIL FAKE_HCLOUD_CREATE_FAIL FAKE_HCLOUD_DELETE_FAIL FAKE_SSH_REMOTE_FAIL FAKE_SSH_SANDBOX_FAIL FAKE_RSYNC_FAIL BURST_LANE_NOW
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

# ---- AC2: run's exit-code passthrough + artifact sync-back -----------------
WT="$T/worktree"; mkdir -p "$WT"
echo 'mkdir -p target && echo built > target/out.txt; exit 7' > "$WT/build.sh"
run_out="$("$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc=$?
expect "run propagates the remote exit code" "[ $run_rc -eq 7 ]"
expect "run pulled target/ back to the worktree" "[ -f \"$WT/target/out.txt\" ]"
expect "run journaled the routed call" "grep -q 'burst-lane  run  routed' \"$BURST_LANE_JOURNAL\""
expect "run's journal line records bytes transferred (req 10)" "grep -q 'burst-lane  run  routed.*bytes=[0-9]' \"$BURST_LANE_JOURNAL\""

# ---- AC11: a second `run` on the same (now-warm) worktree transfers fewer
# bytes than the first — the target/ pull-back is incremental, not a fresh
# whole copy each time (requirement 10).
run_out2="$("$BL" run "$WT" -- bash build.sh 2>&1)"; run_rc2=$?
expect "second run also propagates the remote exit code" "[ $run_rc2 -eq 7 ]"
bytes1="$(grep 'burst-lane  run  routed' "$BURST_LANE_JOURNAL" | sed -n '1p' | grep -oE 'bytes=[0-9]+' | cut -d= -f2)"
bytes2="$(grep 'burst-lane  run  routed' "$BURST_LANE_JOURNAL" | sed -n '2p' | grep -oE 'bytes=[0-9]+' | cut -d= -f2)"
expect "first run journaled a byte count" "[ -n \"$bytes1\" ]"
expect "second run journaled a byte count" "[ -n \"$bytes2\" ]"
expect "second run's journal line shows fewer bytes than the first (AC11)" "[ \"${bytes2:-0}\" -lt \"${bytes1:-0}\" ]"

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
expect "python run pulled .pybuilder/ back to the worktree, not target/ (req 12)" \
  "[ -f \"$WT_PY/.pybuilder/out.txt\" ] && [ ! -e \"$WT_PY/target\" ]"
expect "python run journaled the routed call" "grep -q 'burst-lane  run  routed.*worktree=$WT_PY' \"$BURST_LANE_JOURNAL\""

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
expect "sub-cap journals the AC7-shaped line" \
  "grep -q 'burst: sub-cap=8 (avail_gb=120 nproc=32) local=0' \"$BURST_LANE_JOURNAL\""

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
if len(slug_rows) != 3:
    print("expected 3 slug rows, got", len(slug_rows), file=sys.stderr); sys.exit(1)
if not session_rows:
    print("no session row found for", sid, file=sys.stderr); sys.exit(1)
total = sum(r["eur"] for r in slug_rows)
if abs(total - session_rows[-1]["eur"]) > 1e-6:
    print("conservation mismatch", total, session_rows[-1]["eur"], file=sys.stderr); sys.exit(1)
sys.exit(0)
PY
expect "AC3: cost ledger gains 3 slug rows whose eur sums exactly to the session eur" "[ \"$ac3_rc\" -eq 0 ]"

# ---- AC4: `cost --by-prd --session <id>` lists the 3 slugs + a totals row -
by_prd_out="$("$BL" cost --by-prd --session "$sid3" 2>&1)"; by_prd_rc=$?
expect "AC4: cost --by-prd --session exits 0 (conservation check passes)" "[ $by_prd_rc -eq 0 ]"
expect "AC4: cost --by-prd lists all 3 slugs" \
  "grep -q '^alpha' <<<\"$by_prd_out\" && grep -q '^beta' <<<\"$by_prd_out\" && grep -q '^gamma' <<<\"$by_prd_out\""
expect "AC4: cost --by-prd prints a TOTAL row" "grep -q '^TOTAL' <<<\"$by_prd_out\""
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
unset BURST_LANE_NOW

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
