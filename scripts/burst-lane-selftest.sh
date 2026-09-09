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
# -> 6, no session -> local cap 3 only).
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

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
