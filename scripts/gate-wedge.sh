#!/usr/bin/env bash
# gate-wedge.sh — per-step wall-clock budget + CPU-delta wedge probe for
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
# classification), prints `gate-wedge: wedged: <classification>
# receipt=<path>` to stderr, and retries the command ONCE from scratch.
# A second wedge fails the step: exit 98, both receipts referenced,
# `gate-wedge: wedges=2` on stderr.
#
# Classification:
#   sccache-client-orphans — the wedged tree contains a process named
#     `sccache`, AND the managed unit's current MainPID differs from the
#     MainPID recorded when this run started — the server the step was
#     talking to when it began is not the server running now.
#   budget-exceeded — the step ran past --budget with the tree still
#     alive, regardless of CPU state (checked independently of the
#     wedge probe above, at the same cadence).
#   unknown — a wedge with neither signal above (any other zero-CPU hang).
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
#   SCCACHE_ASSERT_SYSTEMCTL   ("systemctl --user") same override
#   SCCACHE_ASSERT_UNIT        (sccache-server.service)   sccache-assert.sh uses
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${GATE_WEDGE_STATE_DIR:-$SKILL_DIR/state/gate-wedge}"

BUDGET_S="${GATE_STEP_BUDGET_S:-1800}"
PROBE_DELAY_S="${GATE_WEDGE_PROBE_DELAY_S:-300}"
PROBE_EVERY_S="${GATE_WEDGE_PROBE_EVERY_S:-60}"
SNAPSHOT_GAP_S="${GATE_WEDGE_SNAPSHOT_GAP_S:-30}"
SYSTEMCTL="${SCCACHE_ASSERT_SYSTEMCTL:-systemctl --user}"
UNIT="${SCCACHE_ASSERT_UNIT:-sccache-server.service}"

die() { echo "gate-wedge: $1" >&2; exit "${2:-2}"; }
usage() { echo "usage: gate-wedge.sh run [--budget SECS] [--step NAME] -- <cmd...>" >&2; exit 2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

server_pid_now() {
  local pid
  pid="$($SYSTEMCTL show -p MainPID --value "$UNIT" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "0" ] || pid="unknown"
  printf '%s' "$pid"
}

# Prints one JSON object: {"total_cpu_ticks": N, "procs": [{"pid":P,
# "comm":C,"cpu_ticks":T,"wchan":W}, ...]} for <root_pid> and every live
# descendant (BFS over ppid via /proc — never a single pid).
tree_snapshot() {
  local root="$1"
  python3 - "$root" <<'PY'
import sys, os, json

root = int(sys.argv[1])
procs = {}
for p in os.listdir('/proc'):
    if not p.isdigit():
        continue
    try:
        with open(f'/proc/{p}/stat', 'rb') as f:
            data = f.read().decode(errors='replace')
        rp = data.rfind(')')
        comm = data[data.find('(') + 1:rp]
        after = data[rp + 2:].split()
        ppid = int(after[1])
        utime = int(after[11]); stime = int(after[12])
        procs[int(p)] = {'ppid': ppid, 'comm': comm, 'cpu': utime + stime}
    except (FileNotFoundError, ProcessLookupError, ValueError, IndexError, OSError):
        continue

tree = {root} if root in procs or os.path.exists(f'/proc/{root}') else set()
tree.add(root)
changed = True
while changed:
    changed = False
    for pid, info in procs.items():
        if info['ppid'] in tree and pid not in tree:
            tree.add(pid)
            changed = True

total = 0
out = []
for pid in sorted(tree):
    info = procs.get(pid)
    if not info:
        continue
    total += info['cpu']
    wchan = ''
    try:
        with open(f'/proc/{pid}/wchan') as f:
            wchan = f.read()
    except OSError:
        pass
    out.append({'pid': pid, 'comm': info['comm'], 'cpu_ticks': info['cpu'], 'wchan': wchan})
print(json.dumps({'total_cpu_ticks': total, 'procs': out}))
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

write_receipt() {
  local step="$1" budget="$2" elapsed="$3" snap1="$4" snap2="$5" classification="$6" pid_before="$7" pid_after="$8"
  mkdir -p "$STATE_DIR"
  local out="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${step}-wedge-receipt.json"
  python3 - "$out" "$step" "$budget" "$elapsed" "$snap1" "$snap2" "$classification" "$pid_before" "$pid_after" <<'PY'
import sys, json

out, step, budget, elapsed, snap1_f, snap2_f, classification, pid_before, pid_after = sys.argv[1:10]
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

doc = {
    'step': step,
    'budget_s': int(budget),
    'elapsed_s': int(elapsed),
    'cpu_delta_table': cpu_delta_table,
    'wchan_table': wchan_table,
    'sccache_pid_before': pid_before,
    'sccache_pid_after': pid_after,
    'classification': classification,
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

    while tree_alive "$root"; do
      elapsed=$(( $(date +%s) - start_epoch ))
      if [ "$elapsed" -ge "$budget" ]; then
        snap1="$(mktemp "${TMPDIR:-/tmp}/gate-wedge-snap.XXXXXX")"
        tree_snapshot "$root" > "$snap1"
        snap2="$snap1"
        wedge_reason="budget"
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
        local t0 t1
        t0="$(python3 -c "import json;print(json.load(open('$s1f'))['total_cpu_ticks'])")"
        t1="$(python3 -c "import json;print(json.load(open('$s2f'))['total_cpu_ticks'])")"
        if [ "$t0" = "$t1" ]; then
          snap1="$s1f"; snap2="$s2f"
          wedge_reason="wedge"
          break
        fi
        rm -f "$s1f" "$s2f"
        next_probe=$(( elapsed + PROBE_EVERY_S ))
      fi
      sleep 1
    done

    if [ -n "$wedge_reason" ]; then
      local classification pid_after
      classification="$(classify "$snap1" "$snap2" "$wedge_reason" "$pid_before")"
      kill_tree "$(cat "$snap2")"
      pid_after="$(server_pid_now)"
      local receipt; receipt="$(write_receipt "$step" "$budget" "$elapsed" "$snap1" "$snap2" "$classification" "$pid_before" "$pid_after")"
      receipts+=("$receipt")
      wedges=$((wedges + 1))
      echo "gate-wedge: wedged: $classification receipt=$receipt" >&2
      rm -f "$snap1"; [ "$snap2" != "$snap1" ] && rm -f "$snap2"
      rm -f "$outlog"
      continue
    fi

    # Command exited on its own — pass its output and exit code through.
    wait "$root"; local rc=$?
    cat "$outlog"
    rm -f "$outlog"
    echo "gate-wedge: wedges=$wedges" >&2
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
