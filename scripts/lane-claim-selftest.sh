#!/usr/bin/env bash
# lane-claim-selftest.sh — exercises lane-claim.sh's claim/status/release/
# target-busy paths (free, held, race, stale-reclaim) against a scratch git
# repo under /tmp/. Never touches the real ~/Documents/PRDs clone.
set -euo pipefail
LC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane-claim.sh"
ROOT=$(mktemp -d /tmp/lane-claim-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

# "origin" bare repo + one working clone to act as the shared remote.
git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"
cat > "$ROOT/clone/build-queue/PRD-smoke-test.md" <<'EOF'
# PRD: smoke-test

- Status: queued
- build_target: shell
- build_into: /tmp/some-target-repo
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ROOT/clone" push -q origin master 2>/dev/null || git -C "$ROOT/clone" push -q origin main 2>/dev/null || true
BR=$(git -C "$ROOT/clone" symbolic-ref --short HEAD)

PRD="$ROOT/clone/build-queue/PRD-smoke-test.md"

echo "== status: free =="
out=$("$LC" status "$PRD"); [ "$out" = "free" ] || { echo "FAIL free: $out"; exit 1; }
echo ok

echo "== claim by redbaron =="
out=$("$LC" claim "$PRD" redbaron)
echo "$out" | grep -q '^claimed: smoke-test lane=redbaron' || { echo "FAIL claim: $out"; exit 1; }
grep -q '^- Status: building' "$PRD" || { echo "FAIL status-line"; exit 1; }
grep -q '^- Lane: redbaron' "$PRD" || { echo "FAIL lane-line"; exit 1; }
echo ok

echo "== second lane tries same PRD, sees held (not stale) =="
set +e
out=$("$LC" claim "$PRD" carbon 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL expected exit 2, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^held: redbaron' || { echo "FAIL held msg: $out"; exit 1; }
echo ok

echo "== target-busy: foreign lane sees the live claim as busy (cross-lane exclusivity, AC2) =="
set +e
out=$("$LC" target-busy /tmp/some-target-repo --lane carbon --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^busy: smoke-test redbaron' || { echo "FAIL busy msg: $out"; exit 1; }
echo ok

echo "== target-busy: same-lane exemption — the querying lane's own claim does not block it (AC1) =="
out=$("$LC" target-busy /tmp/some-target-repo --lane redbaron --prd-dir "$ROOT/clone")
[ "$out" = "free" ] || { echo "FAIL expected free (same-lane exempt), got: $out"; exit 1; }
echo ok

echo "== race: two lanes both see 'free' before either pushes; first push wins, loser's rebase conflicts and it detects the winner =="
"$LC" release "$PRD" >/dev/null
git clone -q "$ROOT/origin.git" "$ROOT/clone2" >/dev/null
PRD2="$ROOT/clone2/build-queue/PRD-smoke-test.md"
git -C "$ROOT/clone2" pull -q --rebase >/dev/null
# Both clones now locally see "free". Source the script to drive the two
# halves (write+commit, then push) independently so we can interleave them
# — this is the only way to force the true concurrent window past the
# safety `git pull` that cmd_claim always does up front.
source "$LC"
ts=$(now_iso)
write_claim "$PRD2" building "carbon $ts"
git -C "$ROOT/clone2" add -A
git -C "$ROOT/clone2" -c user.name=t -c user.email=t@t commit -q -m "claim: smoke-test lane=carbon"
write_claim "$PRD" building "redbaron $ts"
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: smoke-test lane=redbaron"
# carbon (clone2) pushes first — origin was still at "free", so this lands.
git -C "$ROOT/clone2" push -q origin "$BR"
# redbaron (clone) pushes second against the now-stale base — rejected,
# forcing the fetch+rebase+conflict-detect path in push_or_resolve_race.
set +e
out1=$(push_or_resolve_race "$ROOT/clone" "$PRD" redbaron claim 2>&1); rc1=$?
set -e
[ "$rc1" -eq 2 ] || { echo "FAIL expected loser exit 2, got $rc1: $out1"; exit 1; }
echo "$out1" | grep -q '^lost-race: carbon' || { echo "FAIL lost-race msg: $out1"; exit 1; }
git -C "$ROOT/clone" status --porcelain | grep -q . && { echo "FAIL clone left dirty after losing race"; exit 1; }
echo ok

echo "== stale reclaim =="
# Backdate the claim on clone2's copy by 4 hours and push it as the shared state.
python3 - "$PRD2" <<'PYEOF'
import re, datetime, sys
f = sys.argv[1]
old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(f) as fh: txt = fh.read()
txt = re.sub(r'^- Lane: .*$', f'- Lane: carbon {old}', txt, flags=re.M)
with open(f, 'w') as fh: fh.write(txt)
PYEOF
git -C "$ROOT/clone2" add -A
git -C "$ROOT/clone2" -c user.name=t -c user.email=t@t commit -q -m backdate
git -C "$ROOT/clone2" push -q origin "$BR"
git -C "$ROOT/clone" pull -q --rebase >/dev/null
out=$("$LC" claim "$PRD" redbaron)
echo "$out" | grep -q '^reclaim-receipt: prev_lane=carbon' || { echo "FAIL reclaim receipt: $out"; exit 1; }
echo "$out" | grep -q '^claimed: smoke-test lane=redbaron' || { echo "FAIL reclaim result: $out"; exit 1; }
echo ok

echo "== same-lane sub-cap: reproduces the mcphost/synthorg wedge shape =="
# Two live same-lane claims on one build_into repo must NOT block a 3rd
# same-lane candidate (today's bug: cmd_target_busy blocked on claim
# presence alone, ignoring host, wedging the queue serial). A 4th candidate,
# once 3 are live, must be rejected at the sub-cap with a distinct message.
for n in a b c d; do
cat > "$ROOT/clone/build-queue/PRD-wedge-$n.md" <<EOF
# PRD: wedge-$n

- Status: queued
- build_target: shell
- build_into: /tmp/wedge-target-repo
- build_priority: high
EOF
done
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-wedge-prds
git -C "$ROOT/clone" push -q origin "$BR"

WEDGE_A="$ROOT/clone/build-queue/PRD-wedge-a.md"
WEDGE_B="$ROOT/clone/build-queue/PRD-wedge-b.md"
WEDGE_C="$ROOT/clone/build-queue/PRD-wedge-c.md"
WEDGE_D="$ROOT/clone/build-queue/PRD-wedge-d.md"

"$LC" claim "$WEDGE_A" redbaron >/dev/null
"$LC" claim "$WEDGE_B" redbaron >/dev/null

echo "-- 2 same-lane claims live; 3rd candidate admitted (AC4) --"
out=$("$LC" target-busy /tmp/wedge-target-repo --lane redbaron --exclude-prd "$WEDGE_C" --prd-dir "$ROOT/clone")
[ "$out" = "free" ] || { echo "FAIL expected free (wedge regression), got: $out"; exit 1; }
echo ok

"$LC" claim "$WEDGE_C" redbaron >/dev/null

echo "-- 3 same-lane claims live; a 4th is rejected at the sub-cap, distinct msg (AC1/AC3) --"
set +e
out=$("$LC" target-busy /tmp/wedge-target-repo --lane redbaron --exclude-prd "$WEDGE_D" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 3 same-lane claims already live' || { echo "FAIL expected sub-cap message, got: $out"; exit 1; }
echo ok

echo "-- cross-lane exclusivity unaffected by same-lane sub-cap accounting (AC2) --"
set +e
out=$("$LC" target-busy /tmp/wedge-target-repo --lane carbon --exclude-prd "$WEDGE_D" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected cross-lane busy, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^busy: wedge-' || { echo "FAIL expected generic busy msg, got: $out"; exit 1; }
echo ok

echo "== own-claim continuation: a PRD already claimed by this lane is never blocked by its own claim (PRD-build-claims-resume-not-count, AC1/AC2) =="
# Reproduces the 06:23Z OOM shape exactly: 3 live same-lane claims already
# sit at the sub-cap (set up above), yet each of THOSE THREE PRDs must
# still be selectable as a continuation of its own claim — the bug was
# that the dead coordinator's own six claims blocked one another forever.
echo "-- each of the 3 already-live claims resumes cleanly despite sitting at the sub-cap (AC1) --"
for w in "$WEDGE_A" "$WEDGE_B" "$WEDGE_C"; do
  out=$("$LC" target-busy /tmp/wedge-target-repo --lane redbaron --exclude-prd "$w" --prd-dir "$ROOT/clone")
  echo "$out" | grep -q '^resume: own claim on /tmp/wedge-target-repo (lane=redbaron)$' \
    || { echo "FAIL expected resume for $w, got: $out"; exit 1; }
done
echo ok

echo "-- a genuinely new (unclaimed) 4th candidate is still sub-cap-blocked while the 3 continuations remain live (AC2) --"
set +e
out=$("$LC" target-busy /tmp/wedge-target-repo --lane redbaron --exclude-prd "$WEDGE_D" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 3 same-lane claims already live' || { echo "FAIL expected sub-cap message, got: $out"; exit 1; }
echo ok

echo "== coordinator-liveness: a same-lane claim with a dead recorded PID is stale immediately, not after 3h (Requirement P0 #3, AC3) =="
cat > "$ROOT/clone/build-queue/PRD-deadpid.md" <<'EOF'
# PRD: deadpid

- Status: queued
- build_target: shell
- build_into: /tmp/deadpid-target-repo
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-deadpid
git -C "$ROOT/clone" push -q origin "$BR"
DEADPID_PRD="$ROOT/clone/build-queue/PRD-deadpid.md"

# Pick a PID guaranteed not to be running right now.
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done

ts_fresh=$(now_iso)
write_claim "$DEADPID_PRD" building "$(hostname) $ts_fresh pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: deadpid lane=$(hostname) (fixture, dead pid)"
git -C "$ROOT/clone" push -q origin "$BR"

echo "-- status: stale=yes at age ~0 because the recorded coordinator PID is gone --"
out=$("$LC" status "$DEADPID_PRD")
echo "$out" | grep -q 'stale=yes' || { echo "FAIL expected stale=yes, got: $out"; exit 1; }
age_val=$(sed -E 's/.*age=([0-9]+)s.*/\1/' <<<"$out")
[ "$age_val" -lt 10 ] || { echo "FAIL expected age <10s (immediate), got: $out"; exit 1; }
echo ok

echo "-- target-busy: the dead-pid claim doesn't count toward this lane's own sub-cap at all --"
out=$("$LC" target-busy /tmp/deadpid-target-repo --lane "$(hostname)" --prd-dir "$ROOT/clone")
[ "$out" = "free" ] || { echo "FAIL expected free (dead-pid claim excluded from count), got: $out"; exit 1; }
echo ok

echo "== coordinator-liveness: a claim recorded on ANOTHER host keeps the plain 3h age rule regardless of its pid trailer (Non-goal, AC4) =="
cat > "$ROOT/clone/build-queue/PRD-otherhost.md" <<'EOF'
# PRD: otherhost

- Status: queued
- build_target: shell
- build_into: /tmp/otherhost-target-repo
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-otherhost
git -C "$ROOT/clone" push -q origin "$BR"
OTHERHOST_PRD="$ROOT/clone/build-queue/PRD-otherhost.md"

# 1h old, pid=$$ (this very shell — definitely alive) but under a lane name
# that never matches this host's hostname: PID namespaces are host-local,
# so this must fall back to the age rule (not stale at 1h) rather than
# either confirming it alive or dead.
one_hour_ago=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$OTHERHOST_PRD" building "some-other-lane-name $one_hour_ago pid=$$ boot=$(current_boot_id)"
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: otherhost lane=some-other-lane-name (fixture)"
git -C "$ROOT/clone" push -q origin "$BR"

set +e
out=$("$LC" target-busy /tmp/otherhost-target-repo --lane redbaron --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^busy: otherhost some-other-lane-name' || { echo "FAIL busy msg: $out"; exit 1; }
echo ok

echo "ALL SELFTESTS PASSED"
