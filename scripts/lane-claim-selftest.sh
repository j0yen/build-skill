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

echo "== target-busy sees the live claim =="
set +e
out=$("$LC" target-busy /tmp/some-target-repo --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^busy: smoke-test redbaron' || { echo "FAIL busy msg: $out"; exit 1; }
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

echo "ALL SELFTESTS PASSED"
