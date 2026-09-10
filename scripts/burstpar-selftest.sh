#!/usr/bin/env bash
# burstpar-selftest.sh — PRD-build-burst-parallel-runs. Proves the
# per-worktree-lock + slot-cap replacement for the old global whole-run
# flock against real (fake ssh/rsync) concurrent invocations of
# burst-lane.sh run/status. One monolithic suite, labeled `ok  <AC label>`
# assertions per line, so tests/burstpar_ac{1..6}_*.sh can each require
# their own subset without a second, hand-duplicated implementation to
# drift from this one (same convention as burst-lane-ac-common.sh's
# run_suite_and_expect_labels over scripts/burst-lane-selftest.sh).
set -u
T="$(mktemp -d "${TMPDIR:-/tmp}/burstpar.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/burst-lane.sh"

mkdir -p "$T/state" "$T/wa" "$T/wb" "$T/wc"
cat > "$T/state/session.json" <<'JSON'
{"server_id":1,"ip":"127.0.0.1","server_type":"test","boot_ts":"2026-01-01T00:00:00Z","boot_epoch":1,"ttl_hours":6,"hard_ttl_hours":12,"runs_served":0,"sandbox_ok":"true","teardown_scheduled":"false","teardown_epoch":"","verified":"true"}
JSON
cat > "$T/ssh" <<'EOF2'
#!/usr/bin/env bash
# last arg is the remote command; simulate a build
echo "start $$ $(date +%s.%N)" >> "$SPAN_LOG"
sleep 0.8
echo "end $$ $(date +%s.%N)" >> "$SPAN_LOG"
exit 0
EOF2
cat > "$T/rsync" <<'EOF2'
#!/usr/bin/env bash
echo "Total transferred file size: 100"
exit 0
EOF2
chmod +x "$T/ssh" "$T/rsync"
export BURST_LANE_STATE_DIR="$T/state" BURST_LANE_JOURNAL="$T/journal.log" \
       BURST_LANE_SSH_BIN="$T/ssh" BURST_LANE_RSYNC_BIN="$T/rsync" \
       BURST_LANE_ENV_FILE="$T/noenv" SPAN_LOG="$T/spans.log"

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1"; fail=1; }

peak_of() {  # $1 = span log -> stdout peak overlap, side effect: also echoes start count to fd3
  python3 - "$1" <<'PY'
import sys
ev=[]
for line in open(sys.argv[1]):
    k,pid,ts=line.split()
    ev.append((float(ts), 1 if k=="start" else -1))
ev.sort()
cur=peak=0
for _,d in ev: cur+=d; peak=max(peak,cur)
starts=sum(1 for _,d in ev if d==1)
print(peak, starts)
PY
}

# --- AC1 + AC3: 12 different worktrees, cap 4 -> at most 4 overlap, real
# parallelism reached, all 12 complete exit 0 --------------------------
export BURST_MAX_CONCURRENT_RUNS=4
: > "$SPAN_LOG"
pids=()
for i in $(seq 1 12); do
  mkdir -p "$T/w$i"
  bash "$BL" run "$T/w$i" -- cargo build >"$T/out.$i.log" 2>&1 &
  pids+=($!)
done
rc_bad=0
for p in "${pids[@]}"; do wait "$p" || rc_bad=$((rc_bad+1)); done
read -r peak starts <<<"$(peak_of "$SPAN_LOG")"
[ "$starts" = "12" ] && ok "AC3: all 12 invocations ran (starts=12)" || bad "AC3: expected 12 starts, saw $starts"
[ "$rc_bad" = "0" ] && ok "AC1: all 12 runs exit 0" || bad "AC1: $rc_bad of 12 runs exited nonzero"
[ "$peak" -le 4 ] 2>/dev/null && ok "AC3: at most 4 slots held at any instant (peak=$peak)" || bad "AC3: cap 4 violated (peak=$peak)"
[ "$peak" = "4" ] 2>/dev/null && ok "AC1: different-worktree runs overlap in time (peak=$peak of 12)" || bad "AC1: no real parallelism observed (peak=$peak)"

# --- AC4: counters exact after 12 concurrent completed runs ------------
runs=$(python3 -c "import json;print(json.load(open('$T/state/session.json'))['runs_served'])" 2>/dev/null)
[ "$runs" = "12" ] && ok "AC4: runs_served increased by exactly 12" || bad "AC4: runs_served=$runs want 12"
rows=$(wc -l < "$T/state/attribution.jsonl" 2>/dev/null || echo 0)
[ "$rows" = "12" ] && ok "AC4: exactly 12 attribution rows exist" || bad "AC4: attribution rows=$rows want 12"

# --- AC2: same worktree serializes: second starts only after first's
# pull-back (i.e. the whole run) completes ------------------------------
: > "$SPAN_LOG"
( bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 ) &
( bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 ) &
wait
read -r peak2 starts2 <<<"$(peak_of "$SPAN_LOG")"
[ "$starts2" = "2" ] && [ "$peak2" = "1" ] && \
  ok "AC2: same-worktree runs never overlap (peak=1 of 2)" || bad "AC2: same-worktree overlap peak=$peak2 starts=$starts2"

# --- AC5: a run holder killed mid-run releases its slot and worktree
# lock (flock semantics — the fd dies with the process); a waiting run
# (same worktree, so this also proves the worktree lock released, not
# just the slot) then proceeds instead of hanging. -----------------------
: > "$SPAN_LOG"
cat > "$T/ssh_slow" <<'EOF2'
#!/usr/bin/env bash
# exec (not a plain `sleep 30` line) — a real ssh client blocks in its own
# process, it does not fork a further local child for the remote command,
# so this stub must not either: a grandchild left holding a copy of fd 202
# would survive `pkill -P $holder` (which only reaches DIRECT children) and
# falsely fail this AC by outliving the kill.
echo "start $$ $(date +%s.%N)" >> "$SPAN_LOG"
exec sleep 30
EOF2
chmod +x "$T/ssh_slow"
BURST_LANE_SSH_BIN="$T/ssh_slow" BURST_MAX_CONCURRENT_RUNS=1 \
  bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 &
holder=$!
waited=0
while [ ! -s "$SPAN_LOG" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
pkill -9 -P "$holder" >/dev/null 2>&1
kill -9 "$holder" >/dev/null 2>&1
wait "$holder" 2>/dev/null
if timeout 10 bash -c "BURST_MAX_CONCURRENT_RUNS=1 '$BL' run '$T/wa' -- cargo build" >/dev/null 2>&1; then
  ok "AC5: killed holder releases slot+worktree lock; waiting run proceeds"
else
  bad "AC5: waiting run did not proceed after holder was killed (timeout or nonzero exit)"
fi

# --- AC6: `status` reports live concurrency as held/cap -----------------
export BURST_MAX_CONCURRENT_RUNS=4
cat > "$T/ssh_status" <<'EOF2'
#!/usr/bin/env bash
sleep 1.5
exit 0
EOF2
chmod +x "$T/ssh_status"
mkdir -p "$T/wx" "$T/wy" "$T/wz"
for w in wx wy wz; do
  BURST_LANE_SSH_BIN="$T/ssh_status" bash "$BL" run "$T/$w" -- cargo build >/dev/null 2>&1 &
done
waited=0
while [ "$(bash "$BL" status 2>/dev/null | grep -oE 'concurrent=[0-9]+/[0-9]+' | cut -d= -f2 | cut -d/ -f1)" != "3" ] && [ "$waited" -lt 30 ]; do
  sleep 0.1; waited=$((waited+1))
done
status_out="$(bash "$BL" status)"
wait
if grep -q "concurrent=3/4" <<<"$status_out"; then
  ok "AC6: status reports 3/4 live runs"
else
  bad "AC6: status did not report 3/4 (got: $status_out)"
fi

exit $fail
