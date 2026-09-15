#!/usr/bin/env bash
# burst-lane-pull-remote-target-missing-selftest.sh — offline proof for
# PRD-build-burst-pull-remote-target-missing, using the same fake hcloud/
# ssh/rsync fixtures under tests/fixtures/burst-lane-fake/ as
# scripts/burst-lane-selftest.sh. A dedicated, standalone suite (per the
# PRD's own Engineering target) rather than another few hundred lines woven
# into the giant suite — this PRD's whole surface is one function
# (do_marker_pull) plus its two helpers (pull_target_incremental,
# rsync_failure_cause/pull_backoff_delay_s) and one small P2 addition
# (reap_stuck_markers), small enough to prove end to end on its own.
#
# fresh_env() below is a deliberate near-verbatim copy of
# burst-lane-selftest.sh's own fresh_env — the full env-var surface a real
# `up`/`run`/`pull` touches (gate-tools, volume, reality-check, cost
# attribution, ...) is wide enough that a hand-trimmed subset risks a
# fixture unexpectedly reaching this machine's real $HOME. Copying the
# proven-working set is safer than re-deriving it; if that function's own
# env surface grows, this one may drift and need a manual re-sync.
#
# Covers all 9 ACs (pullmiss_ac1..ac9) plus a smoke check of the P2 `reap`
# addition (requirement 8, not itself one of the 9 numbered ACs).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/burst-lane.sh"
FAKE="$HERE/../tests/fixtures/burst-lane-fake"
[ -x "$BL" ] || { echo "selftest: $BL not executable" >&2; exit 2; }

export BURST_LANE_TEST=1
[ "${BURST_LANE_TEST:-}" = "1" ] || {
  echo "pullmiss-selftest: BURST_LANE_TEST not set in own environment — refusing to start" >&2
  exit 2
}

# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — see burst-configured.sh; set BUILD_BURST_ENABLED=1 to force"
  exit 0
fi

fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Fixture worktrees land under a tmpfs that may be far smaller than
# do_marker_pull's production 60 GB floor — same fail-fast-avoidance
# override tests/fixtures/pullback-ac-common.sh already uses.
export BURST_LOCAL_DISK_FLOOR_GB="${BURST_LOCAL_DISK_FLOOR_GB:-2}"

# rc0 iff `status --json`'s "dirty" array lists $1 by exact worktree path.
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

# The dirty marker's own recorded remote_path for $1, read back through
# `status --json` (never by recomputing remote_path_for() ourselves — that
# would prove nothing about what the running code actually wrote).
pullmiss_remote_path() {  # $1=worktree -> stdout remote_path
  "$BL" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for x in d.get("dirty", []):
    if x.get("worktree") == sys.argv[1]:
        print(x.get("remote_path", ""))
        sys.exit(0)
sys.exit(1)
' "$1"
}

# One field out of a dirty marker's `status --json` row for $1 (empty/None
# stringified as "None" by python's own print — callers compare against
# that literal for "absent").
pullmiss_dirty_field() {  # $1=worktree $2=field -> stdout value
  "$BL" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("None"); sys.exit(0)
for x in d.get("dirty", []):
    if x.get("worktree") == sys.argv[1]:
        print(x.get(sys.argv[2]))
        sys.exit(0)
print("None")
' "$1" "$2"
}

# ---- fresh_env: near-verbatim copy of burst-lane-selftest.sh's own -------
fresh_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/bl-pullmiss-selftest.XXXXXX")"
  ALL_TMPDIRS+=("$T")
  export PATH="$FAKE:$PATH"
  export BURST_LANE_TEST=1
  export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$T/journal.log"
  export BURST_PROVE_TMP="$T/prove-tmp"; mkdir -p "$BURST_PROVE_TMP"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$T/remote"
  export BURST_LANE_REMOTE_HOME="$T/remote-home"
  export BURST_LANE_ROOT_RUSTUP_HOME="$HOME/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="$HOME/.cargo"
  export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
  export FAKE_HCLOUD_STATE="$T/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$T/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  export FAKE_HCLOUD_IMAGE_STATE="$T/hcloud-image.state"
  export BURST_LANE_SYSTEMD_DROPIN="$T/systemd-user/claude-build.service.d/burst.conf"
  export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$T/cost.jsonl"
  export BUILD_STATE_DIR="$T/state"
  export PROBE_JOURNAL_DIR="$T/probe-journal"
  export BUILD_JOURNAL_DIR="$T/reality-journal"
  export BUILD_RECEIPTS_DIR="$T/reality-journal/receipts"
  export REALITY_CHECK_PENDING_DIR="$T/reality-pending"
  export BURST_LANE_ATTR_LEDGER="$T/attribution.jsonl"
  export BURST_LANE_REPOS_DIR="$T/repos"; mkdir -p "$BURST_LANE_REPOS_DIR"
  export BURST_LANE_TICK_JOURNAL_DIR="$T/tick-journal"; mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
  export FAKE_GATE_TOOLS_STATE="$T/gate-tools-installed"
  export BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR="$T/remote-cargo-bin"
  export BURST_LANE_GATE_CRED_REMOTE_PATH="$T/remote-cred/.credentials.json"
  export BURST_GATE_REMOTE=1
  export BURST_LANE_FORCE_NEXTEST_LOCAL=0
  export BURST_VOLUME_NAME=""
  export FAKE_HCLOUD_VOLUME_STATE="$T/hcloud-volume.state"
  unset FAKE_HCLOUD_AUTH_FAIL FAKE_HCLOUD_CREATE_FAIL FAKE_HCLOUD_DELETE_FAIL FAKE_SSH_REMOTE_FAIL FAKE_SSH_SANDBOX_FAIL FAKE_RSYNC_FAIL BURST_LANE_NOW \
        FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG FAKE_RSYNC_TARGET_MISSING FAKE_RSYNC_CONN_REFUSED FAKE_RSYNC_CONN_REFUSED_HOST FAKE_RSYNC_CALL_LOG \
        FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL FAKE_SSH_AUTOBUILDER_VERSION BURST_GATE_REVIEWER BURST_CLAUDE_CRED_SRC \
        FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR \
        FAKE_SSH_GATE_TOOLS_TOOLCHAIN_SIM FAKE_GATE_TOOLS_TOOLCHAIN_BIN FAKE_RUSTUP_TOOLCHAINS FAKE_CARGO_REQUIRE_TOOLCHAIN \
        FAKE_SSH_GATE_TOOLS_APT_UPDATE_FAIL FAKE_SSH_NEXTEST_PRESENT \
        FAKE_HCLOUD_VOLUME_CREATE_FAIL FAKE_HCLOUD_VOLUME_ATTACH_FAIL FAKE_HCLOUD_VOLUME_DETACH_FAIL \
        FAKE_HCLOUD_VOLUME_CREATE_STDERR_NOISE FAKE_HCLOUD_VOLUME_CREATE_GARBLED \
        FAKE_SSH_VOLUME_LABEL_PRESENT FAKE_SSH_VOLUME_MOUNT_FAIL FAKE_SSH_VOLUME_USED_GB FAKE_SSH_VOLUME_SIZE_GB FAKE_SSH_VOLUME_USED_PCT \
        FAKE_SSH_VOLUME_FSCK_CALLLOG \
        FAKE_HCLOUD_CREATE_IMAGE_FAIL FAKE_HCLOUD_CREATE_IMAGE_PENDING \
        FAKE_SSH_PULL_PROBE_BYTES FAKE_SSH_PULL_PROBE_FAIL FAKE_SSH_PULL_PROBE_HANG BURST_PULL_PROBE_TIMEOUT_S \
        BURST_PULL_BACKOFF_BASE_S BURST_PULL_BACKOFF_CAP_S BURST_PULL_MAX_ATTEMPTS
}

# ============================================================================
# AC1 — a dirty marker whose remote_path exists but has no target/: cleared
# in one pass, one `pull cold ... cause=remote-target-missing` line, a
# second read journals nothing and makes no ssh call.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT1="$T/wt-ac1"; mkdir -p "$WT1"
echo 'exit 0' > "$WT1/build.sh"   # deliberately never creates target/
"$BL" run "$WT1" -- bash build.sh >/dev/null 2>&1
expect "AC1 setup: run left the worktree dirty" "dirty_has \"$WT1\""
rp1="$(pullmiss_remote_path "$WT1")"
export FAKE_RSYNC_TARGET_MISSING="$rp1/target"
out1="$("$BL" ensure-fresh "$WT1" 2>&1)"; rc1=$?
expect "AC1: ensure-fresh (local-read) exits 0" "[ $rc1 -eq 0 ]"
expect "AC1: marker is cleared" "! dirty_has \"$WT1\""
expect "AC1: journal names cause=remote-target-missing" \
  "grep -qE 'burst-lane  pull  cold  \(worktree=$WT1 .*cause=remote-target-missing' \"$BURST_LANE_JOURNAL\""
lines1_before="$(wc -l < "$BURST_LANE_JOURNAL")"
out1b="$("$BL" ensure-fresh "$WT1" 2>&1)"
lines1_after="$(wc -l < "$BURST_LANE_JOURNAL")"
expect "AC1: second read reports clean (nothing left to pull)" "[ \"$out1b\" = clean ]"
expect "AC1: second read journals nothing (no ssh call — marker already gone)" "[ \"$lines1_before\" = \"$lines1_after\" ]"
unset FAKE_RSYNC_TARGET_MISSING

# ============================================================================
# AC2 — fake rsync exits 23 with the real "change_dir ... No such file or
# directory" text: outcome is cold with cause=remote-target-missing, never
# rsync-failed.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT2="$T/wt-ac2"; mkdir -p "$WT2"
echo 'exit 0' > "$WT2/build.sh"
"$BL" run "$WT2" -- bash build.sh >/dev/null 2>&1
rp2="$(pullmiss_remote_path "$WT2")"
export FAKE_RSYNC_TARGET_MISSING="$rp2/target"
out2="$("$BL" pull "$WT2" 2>&1)"; rc2=$?
expect "AC2: rc23 target-missing pull exits 0 (cold, not a failure)" "[ $rc2 -eq 0 ]"
expect "AC2: stdout reports cold" "[ \"$out2\" = 'cold: remote artifacts gone, marker cleared' ]"
expect "AC2: journal cause is remote-target-missing" \
  "grep -qE 'burst-lane  pull  cold  \(worktree=$WT2 .*cause=remote-target-missing' \"$BURST_LANE_JOURNAL\""
expect "AC2: never journaled as cause=rsync-failed" \
  "! grep -qE 'cause=rsync-failed.*worktree=$WT2( |\$)' \"$BURST_LANE_JOURNAL\""
unset FAKE_RSYNC_TARGET_MISSING

# ============================================================================
# AC3 — fake rsync exits 255 (connection refused): fallback line carries
# rc=255, the err= text, attempts=1 next_retry_s=30; the full stderr is kept
# under $STATE_DIR/logs/pull-fail.<marker-id>.<epoch>.log.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT3="$T/wt-ac3"; mkdir -p "$WT3"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT3/build.sh"
"$BL" run "$WT3" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_CONN_REFUSED=1 FAKE_RSYNC_CONN_REFUSED_HOST=9.9.9.9
out3="$("$BL" pull "$WT3" 2>&1)"; rc3=$?
expect "AC3: rc255 pull exits non-zero" "[ $rc3 -ne 0 ]"
expect "AC3: fallback line carries cause=ssh-failed rc=255 and the err text" \
  "grep -qE 'burst-lane  pull  fallback  \(cause=ssh-failed rc=255 err=\"ssh: connect to host' \"$BURST_LANE_JOURNAL\""
expect "AC3: fallback line carries attempts=1 next_retry_s=30" \
  "grep -q 'attempts=1 next_retry_s=30' \"$BURST_LANE_JOURNAL\""
wkey3="$(printf '%s' "$WT3" | sha1sum | cut -c1-8)"
faillog3="$(ls "$BURST_LANE_STATE_DIR"/logs/pull-fail."$wkey3".*.log 2>/dev/null | head -1)"
expect "AC3: pull-fail log exists and is kept" "[ -n \"$faillog3\" ] && [ -s \"$faillog3\" ]"
expect "AC3: pull-fail log holds the FULL rsync stderr" "grep -q 'Connection refused' \"$faillog3\""
unset FAKE_RSYNC_CONN_REFUSED FAKE_RSYNC_CONN_REFUSED_HOST

# ============================================================================
# AC4 — 20 local-read pulls over a simulated 10 minutes: at most 5 real
# rsync attempts (30, 60, 120, 240, 480 s apart), remaining calls journal at
# most one `pull backoff` line per backoff window.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT4="$T/wt-ac4"; mkdir -p "$WT4"
echo 'exit 0' > "$WT4/build.sh"
"$BL" run "$WT4" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=6 FAKE_RSYNC_FAIL_MSG='rsync: fake ac4 failure'
t4=0
for _ in $(seq 1 20); do
  BURST_LANE_NOW="$t4" "$BL" ensure-fresh "$WT4" >/dev/null 2>&1
  t4=$((t4 + 30))
done
fallback4="$(grep -cE "burst-lane  pull  fallback  .*worktree=$WT4( |\$)" "$BURST_LANE_JOURNAL")"
backoff4="$(grep -cE "burst-lane  pull  backoff  \(worktree=$WT4 " "$BURST_LANE_JOURNAL")"
expect "AC4: at most 5 real rsync attempts over 20 local-read calls / 600s" "[ \"$fallback4\" -le 5 ]"
expect "AC4: at most one backoff line per window (<=4 windows opened)" "[ \"$backoff4\" -le 4 ]"
delays4="$(grep -E "burst-lane  pull  fallback  .*worktree=$WT4( |\$)" "$BURST_LANE_JOURNAL" | grep -oE 'next_retry_s=[0-9]+' | cut -d= -f2 | tr '\n' ' ')"
expect "AC4: backoff delays are exactly 30 60 120 240 480 in order" "[ \"$delays4\" = '30 60 120 240 480 ' ]"
unset FAKE_RSYNC_FAIL FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG

# ============================================================================
# AC5 — 8 consecutive failures -> the 9th local-read makes no ssh call, one
# `pull stuck` line exists, status --json shows stuck:true; a new routed run
# resets attempts to 0 and pulls resume.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT5="$T/wt-ac5"; mkdir -p "$WT5"
echo 'exit 0' > "$WT5/build.sh"
"$BL" run "$WT5" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=6 FAKE_RSYNC_FAIL_MSG='rsync: fake ac5 failure'
t5=0
for _ in 1 2 3 4 5 6 7 8; do
  BURST_LANE_NOW="$t5" "$BL" ensure-fresh "$WT5" >/dev/null 2>&1
  t5=$((t5 + 901))
done
stuck5="$(grep -c "burst-lane  pull  stuck  (worktree=$WT5 " "$BURST_LANE_JOURNAL")"
expect "AC5: exactly one 'pull stuck' line after 8 consecutive failures" "[ \"$stuck5\" -eq 1 ]"
expect "AC5: status --json shows stuck:true" "[ \"$(pullmiss_dirty_field "$WT5" stuck)\" = True ]"
lines5_before="$(wc -l < "$BURST_LANE_JOURNAL")"
"$BL" ensure-fresh "$WT5" >/dev/null 2>&1   # 9th local-read
lines5_after="$(wc -l < "$BURST_LANE_JOURNAL")"
expect "AC5: 9th local-read makes no ssh call (journals nothing new)" "[ \"$lines5_before\" = \"$lines5_after\" ]"
stuck5b="$(grep -c "burst-lane  pull  stuck  (worktree=$WT5 " "$BURST_LANE_JOURNAL")"
expect "AC5: still exactly one stuck line (not re-journaled)" "[ \"$stuck5b\" -eq 1 ]"
unset FAKE_RSYNC_FAIL FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG
rm -rf "${WT5:?}/target" 2>/dev/null || true
"$BL" run "$WT5" -- bash build.sh >/dev/null 2>&1
expect "AC5: a new routed run resets attempts to 0" "[ \"$(pullmiss_dirty_field "$WT5" attempts)\" = 0 ]"
expect "AC5: a new routed run resets stuck to false" "[ \"$(pullmiss_dirty_field "$WT5" stuck)\" = False ]"

# ============================================================================
# AC6 — a stuck marker's explicit `pull` still makes one rsync attempt
# regardless of backoff/stuck.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT6="$T/wt-ac6"; mkdir -p "$WT6"
echo 'exit 0' > "$WT6/build.sh"
"$BL" run "$WT6" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=6 FAKE_RSYNC_FAIL_MSG='rsync: fake ac6 failure'
t6=0
for _ in 1 2 3 4 5 6 7 8; do
  BURST_LANE_NOW="$t6" "$BL" ensure-fresh "$WT6" >/dev/null 2>&1
  t6=$((t6 + 901))
done
expect "AC6 setup: marker is stuck" "[ \"$(pullmiss_dirty_field "$WT6" stuck)\" = True ]"
combined6_before="$(grep -cE "burst-lane  pull  (fallback|stuck)  .*worktree=$WT6( |\$)" "$BURST_LANE_JOURNAL")"
out6="$("$BL" pull "$WT6" 2>&1)"; rc6=$?
combined6_after="$(grep -cE "burst-lane  pull  (fallback|stuck)  .*worktree=$WT6( |\$)" "$BURST_LANE_JOURNAL")"
expect "AC6: explicit pull on a stuck marker still attempts once (exits non-zero)" "[ $rc6 -ne 0 ]"
expect "AC6: exactly one more rsync attempt was made (ignoring backoff/stuck)" "[ \"$combined6_after\" -eq $((combined6_before + 1)) ]"
unset FAKE_RSYNC_FAIL FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG

# ============================================================================
# AC7 — the 2026-09-15 storm replayed: two worktrees, remote target absent,
# ~123 rapid local-reads each -> exactly 2 cold lines total (not 246
# fallbacks).
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT7A="$T/wt-ac7a"; mkdir -p "$WT7A"; echo 'exit 0' > "$WT7A/build.sh"
WT7B="$T/wt-ac7b"; mkdir -p "$WT7B"; echo 'exit 0' > "$WT7B/build.sh"
"$BL" run "$WT7A" -- bash build.sh >/dev/null 2>&1
"$BL" run "$WT7B" -- bash build.sh >/dev/null 2>&1
rp7a="$(pullmiss_remote_path "$WT7A")"
rp7b="$(pullmiss_remote_path "$WT7B")"
t7=1000
for _ in $(seq 1 123); do
  FAKE_RSYNC_TARGET_MISSING="$rp7a/target" BURST_LANE_NOW="$t7" "$BL" ensure-fresh "$WT7A" >/dev/null 2>&1
  t7=$((t7 + 7))
done
for _ in $(seq 1 123); do
  FAKE_RSYNC_TARGET_MISSING="$rp7b/target" BURST_LANE_NOW="$t7" "$BL" ensure-fresh "$WT7B" >/dev/null 2>&1
  t7=$((t7 + 7))
done
cold7a="$(grep -c "burst-lane  pull  cold  (worktree=$WT7A .*cause=remote-target-missing" "$BURST_LANE_JOURNAL")"
cold7b="$(grep -c "burst-lane  pull  cold  (worktree=$WT7B .*cause=remote-target-missing" "$BURST_LANE_JOURNAL")"
fallback7="$(grep -c "burst-lane  pull  fallback" "$BURST_LANE_JOURNAL")"
expect "AC7: worktree A -> exactly one cold line despite 123 rapid reads" "[ \"$cold7a\" -eq 1 ]"
expect "AC7: worktree B -> exactly one cold line despite 123 rapid reads" "[ \"$cold7b\" -eq 1 ]"
expect "AC7: zero fallback lines anywhere (never mistaken for rsync-failed)" "[ \"$fallback7\" -eq 0 ]"

# ============================================================================
# AC8 — status --json dirty[] shows attempts, next_retry_epoch, stuck,
# last_err for a marker with a real backoff history.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT8="$T/wt-ac8"; mkdir -p "$WT8"
echo 'exit 0' > "$WT8/build.sh"
"$BL" run "$WT8" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=6 FAKE_RSYNC_FAIL_MSG='rsync: fake ac8 failure'
t8=0
for _ in 1 2 3; do
  BURST_LANE_NOW="$t8" "$BL" ensure-fresh "$WT8" >/dev/null 2>&1
  t8=$((t8 + 901))
done
expect "AC8: status --json attempts is 3" "[ \"$(pullmiss_dirty_field "$WT8" attempts)\" = 3 ]"
expect "AC8: status --json stuck is false" "[ \"$(pullmiss_dirty_field "$WT8" stuck)\" = False ]"
nre8="$(pullmiss_dirty_field "$WT8" next_retry_epoch)"
expect "AC8: status --json next_retry_epoch is present and numeric" "printf '%s' \"$nre8\" | grep -qE '^[0-9]+\$'"
expect "AC8: status --json last_err names the fixture failure" "pullmiss_dirty_field \"$WT8\" last_err | grep -q 'fake ac8 failure'"
unset FAKE_RSYNC_FAIL FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG

# ============================================================================
# AC9 — happy path (target/ present): exactly one rsync invocation, `pull
# ok` line unchanged from today's shape.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT9="$T/wt-ac9"; mkdir -p "$WT9"
echo 'mkdir -p target && echo built > target/out.txt; exit 0' > "$WT9/build.sh"
"$BL" run "$WT9" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_CALL_LOG="$T/rsync-calls-ac9.log"; : > "$FAKE_RSYNC_CALL_LOG"
out9="$("$BL" pull "$WT9" 2>&1)"; rc9=$?
calls9="$(wc -l < "$FAKE_RSYNC_CALL_LOG")"
expect "AC9: happy-path pull makes exactly one rsync invocation (no extra probe)" "[ \"$calls9\" -eq 1 ]"
expect "AC9: pull succeeds and reports pulled" "[ $rc9 -eq 0 ] && [ \"$out9\" = pulled ]"
expect "AC9: 'pull ok' line shape is unchanged" \
  "grep -qE 'burst-lane  pull  ok  \(worktree=$WT9 trigger=explicit bytes=[0-9]+ slug=' \"$BURST_LANE_JOURNAL\""
unset FAKE_RSYNC_CALL_LOG

# ============================================================================
# Bonus (requirement 8, P2 — not one of the 9 numbered ACs): `reap` clears a
# stuck marker once its session is no longer the active one.
# ============================================================================
fresh_env
"$BL" up >/dev/null
WT10="$T/wt-reap"; mkdir -p "$WT10"
echo 'exit 0' > "$WT10/build.sh"
"$BL" run "$WT10" -- bash build.sh >/dev/null 2>&1
export FAKE_RSYNC_FAIL=1 FAKE_RSYNC_FAIL_RC=6 FAKE_RSYNC_FAIL_MSG='rsync: fake reap failure'
t10=0
for _ in 1 2 3 4 5 6 7 8; do
  BURST_LANE_NOW="$t10" "$BL" ensure-fresh "$WT10" >/dev/null 2>&1
  t10=$((t10 + 901))
done
unset FAKE_RSYNC_FAIL FAKE_RSYNC_FAIL_RC FAKE_RSYNC_FAIL_MSG
expect "reap-stuck setup: marker is stuck" "[ \"$(pullmiss_dirty_field "$WT10" stuck)\" = True ]"
rm -f "$BURST_LANE_STATE_DIR/session.json"   # session gone — nobody left to un-stick it
"$BL" reap >/dev/null 2>&1
expect "reap: a stuck marker with a dead session is cleared" "! dirty_has \"$WT10\""
expect "reap: journals marker-stuck-cleared" "grep -q 'burst-lane  reap  marker-stuck-cleared' \"$BURST_LANE_JOURNAL\""

echo "=== $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
