#!/usr/bin/env bash
# burst-lane-provision-forensics-selftest.sh — offline proof for
# PRD-build-burst-provision-forensics: gate-tools loop journaling
# (install-start/install/install-failed/provision-aborted), failure-log
# evidence retention + pruning, per-tool rc summary, apt lock tolerance,
# and the provision/up concurrency guards + orphan reap. Uses the same
# fake hcloud/ssh/rsync fixtures as burst-lane-selftest.sh — no network
# calls, no real Hetzner spend. Run standalone:
#   BUILD_BURST_ENABLED=1 bash scripts/burst-lane-provision-forensics-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/burst-lane.sh"
FAKE="$HERE/../tests/fixtures/burst-lane-fake"
[ -x "$BL" ] || { echo "selftest: $BL not executable" >&2; exit 2; }

export BURST_LANE_TEST=1
[ "${BURST_LANE_TEST:-}" = "1" ] || {
  echo "burst-lane-provision-forensics-selftest: BURST_LANE_TEST not set — refusing to start" >&2
  exit 2
}

fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — see burst-configured.sh"
  exit 0
fi

fresh_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/bl-forensics-selftest.XXXXXX")"
  ALL_TMPDIRS+=("$T")
  export PATH="$FAKE:$PATH"
  export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$T/journal.log"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$T/remote"
  export BURST_LANE_REMOTE_HOME="$T/remote-home"
  export BURST_LANE_ROOT_RUSTUP_HOME="$HOME/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="$HOME/.cargo"
  export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
  export FAKE_HCLOUD_STATE="$T/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$T/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$T/cost.jsonl"
  export BUILD_STATE_DIR="$T/state"
  export PROBE_JOURNAL_DIR="$T/probe-journal"
  export BURST_LANE_ATTR_LEDGER="$T/attribution.jsonl"
  export BURST_LANE_REPOS_DIR="$T/repos"; mkdir -p "$BURST_LANE_REPOS_DIR"
  export BURST_LANE_TICK_JOURNAL_DIR="$T/tick-journal"; mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
  export FAKE_GATE_TOOLS_STATE="$T/gate-tools-installed"
  export BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR="$T/remote-cargo-bin"
  export BURST_LANE_GATE_CRED_REMOTE_PATH="$T/remote-cred/.credentials.json"
  # This suite's own local autobuilder binary, versioned to match the fake
  # ssh probe's default remote reply — a real ~/.cargo/bin/autobuilder on
  # the host running this suite must never leak in and trip version-drift.
  mkdir -p "$T/autobuilder-bin"
  printf '#!/bin/sh\necho "autobuilder 9.9.9"\n' > "$T/autobuilder-bin/autobuilder"
  chmod +x "$T/autobuilder-bin/autobuilder"
  export BURST_LANE_AUTOBUILDER_BIN="$T/autobuilder-bin/autobuilder"
  export BURST_GATE_REMOTE=1
  export BURST_LANE_FORCE_NEXTEST_LOCAL=0
  export BURST_VOLUME_NAME=""
  export FAKE_HCLOUD_VOLUME_STATE="$T/hcloud-volume.state"
  export BURST_ORPHAN_AGE_S=600
  unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL FAKE_SSH_AUTOBUILDER_VERSION \
        FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR \
        FAKE_SSH_GATE_TOOLS_APT_UPDATE_FAIL BURST_LANE_NOW
}

# ============================================================================
# forensics AC1/AC2/goal3: all 8 tools missing, gh (tool 3) fails — every
# tool gets install-start, gh gets install-failed with the FIRST stderr
# line, tools 4-8 get plain terminal install lines, and the summary line
# lists a per-tool rc for all 8.
# ============================================================================
fresh_env
"$BL" up >/tmp/.forensics-up1.out 2>&1 || { echo "FAIL forensics setup: up failed" >&2; cat /tmp/.forensics-up1.out >&2; fail=1; }

# up already provisioned once with nothing missing (default fake probe: only
# autobuilder tracked via BURST_LANE_AUTOBUILDER_BIN, everything else reports
# a fake version) — re-provision from scratch with everything reported
# missing to exercise the full 8-tool loop deterministically via `provision`.
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder jq gh mold cargo-deny cargo-nextest uv claude"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL="gh"
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC=17
export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR=$'gh apt package not found\nsecond stderr line should never be quoted'
ac1_out="$("$BL" provision 2>&1)"; ac1_rc=$?
expect "AC1: provision exits 1 (gh still missing)" "[ $ac1_rc -eq 1 ]"
for t in autobuilder jq gh mold cargo-deny cargo-nextest uv claude; do
  expect "AC1: install-start journaled for tool=$t" \
    "grep -q \"gate-tools  install-start  (tool=$t)\" \"$BURST_LANE_JOURNAL\""
done
expect "AC1: gh gets install-failed with rc=17" \
  "grep -q 'gate-tools  install-failed  (tool=gh rc=17' \"$BURST_LANE_JOURNAL\""
expect "AC1 (requirement 1): err= is the FIRST stderr line, not the last" \
  "grep -q 'gate-tools  install-failed  (tool=gh rc=17 secs=[0-9]* err=\"gh apt package not found\")' \"$BURST_LANE_JOURNAL\""
for t in mold cargo-deny cargo-nextest uv claude; do
  expect "AC1: terminal install line (not install-failed) for tool=$t" \
    "grep -q \"gate-tools  install  (tool=$t rc=0\" \"$BURST_LANE_JOURNAL\""
done
expect "AC1: summary line lists a per-tool rc for all 8" \
  "grep -qE 'gate-tools  summary  \\(per_tool_rc=\"autobuilder=[0-9]+ jq=[0-9]+ gh=17 mold=0 cargo-deny=0 cargo-nextest=0 uv=0 claude=0\"\\)' \"$BURST_LANE_JOURNAL\""
expect "AC1: provision's own stdout also carries per_tool_rc" \
  "grep -q 'per_tool_rc=' <<<\"\$ac1_out\""

# ---- AC2 (evidence retention): gh's stderr survives under logs/failed/,
# jq's log is gone (rc=0 path).
sid1="$(python3 -c "import json,sys; print(json.load(open('$BURST_LANE_STATE_DIR/session.json')).get('server_id',''))" 2>/dev/null)"
expect "AC2: gh's failure log exists under logs/failed/" \
  "[ -f \"$BURST_LANE_STATE_DIR/logs/failed/${sid1}-gh.log\" ]"
expect "AC2: gh's failure log carries the fixture's error text" \
  "grep -q 'gh apt package not found' \"$BURST_LANE_STATE_DIR/logs/failed/${sid1}-gh.log\""
expect "AC2: jq's per-tool log is gone (rc=0 path)" \
  "! ls \"$BURST_LANE_STATE_DIR\"/logs/gate-tools-install.*-jq.log >/dev/null 2>&1"
expect "AC2: gate-tools.json records gh's last_rc/last_err under attempts" \
  "python3 -c \"import json; d=json.load(open('$BURST_LANE_STATE_DIR/gate-tools.json')); a=d.get('attempts',{}).get('gh',{}); import sys; sys.exit(0 if a.get('last_rc')==17 and 'gh apt package not found' in (a.get('last_err') or '') else 1)\""

# ---- AC2 (pruning): run 6 more failing-tool provisions under 6 more
# distinct session_ids; only the newest 5 sessions' failure logs survive
# (the block above already produced session #1's failure).
for i in 2 3 4 5 6 7; do
  new_sid=$((100000 + i))
  python3 -c "
import json
p = '$BURST_LANE_STATE_DIR/session.json'
d = json.load(open(p))
d['server_id'] = $new_sid
json.dump(d, open(p, 'w'))
"
  "$BL" provision >/dev/null 2>&1 || true
done
failed_sessions_count="$(ls "$BURST_LANE_STATE_DIR/logs/failed" 2>/dev/null | sed -E 's/-gh\.log$//' | sort -u | wc -l)"
expect "AC2: pruning retains at most the newest 5 sessions' failure logs" \
  "[ \"$failed_sessions_count\" -le 5 ]"
expect "AC2: pruning actually dropped the oldest session's log (session #1)" \
  "[ ! -f \"$BURST_LANE_STATE_DIR/logs/failed/${sid1}-gh.log\" ]"

unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR

# ============================================================================
# AC6: all-green fixture installers — all 8 tools rc=0, gate_ready=true.
# ============================================================================
fresh_env
"$BL" up >/tmp/.forensics-up2.out 2>&1 || { echo "FAIL forensics AC6 setup: up failed" >&2; cat /tmp/.forensics-up2.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder jq gh mold cargo-deny cargo-nextest uv claude"
ac6_out="$("$BL" provision 2>&1)"; ac6_rc=$?
expect "AC6: provision exits 0 when every tool installs clean" "[ $ac6_rc -eq 0 ]"
expect "AC6: provision reports gate_ready=true" "grep -q 'gate_ready=true' <<<\"\$ac6_out\""
expect "AC6: summary line shows rc=0 for all 8 tools" \
  "grep -qE 'gate-tools  summary  \\(per_tool_rc=\"autobuilder=0 jq=0 gh=0 mold=0 cargo-deny=0 cargo-nextest=0 uv=0 claude=0\"\\)' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_MISSING

# ============================================================================
# AC3: a fixture installer that blocks mid-gh, killed — the journal's last
# provision line is provision-aborted (during=gh ...). The blocking tool's
# own ssh call self-signals its parent (burst-lane.sh) with TERM and exits
# quickly afterward — an external `kill` against a process blocked on a
# real foreground child would only be noticed by bash once that child
# actually returns control, so this reproduces the same "signal arrives
# while gh's install is the in-flight command" shape without an indefinite
# hang in this test run.
# ============================================================================
fresh_env
"$BL" up >/tmp/.forensics-up3.out 2>&1 || { echo "FAIL forensics AC3 setup: up failed" >&2; cat /tmp/.forensics-up3.out >&2; fail=1; }

BLOCK_SSH_DIR="$T/block-ssh-bin"; mkdir -p "$BLOCK_SSH_DIR"
cat > "$BLOCK_SSH_DIR/ssh" <<EOF
#!/usr/bin/env bash
# Delegates every call to the real fake ssh fixture EXCEPT the gh install,
# which simulates "the whole provision process gets killed mid-install":
# signal its own parent (burst-lane.sh, blocked waiting on this very
# child) and exit shortly after, rather than actually hanging — see this
# suite's own header for why an external kill can't be used directly here.
args=("\$@")
cmd="\${args[-1]}"
case "\$cmd" in
  *'# gate-tools-install gh'*)
    kill -TERM "\$PPID" 2>/dev/null || true
    sleep 0.3
    exit 143
    ;;
  *)
    exec "$FAKE/ssh" "\$@"
    ;;
esac
EOF
chmod +x "$BLOCK_SSH_DIR/ssh"
export BURST_LANE_SSH_BIN="$BLOCK_SSH_DIR/ssh"
export FAKE_SSH_GATE_TOOLS_MISSING="autobuilder jq gh mold cargo-deny cargo-nextest uv claude"
"$BL" provision >/tmp/.forensics-ac3.out 2>&1
ac3_rc=$?
expect "AC3: provision exited nonzero (killed mid-gh)" "[ $ac3_rc -ne 0 ]"
last_gt_line="$(grep 'burst-lane  gate-tools\|burst-lane  provision' "$BURST_LANE_JOURNAL" | tail -1)"
expect "AC3: the last gate-tools/provision journal line is provision-aborted during gh" \
  "grep -q 'provision-aborted  (during=gh' <<<\"\$last_gt_line\""
expect "AC3: no terminal install/install-failed line was ever written for gh" \
  "! grep -qE 'gate-tools  install(-failed)?  \\(tool=gh rc=' \"$BURST_LANE_JOURNAL\""
unset BURST_LANE_SSH_BIN FAKE_SSH_GATE_TOOLS_MISSING

# ============================================================================
# AC4: a provision holding the lock refuses a second concurrent provision
# within 5s, journaling provision-refused with the holder's pid.
# ============================================================================
fresh_env
"$BL" up >/tmp/.forensics-up4.out 2>&1 || { echo "FAIL forensics AC4 setup: up failed" >&2; cat /tmp/.forensics-up4.out >&2; fail=1; }
HOLDER_PID=12345
mkdir -p "$BURST_LANE_STATE_DIR"
echo "$HOLDER_PID" > "$BURST_LANE_STATE_DIR/provision.pid"
(
  exec 220>"$BURST_LANE_STATE_DIR/provision.lock"
  flock 220
  sleep 5
) &
HOLDER_SUBSHELL=$!
# Give the background holder a moment to actually acquire the flock before
# racing it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! ( exec 230>"$BURST_LANE_STATE_DIR/provision.lock"; flock -n 230 ); then
    break
  fi
  sleep 0.1
done
ac4_start="$(date +%s)"
ac4_out="$("$BL" provision 2>&1)"; ac4_rc=$?
ac4_elapsed=$(( $(date +%s) - ac4_start ))
expect "AC4: second provision exits nonzero" "[ $ac4_rc -ne 0 ]"
expect "AC4: second provision refused within 5s" "[ $ac4_elapsed -le 5 ]"
expect "AC4: journal names provision-refused with the holder's pid" \
  "grep -q \"provision-refused  (lock-held pid=$HOLDER_PID)\" \"$BURST_LANE_JOURNAL\""
kill "$HOLDER_SUBSHELL" 2>/dev/null || true
wait "$HOLDER_SUBSHELL" 2>/dev/null || true

# ============================================================================
# AC5: a fake stale `up` process for the lane — `up` refuses (naming the
# pid), then `reap` kills the orphan and journals its pid.
# ============================================================================
fresh_env
"$BL" up >/tmp/.forensics-up5.out 2>&1 || { echo "FAIL forensics AC5 setup: up failed" >&2; cat /tmp/.forensics-up5.out >&2; fail=1; }
(
  exec 221>"$BURST_LANE_STATE_DIR/up.lock"
  flock 221
  sleep 300
) &
FAKE_UP_PID=$!
sleep 0.3
echo "$FAKE_UP_PID" > "$BURST_LANE_STATE_DIR/up.pid"
# Register it in inflight.log too, backdated past the orphan-age
# threshold — exactly what a real `up` would have left behind the moment
# it acquired its lock, before whatever made it never finish. reap keys
# purely on age (see reap_orphan_processes' own header for why it does
# not special-case "still named in up.pid" as automatically legitimate).
old_ts=$(( $(date +%s) - 700 ))
printf '%s %s %s\n' "$old_ts" "$FAKE_UP_PID" "up" >> "$BURST_LANE_STATE_DIR/inflight.log"

ac5up_out="$("$BL" up 2>&1)"; ac5up_rc=$?
expect "AC5: up refuses while the fake stale up process holds the lock" "[ $ac5up_rc -ne 0 ]"
expect "AC5: up-refused journaled naming the stale process's pid" \
  "grep -q \"up-refused  (lock-held pid=$FAKE_UP_PID)\" \"$BURST_LANE_JOURNAL\""
expect "AC5 setup: the fake stale up process is still alive before reap" "kill -0 $FAKE_UP_PID 2>/dev/null"

reap_out="$("$BL" reap 2>&1)"
expect "AC5: reap reports killing the orphan" "grep -q 'orphan-processes-killed=1' <<<\"\$reap_out\""
sleep 0.5
expect "AC5: reap actually killed the orphan process" "! kill -0 $FAKE_UP_PID 2>/dev/null"
expect "AC5: reap journaled the killed pid" \
  "grep -q \"reap  orphan-killed  (pid=$FAKE_UP_PID kind=up\" \"$BURST_LANE_JOURNAL\""

# ============================================================================
# Goal 5 / requirement 5: apt-based installs (jq, gh, mold) pass
# -o DPkg::Lock::Timeout=120 so a transient dpkg/apt lock waits instead of
# failing instantly. Checked structurally against the generated remote
# command (gate_tools_install_cmd is a pure function — no ssh/rsync
# involved), by sourcing burst-lane.sh without running its main dispatch.
# ============================================================================
apt_lock_check_rc=0
(
  # shellcheck source=burst-lane.sh
  source "$BL"
  for tool in jq gh mold; do
    cmd_txt="$(gate_tools_install_cmd "$tool")"
    case "$cmd_txt" in
      *'-o DPkg::Lock::Timeout=120'*) ;;
      *) echo "missing DPkg::Lock::Timeout=120 for $tool" >&2; exit 1 ;;
    esac
  done
) || apt_lock_check_rc=1
expect "goal5: jq/gh/mold install commands carry DPkg::Lock::Timeout=120" "[ $apt_lock_check_rc -eq 0 ]"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
