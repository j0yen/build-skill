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

# 2026-09-11 RedBaron-local policy: the real Hetzner burst box is deleted;
# this suite proves burst-lane.sh's slot-cap/lock logic against fake
# ssh/rsync stubs, which says nothing about whether burst is the fleet's
# actual routing target right now. Gated, not deleted — see
# lib/burst-configured.sh's header for the exact condition and how to
# force this suite to run for real. Checked BEFORE the exports below
# override BURST_LANE_ENV_FILE with this run's own fake one.
# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — see burst-configured.sh"
  exit 0
fi

mkdir -p "$T/state" "$T/wa" "$T/wb" "$T/wc"
cat > "$T/state/session.json" <<'JSON'
{"server_id":1,"ip":"127.0.0.1","server_type":"test","boot_ts":"2026-01-01T00:00:00Z","boot_epoch":1,"ttl_hours":6,"hard_ttl_hours":12,"runs_served":0,"sandbox_ok":"true","teardown_scheduled":"false","teardown_epoch":"","verified":"true"}
JSON
cat > "$T/ssh" <<'EOF2'
#!/usr/bin/env bash
# cmd_run makes THREE ssh round-trips per run now: a warm-check
# (`remote_dir_exists`, command text `[ -d`), a capacity probe
# (`probe_remote_capacity`, command text `meminfo`), and the actual exec.
# PRD-build-burst-selftest-drift-and-bake-gate requirement 1: only the exec
# is a "run" for this suite's start/end counting — the other two are
# answered and pass through SILENTLY (no SPAN_LOG write), detected by
# their command text (last arg = the full remote command).
cmd="${!#}"
case "$cmd" in
  *"[ -d"*) exit 0 ;;      # warm check: dir present (warm=true), no journal footprint
  *meminfo*) exit 0 ;;     # capacity probe: no stdout -> probe unavailable, disk-floor check skipped
esac
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
# PRD-build-burst-selftest-isolation: BURST_LANE_HCLOUD_BIN is resolved+
# checked unconditionally by burst-lane.sh's top-of-script isolation guard
# under BURST_LANE_TEST=1 regardless of which subcommand runs — an unset
# override here would resolve to this machine's REAL hcloud
# (/home/jsy/.local/bin/hcloud) and trip the guard. It IS now actually
# invoked, though: `status` reaches session_reconcile -> server_alive,
# which calls `hcloud server describe <id> -o json`
# (PRD-build-burst-selftest-drift-and-bake-gate requirement 1) — answer it
# with the fixture session's own server_id/ip in the shape server_alive's
# sibling parsers use (`{"id":...,"public_net":{"ipv4":{"ip":...}}}`) so
# session_reconcile sees the session as alive instead of archiving it.
cat > "$T/hcloud" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  *"server describe"*)
    echo '{"id":1,"public_net":{"ipv4":{"ip":"127.0.0.1"}}}'
    exit 0
    ;;
esac
echo "hcloud: not used by burstpar-selftest.sh" >&2
exit 1
EOF2
chmod +x "$T/ssh" "$T/rsync" "$T/hcloud"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$T/state" BURST_LANE_JOURNAL="$T/journal.log" \
       BURST_LANE_SSH_BIN="$T/ssh" BURST_LANE_RSYNC_BIN="$T/rsync" \
       BURST_LANE_HCLOUD_BIN="$T/hcloud" \
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
# PRD-build-burst-state-keyed-by-server-v2 requirement 1: session.json and
# attribution.jsonl are per-box now (boxes/<id>/, reached through the
# `current` symlink this fixture's very first invocation creates via
# migrate_state_layout) — never top-level anymore. Read through
# $T/state/current/ so this suite still proves what it always proved
# instead of silently reading a file that no longer exists (regression
# caught 2026-09-15: both checks read runs=/rows=0 against the old
# top-level paths post-migration).
runs=$(python3 -c "import json;print(json.load(open('$T/state/current/session.json'))['runs_served'])" 2>/dev/null)
[ "$runs" = "12" ] && ok "AC4: runs_served increased by exactly 12" || bad "AC4: runs_served=$runs want 12"
rows=$(wc -l < "$T/state/current/attribution.jsonl" 2>/dev/null || echo 0)
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


# ---- multibox AC3 (PRD-build-burst-state-keyed-by-server-v2 requirement
# 3 / AC3): two ready boxes, cap 4 each (same "box_cores unparseable ->
# default 4" path AC1/AC3 above already exercise — this fixture's
# session.json omits box_cores/mem/disk on purpose), 12 runs distributed
# across them by select_run_box (current-first order, first box with a
# free slot) reach peak concurrency 8 (4 per box), all 12 complete, and
# each attribution row names its own box (session_id 201 or 202). A
# DEDICATED state dir + two distinct fake-ssh target IPs (never
# 127.0.0.1, this file's single-box fixture's own ip) so this block can
# attribute each span to its box without disturbing the single-box
# sections above — this PRD's Goal 2 (zero behavior change for callers
# that never pass --count) is what those sections already prove; this
# block proves the NEW multi-box path side by side, never touching the
# old one's state.
MB="$(mktemp -d "${TMPDIR:-/tmp}/burstpar-mb.XXXXXX")" || exit 2
mkdir -p "$MB/boxes/201" "$MB/boxes/202"
for i in $(seq 1 12); do mkdir -p "$MB/w$i"; done
seed_mb_box() {  # $1=id $2=ip
  cat > "$MB/boxes/$1/session.json" <<JSON
{"server_id":$1,"ip":"$2","server_type":"test","boot_ts":"2026-01-01T00:00:00Z","boot_epoch":1,"ttl_hours":6,"hard_ttl_hours":12,"runs_served":0,"sandbox_ok":"true","teardown_scheduled":"false","teardown_epoch":"","verified":"true"}
JSON
}
seed_mb_box 201 127.0.0.11
seed_mb_box 202 127.0.0.12
ln -sfn boxes/201 "$MB/current"

MB_SPAN="$MB/spans.log"
cat > "$MB/ssh" <<EOF2
#!/usr/bin/env bash
cmd="\${!#}"
case "\$cmd" in
  *"[ -d"*) exit 0 ;;
  *meminfo*) exit 0 ;;
esac
target="\${@: -2:1}"
ip="\${target#*@}"
echo "start \$ip \$\$ \$(date +%s.%N)" >> "$MB_SPAN"
sleep 0.8
echo "end \$ip \$\$ \$(date +%s.%N)" >> "$MB_SPAN"
exit 0
EOF2
chmod +x "$MB/ssh"

: > "$MB_SPAN"
mb3_pids=()
for i in $(seq 1 12); do
  BURST_LANE_STATE_DIR="$MB" BURST_LANE_JOURNAL="$MB/journal.log" BURST_LANE_SSH_BIN="$MB/ssh" \
    BURST_MAX_CONCURRENT_RUNS=4 \
    bash "$BL" run "$MB/w$i" -- cargo build >"$MB/out.$i.log" 2>&1 &
  mb3_pids+=($!)
done
mb3_rc_bad=0
for p in "${mb3_pids[@]}"; do wait "$p" || mb3_rc_bad=$((mb3_rc_bad+1)); done
[ "$mb3_rc_bad" = "0" ] && ok "multibox AC3: all 12 runs exit 0 across two boxes" || bad "multibox AC3: $mb3_rc_bad of 12 runs exited nonzero"

mb3_peaks="$(python3 - "$MB_SPAN" <<'PY'
import sys
ev=[]
for line in open(sys.argv[1]):
    parts=line.split()
    if len(parts) < 4:
        continue
    k, ip, pid, ts = parts[0], parts[1], parts[2], parts[3]
    ev.append((float(ts), 1 if k == "start" else -1, ip))
ev.sort()
cur = peak = starts = 0
cur_ip = {}
peak_ip = {}
for ts, d, ip in ev:
    cur += d
    peak = max(peak, cur)
    if d == 1:
        starts += 1
    cur_ip[ip] = cur_ip.get(ip, 0) + d
    peak_ip[ip] = max(peak_ip.get(ip, 0), cur_ip[ip])
for ip in sorted(peak_ip):
    print("IP", ip, peak_ip[ip])
print("TOTAL", peak, starts)
PY
)"
mb3_total_peak="$(awk '$1=="TOTAL"{print $2}' <<<"$mb3_peaks")"
mb3_total_starts="$(awk '$1=="TOTAL"{print $3}' <<<"$mb3_peaks")"
mb3_peak_11="$(awk '$1=="IP" && $2=="127.0.0.11"{print $3}' <<<"$mb3_peaks")"
mb3_peak_12="$(awk '$1=="IP" && $2=="127.0.0.12"{print $3}' <<<"$mb3_peaks")"
[ "$mb3_total_starts" = "12" ] && ok "multibox AC3: all 12 runs actually started (starts=12)" \
  || bad "multibox AC3: expected 12 starts, saw $mb3_total_starts"
[ "$mb3_total_peak" = "8" ] && ok "multibox AC3: peak concurrency is 8 across both boxes" \
  || bad "multibox AC3: expected combined peak 8, saw $mb3_total_peak"
[ "$mb3_peak_11" = "4" ] && ok "multibox AC3: box 201 (127.0.0.11) reached its own cap of 4" \
  || bad "multibox AC3: box 201 peak=$mb3_peak_11 want 4"
[ "$mb3_peak_12" = "4" ] && ok "multibox AC3: box 202 (127.0.0.12) reached its own cap of 4" \
  || bad "multibox AC3: box 202 peak=$mb3_peak_12 want 4"

mb3_attr_201="$(wc -l < "$MB/boxes/201/attribution.jsonl" 2>/dev/null || echo 0)"
mb3_attr_202="$(wc -l < "$MB/boxes/202/attribution.jsonl" 2>/dev/null || echo 0)"
[ "$((mb3_attr_201 + mb3_attr_202))" = "12" ] && ok "multibox AC3: 12 attribution rows total, split across both boxes' own ledgers" \
  || bad "multibox AC3: attribution rows 201=$mb3_attr_201 202=$mb3_attr_202 (want sum 12)"
mb3_attr_201_bad="$(python3 -c "
import json,sys
n=0
for line in open(sys.argv[1]):
    if json.loads(line).get('session_id') != '201':
        n+=1
print(n)
" "$MB/boxes/201/attribution.jsonl" 2>/dev/null || echo 99)"
mb3_attr_202_bad="$(python3 -c "
import json,sys
n=0
for line in open(sys.argv[1]):
    if json.loads(line).get('session_id') != '202':
        n+=1
print(n)
" "$MB/boxes/202/attribution.jsonl" 2>/dev/null || echo 99)"
[ "${mb3_attr_201_bad:-99}" = "0" ] && [ "${mb3_attr_202_bad:-99}" = "0" ] && \
  ok "multibox AC3: every attribution row's session_id names its own box (201/202, never crossed)" \
  || bad "multibox AC3: cross-attributed rows found (201 mismatches=$mb3_attr_201_bad, 202 mismatches=$mb3_attr_202_bad)"

rm -rf "$MB" 2>/dev/null || true

exit $fail
