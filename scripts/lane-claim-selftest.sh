#!/usr/bin/env bash
# lane-claim-selftest.sh — exercises lane-claim.sh's claim/status/release/
# target-busy paths (free, held, race, stale-reclaim) against a scratch git
# repo under /tmp/. Never touches the real ~/Documents/PRDs clone.
export SAME_LANE_SUBCAP=3  # pin: these fixtures test the sub-cap mechanism at 3
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

echo "== stale reclaim (PRD-build-lane-claim-integrity: evidence bar, not age alone) =="
# Backdate the claim on clone2's copy by 4 hours and push it as the shared
# state. The commit that carries the backdated claim is ALSO backdated
# (GIT_AUTHOR/COMMITTER_DATE) to the same instant — otherwise the commit
# probe below would see a very-recent commit touching the file (this
# backdate commit itself) and correctly read that as liveness, which
# would defeat the fixture's own intent (simulate a claim that has had NO
# real activity, commit or otherwise, since it was written 4h ago).
old=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
python3 - "$PRD2" "$old" <<'PYEOF'
import re, sys
f, old = sys.argv[1], sys.argv[2]
with open(f) as fh: txt = fh.read()
txt = re.sub(r'^- Lane: .*$', f'- Lane: carbon {old}', txt, flags=re.M)
with open(f, 'w') as fh: fh.write(txt)
PYEOF
git -C "$ROOT/clone2" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$ROOT/clone2" -c user.name=t -c user.email=t@t commit -q -m backdate
git -C "$ROOT/clone2" push -q origin "$BR"
git -C "$ROOT/clone" pull -q --rebase >/dev/null
# carbon is a fake fleet hostname with no real network presence in this
# scratch/CI environment — pin it reachable so the fixture exercises the
# "reachable, no commit/iter_log/pid signal -> stale" path (AC4) rather
# than the unrelated AC5 unreachable->unknown path (covered separately
# below).
out=$(LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes" "$LC" claim "$PRD" redbaron)
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

echo "== burst-lane override (PRD-build-burst-lane-ccx53 requirement 7): a rust target with a live session uses the box's sub-cap, not SAME_LANE_SUBCAP =="
RUST_TARGET="$ROOT/rust-target-repo"
mkdir -p "$RUST_TARGET"
cat > "$RUST_TARGET/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
EOF

FAKE_BURST="$ROOT/fake-burst-lane.sh"
cat > "$FAKE_BURST" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "sub-cap" ] || { echo "unexpected: $*" >&2; exit 2; }
echo "${FAKE_BURST_OUT:-sub-cap=8 local=0 (avail_gb=120 nproc=32)}"
exit "${FAKE_BURST_RC:-0}"
EOF
chmod +x "$FAKE_BURST"

for n in 1 2 3 4 5 6 7 8 9; do
cat > "$ROOT/clone/build-queue/PRD-rust-$n.md" <<EOF
# PRD: rust-$n

- Status: queued
- build_target: rust-extend
- build_into: $RUST_TARGET
- build_priority: high
EOF
done
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-rust-prds
git -C "$ROOT/clone" push -q origin "$BR"

for n in 1 2 3 4 5 6 7; do
  BURST_LANE_SH="$FAKE_BURST" "$LC" claim "$ROOT/clone/build-queue/PRD-rust-$n.md" redbaron >/dev/null
done
RUST8="$ROOT/clone/build-queue/PRD-rust-8.md"
RUST9="$ROOT/clone/build-queue/PRD-rust-9.md"

echo "-- 7 same-lane claims live on a rust target (SAME_LANE_SUBCAP=3 would already block); fake box sub-cap=8 still admits the 8th candidate --"
out=$(BURST_LANE_SH="$FAKE_BURST" "$LC" target-busy "$RUST_TARGET" --lane redbaron --exclude-prd "$RUST8" --prd-dir "$ROOT/clone")
[ "$out" = "free" ] || { echo "FAIL expected free under burst sub-cap=8, got: $out"; exit 1; }
echo ok

BURST_LANE_SH="$FAKE_BURST" "$LC" claim "$RUST8" redbaron >/dev/null

echo "-- 8th claimed (8 live, at the fake box's sub-cap=8); a 9th candidate is now blocked with the box's own number, not the local 3 --"
set +e
out=$(BURST_LANE_SH="$FAKE_BURST" "$LC" target-busy "$RUST_TARGET" --lane redbaron --exclude-prd "$RUST9" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 8 same-lane claims already live' || { echo "FAIL expected sub-cap=8 message, got: $out"; exit 1; }
echo ok

echo "-- same target WITHOUT the override (BURST_LANE_SH unset -> real burst-lane.sh, no session up here) falls back to local SAME_LANE_SUBCAP=3 and blocks the 9th --"
# Isolate from whatever the REAL burst-lane.sh sees on this host: BURST_LANE_SH
# is deliberately unset (this sub-test proves the real script's own no-session
# fallback, not the fake's), but a real box may genuinely be up on this
# machine right now (PRD-build-burst-lane-ccx53's own session) — without an
# isolated state dir, real burst-lane.sh would read the REAL session.json and
# report the real box's sub-cap instead of "no session," making this
# assertion depend on ambient host state rather than the code path under
# test. Point it at an empty scratch dir so "no session" is deterministic.
set +e
out=$(BURST_LANE_STATE_DIR="$ROOT/no-real-session-state" "$LC" target-busy "$RUST_TARGET" --lane redbaron --exclude-prd "$RUST9" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1 (no-session fallback), got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 3 same-lane claims already live' || { echo "FAIL expected local sub-cap=3 message, got: $out"; exit 1; }
echo ok

echo "-- fake box reporting only 40GB/16 cores (sub-cap=6): 8 live claims already exceed 6, candidate blocked with the box's own number --"
set +e
out=$(BURST_LANE_SH="$FAKE_BURST" FAKE_BURST_OUT="sub-cap=6 local=0 (avail_gb=40 nproc=16)" "$LC" target-busy "$RUST_TARGET" --lane redbaron --exclude-prd "$RUST9" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 6 same-lane claims already live' || { echo "FAIL expected sub-cap=6 message, got: $out"; exit 1; }
echo ok

echo "-- burst override only applies to rust (Cargo.toml) targets: the same fake box (sub-cap=8) has no effect on the earlier non-rust wedge target, local SAME_LANE_SUBCAP=3 still governs --"
set +e
out=$(BURST_LANE_SH="$FAKE_BURST" "$LC" target-busy /tmp/wedge-target-repo --lane redbaron --exclude-prd "$WEDGE_D" --prd-dir "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected sub-cap busy exit 1 (non-rust unaffected), got $rc: $out"; exit 1; }
echo "$out" | grep -q '^sub-cap: 3 same-lane claims already live' || { echo "FAIL expected local sub-cap=3 message on non-rust target, got: $out"; exit 1; }
echo ok

SCHEMA="$(cd "$(dirname "$LC")" && pwd)/lane-claim.schema.json"
validate_schema() {
  # $1 = json text on stdin's behalf (passed as arg to keep call sites simple)
  python3 -c '
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
doc = json.loads(sys.argv[2])
jsonschema.validate(instance=doc, schema=schema)
' "$SCHEMA" "$1"
}

echo "== AC1/AC7: --json reproduces-then-fixes the old invalid output, schema_version present =="
# The pre-fix defect (handoff 2026-09-12 follow-up 4, also documented in
# manifest-invariants.sh's own NOTE workaround comment) was that
# `status --json`'s "stale" field was an unquoted bare word (yes/no) --
# not a JSON boolean, not a string -- so `jq -e .` rejected EVERY
# invocation, not just adversarial ones. Reproduce that shape first (AC1's
# own reproduction requirement), pin it as the broken fixture, then show
# the real command no longer emits it.
broken_fixture='{"claimed":true,"lane":"carbon","ts":"2026-09-01T00:00:00Z","age_seconds":99,"stale":yes}'
if echo "$broken_fixture" | jq -e . >/dev/null 2>&1; then
  echo "FAIL fixture: expected the pinned pre-fix shape to be invalid JSON"; exit 1
fi
echo ok

json=$("$LC" status "$PRD" --json)
echo "$json" | jq -e . >/dev/null || { echo "FAIL status --json invalid: $json"; exit 1; }
echo "$json" | jq -e '.schema_version == 1' >/dev/null || { echo "FAIL schema_version: $json"; exit 1; }
validate_schema "$json" || { echo "FAIL status --json failed schema validation: $json"; exit 1; }
echo ok

bulk=$("$LC" --json --prd-dir "$ROOT/clone")
echo "$bulk" | jq -e . >/dev/null || { echo "FAIL --json invalid: $bulk"; exit 1; }
echo "$bulk" | jq -e '.schema_version == 1 and (.claims | type == "array")' >/dev/null \
  || { echo "FAIL --json shape: $bulk"; exit 1; }
validate_schema "$bulk" || { echo "FAIL --json failed schema validation: $bulk"; exit 1; }
echo "$LC claims" alias:
"$LC" claims --prd-dir "$ROOT/clone" | jq -e '.claims | length >= 1' >/dev/null \
  || { echo "FAIL claims alias"; exit 1; }
echo ok

echo "== AC2: quotes and UTF-8 in the prd path round-trip exactly through --json =="
mkdir -p "$ROOT/clone/build-queue"
QUOTE_PRD="$ROOT/clone/build-queue/PRD-quote\"embed.md"
cat > "$QUOTE_PRD" <<'EOF'
# PRD: quote-embed

- Status: queued
- build_target: shell
- build_priority: high
EOF
UTF8_PRD="$ROOT/clone/build-queue/PRD-caf\xc3\xa9-utf8.md"
UTF8_PRD=$(printf "$UTF8_PRD")
cat > "$UTF8_PRD" <<'EOF'
# PRD: utf8

- Status: queued
- build_target: shell
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-quote-utf8-fixtures
git -C "$ROOT/clone" push -q origin "$BR"
"$LC" claim "$QUOTE_PRD" redbaron >/dev/null
"$LC" claim "$UTF8_PRD" redbaron >/dev/null

bulk=$("$LC" --json --prd-dir "$ROOT/clone")
echo "$bulk" | jq -e . >/dev/null || { echo "FAIL bulk --json invalid with quote/utf8 fixtures: $bulk"; exit 1; }
validate_schema "$bulk" || { echo "FAIL bulk --json schema with quote/utf8 fixtures: $bulk"; exit 1; }
got_quote=$(echo "$bulk" | jq -r --arg p "$QUOTE_PRD" '.claims[] | select(.prd == $p) | .prd')
[ "$got_quote" = "$QUOTE_PRD" ] || { echo "FAIL quote round-trip: got '$got_quote'"; exit 1; }
got_utf8=$(echo "$bulk" | jq -r --arg p "$UTF8_PRD" '.claims[] | select(.prd == $p) | .prd')
[ "$got_utf8" = "$UTF8_PRD" ] || { echo "FAIL utf8 round-trip: got '$got_utf8'"; exit 1; }
echo ok

echo "== AC3: age past threshold + iter_log activity -> long-running, not reclaimed =="
cat > "$ROOT/clone/build-queue/PRD-longrunning.md" <<'EOF'
# PRD: longrunning

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-longrunning
git -C "$ROOT/clone" push -q origin "$BR"
LR_PRD="$ROOT/clone/build-queue/PRD-longrunning.md"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$LR_PRD" building "redbaron $old"
git -C "$ROOT/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: longrunning lane=redbaron (fixture)"
git -C "$ROOT/clone" push -q origin "$BR"
# iter_log activity 5 minutes ago (AC3's own wording) -- written+committed
# AFTER the backdated claim commit, so the commit probe also fires; either
# probe alone is sufficient for long-running, this exercises both at once.
five_min_ago=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
printf -- '- iter_log: %s still iterating\n' "$five_min_ago" >> "$LR_PRD"
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "iter_log: longrunning progress"
git -C "$ROOT/clone" push -q origin "$BR"

st=$("$LC" status "$LR_PRD" --json)
echo "$st" | jq -e '.state == "long-running" and .stale == false' >/dev/null \
  || { echo "FAIL expected long-running state: $st"; exit 1; }
set +e
out=$("$LC" claim "$LR_PRD" carbon 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL expected long-running claim to stay held, got $rc: $out"; exit 1; }
echo "$out" | grep -q 'state=long-running' || { echo "FAIL expected state=long-running in held msg: $out"; exit 1; }
echo ok

echo "== AC3b: journal-only activity (no iter_log, no commit since claim) also reads long-running =="
JOURNAL_DIR=$(mktemp -d /tmp/lane-claim-journal.XXXXXX)
trap 'rm -rf "$ROOT" "$JOURNAL_DIR"' EXIT
cat > "$ROOT/clone/build-queue/PRD-journalonly.md" <<'EOF'
# PRD: journalonly

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-journalonly
git -C "$ROOT/clone" push -q origin "$BR"
JO_PRD="$ROOT/clone/build-queue/PRD-journalonly.md"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$JO_PRD" building "redbaron $old"
git -C "$ROOT/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: journalonly lane=redbaron (fixture)"
git -C "$ROOT/clone" push -q origin "$BR"
five_min_ago=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
printf '%s  journalonly  tick  progress  (lane=redbaron)\n' "$five_min_ago" > "$JOURNAL_DIR/today.md"

st=$(JOURNAL_DIR="$JOURNAL_DIR" "$LC" status "$JO_PRD" --json)
echo "$st" | jq -e '.state == "long-running"' >/dev/null \
  || { echo "FAIL expected journal-driven long-running: $st"; exit 1; }
echo ok

echo "== AC4: reclaimed only when EVERY probe is negative, journal line names them all =="
cat > "$ROOT/clone/build-queue/PRD-deadclaim.md" <<'EOF'
# PRD: deadclaim

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-deadclaim
git -C "$ROOT/clone" push -q origin "$BR"
DC_PRD="$ROOT/clone/build-queue/PRD-deadclaim.md"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$DC_PRD" building "carbon $old"
git -C "$ROOT/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: deadclaim lane=carbon (fixture)"
git -C "$ROOT/clone" push -q origin "$BR"

st=$(LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes" "$LC" status "$DC_PRD" --json)
echo "$st" | jq -e '.state == "stale" and .stale == true' >/dev/null \
  || { echo "FAIL expected stale state for genuinely dead claim: $st"; exit 1; }

out=$(LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes" "$LC" claim "$DC_PRD" redbaron)
echo "$out" | grep -q '^reclaim-receipt: prev_lane=carbon' || { echo "FAIL reclaim-receipt: $out"; exit 1; }
for probe in 'reachable=yes' 'commit=no' 'iter_log=no'; do
  echo "$out" | grep -q "$probe" || { echo "FAIL reclaim-receipt missing probe '$probe': $out"; exit 1; }
done
echo ok

echo "== AC5: unreachable claiming host -> unknown, never reclaimed =="
cat > "$ROOT/clone/build-queue/PRD-unreachable.md" <<'EOF'
# PRD: unreachable

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-unreachable
git -C "$ROOT/clone" push -q origin "$BR"
UR_PRD="$ROOT/clone/build-queue/PRD-unreachable.md"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$UR_PRD" building "ryzen7 $old"
git -C "$ROOT/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: unreachable lane=ryzen7 (fixture, ryzen7 off)"
git -C "$ROOT/clone" push -q origin "$BR"

st=$(LANE_CLAIM_REACHABLE_OVERRIDE="ryzen7=no" "$LC" status "$UR_PRD" --json)
echo "$st" | jq -e '.state == "unknown" and .stale == false' >/dev/null \
  || { echo "FAIL expected unknown state for unreachable host: $st"; exit 1; }

set +e
out=$(LANE_CLAIM_REACHABLE_OVERRIDE="ryzen7=no" "$LC" claim "$UR_PRD" redbaron 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL expected unknown claim to stay held (never reclaimed), got $rc: $out"; exit 1; }
echo "$out" | grep -q 'state=unknown' || { echo "FAIL expected state=unknown in held msg: $out"; exit 1; }
echo ok

echo "== AC6 (P1): lint-reclaims flags a reclaim journal line with no recorded probes =="
LINTJ=$(mktemp /tmp/lane-claim-lintjournal.XXXXXX)
cat > "$LINTJ" <<'EOF'
2026-09-12T10:00:00Z  good-prd  claim  reclaimed  (prd=good-prd age=99s probes: commit=no iter_log=no pid=no journal=no)
2026-09-12T10:05:00Z  bad-prd  claim  reclaimed  (prd=bad-prd age=99s)
EOF
set +e
"$LC" lint-reclaims "$LINTJ" > /tmp/lintout.txt 2>&1; rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected lint-reclaims to flag exactly 1 bad line, got exit $rc: $(cat /tmp/lintout.txt)"; exit 1; }
grep -q 'bad-prd' /tmp/lintout.txt || { echo "FAIL lint-reclaims didn't name the bad line: $(cat /tmp/lintout.txt)"; exit 1; }
! grep -q 'good-prd' /tmp/lintout.txt || { echo "FAIL lint-reclaims flagged a good line: $(cat /tmp/lintout.txt)"; exit 1; }
rm -f "$LINTJ" /tmp/lintout.txt
echo ok

echo "ALL SELFTESTS PASSED"
