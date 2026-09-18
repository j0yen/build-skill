#!/usr/bin/env bash
# tests/canaryliv_ac17_refusal_cost_bounded.sh — PRD-build-burst-canary-
# live-parity R9/AC17: "Given the fake gate-launch that exits 1 in two
# seconds, When the canary refuses, Then the canary cost line reports
# <= 2 minutes."
#
# Same fake-gate-launch fixture shape as canaryliv_ac2 (AC2's "gate exits
# 1 in <2s, leaves only stale receipts" scenario, the exact 2026-09-18
# 04:36Z shape) -- AC2 proves the refusal itself (exit 4, baseline-failed);
# this test proves the cost line burst-lane.sh already emits on that same
# refusal path (scripts/burst-lane.sh ~line 5011, "AC17: the canary cost
# line reports <= 2 minutes on exactly this refusal") actually reports a
# bounded number, not just that a line exists.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

echo "== AC17: baseline-failed refusal still journals a cost line, bounded <= 2 minutes =="
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac17.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head_sha="$(git -C "$repo" rev-parse HEAD)"

fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<'EOF'
#!/usr/bin/env bash
repo="$1"
mkdir -p "$repo/target/autobuilder/receipts"
i=0
while [ "$i" -lt 5 ]; do
  f="$repo/target/autobuilder/receipts/stale-$i.json"
  echo '{"schema":"autobuilder.extended_receipts.v1","verdict":"pass"}' > "$f"
  touch -d "@$(( $(date +%s) - 3600 ))" "$f"
  i=$((i + 1))
done
sleep 2
exit 1
EOF
chmod +x "$fake_gl"

wt_root="$ROOT/wt-root"
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
export BURST_LANE_CANARY_WORKTREE_ROOT="$wt_root"
export BURST_LANE_CANARY_GATE_STATUS="/bin/true"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox-ac17","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

t0=$(date +%s)
set +e
"$BL" canary --head "$head_sha" --variants main >/dev/null 2>&1
rc=$?
set -e
t1=$(date +%s)
echo "  wall: $((t1 - t0))s"

expect "AC17 precondition: canary exits 4 on baseline-failed refusal (same as AC2)" "[ '$rc' -eq 4 ]"
expect "AC17 precondition: refusal finished well within 120s (R9)" "[ $((t1 - t0)) -lt 120 ]"

cost_line="$(grep '  canary  cost  ' "$BURST_LANE_JOURNAL" 2>/dev/null | head -1 || true)"
echo "  cost line: ${cost_line:-<none>}"
expect "AC17: a canary cost line was journaled for the refusal" "[ -n \"\$cost_line\" ]"

minutes="$(printf '%s' "$cost_line" | grep -oE 'minutes=[0-9]+' | cut -d= -f2)"
echo "  cost minutes: ${minutes:-<not found>}"
expect "AC17: cost line reports <= 2 minutes" "[ -n \"\$minutes\" ] && [ \"\$minutes\" -le 2 ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac17_refusal_cost_bounded: ALL PASS"
else
  echo "canaryliv_ac17_refusal_cost_bounded: FAILED" >&2
fi
exit "$fail"
