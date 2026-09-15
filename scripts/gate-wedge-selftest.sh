#!/usr/bin/env bash
# gate-wedge-selftest.sh — regression coverage for gate-wedge.sh
# (PRD-build-gate-wall-clock requirement 6 / AC3-6). Fixture-only, `sleep`
# and a self-renaming python stub — never a real cargo build and never the
# real production sccache/systemctl, precisely so validating this
# stall-detector cannot itself recreate a stall (same discipline as
# cargo-budget-selftest.sh). All timers overridden to single-digit seconds
# via env. AC3-AC6 alone run in well under a minute; the newer PROG-i..v
# progress-signal cases each need several real probe cycles (2s cadence)
# to prove out, so the full suite now runs in a couple of minutes.
#
# Cases (PRD acceptance criteria numbering):
#   AC3 — a fixture step sleeping at zero CPU past its budget is killed
#         and classified `unknown`; wedge-receipt.json has cpu_delta_table
#         and wchan_table; one retry runs (a fresh command instance, not
#         the leaked prior one).
#   AC4 — a fixture step whose child is named `sccache` (via prctl rename,
#         so /proc/<pid>/comm genuinely reads "sccache" — a shebang
#         script's comm is the interpreter's, not useful here) is
#         classified `sccache-client-orphans` when the fake systemd
#         unit's MainPID differs between step-start and classification
#         time (a restart happened mid-step).
#   AC5 — a fixture step whose CPU visibly advances (a busy-wait) is never
#         killed even past the probe delay + one full probe interval.
#   AC6 — a step that wedges twice (both attempts hang) fails with wedges=2
#         and two receipts, never a third attempt.
# "The watchdog follows the work" (2026-09-15, PRD-build-gate-wall-clock
# progress-follows-the-work pass) — a fake `<name>burst-lane.sh run
# <worktree>` descendant (never the real burst-lane.sh; a fixture whose
# argv0's basename merely ENDS in burst-lane.sh, which is all the
# inflight-run detector looks at) stands in for the real routed shim:
#   PROG-i   — remote sampler (GATE_WEDGE_REMOTE_PROBE override) reports
#              increasing cpu across probes -> never wedged, even at
#              zero local CPU/IO the whole time.
#   PROG-ii  — remote sampler reports CONSTANT cpu and a stale run-marker
#              -> wedged (remote confirms no progress either).
#   PROG-iii — a descendant genuinely moving bytes (looped `dd` writes)
#              is never wedged via the IO-delta signal alone.
#   PROG-iv  — a descendant blocked (real flock(2), via /proc/locks) on a
#              lock file a live sibling process holds -> never wedged
#              while the holder lives; wedged once the holder is killed
#              (proves "waiting on a live holder" is not just "any lock
#              file present").
#   PROG-v   — the remote sampler always fails (exit 1) -> UNKNOWN for
#              two probes (never wedged on unknown alone), then the third
#              consecutive failure falls back to the local zero-CPU rule
#              -> wedged, receipt's progress.remote.sampled is false.
# Also asserts: no fixture process is ever left running after this script
# exits (the kill_tree exact-PID path actually reaps what it kills).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/gate-wedge.sh"
[ -x "$GW" ] || { echo "selftest: $GW not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-wedge-selftest.XXXXXX")"
trap '[ -n "${GATE_WEDGE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

export GATE_WEDGE_PROBE_DELAY_S=2
export GATE_WEDGE_PROBE_EVERY_S=2
export GATE_WEDGE_SNAPSHOT_GAP_S=2
export GATE_STEP_BUDGET_S=999

# --- AC3: zero-CPU hang, classified unknown, killed both attempts, 2 receipts
state3="$T/state3"
GATE_WEDGE_STATE_DIR="$state3" timeout 40 "$GW" run --step ac3b -- sleep 600 >"$T/ac3.out" 2>&1
rc3=$?
expect "AC3 exit 98 (both attempts wedged)"     "[ $rc3 -eq 98 ]"
expect "AC3 exactly 2 receipts written"         "[ \$(ls '$state3'/*ac3b*wedge-receipt.json 2>/dev/null | wc -l) -eq 2 ]"
r3="$(ls "$state3"/*ac3b*wedge-receipt.json 2>/dev/null | head -1)"
expect "AC3 classification is unknown"          "[ \"\$(python3 -c \"import json;print(json.load(open('$r3'))['classification'])\")\" = unknown ]"
expect "AC3 receipt has cpu_delta_table"        "python3 -c \"import json;d=json.load(open('$r3'));exit(0 if d['cpu_delta_table'] else 1)\""
expect "AC3 receipt has wchan_table"             "python3 -c \"import json;d=json.load(open('$r3'));exit(0 if d['wchan_table'] else 1)\""
sleep 1  # kill_tree's TERM->KILL grace can still be draining right as gate-wedge.sh exits
expect "AC3 no leaked sleep-600 process remains" "[ -z \"\$(pgrep -f 'sleep 600' || true)\" ]"
expect "AC6 wedges=2 reported, never a third attempt" "grep -q 'wedges=2' '$T/ac3.out'"

# --- AC4: sccache-named child, unit MainPID changes mid-step -> orphans ----
FAKE_SYSTEMCTL="$T/fake-systemctl"
cat > "$FAKE_SYSTEMCTL" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "show" ]; then
  [ -f "$T/restarted" ] && echo 222 || echo 111
  exit 0
fi
EOF
chmod +x "$FAKE_SYSTEMCTL"
cat > "$T/sccache_fixture.py" <<'PY'
import ctypes, ctypes.util, sys, time
libc = ctypes.CDLL(ctypes.util.find_library('c'))
libc.prctl(15, b'sccache', 0, 0, 0)
time.sleep(float(sys.argv[1]))
PY
state4="$T/state4"
( sleep 3; : > "$T/restarted" ) &
restart_bg=$!
GATE_WEDGE_STATE_DIR="$state4" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL" \
  timeout 40 "$GW" run --step ac4 -- python3 "$T/sccache_fixture.py" 600 >"$T/ac4.out" 2>&1
rc4=$?
wait "$restart_bg" 2>/dev/null || true
r4="$(ls "$state4"/*ac4*wedge-receipt.json 2>/dev/null | head -1)"
expect "AC4 exit 98 (both attempts eventually wedge)" "[ $rc4 -eq 98 ]"
expect "AC4 first receipt classified sccache-client-orphans" \
  "[ \"\$(python3 -c \"import json;print(json.load(open('$r4'))['classification'])\")\" = sccache-client-orphans ]"
expect "AC4 no leaked sccache_fixture process remains" \
  "[ -z \"\$(pgrep -f 'sccache_fixture.py' || true)\" ]"

# --- AC5: CPU visibly advancing is never killed, even past probe delay+interval
state5="$T/state5"
out5="$(GATE_WEDGE_STATE_DIR="$state5" timeout 30 "$GW" run --step ac5 -- \
  bash -c 'end=$((SECONDS+7)); while [ $SECONDS -lt $end ]; do :; done; echo busy-done' 2>&1)"
rc5=$?
expect "AC5 exit 0 (never killed)"          "[ $rc5 -eq 0 ]"
expect "AC5 command's own output passed through" "[[ \"$out5\" == *busy-done* ]]"
expect "AC5 no wedge receipt written"       "[ ! -d '$state5' ] || [ -z \"\$(ls '$state5' 2>/dev/null)\" ]"
expect "AC5 wedges=0 reported"              "[[ \"$out5\" == *'wedges=0'* ]]"

# --- PROG-i: routed run, remote cpu keeps increasing -> never wedged -------
state_i="$T/state_i"
cat > "$T/fake-burst-lane.sh" <<'EOF'
#!/usr/bin/env bash
sleep 9 &
wait
EOF
chmod +x "$T/fake-burst-lane.sh"
cat > "$T/remote-probe-i.sh" <<EOF
#!/usr/bin/env bash
state="$T/remote-cpu-i.count"
n=0
[ -f "\$state" ] && n="\$(cat "\$state")"
n=\$((n + 100))
echo "\$n" > "\$state"
echo "\$n 1 -1"
EOF
chmod +x "$T/remote-probe-i.sh"
out_i="$(GATE_WEDGE_STATE_DIR="$state_i" GATE_WEDGE_REMOTE_PROBE="$T/remote-probe-i.sh" \
  timeout 20 "$GW" run --step progi -- bash "$T/fake-burst-lane.sh" run /fake/worktree-i 2>&1)"
rc_i=$?
expect "PROG-i exit 0 (routed run with increasing remote cpu never wedged)" "[ $rc_i -eq 0 ]"
expect "PROG-i no wedge receipt written" "[ ! -d '$state_i' ] || [ -z \"\$(ls '$state_i' 2>/dev/null)\" ]"
expect "PROG-i remote probe was actually called more than once" "[ \$(cat '$T/remote-cpu-i.count' 2>/dev/null || echo 0) -ge 200 ]"

# --- PROG-ii: routed run, remote cpu constant + stale marker -> wedged -----
state_ii="$T/state_ii"
cat > "$T/fake-hang-burst-lane.sh" <<'EOF'
#!/usr/bin/env bash
sleep 600 &
wait
EOF
chmod +x "$T/fake-hang-burst-lane.sh"
cat > "$T/remote-probe-ii.sh" <<'EOF'
#!/usr/bin/env bash
echo "500 1 99999"
EOF
chmod +x "$T/remote-probe-ii.sh"
GATE_WEDGE_STATE_DIR="$state_ii" GATE_WEDGE_REMOTE_PROBE="$T/remote-probe-ii.sh" \
  timeout 40 "$GW" run --step progii -- bash "$T/fake-hang-burst-lane.sh" run /fake/worktree-ii >"$T/progii.out" 2>&1
rc_ii=$?
expect "PROG-ii exit 98 (remote confirms no progress -> wedged both attempts)" "[ $rc_ii -eq 98 ]"
r_ii="$(ls "$state_ii"/*progii*wedge-receipt.json 2>/dev/null | head -1)"
expect "PROG-ii route is burst" "[ \"\$(python3 -c \"import json;print(json.load(open('$r_ii'))['route'])\")\" = burst ]"
expect "PROG-ii remote.sampled true, cpu_delta 0" \
  "python3 -c \"import json;d=json.load(open('$r_ii'))['progress']['remote'];exit(0 if d['sampled'] and d['cpu_delta']==0 else 1)\""
pkill -9 -f 'fake-hang-burst-lane.sh' 2>/dev/null || true

# --- PROG-iii: descendant moving real bytes -> never wedged via IO delta ---
state_iii="$T/state_iii"
cat > "$T/dd-writer.sh" <<EOF
#!/usr/bin/env bash
out="$T/dd-writer.out"
: > "\$out"
end=\$((SECONDS + 9))
while [ \$SECONDS -lt \$end ]; do
  dd if=/dev/zero of="\$out" bs=64k count=4 oflag=append conv=notrunc status=none
  sleep 0.2
done
echo dd-done
EOF
chmod +x "$T/dd-writer.sh"
out_iii="$(GATE_WEDGE_STATE_DIR="$state_iii" timeout 30 "$GW" run --step progiii -- bash "$T/dd-writer.sh" 2>&1)"
rc_iii=$?
expect "PROG-iii exit 0 (io-bound descendant never wedged)" "[ $rc_iii -eq 0 ]"
expect "PROG-iii command's own output passed through" "[[ \"$out_iii\" == *dd-done* ]]"
expect "PROG-iii no wedge receipt written" "[ ! -d '$state_iii' ] || [ -z \"\$(ls '$state_iii' 2>/dev/null)\" ]"

# --- PROG-iv: waiting on a lock a LIVE holder owns -> not wedged; ----------
# holder killed -> wedged (progress-equivalent only while the holder lives)
state_iv="$T/state_iv"
locks_iv="$T/locks_iv"
mkdir -p "$locks_iv"
lockfile_iv="$locks_iv/wt-fake.lock"
: > "$lockfile_iv"
cat > "$T/holder_iv.sh" <<EOF
#!/usr/bin/env bash
exec 9>"$lockfile_iv"
flock 9
exec sleep 600
EOF
chmod +x "$T/holder_iv.sh"
"$T/holder_iv.sh" &
holder_pid=$!
sleep 1  # let the holder actually acquire before the waiter tries

cat > "$T/waiter_iv.sh" <<EOF
#!/usr/bin/env bash
exec 9>"$lockfile_iv"
flock 9
sleep 600
EOF
chmod +x "$T/waiter_iv.sh"
GATE_WEDGE_STATE_DIR="$state_iv" GATE_WEDGE_LOCK_DIRS="$locks_iv" \
  timeout 40 "$GW" run --step prog4 -- bash "$T/waiter_iv.sh" >"$T/prog4.out" 2>&1 &
gw4_pid=$!

sleep 6
expect "PROG-iv no wedge receipt yet while lock holder is alive" \
  "[ -z \"\$(ls '$state_iv'/*prog4*wedge-receipt.json 2>/dev/null)\" ]"

kill -9 "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

wait "$gw4_pid"; rc_iv=$?
expect "PROG-iv exit 98 once the lock holder is dead (genuine hang after release)" "[ $rc_iv -eq 98 ]"
expect "PROG-iv wedge receipt written after holder death" \
  "[ -n \"\$(ls '$state_iv'/*prog4*wedge-receipt.json 2>/dev/null)\" ]"
pkill -9 -f 'waiter_iv.sh' 2>/dev/null || true

# --- PROG-v: remote probe always fails -> UNKNOWN twice, then local rule --
state_v="$T/state_v"
cat > "$T/remote-probe-v.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T/remote-probe-v.sh"
GATE_WEDGE_STATE_DIR="$state_v" GATE_WEDGE_REMOTE_PROBE="$T/remote-probe-v.sh" \
  timeout 60 "$GW" run --step progv -- bash "$T/fake-hang-burst-lane.sh" run /fake/worktree-v >"$T/progv.out" 2>&1
rc_v=$?
expect "PROG-v exit 98 (unknown streak falls back to local rule -> wedged)" "[ $rc_v -eq 98 ]"
r_v="$(ls "$state_v"/*progv*wedge-receipt.json 2>/dev/null | head -1)"
expect "PROG-v receipt records remote.sampled=false" \
  "python3 -c \"import json;d=json.load(open('$r_v'))['progress']['remote'];exit(0 if d['sampled'] is False else 1)\""
pkill -9 -f 'fake-hang-burst-lane.sh' 2>/dev/null || true

if [ "$fail" -eq 0 ]; then
  echo "gate-wedge-selftest: all cases passed"
else
  echo "gate-wedge-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
