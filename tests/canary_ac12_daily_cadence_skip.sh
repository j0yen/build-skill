#!/usr/bin/env bash
# tests/canary_ac12_daily_cadence_skip.sh — PRD-build-burst-gate-canary-
# invariant AC12: given a routed --scope main gate at a green HEAD passed
# 3h ago, the daily timer's own entrypoint (`canary-daily`) skips with
# `canary skipped (cause=recent-routed-pass head=... age_h=...)` and NEVER
# reaches head resolution (proven by leaving CANARY_REPO pointed at a
# nonexistent path — a real attempt to run would blow up there, not
# silently succeed); given the last such pass is 25h old, it proceeds PAST
# the skip check (proven by reaching canary_resolve_head's own
# cause=no-green-head refusal against a fixture repo with red main and no
# tags — a distinct, unambiguous signal that execution moved past the
# cadence gate). Pure fixture: no real box, no gate run, no network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac12.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"

BOX_DIR="$BURST_LANE_STATE_DIR/current"
mkdir -p "$BOX_DIR"
echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$BOX_DIR/session.json"

echo "== AC12 part 1: recent-routed-pass (3h old) -> skip, never touches CANARY_REPO =="
three_h_ago="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BOX_DIR/canary-last-routed-main-pass.json" <<EOF
{"head": "abc123head", "ts": "$three_h_ago"}
EOF
: > "$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$ROOT/does-not-exist"
set +e
out="$("$BL" canary-daily 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0, got $rc: $out"; exit 1; }
grep -qE 'canary  skipped  \(cause=recent-routed-pass head=abc123head age_h=[0-9.]+\)' "$BURST_LANE_JOURNAL" \
  || { echo "FAIL: journal missing recent-routed-pass skip line:"; cat "$BURST_LANE_JOURNAL"; exit 1; }
echo "ok  skipped without ever touching a (nonexistent) CANARY_REPO"

echo "== AC12 part 2: last pass is 25h old -> proceeds past the cadence gate =="
twentyfive_h_ago="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BOX_DIR/canary-last-routed-main-pass.json" <<EOF
{"head": "abc123head", "ts": "$twentyfive_h_ago"}
EOF

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/fixture/repo.git

fake_gh="$ROOT/fake-gh"
cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
# Red main, no tags on the fixture repo -- canary_resolve_head refuses
# with cause=no-green-head. Reaching THIS refusal (rather than the
# recent-routed-pass skip) is the proof that the 25h-old case runs.
echo '[{"status":"completed","conclusion":"failure","headSha":"deadbeef"}]'
EOF
chmod +x "$fake_gh"

export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_GH="$fake_gh"
: > "$BURST_LANE_JOURNAL"
set +e
out="$("$BL" canary-daily 2>&1)"; rc=$?
set -e
[ "$rc" -eq 4 ] || { echo "FAIL: expected exit 4 (no-green-head), got $rc: $out"; exit 1; }
grep -q "canary  skipped  (cause=recent-routed-pass" "$BURST_LANE_JOURNAL" \
  && { echo "FAIL: 25h-old pass should NOT be treated as recent"; exit 1; }
grep -q "canary  refused  (cause=no-green-head)" "$BURST_LANE_JOURNAL" \
  || { echo "FAIL: expected no-green-head refusal proving execution ran; journal:"; cat "$BURST_LANE_JOURNAL"; exit 1; }
echo "ok  25h-old pass does not skip; canary-daily reached head resolution"

echo "canary_ac12_daily_cadence_skip: ALL PASS"
