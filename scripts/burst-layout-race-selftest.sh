#!/usr/bin/env bash
# burst-layout-race-selftest.sh — concurrent first invocations of
# burst-lane.sh against its state-layout migration and every re-point of
# `current` (the race in the review of A1300 component 0 r3, section 1.6:
# unlocked migration, check-then-act `current`, an unlink-then-symlink
# re-point and locks opened through the moving link). Offline: the fake ssh,
# rsync, hcloud, systemctl and systemd-run written below record every call;
# nothing reaches a network, a real token or a real env file, and HOME points
# at an empty directory of this run. Fault injection is PATH-only: wrappers
# around the real ln/mv/rmdir that delay one named call and then run the real
# binary with the same argv. A delay reorders nothing by itself; it only
# widens a window the scheduler can open on its own.
#
# Each control runs BURST_LAYOUT_RACE_N iterations (default 3; the review asks
# for N >= 10 per control as fix evidence, so pass that explicitly). An iteration
# is a fresh state directory and 12 `burst-lane.sh run` invocations against
# fake worktrees (run slots capped at 4, as burstpar-selftest.sh does). It
# holds when:
#   - 12 run starts reached the fake box and no run exited nonzero (control 8:
#     no start at all, and every run fell back with cause=verify-failed);
#   - no run printed an ENOENT for a path through `current`;
#   - `current` ends as a link to boxes/1;
#   - a watcher polling `current` never saw it absent or dangling once it had
#     first resolved;
#   - the money path did what one correct sequence does: with a verified
#     session already on disk (controls 1, 2, 4, 5) no `up` ran at all, the
#     session survived (every seeded field unchanged, runs_served +12) and
#     hcloud saw nothing but `server describe`; on a lane with no session
#     (controls 3, 7) exactly one `up adopted` ran and hcloud saw exactly the
#     calls one single run's adopt makes in the same fixture.
# Controls (numbered as the review lists them; 7 and 8 are this file's additions):
#   1 r-c        flat legacy session.json (verified); every `ln` that links to
#                boxes/<n> (a re-point of `current`, either form) is delayed
#                0.3 s; the deterministic reproducer R-c
#   2 two-point  flat legacy session.json; 0.3 s pause right after the
#                migration's mv of session.json out of the flat layout, and
#                0.3 s after any rmdir of boxes/pending; unfixed, this
#                re-adopts the live box over its session: hcloud volume
#                calls, gate tools reinstalled, session.json rewritten with a
#                new boot time (its TTL clock restarts; unverified whenever
#                that verify fails)
#   3 fresh      no state at all; runs start 0.15 s apart and the first one
#                adopts server 1 through `up`; 0.3 s pause after the pending
#                rmdir (the box_activate fold, no migration involved)
#   4 wedged     boxes/1 holds the verified session and `current` dangles at
#                a removed boxes/pending: the stuck lane the race leaves
#   5 natural    control 1's fixture with no injection; run this file under
#                induced load for the review's >= 20 natural iterations
#   6 ln         controls 1-5, 7 and 8 run once per ln implementation found
#                (uutils and GNU coreutils); a missing one prints SKIP
#   7 readopt    boxes/1 survives with run.lock and up.lock but no session;
#                staggered runs adopt server 1 into it again (the split
#                run.lock/up.lock that mv -n leaves behind in pending)
#   8 unverified control 1's race on a flat session that is NOT verified, with
#                verify failing: every run must fall back (cause=verify-failed)
#                before any exec, nothing may go `up`, and hcloud may see
#                nothing but `server describe` (money path on an unverified lane)
# The single-run reference adopts of controls 3 and 7 are recorded too
# (expect=reference), so call counts can be compared across versions.
# BURST_LAYOUT_RACE_ONLY="1 4" (or "1,4") runs a subset; BURST_LAYOUT_RACE_RECORD=<file>
# appends one JSON line per iteration (counts and the reasons it broke).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/burst-lane.sh"
[ -r "$BL" ] || { echo "FAIL layout-race: $BL missing"; exit 2; }

# Same dormant-lane gate as burstpar-selftest.sh: opt in with
# BUILD_BURST_ENABLED=1. The live env file is never consulted here.
# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! BURST_LANE_ENV_FILE=/nonexistent burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — set BUILD_BURST_ENABLED=1 to run this offline suite"
  exit 0
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/burst-layout-race.XXXXXX")" || exit 2
WATCH_PIDS=()
cleanup() {
  local p; for p in "${WATCH_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$ROOT"
}
trap cleanup EXIT
N="${BURST_LAYOUT_RACE_N:-3}"
case "$N" in ''|*[!0-9]*|0) N=3 ;; esac
ONLY="${BURST_LAYOUT_RACE_ONLY:-1 2 3 4 5 7 8}"; ONLY=" ${ONLY//,/ } "
RECORD="${BURST_LAYOUT_RACE_RECORD:-$ROOT/record.jsonl}"
RUNS=12
PATH0="$PATH"
export HOME="$ROOT/home"; mkdir -p "$HOME" "$ROOT/empty"
unset CLAUDE_CODE_OAUTH_TOKEN

# ---- fakes (on PATH and as the BURST_LANE_*_BIN overrides) -----------------
mkdir -p "$ROOT/fake"
cat > "$ROOT/fake/ssh" <<'EOF'
#!/usr/bin/env bash
# Records the remote command (last argv word) and answers it: the warm check
# and capacity probe silently, verify's toolchain probe with the three lines
# it greps for, a run's cargo exec as one start/end span, anything else exit 0.
cmd="${!#}"
printf '%s\n' "${cmd//$'\n'/ }" >> "$RACE_SSH_CALLS"
case "$cmd" in
  *"[ -d"*) exit 0 ;;
  *meminfo*) exit 0 ;;
  *"cargo --version"*)
    [ "${RACE_VERIFY_FAIL:-0}" = 1 ] && exit 1
    printf 'cargo 1.0.0\nuv 0.1.0\n1\n'; exit 0 ;;
  *"cargo build"*)
    echo "start $$ $(date +%s.%N)" >> "$SPAN_LOG"
    sleep "${RACE_RUN_SECS:-0.2}"
    echo "end $$ $(date +%s.%N)" >> "$SPAN_LOG"
    exit 0 ;;
esac
exit 0
EOF
cat > "$ROOT/fake/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RACE_RSYNC_CALLS"
echo "Total transferred file size: 100"
exit 0
EOF
cat > "$ROOT/fake/hcloud" <<'EOF'
#!/usr/bin/env bash
# One server, id 1, alive under any name; every other call is refused.
printf '%s\n' "$*" >> "$RACE_HCLOUD_CALLS"
if [ "${1:-}" = server ] && [ "${2:-}" = describe ]; then
  printf '{"id":1,"name":"%s","status":"running","created":"2026-01-01T00:00:00Z","public_net":{"ipv4":{"ip":"127.0.0.1"}}}\n' "${3:-}"
  exit 0
fi
echo "hcloud (burst-layout-race fake): ${1:-} ${2:-}: not found" >&2
exit 1
EOF
cat > "$ROOT/fake/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$RACE_TIMER_CALLS"
case "$*" in *is-active*) echo inactive; exit 3 ;; esac
exit 0
EOF
cat > "$ROOT/fake/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >> "$RACE_TIMER_CALLS"
exit 0
EOF
chmod +x "$ROOT/fake/"*

# ---- ln flavours and the delay wrappers ------------------------------------
ln_flavour() {  # $1 = an ln binary -> uutils | gnu | ""
  local v; v="$("$1" --version 2>/dev/null | head -n1)"
  case "$v" in *uutils*) echo uutils ;; *"GNU coreutils"*) echo gnu ;; *) echo "" ;; esac
}
LN_UUTILS=""; LN_GNU=""
for cand in "$(PATH="$PATH0" command -v ln)" "$(PATH="$PATH0" command -v gnuln)" \
            /usr/lib/cargo/bin/coreutils/ln /usr/bin/gnuln /usr/bin/ln /bin/ln; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  case "$(ln_flavour "$cand")" in
    uutils) [ -n "$LN_UUTILS" ] || LN_UUTILS="$cand" ;;
    gnu)    [ -n "$LN_GNU" ] || LN_GNU="$cand" ;;
  esac
done
REAL_MV="$(PATH="$PATH0" command -v mv)"; REAL_RMDIR="$(PATH="$PATH0" command -v rmdir)"
make_shims() {  # $1 = flavour, $2 = real ln
  local d="$ROOT/shim.$1"; mkdir -p "$d"
  cat > "$d/ln" <<EOF
#!/usr/bin/env bash
# RACE_INJECT=r-c: delay an ln that links to boxes/<n> (a re-point of current).
if [ "\${RACE_INJECT:-}" = r-c ]; then
  for a in "\$@"; do
    case "\$a" in boxes/[0-9]*) echo "ln-delay \$*" >> "\$RACE_INJECT_LOG"; sleep "\$RACE_DELAY"; break ;; esac
  done
fi
exec "$2" "\$@"
EOF
  cat > "$d/mv" <<EOF
#!/usr/bin/env bash
# RACE_INJECT=two-point: pause right after the migration's mv of the flat
# session.json (it has left the flat layout; nothing points at it yet).
if [ "\${RACE_INJECT:-}" = two-point ] && [ "\${1:-}" = -f ] && [ "\${2:-}" = "\$RACE_STATE/session.json" ]; then
  "$REAL_MV" "\$@"; rc=\$?
  echo "mv-pause \$*" >> "\$RACE_INJECT_LOG"; sleep "\$RACE_DELAY"; exit \$rc
fi
exec "$REAL_MV" "\$@"
EOF
  cat > "$d/rmdir" <<EOF
#!/usr/bin/env bash
# RACE_INJECT=two-point|rmdir: pause right after an rmdir of boxes/pending.
case "\${RACE_INJECT:-}" in
  two-point|rmdir)
    if [ "\${1:-}" = "\$RACE_STATE/boxes/pending" ]; then
      "$REAL_RMDIR" "\$@"; rc=\$?
      echo "rmdir-pause rc=\$rc \$*" >> "\$RACE_INJECT_LOG"; sleep "\$RACE_DELAY"; exit \$rc
    fi ;;
esac
exec "$REAL_RMDIR" "\$@"
EOF
  chmod +x "$d/ln" "$d/mv" "$d/rmdir"
}
FLAVOURS=()
[ -n "$LN_UUTILS" ] && { make_shims uutils "$LN_UUTILS"; FLAVOURS+=(uutils); }
[ -n "$LN_GNU" ] && { make_shims gnu "$LN_GNU"; FLAVOURS+=(gnu); }
[ "${#FLAVOURS[@]}" -gt 0 ] || { echo "FAIL layout-race: no usable ln found"; exit 2; }

# ---- environment shared by every invocation --------------------------------
export BURST_LANE_TEST=1 BURST_MAX_CONCURRENT_RUNS=4 BURST_GATE_REVIEWER=0 \
       BURST_LANE_SSH_BIN="$ROOT/fake/ssh" BURST_LANE_RSYNC_BIN="$ROOT/fake/rsync" \
       BURST_LANE_HCLOUD_BIN="$ROOT/fake/hcloud" BURST_LANE_ENV_FILE="$ROOT/noenv" \
       BURST_CLAUDE_CRED_SRC="$ROOT/nocred" BURST_LANE_GATE_BUILD_SCRIPTS="$ROOT/empty" \
       BURST_LANE_GATE_RUSTBUILD_SCRIPTS="$ROOT/empty" BURST_LANE_GATE_RUSTBUILD_PROMPTS="$ROOT/empty" \
       BURST_LANE_AUTOBUILDER_BIN="$ROOT/empty/autobuilder" RACE_DELAY=0.3

SEED_SESSION='{"server_id":1,"ip":"127.0.0.1","server_type":"test","boot_ts":"2026-01-01T00:00:00Z","boot_epoch":1,"ttl_hours":6,"hard_ttl_hours":12,"runs_served":0,"sandbox_ok":"true","teardown_scheduled":"false","teardown_epoch":"","verified":"true"}'

SEED_UNVERIFIED="${SEED_SESSION/\"verified\":\"true\"/\"verified\":\"false\"}"

seed() {  # $1 = fixture, $2 = state dir
  case "$1" in
    legacy) printf '%s\n' "$SEED_SESSION" > "$2/session.json" ;;
    unverified) printf '%s\n' "$SEED_UNVERIFIED" > "$2/session.json" ;;
    fresh)  : ;;
    wedged) mkdir -p "$2/boxes/1"; printf '%s\n' "$SEED_SESSION" > "$2/boxes/1/session.json"
            ln -s boxes/pending "$2/current" ;;
    readopt) mkdir -p "$2/boxes/1"; : > "$2/boxes/1/run.lock"; : > "$2/boxes/1/up.lock"
            printf '%s\n' "$SEED_SESSION" > "$2/boxes/1/session.json.stale-20260101T000000Z" ;;
  esac
}

watch_current() {  # $1 = state dir, $2 = stop file, $3 = result file
  local armed=0 polls=0 bad=0
  while [ ! -e "$2" ]; do
    if [ -L "$1/current" ] && [ -d "$1/current" ]; then armed=1
    elif [ "$armed" = 1 ]; then bad=$((bad + 1))
    fi
    polls=$((polls + 1))
  done
  echo "$polls $bad" > "$3"
}

# run_iteration <dir> <fixture> <inject> <stagger> <flavour> <runs>
run_iteration() {
  local it="$1" fx="$2" inj="$3" stagger="$4" fl="$5" nr="$6" i wpid
  mkdir -p "$it/state" "$it/w" "$it/remote" "$it/remote-home" "$it/prove" "$it/prds/build-queue" "$it/iso"
  : > "$it/hcloud.calls"; : > "$it/ssh.calls"; : > "$it/rsync.calls"; : > "$it/timer.calls"
  : > "$it/spans.log"; : > "$it/inject.log"
  seed "$fx" "$it/state"
  watch_current "$it/state" "$it/stop" "$it/watch" &
  wpid=$!; WATCH_PIDS+=("$wpid")
  for i in $(seq 1 "$nr"); do
    mkdir -p "$it/w/w$i"
    ( export PATH="$ROOT/shim.$fl:$ROOT/fake:$PATH0" \
        BURST_LANE_STATE_DIR="$it/state" BURST_LANE_JOURNAL="$it/journal.log" \
        BURST_LANE_REMOTE_ROOT="$it/remote" BURST_LANE_REMOTE_HOME="$it/remote-home" \
        BURST_PROVE_TMP="$it/prove" BURST_LANE_PRD_DIR="$it/prds" \
        BURST_LANE_SYSTEMD_DROPIN="$it/dropin.conf" BURST_ISOLATION_LIVE_JOURNAL="$it/journal.log" \
        ISOLATION_STATE_DIR="$it/iso" SPAN_LOG="$it/spans.log" \
        RACE_SSH_CALLS="$it/ssh.calls" RACE_RSYNC_CALLS="$it/rsync.calls" \
        RACE_HCLOUD_CALLS="$it/hcloud.calls" RACE_TIMER_CALLS="$it/timer.calls" \
        RACE_INJECT="$inj" RACE_INJECT_LOG="$it/inject.log" RACE_STATE="$it/state" \
        RACE_VERIFY_FAIL="$([ "$fx" = unverified ] && echo 1 || echo 0)"
      bash "$BL" run "$it/w/w$i" -- cargo build >"$it/out.$i.log" 2>&1
      echo $? > "$it/rc.$i" ) &
    [ "$stagger" = 0 ] || sleep "$stagger"
  done
  # wait for the runs only (the watcher stops on the stop file below)
  for i in $(jobs -p); do [ "$i" = "$wpid" ] || wait "$i"; done
  touch "$it/stop"; wait "$wpid" 2>/dev/null
}

# check <dir> <expect> <ref-json|""> <runs> <required injection mark|none>
#   -> prints "hold" or "broke: <reasons>"; appends one record line
check() {
  local seedjson="$SEED_SESSION"
  [ "$2" = fallback ] && seedjson="$SEED_UNVERIFIED"
  python3 - "$1" "$2" "$3" "$4" "$5" "$seedjson" "$RECORD" <<'PY'
import json, os, re, sys, collections
it, expect, ref, nr, req = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
seed, record = json.loads(sys.argv[6]), sys.argv[7]
def lines(p):
    try:
        with open(os.path.join(it, p)) as fh: return [l.rstrip("\n") for l in fh]
    except OSError: return []
starts = sum(1 for l in lines("spans.log") if l.startswith("start "))
rcs = []
for i in range(1, nr + 1):
    v = (lines("rc.%d" % i) or ["missing"])[0]
    rcs.append(v)
nonzero = sum(1 for v in rcs if v != "0")
enoent = 0
for i in range(1, nr + 1):
    enoent += sum(1 for l in lines("out.%d.log" % i) if "No such file or directory" in l and "/current" in l)
st = os.path.join(it, "state")
cur = os.readlink(os.path.join(st, "current")) if os.path.islink(os.path.join(st, "current")) else None
w = (lines("watch") or ["0 -1"])[0].split()
polls, bad = int(w[0]), int(w[1])
journal = lines("journal.log")
up_events = [l for l in journal if re.search(r"burst-lane  up  ", l)]
adopted = sum(1 for l in journal if "burst-lane  up  adopted" in l)
fallbacks = [l for l in journal if "run  fallback" in l]
hc = lines("hcloud.calls")
hc_other = sorted(l for l in hc if not l.startswith("server describe"))
inject = collections.Counter(l.split()[0] for l in lines("inject.log"))
sess = None
try:
    with open(os.path.join(st, "boxes", "1", "session.json")) as fh: sess = json.load(fh)
except Exception: pass
reasons = []
if req != "none" and inject.get(req, 0) < 1: reasons.append("injection_not_fired=%s" % req)
want_starts, want_nonzero = (0, nr) if expect == "fallback" else (nr, 0)
if expect == "reference": want_starts, want_nonzero = starts, nonzero
if starts != want_starts: reasons.append("starts=%d" % starts)
if nonzero != want_nonzero: reasons.append("nonzero=%d" % nonzero)
if enoent: reasons.append("enoent_lines=%d" % enoent)
if cur != "boxes/1": reasons.append("current=%s" % cur)
if bad != 0: reasons.append("current_absent_or_dangling_polls=%d" % bad)
verify_fallbacks = sum(1 for l in fallbacks if "cause=verify-failed" in l)
if expect == "fallback":
    if verify_fallbacks != nr or len(fallbacks) != nr: reasons.append("fallbacks=%d verify_failed=%d" % (len(fallbacks), verify_fallbacks))
elif fallbacks and expect != "reference": reasons.append("run_fallbacks=%d" % len(fallbacks))
if expect == "reference": reasons = []
elif expect in ("keep", "fallback"):
    if up_events: reasons.append("up_events=%d" % len(up_events))
    if hc_other: reasons.append("hcloud_beyond_describe=%d" % len(hc_other))
    if sess is None: reasons.append("session=missing")
    else:
        changed = sorted(k for k in seed if k != "runs_served" and str(sess.get(k)) != str(seed[k]))
        if changed: reasons.append("session_fields_changed=%s" % ",".join(changed))
        want_served = seed["runs_served"] + (nr if expect == "keep" else 0)
        if str(sess.get("runs_served")) != str(want_served): reasons.append("runs_served=%s" % sess.get("runs_served"))
else:
    want = json.loads(ref) if ref else None
    if adopted != 1: reasons.append("adopted=%d" % adopted)
    if want is not None and hc_other != want["hcloud_other"]:
        reasons.append("hcloud_other=%d want %d" % (len(hc_other), len(want["hcloud_other"])))
    if sess is None or str(sess.get("verified")) != "true": reasons.append("session_verified=%s" % (sess or {}).get("verified"))
rec = {"dir": os.path.basename(it), "expect": expect, "starts": starts, "nonzero": nonzero, "enoent_lines": enoent,
       "run_fallbacks_verify_failed": verify_fallbacks, "rsync_calls": len(lines("rsync.calls")),
       "current": cur, "watch_polls": polls, "watch_bad": bad, "up_events": len(up_events), "adopted": adopted,
       "run_fallbacks": len(fallbacks), "hcloud_calls": len(hc), "hcloud_other": hc_other,
       "ssh_calls": len(lines("ssh.calls")), "timer_calls": len(lines("timer.calls")),
       "inject": dict(inject), "holds": not reasons, "reasons": reasons}
with open(record, "a") as fh: fh.write(json.dumps(rec, sort_keys=True) + "\n")
if expect == "reference":
    print(json.dumps({"hcloud_other": hc_other}))
else:
    print("hold" if not reasons else "broke: " + " ".join(reasons))
PY
}

# reference <fixture> <flavour> -> JSON of what one single run's adopt calls
reference() {
  local it="$ROOT/ref.$1.$2"
  run_iteration "$it" "$1" none 0 "$2" 1
  check "$it" reference "" 1 none
}

fail=0
control() {  # <n> <name> <fixture> <inject> <stagger> <expect keep|adopt> <required mark>
  local n="$1" name="$2" fx="$3" inj="$4" stagger="$5" expect="$6" req="$7" fl k res held ref first
  case "$ONLY" in *" $n "*) : ;; *) return 0 ;; esac
  for fl in uutils gnu; do
    case " ${FLAVOURS[*]} " in
      *" $fl "*) : ;;
      *) echo "SKIP layout-race $n $name [ln=$fl]: no $fl ln on this host"; continue ;;
    esac
    ref=""
    [ "$expect" = adopt ] && ref="$(reference "$fx" "$fl")"
    held=0; first=""
    for k in $(seq 1 "$N"); do
      run_iteration "$ROOT/c$n.$fl.$k" "$fx" "$inj" "$stagger" "$fl" "$RUNS"
      res="$(check "$ROOT/c$n.$fl.$k" "$expect" "$ref" "$RUNS" "$req")"
      if [ "$res" = hold ]; then held=$((held + 1)); else [ -n "$first" ] || first="iteration $k $res"; fi
    done
    if [ "$held" -eq "$N" ]; then
      echo "ok  layout-race $n $name [ln=$fl]: $held/$N iterations hold"
    else
      echo "FAIL layout-race $n $name [ln=$fl]: $held/$N iterations hold; first: $first"
      fail=1
    fi
  done
}

control 1 r-c       legacy  r-c       0    keep  ln-delay
control 2 two-point legacy  two-point 0    keep  mv-pause
control 3 fresh     fresh   rmdir     0.15 adopt rmdir-pause
control 4 wedged    wedged  none      0    keep  none
control 5 natural   legacy  none      0    keep  none
control 7 readopt   readopt rmdir     0.15 adopt rmdir-pause
control 8 unverified unverified r-c   0    fallback ln-delay
if [ "${#FLAVOURS[@]}" -eq 2 ]; then
  echo "ok  layout-race 6 ln flavours: every control above ran with uutils ($LN_UUTILS) and GNU ($LN_GNU) ln"
else
  echo "SKIP layout-race 6 ln flavours: only ${FLAVOURS[*]} ln found on this host"
fi
exit "$fail"
