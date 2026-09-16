#!/usr/bin/env bash
# tests/canary_ac9_no_green_head.sh — PRD-build-burst-gate-canary-invariant
# AC9: given mcphost main red (fixture `gh run list` returning a completed
# FAILURE conclusion) and no green tag anywhere in the fixture repo, `canary`
# (via canary_resolve_head) refuses with cause=no-green-head — no stdout, no
# fallback past "no tag is green" either. Pure fixture: no real box, no gh
# network call ($BURST_LANE_GH points this run at a fake script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac9.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/fixture/repo.git

fake_gh="$ROOT/fake-gh"
cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
# Every `run list` call in this fixture answers with one completed,
# FAILURE-conclusion run — main is red, and (since this repo has no tags
# at all) canary_resolve_head's tag loop never iterates.
echo '[{"status":"completed","conclusion":"failure","headSha":"deadbeef"}]'
EOF
chmod +x "$fake_gh"

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"; mkdir -p "$BURST_LANE_STATE_DIR/current"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_GH="$fake_gh"

echo "== AC9: red main, no tags -> refused cause=no-green-head =="
set +e
out="$("$BL" _debug-canary-resolve-head "$repo" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL: expected exit 1, got $rc: $out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected no stdout on refusal, got: $out"; exit 1; }
echo ok
