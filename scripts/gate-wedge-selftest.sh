#!/usr/bin/env bash
# gate-wedge-selftest.sh — regression coverage for gate-wedge.sh
# (PRD-build-gate-wall-clock requirement 6 / AC3-6). Fixture-only, `sleep`
# and a self-renaming python stub — never a real cargo build and never the
# real production sccache/systemctl, precisely so validating this
# stall-detector cannot itself recreate a stall (same discipline as
# cargo-budget-selftest.sh). All timers overridden to single-digit seconds
# via env so the whole suite runs in well under a minute.
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

if [ "$fail" -eq 0 ]; then
  echo "gate-wedge-selftest: all cases passed"
else
  echo "gate-wedge-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
