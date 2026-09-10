#!/usr/bin/env bash
# burstpar core: cap honored, same-worktree serializes, counters exact (offline stubs).
set -u
T="$(mktemp -d "${TMPDIR:-/tmp}/burstpar.XXXXXX)")" 2>/dev/null || T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BL=~/wintermute/build-skill/scripts/burst-lane.sh
[ -f "$BL" ] || BL="$(dirname "$0")/../scripts/burst-lane.sh"

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
       BURST_LANE_ENV_FILE="$T/noenv" SPAN_LOG="$T/spans.log" \
       BURST_MAX_CONCURRENT_RUNS=2

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1"; fail=1; }

# --- cap=2: three different worktrees, max 2 overlapping ssh spans ---
( bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 ) &
( bash "$BL" run "$T/wb" -- cargo build >/dev/null 2>&1 ) &
( bash "$BL" run "$T/wc" -- cargo build >/dev/null 2>&1 ) &
wait
python3 - "$T/spans.log" <<'PY'
import sys
ev=[]
for line in open(sys.argv[1]):
    k,pid,ts=line.split()
    ev.append((float(ts), 1 if k=="start" else -1))
ev.sort()
cur=peak=0
for _,d in ev: cur+=d; peak=max(peak,cur)
starts=sum(1 for _,d in ev if d==1)
assert starts==3, f"expected 3 spans, saw {starts}"
assert peak<=2, f"cap 2 violated: peak {peak}"
assert peak==2, f"no parallelism observed: peak {peak}"
PY
[ $? -eq 0 ] && ok "cap honored with real overlap (peak=2 of 3)" || bad "cap/overlap"

# --- counters exact after 3 concurrent runs ---
runs=$(python3 -c "import json;print(json.load(open('$T/state/session.json'))['runs_served'])")
[ "$runs" = "3" ] && ok "runs_served exact ($runs)" || bad "runs_served=$runs want 3"
rows=$(wc -l < "$T/state/attribution.jsonl" 2>/dev/null || echo 0)
[ "$rows" = "3" ] && ok "attribution rows exact ($rows)" || bad "attribution rows=$rows want 3"

# --- same worktree serializes ---
: > "$SPAN_LOG"
( bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 ) &
( bash "$BL" run "$T/wa" -- cargo build >/dev/null 2>&1 ) &
wait
python3 - "$T/spans.log" <<'PY'
import sys
ev=[]
for line in open(sys.argv[1]):
    k,pid,ts=line.split()
    ev.append((float(ts), 1 if k=="start" else -1))
ev.sort()
cur=peak=0
for _,d in ev: cur+=d; peak=max(peak,cur)
assert peak==1, f"same-worktree overlap: peak {peak}"
PY
[ $? -eq 0 ] && ok "same worktree serialized" || bad "same-worktree"

exit $fail
