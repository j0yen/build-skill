#!/usr/bin/env bash
# gate-wedge.sh — per-step wall-clock budget + progress-aware wedge probe for
# gate steps (PRD-build-gate-wall-clock requirements 3/4/6). Fixes the
# 2026-09-10 incident's blind spot: a gate step sat with a process tree at
# zero CPU for 60+ minutes and nothing noticed until a human read `wchan`
# by hand at 4am. This wraps a step's command in its own process group and
# watches it: a wedge probe starting GATE_WEDGE_PROBE_DELAY_S (default
# 300s) in, every GATE_WEDGE_PROBE_EVERY_S (default 60s) thereafter,
# compares two snapshots of the tree's SUMMED cpu ticks
# GATE_WEDGE_SNAPSHOT_GAP_S (default 30s) apart (never a single pid — a
# process tree, summed, per the PRD's own note) — zero growth is a wedge,
# killed by exact PID (start-time re-verified immediately before
# signaling — never a pattern kill, never a stale/reused pid) and
# retried once. A step still running past GATE_STEP_BUDGET_S (default
# 1800) is killed too, classified budget-exceeded, also retried once.
#
# "The watchdog follows the work" (2026-09-15 fix): local zero-CPU is no
# longer sufficient on its own to call a wedge. extend-gate's autobuilder
# loop shells cargo through the burst shim (scripts/burst-lane-bin/cargo ->
# burst-lane.sh run -> rsync + ssh to the Hetzner box); while cargo is
# actually running remotely, the LOCAL tree (autobuilder/bash/cargo shim/
# ssh waiting on the socket) sits at ~0 local CPU by design — that killed a
# healthy gate on 2026-09-15 10:17:03Z (receipt
# 20260915T095202Z-autobuilder-loop-wedge-receipt.json: autobuilder, bash,
# cargo, tee all at 0 ticks, no ssh/rsync child even present — the run was
# blocked on a local flock, not hung). Progress is now ANY of:
#   - local: the full descendant tree's summed CPU ticks OR summed I/O
#     bytes (rchar+wchar — syscall-level bytes moved, not the block-io
#     counters, which miss network reads and page-cache-buffered writes
#     that never provoke an actual block write inside one short probe
#     window) advance between the two gap-apart
#     snapshots (an rsync moving bytes counts, even at ~0 CPU).
#   - routed: a live `burst-lane.sh run <worktree>` descendant exists AND
#     one remote ssh probe (GATE_WEDGE_REMOTE_PROBE, default
#     gate-wedge-remote-probe.sh) shows the box's own cargo/rustc CPU
#     advancing since the last probe, or a target/.burst-run-marker mtime
#     younger than the probe interval. An ssh/probe failure is UNKNOWN,
#     never wedged, on its own — three consecutive UNKNOWNs fall back to
#     the local-only rule.
#   - waiting: a descendant blocked (via the kernel's own /proc/locks
#     "->" pending-request line) on a lock under state/burst-lane/{locks,
#     slots}/ whose current holder pid is still alive — a run legitimately
#     waiting its turn for a slot/worktree lock is progress-equivalent,
#     never a wedge.
# Only when local CPU delta == 0 AND I/O delta == 0 AND no alive routed
# run shows remote progress AND no live lock holder is the step wedged.
# The wedge-receipt gains `route` (local|burst|mixed) and a `progress`
# object recording every signal checked, so a receipt is self-explanatory
# without a live re-investigation.
#
# Usage:
#   gate-wedge.sh run [--budget SECS] [--step NAME] -- <cmd...>
#
# On success (the command, or its one retry, exits 0 without wedging):
# passes the command's own stdout/stderr through and exits with its exit
# code; prints `gate-wedge: wedges=0` to stderr.
#
# On a wedge: kills the tree, writes
# $GATE_WEDGE_STATE_DIR/<ts>-<step>-wedge-receipt.json (step, budget_s,
# elapsed_s, cpu_delta_table, wchan_table, sccache_pid_before/after,
# classification, route, progress), prints `gate-wedge: wedged:
# <classification> receipt=<path>` to stderr, and retries the command
# ONCE from scratch. A second wedge fails the step: exit 98, both receipts
# referenced, `gate-wedge: wedges=2` on stderr.
#
# Classification:
#   sccache-client-orphans — the wedged tree contains a process named
#     `sccache`, AND the managed unit's current MainPID differs from the
#     MainPID recorded when this run started — the server the step was
#     talking to when it began is not the server running now.
#   budget-exceeded — the step ran past --budget with the tree still
#     alive, regardless of CPU state (checked independently of the
#     wedge probe above, at the same cadence).
#   unknown — a wedge with neither signal above (any other zero-progress
#     hang: no CPU, no I/O, no live routed remote progress, no live lock
#     holder).
#
# Never a pattern kill: every PID's /proc/<pid>/stat start-time (field 22)
# is re-read immediately before signaling; a PID whose start-time no
# longer matches what was recorded at classification time (already exited
# and reused) is skipped, never signaled — the self-match/PID-reuse traps
# named in the PRD.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   GATE_STEP_BUDGET_S         (1800)
#   GATE_WEDGE_PROBE_DELAY_S   (300)  seconds before the first probe
#   GATE_WEDGE_PROBE_EVERY_S   (60)   seconds between probes thereafter
#   GATE_WEDGE_SNAPSHOT_GAP_S  (30)   seconds between the two cpu snapshots
#   GATE_WEDGE_STATE_DIR       (<skill-dir>/state/gate-wedge)
#   GATE_WEDGE_LOCK_DIRS       (<skill-dir>/state/burst-lane/locks:<skill-dir>/state/burst-lane/slots)
#                              colon-separated dirs scanned for the
#                              wt-*.lock / slot *.lock files a burst-lane.sh
#                              run descendant can be blocked on.
#   GATE_WEDGE_REMOTE_PROBE    (<here>/gate-wedge-remote-probe.sh <worktree>)
#                              one-shot remote sampler; prints
#                              "<cpu_ticks> <cargo_procs> <marker_age_s>"
#                              (marker_age_s -1 = marker absent) and exits
#                              0, or exits non-zero on any failure (never
#                              treated as wedged on its own).
#   GATE_WEDGE_JOURNAL         ($HOME/brain/journal/build/<date>.md) one
#                              line per verdict, same convention as
#                              gate-wedge-rollup.sh's own journal writes.
#   SCCACHE_ASSERT_SYSTEMCTL   ("systemctl --user") same override
#   SCCACHE_ASSERT_UNIT        (sccache-server.service)   sccache-assert.sh uses
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

STATE_DIR="${GATE_WEDGE_STATE_DIR:-$SKILL_DIR/state/gate-wedge}"

BUDGET_S="${GATE_STEP_BUDGET_S:-1800}"
PROBE_DELAY_S="${GATE_WEDGE_PROBE_DELAY_S:-300}"
PROBE_EVERY_S="${GATE_WEDGE_PROBE_EVERY_S:-60}"
SNAPSHOT_GAP_S="${GATE_WEDGE_SNAPSHOT_GAP_S:-30}"
SYSTEMCTL="${SCCACHE_ASSERT_SYSTEMCTL:-systemctl --user}"
UNIT="${SCCACHE_ASSERT_UNIT:-sccache-server.service}"
LOCK_SCAN_DIRS="${GATE_WEDGE_LOCK_DIRS:-$SKILL_DIR/state/burst-lane/locks:$SKILL_DIR/state/burst-lane/slots}"
REMOTE_PROBE_BIN="${GATE_WEDGE_REMOTE_PROBE:-$HERE/gate-wedge-remote-probe.sh}"
JOURNAL="${GATE_WEDGE_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"

# PRD-build-test-isolation-by-default requirement 4: structural isolation,
# wired here (previously the one writer in the six-copy list that wasn't
# wired to isolation-guard.sh at all — Grounding). Checked AFTER override
# resolution (STATE_DIR/JOURNAL above) but BEFORE the first mkdir/write.
if [ -r "$HERE/isolation-guard.sh" ]; then
  # shellcheck source=isolation-guard.sh
  source "$HERE/isolation-guard.sh"
else
  isolation_guard_path() { :; }
fi
isolation_guard_path "$STATE_DIR" "gate-wedge.sh"
isolation_guard_path "$JOURNAL" "gate-wedge.sh"

die() { echo "gate-wedge: $1" >&2; exit "${2:-2}"; }
usage() { echo "usage: gate-wedge.sh run [--budget SECS] [--step NAME] -- <cmd...>" >&2; exit 2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# journal_line is now the shared scripts/lib/journal.sh one (sourced
# above); call sites embed the "<ts>  gate-wedge  " prefix the old private
# copy used to add, and pass this script's own $JOURNAL as an absolute
# --file target (PRD-build-test-isolation-by-default).

is_int() { case "$1" in ''|*[!0-9-]*) return 1 ;; *) return 0 ;; esac; }

server_pid_now() {
  local pid
  pid="$($SYSTEMCTL show -p MainPID --value "$UNIT" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "0" ] || pid="unknown"
  printf '%s' "$pid"
}

# One remote sample for a routed worktree's box-side cargo/rustc CPU +
# run-marker age. Stdout on success: "<cpu_ticks> <cargo_procs>
# <marker_age_s>" (marker_age_s -1 = marker absent) and exit 0; any
# failure (no session, ssh timeout, bad output) exits non-zero and prints
# nothing meaningful — callers treat that as UNKNOWN, never wedged.
remote_probe_sample() {
  local worktree="$1"
  [ -x "$REMOTE_PROBE_BIN" ] || return 1
  "$REMOTE_PROBE_BIN" "$worktree" 2>/dev/null
}

# Prints one JSON object for <root_pid> and its full live descendant tree
# (BFS over ppid via /proc — never a single pid, never direct children
# only): {"total_cpu_ticks":N, "total_io_bytes":N, "procs":[{"pid":P,
# "comm":C,"cpu_ticks":T,"io_bytes":T,"wchan":W}, ...],
# "inflight_runs":[{"pid":P,"worktree":W,"age_s":A,"alive":true}, ...],
# "lock_waits":[{"lock":path,"waiter_pid":P,"holder_pid":P|null,
# "holder_alive":bool}, ...]}.
#
# inflight_runs: any descendant whose /proc/<pid>/cmdline names
# `burst-lane.sh run <worktree>` — this is the local half of "the watchdog
# follows the work" (requirement 2b's "routed" signal).
#
# lock_waits: read directly from the kernel's own /proc/locks rather than
# probed per-fd — a blocked flock(2) call appears there as a "-> ..." line
# naming the SAME dev:inode as the granted holder's line right above it
# (both in hex major:minor, decimal inode, per fs/locks.c's own
# seq_printf). Candidate lock files are stat()'d up front from
# $GATE_WEDGE_LOCK_DIRS so a dev:inode match resolves back to a real path
# (acquire_run_slot's slots/*.lock, cmd_run's locks/wt-*.lock).
tree_snapshot() {
  local root="$1"
  python3 - "$root" "$LOCK_SCAN_DIRS" <<'PY'
import sys, os, json, time

root = int(sys.argv[1])
lock_dirs = [d for d in sys.argv[2].split(':') if d]

procs = {}
for p in os.listdir('/proc'):
    if not p.isdigit():
        continue
    pid = int(p)
    try:
        with open(f'/proc/{p}/stat', 'rb') as f:
            data = f.read().decode(errors='replace')
        rp = data.rfind(')')
        comm = data[data.find('(') + 1:rp]
        after = data[rp + 2:].split()
        ppid = int(after[1])
        utime = int(after[11]); stime = int(after[12])
        starttime = int(after[19])
    except (FileNotFoundError, ProcessLookupError, ValueError, IndexError, OSError):
        continue
    cmdline = ''
    try:
        with open(f'/proc/{p}/cmdline', 'rb') as f:
            cmdline = f.read().replace(b'\x00', b' ').decode(errors='replace').strip()
    except OSError:
        pass
    io_bytes = 0
    try:
        with open(f'/proc/{p}/io') as f:
            rd = wr = 0
            for line in f:
                if line.startswith('rchar:'):
                    rd = int(line.split()[1])
                elif line.startswith('wchar:'):
                    wr = int(line.split()[1])
            io_bytes = rd + wr
    except OSError:
        pass
    procs[pid] = {'ppid': ppid, 'comm': comm, 'cpu': utime + stime,
                  'cmdline': cmdline, 'io': io_bytes, 'starttime': starttime}

tree = {root} if root in procs or os.path.exists(f'/proc/{root}') else set()
tree.add(root)
changed = True
while changed:
    changed = False
    for pid, info in procs.items():
        if info['ppid'] in tree and pid not in tree:
            tree.add(pid)
            changed = True

try:
    with open('/proc/uptime') as f:
        uptime = float(f.read().split()[0])
except OSError:
    uptime = None
try:
    clk_tck = os.sysconf('SC_CLK_TCK')
except (ValueError, OSError):
    clk_tck = 100

total_cpu = 0
total_io = 0
out = []
inflight_runs = []
for pid in sorted(tree):
    info = procs.get(pid)
    if not info:
        continue
    total_cpu += info['cpu']
    total_io += info['io']
    wchan = ''
    try:
        with open(f'/proc/{pid}/wchan') as f:
            wchan = f.read()
    except OSError:
        pass
    out.append({'pid': pid, 'comm': info['comm'], 'cpu_ticks': info['cpu'],
                'io_bytes': info['io'], 'wchan': wchan})

    cl = info['cmdline']
    if 'burst-lane.sh' in cl:
        parts = cl.split(' ')
        worktree = ''
        for i, tok in enumerate(parts):
            if tok.endswith('burst-lane.sh') and i + 2 < len(parts) and parts[i + 1] == 'run':
                worktree = parts[i + 2]
                break
        if worktree:
            age_s = None
            if uptime is not None:
                age_s = int(uptime - (info['starttime'] / clk_tck))
            inflight_runs.append({'pid': pid, 'worktree': worktree, 'age_s': age_s, 'alive': True})

# ---- lock_waits: dev:inode -> candidate lock-file path -------------------
inode_map = {}
for d in lock_dirs:
    try:
        names = os.listdir(d)
    except OSError:
        continue
    for name in names:
        fp = os.path.join(d, name)
        try:
            st = os.stat(fp)
            inode_map[(os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)] = fp
        except OSError:
            continue


# Finds a LIVE pid (other than the waiter) that still holds an open fd on
# the given dev:inode. This is deliberately NOT "is /proc/locks' own
# recorded fl_pid alive" — the "exec N>file; flock N" idiom every lock in
# this codebase uses (burst-lane.sh's RUN_LOCK/wt-lock/slot locks, and
# these fixtures) forks a TRANSIENT `flock` process to make the syscall;
# that process exits the instant it acquires, so the kernel's fl_pid is
# almost always already a dead pid even while the lock is still very much
# held (kept alive by the ORIGINAL shell's own surviving copy of the fd,
# inherited across the fork — same open file description, lock persists
# until every fd referencing it closes). Verified empirically against
# this exact idiom before shipping — trusting fl_pid's liveness directly
# would classify a live, actively-held lock as "holder dead" essentially
# every time.
def find_fd_owner(maj, minr, ino, exclude_pid):
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        pid = int(p)
        if pid == exclude_pid:
            continue
        try:
            fds = os.listdir(f'/proc/{p}/fd')
        except OSError:
            continue
        for fd in fds:
            try:
                st = os.stat(f'/proc/{p}/fd/{fd}')
            except OSError:
                continue
            if os.major(st.st_dev) == maj and os.minor(st.st_dev) == minr and st.st_ino == ino:
                return pid
    return None

lock_waits = []
try:
    with open('/proc/locks') as f:
        lock_lines = f.readlines()
except OSError:
    lock_lines = []

last_holder = {}
for line in lock_lines:
    fields = line.split()
    is_wait = len(fields) > 1 and fields[1] == '->'
    idx = 2 if is_wait else 1
    if len(fields) < idx + 5:
        continue
    if fields[idx] != 'FLOCK':
        continue
    pid_field_s = fields[idx + 3]
    devino = fields[idx + 4]
    try:
        pid_field = int(pid_field_s)
        maj_s, min_s, ino_s = devino.split(':')
        key = (int(maj_s, 16), int(min_s, 16), int(ino_s))
    except (ValueError, IndexError):
        continue
    if not is_wait:
        last_holder[key] = pid_field
    elif pid_field in tree:
        reported_holder_pid = last_holder.get(key)
        live_holder_pid = find_fd_owner(key[0], key[1], key[2], pid_field)
        holder_alive = live_holder_pid is not None
        holder_pid = live_holder_pid if live_holder_pid is not None else reported_holder_pid
        lock_waits.append({
            'lock': inode_map.get(key, f'dev={key[0]:x}:{key[1]:x} ino={key[2]}'),
            'waiter_pid': pid_field,
            'holder_pid': holder_pid,
            'holder_alive': holder_alive,
        })

print(json.dumps({
    'total_cpu_ticks': total_cpu,
    'total_io_bytes': total_io,
    'procs': out,
    'inflight_runs': inflight_runs,
    'lock_waits': lock_waits,
}))
PY
}

tree_alive() {
  local root="$1"
  kill -0 "$root" 2>/dev/null
}

# Kills every live pid in the JSON snapshot's proc list by exact PID,
# re-verifying each pid's /proc/<pid>/stat start-time (field 22, "before"
# the group leader is signaled at all, atomically re-read against the
# CURRENT process table right here) matches what the same field reads
# right now — skips (never signals) a pid whose start-time already
# doesn't match, i.e. it exited and the pid was reused. TERM then, after
# a short grace, KILL any survivor.
kill_tree() {
  local snap_json="$1"
  python3 - "$snap_json" <<'PY'
import sys, os, json, signal, time

snap = json.loads(sys.argv[1])
pids = [p['pid'] for p in snap['procs']]

def start_time(pid):
    try:
        with open(f'/proc/{pid}/stat', 'rb') as f:
            data = f.read().decode(errors='replace')
        rp = data.rfind(')')
        after = data[rp + 2:].split()
        return after[19]  # field 22 overall == index 19 after pid+comm+state
    except (FileNotFoundError, ProcessLookupError, IndexError, OSError):
        return None

live = {}
for pid in pids:
    st = start_time(pid)
    if st is not None:
        live[pid] = st

for pid, st in live.items():
    if start_time(pid) == st:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

time.sleep(1)

for pid, st in live.items():
    if start_time(pid) == st:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
}

# Reads two snapshots for classification, returns via globals:
# CLASS_OUT, CPU_TABLE_OUT (json), WCHAN_TABLE_OUT (json) — set by caller
# reading the last two snapshot files it already took.
classify() {
  local snap1="$1" snap2="$2" reason="$3" pid_before="$4"
  local has_sccache
  has_sccache="$(python3 -c "
import json
s = json.load(open('$snap2'))
print('yes' if any(p['comm'] == 'sccache' for p in s['procs']) else 'no')
" 2>/dev/null)"
  if [ "$reason" = "budget" ]; then
    printf 'budget-exceeded'
    return
  fi
  if [ "$has_sccache" = "yes" ]; then
    local pid_after; pid_after="$(server_pid_now)"
    if [ "$pid_after" != "$pid_before" ]; then
      printf 'sccache-client-orphans'
      return
    fi
  fi
  printf 'unknown'
}

# $9=route $10=local_cpu_delta $11=io_delta $12=remote_sampled(true/false)
# $13=remote_cpu_delta(or empty) $14=remote_cargo_procs(or empty)
# $15=remote_marker_age_s(or empty)
write_receipt() {
  local step="$1" budget="$2" elapsed="$3" snap1="$4" snap2="$5" classification="$6" pid_before="$7" pid_after="$8"
  local route="$9" local_cpu_delta="${10}" io_delta="${11}" remote_sampled="${12}"
  local remote_cpu_delta="${13}" remote_cargo_procs="${14}" remote_marker_age="${15}"
  mkdir -p "$STATE_DIR"
  local out="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${step}-wedge-receipt.json"
  python3 - "$out" "$step" "$budget" "$elapsed" "$snap1" "$snap2" "$classification" "$pid_before" "$pid_after" \
    "$route" "$local_cpu_delta" "$io_delta" "$remote_sampled" "$remote_cpu_delta" "$remote_cargo_procs" "$remote_marker_age" <<'PY'
import sys, json

(out, step, budget, elapsed, snap1_f, snap2_f, classification, pid_before, pid_after,
 route, local_cpu_delta, io_delta, remote_sampled, remote_cpu_delta, remote_cargo_procs,
 remote_marker_age) = sys.argv[1:17]
snap1 = json.load(open(snap1_f))
snap2 = json.load(open(snap2_f))

cpu_delta_table = []
by_pid2 = {p['pid']: p for p in snap2['procs']}
for p in snap1['procs']:
    p2 = by_pid2.get(p['pid'])
    cpu_delta_table.append({
        'pid': p['pid'], 'comm': p['comm'],
        'cpu_ticks_t0': p['cpu_ticks'],
        'cpu_ticks_t1': p2['cpu_ticks'] if p2 else None,
    })
wchan_table = [{'pid': p['pid'], 'comm': p['comm'], 'wchan': p['wchan']} for p in snap2['procs']]

def _int_or_none(s):
    try:
        return int(s)
    except ValueError:
        return None

remote = {
    'sampled': remote_sampled == 'true',
    'cpu_delta': _int_or_none(remote_cpu_delta),
    'cargo_procs': _int_or_none(remote_cargo_procs),
    'marker_age_s': _int_or_none(remote_marker_age),
}

doc = {
    'step': step,
    'budget_s': int(budget),
    'elapsed_s': int(elapsed),
    'cpu_delta_table': cpu_delta_table,
    'wchan_table': wchan_table,
    'sccache_pid_before': pid_before,
    'sccache_pid_after': pid_after,
    'classification': classification,
    'route': route,
    'progress': {
        'local_cpu_delta': _int_or_none(local_cpu_delta) or 0,
        'descendants_io_delta': _int_or_none(io_delta) or 0,
        'inflight_runs': snap2.get('inflight_runs', []),
        'lock_waits': snap2.get('lock_waits', []),
        'remote': remote,
    },
}
json.dump(doc, open(out, 'w'), indent=2)
print(out)
PY
}

cmd_run() {
  local budget="$BUDGET_S" step="step"
  while [ "${1:-}" != "--" ]; do
    case "${1:-}" in
      --budget) budget="${2:?gate-wedge: --budget needs a value}"; shift 2 ;;
      --step)   step="${2:?gate-wedge: --step needs a value}"; shift 2 ;;
      *) usage ;;
    esac
  done
  shift  # drop --
  [ $# -ge 1 ] || usage

  local wedges=0
  local receipts=()
  local attempt

  for attempt in 1 2; do
    local pid_before; pid_before="$(server_pid_now)"
    local outlog; outlog="$(mktemp "${TMPDIR:-/tmp}/gate-wedge-out.XXXXXX")"
    setsid "$@" </dev/null >"$outlog" 2>&1 &
    local root=$!
    local start_epoch; start_epoch=$(date +%s)

    local elapsed=0 wedge_reason="" snap1="" snap2=""
    local next_probe=$PROBE_DELAY_S

    # Per-attempt progress-tracking state (step 2/3): route seen so far,
    # and the previous probe's remote sample (so a remote CPU delta is
    # compared probe-to-probe, PROBE_EVERY_S apart, never inside the
    # SNAPSHOT_GAP_S local-only window — one ssh round trip per probe).
    local route_seen_local=0 route_seen_burst=0
    local remote_prev_worktree="" remote_prev_cpu="" remote_unknown_streak=0
    local last_route="local" last_local_cpu_delta=0 last_io_delta=0
    local last_remote_sampled="false" last_remote_cpu_delta="" last_remote_procs="" last_remote_marker_age=""
    local last_inflight_count=0 last_lockwait_count=0

    while tree_alive "$root"; do
      elapsed=$(( $(date +%s) - start_epoch ))
      if [ "$elapsed" -ge "$budget" ]; then
        snap1="$(mktemp "${TMPDIR:-/tmp}/gate-wedge-snap.XXXXXX")"
        tree_snapshot "$root" > "$snap1"
        snap2="$snap1"
        wedge_reason="budget"
        last_local_cpu_delta=0; last_io_delta=0
        last_inflight_count="$(python3 -c "import json;print(len(json.load(open('$snap2'))['inflight_runs']))" 2>/dev/null || echo 0)"
        last_lockwait_count="$(python3 -c "import json;print(len(json.load(open('$snap2'))['lock_waits']))" 2>/dev/null || echo 0)"
        [ "$last_inflight_count" -gt 0 ] 2>/dev/null && route_seen_burst=1
        break
      fi
      if [ "$elapsed" -ge "$next_probe" ]; then
        local s1f s2f; s1f="$(mktemp "${TMPDIR:-/tmp}/gate-wedge-snap.XXXXXX")"
        tree_snapshot "$root" > "$s1f"
        sleep "$SNAPSHOT_GAP_S"
        if ! tree_alive "$root"; then
          # exited naturally during the snapshot gap — not a wedge.
          rm -f "$s1f"
          break
        fi
        s2f="$(mktemp "${TMPDIR:-/tmp}/gate-wedge-snap.XXXXXX")"
        tree_snapshot "$root" > "$s2f"

        local t0 t1 io0 io1
        t0="$(python3 -c "import json;print(json.load(open('$s1f'))['total_cpu_ticks'])")"
        t1="$(python3 -c "import json;print(json.load(open('$s2f'))['total_cpu_ticks'])")"
        io0="$(python3 -c "import json;print(json.load(open('$s1f'))['total_io_bytes'])")"
        io1="$(python3 -c "import json;print(json.load(open('$s2f'))['total_io_bytes'])")"
        local local_cpu_delta=$(( t1 - t0 )) io_delta=$(( io1 - io0 ))

        local progress=0
        if [ "$local_cpu_delta" -ne 0 ] || [ "$io_delta" -ne 0 ]; then
          progress=1
          route_seen_local=1
        fi

        local inflight_count; inflight_count="$(python3 -c "import json;print(len(json.load(open('$s2f'))['inflight_runs']))")"
        local lockwait_count; lockwait_count="$(python3 -c "import json;print(len(json.load(open('$s2f'))['lock_waits']))")"
        local remote_sampled="false" remote_cpu_delta="" remote_procs="" remote_marker_age=""

        if [ "$progress" -eq 0 ] && [ "$inflight_count" -gt 0 ]; then
          route_seen_burst=1
          local wt; wt="$(python3 -c "import json;d=json.load(open('$s2f'));print(d['inflight_runs'][0]['worktree'])")"
          local remote_out remote_rc
          remote_out="$(remote_probe_sample "$wt")"; remote_rc=$?
          local r_cpu="" r_procs="" r_mage=""
          if [ "$remote_rc" -eq 0 ] && [ -n "$remote_out" ]; then
            read -r r_cpu r_procs r_mage <<<"$remote_out"
          fi
          if [ "$remote_rc" -eq 0 ] && is_int "$r_cpu" && is_int "$r_procs" && is_int "$r_mage"; then
            remote_sampled="true"; remote_procs="$r_procs"; remote_marker_age="$r_mage"
            remote_unknown_streak=0
            local remote_first_sample=0
            if [ "$wt" = "$remote_prev_worktree" ] && [ -n "$remote_prev_cpu" ]; then
              remote_cpu_delta=$(( r_cpu - remote_prev_cpu ))
            else
              # No prior sample for this worktree to diff against yet — this
              # probe only establishes the baseline (same reason the LOCAL
              # rule always needs two snapshots before it can say anything);
              # never a verdict of "no remote progress" on its own.
              remote_first_sample=1
              remote_cpu_delta=0
            fi
            remote_prev_worktree="$wt"; remote_prev_cpu="$r_cpu"
            if [ "$remote_first_sample" -eq 1 ] || [ "$remote_cpu_delta" -gt 0 ] || { [ "$r_mage" != "-1" ] && [ "$r_mage" -lt "$PROBE_EVERY_S" ]; }; then
              progress=1
            fi
          else
            remote_unknown_streak=$((remote_unknown_streak + 1))
            if [ "$remote_unknown_streak" -lt 3 ]; then
              progress=1  # unknown -> never wedged on its own (until the 3rd in a row)
            fi
          fi
        fi

        if [ "$progress" -eq 0 ] && [ "$lockwait_count" -gt 0 ]; then
          local has_live_holder; has_live_holder="$(python3 -c "
import json
d = json.load(open('$s2f'))
print('yes' if any(w['holder_alive'] for w in d['lock_waits']) else 'no')
")"
          [ "$has_live_holder" = "yes" ] && progress=1
        fi

        last_local_cpu_delta="$local_cpu_delta"; last_io_delta="$io_delta"
        last_remote_sampled="$remote_sampled"; last_remote_cpu_delta="$remote_cpu_delta"
        last_remote_procs="$remote_procs"; last_remote_marker_age="$remote_marker_age"
        last_inflight_count="$inflight_count"; last_lockwait_count="$lockwait_count"

        if [ "$progress" -eq 1 ]; then
          rm -f "$s1f" "$s2f"
          next_probe=$(( elapsed + PROBE_EVERY_S ))
        else
          snap1="$s1f"; snap2="$s2f"
          wedge_reason="wedge"
          break
        fi
      fi
      sleep 1
    done

    if [ "$route_seen_local" -eq 1 ] && [ "$route_seen_burst" -eq 1 ]; then last_route="mixed"
    elif [ "$route_seen_burst" -eq 1 ]; then last_route="burst"
    else last_route="local"
    fi

    if [ -n "$wedge_reason" ]; then
      local classification pid_after
      classification="$(classify "$snap1" "$snap2" "$wedge_reason" "$pid_before")"
      kill_tree "$(cat "$snap2")"
      pid_after="$(server_pid_now)"
      local receipt; receipt="$(write_receipt "$step" "$budget" "$elapsed" "$snap1" "$snap2" "$classification" "$pid_before" "$pid_after" \
        "$last_route" "$last_local_cpu_delta" "$last_io_delta" "$last_remote_sampled" "$last_remote_cpu_delta" "$last_remote_procs" "$last_remote_marker_age")"
      receipts+=("$receipt")
      wedges=$((wedges + 1))
      echo "gate-wedge: wedged: $classification receipt=$receipt" >&2
      journal_line --file "$JOURNAL" "$(now_iso)  gate-wedge  $classification  (step=$step wall=${elapsed}s route=$last_route local_cpu=$last_local_cpu_delta io=$last_io_delta remote_cpu=${last_remote_cpu_delta:--} inflight=$last_inflight_count lock_waits=$last_lockwait_count)"
      rm -f "$snap1"; [ "$snap2" != "$snap1" ] && rm -f "$snap2"
      rm -f "$outlog"
      continue
    fi

    # Command exited on its own — pass its output and exit code through.
    wait "$root"; local rc=$?
    cat "$outlog"
    rm -f "$outlog"
    echo "gate-wedge: wedges=$wedges" >&2
    journal_line --file "$JOURNAL" "$(now_iso)  gate-wedge  ok  (step=$step wall=${elapsed}s route=$last_route local_cpu=$last_local_cpu_delta io=$last_io_delta remote_cpu=${last_remote_cpu_delta:--} inflight=$last_inflight_count lock_waits=$last_lockwait_count)"
    exit "$rc"
  done

  echo "gate-wedge: wedges=$wedges" >&2
  for r in "${receipts[@]}"; do echo "gate-wedge: receipt=$r" >&2; done
  exit 98
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  run) cmd_run "$@" ;;
  *) usage ;;
esac
