#!/usr/bin/env bash
# tests/canary_ac11_last_green_tag.sh — PRD-build-burst-gate-canary-invariant
# AC11: given mcphost main red and a tag whose CI was green, `canary` (via
# canary_resolve_head) resolves to that tag's sha with head_source=
# last-green-tag — and, when the NEWEST tag is also red, falls through to
# an OLDER green tag rather than stopping at the first (newest) one (R1:
# "the newest tag whose CI was green"). Pure fixture, no real box/network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac11.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/fixture/repo.git
# v1.2.0 (older, green) then v1.3.0 (newer, red) — creatordate ordering
# needs the two tag commands to land in distinct seconds.
git -C "$repo" tag v1.2.0
sleep 1.1
git -C "$repo" tag v1.3.0

fake_gh="$ROOT/fake-gh"
cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) branch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$branch" in
  main)    echo '[{"status":"completed","conclusion":"failure","headSha":"reddeadbeef"}]' ;;
  v1.3.0)  echo '[{"status":"completed","conclusion":"failure","headSha":"newtagredsha"}]' ;;
  v1.2.0)  echo '[{"status":"completed","conclusion":"success","headSha":"oldtaggreensha"}]' ;;
  *)       echo '[]' ;;
esac
EOF
chmod +x "$fake_gh"

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"; mkdir -p "$BURST_LANE_STATE_DIR/current"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_GH="$fake_gh"

echo "== AC11: red main + red newest tag -> falls through to older green tag =="
set +e
out="$("$BL" _debug-canary-resolve-head "$repo" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0, got $rc: $out"; exit 1; }
[ "$out" = "oldtaggreensha last-green-tag" ] || { echo "FAIL: unexpected output: $out"; exit 1; }
echo ok
