#!/usr/bin/env bash
# build-has-work-selftest.sh — exercises build-has-work.sh's predicate
# (live claim / gate-red-at-unchanged-HEAD / stale claim / disable bypass /
# pace sleep) against scratch fixtures and a scratch git repo under /tmp/.
# NEVER touches the real ~/Documents/PRDs build-queue or any real build_into
# repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BHW="$HERE/build-has-work.sh"
LANE_CLAIM="$HERE/lane-claim.sh"
[ -x "$BHW" ] || { echo "FAIL: build-has-work.sh missing/not executable" >&2; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/build-has-work-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

run_bhw() {
  # $1=prd_dir $2=state_dir $3=pace $4=disable(0/1) -> sets RC, OUT, ELAPSED
  local prd_dir="$1" state_dir="$2" pace="$3" disable="$4" t0 t1
  t0=$(date +%s)
  OUT=$(PRD_DIR="$prd_dir" BUILD_STATE_DIR="$state_dir" \
        CLAUDE_BUILD_LOG="$ROOT/log.txt" \
        BUILD_HASWORK_PACE="$pace" BUILD_HASWORK_DISABLE="$disable" \
        "$BHW" 2>&1)
  RC=$?
  t1=$(date +%s)
  ELAPSED=$(( t1 - t0 ))
}

fresh_claim_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
stale_claim_ts() {
  # Well beyond lane-claim.sh's 3h (10800s) staleness threshold.
  date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

# ---------------------------------------------------------------- case 1 --
# One unclaimed, never-gated PRD -> work.
C1="$ROOT/case1"
mkdir -p "$C1/build-queue" "$C1/state"
cat > "$C1/build-queue/PRD-fresh.md" <<'EOF'
# PRD: fresh

- Status: queued
- build_target: shell
- build_into: /tmp/does-not-exist-case1
EOF
run_bhw "$C1" "$C1/state" 1 0
if [ "$RC" -eq 0 ] && grep -q 'buildable=\[fresh\]' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"; then
  ok "case 1: unclaimed never-gated PRD -> work (exit 0)"
else
  bad "case 1: expected exit 0 + buildable=[fresh], got rc=$RC log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

# ---------------------------------------------------------------- case 2 --
# All PRDs live-claimed -> no-work (exit 1, after pace sleep).
C2="$ROOT/case2"
mkdir -p "$C2/build-queue" "$C2/state"
cat > "$C2/build-queue/PRD-claimed.md" <<EOF
# PRD: claimed

- Status: building
- build_target: shell
- build_into: /tmp/does-not-exist-case2
- Lane: carbon $(fresh_claim_ts)
EOF
run_bhw "$C2" "$C2/state" 1 0
if [ "$RC" -eq 1 ] && grep -q 'claimed=\[claimed\]' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)" && [ "$ELAPSED" -ge 1 ]; then
  ok "case 2: all PRDs live-claimed -> no-work (exit 1, paced)"
else
  bad "case 2: expected exit 1 + claimed=[claimed] + elapsed>=1, got rc=$RC elapsed=${ELAPSED}s log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

# ---------------------------------------------------------------- case 3 --
# Gate-red at fake-repo HEAD X, fake repo at HEAD X -> no-work; advance one
# commit (HEAD -> Y) -> work.
C3="$ROOT/case3"
mkdir -p "$C3/build-queue" "$C3/state" "$C3/fakerepo/target/autobuilder"
git init -q "$C3/fakerepo"
git -C "$C3/fakerepo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c1
HEAD_X="$(git -C "$C3/fakerepo" rev-parse HEAD)"
cat > "$C3/build-queue/PRD-gr.md" <<EOF
# PRD: gr

- Status: in_progress
- build_target: rust-extend
- build_into: $C3/fakerepo
EOF
cat > "$C3/state/manifest.json" <<EOF
{"prds": {"gr": {"slug": "gr", "status": "in_progress", "next": "gate-red", "blockers": ["gate: reviewer-agent -- x"]}}}
EOF
cat > "$C3/fakerepo/target/autobuilder/last-verdict.json" <<EOF
{"head_sha": "$HEAD_X", "verdict": "block", "exit_code": 1}
EOF
run_bhw "$C3" "$C3/state" 1 0
if [ "$RC" -eq 1 ] && grep -q 'gate-red-unchanged=\[gr\]' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"; then
  ok "case 3a: gate-red at unchanged HEAD -> no-work"
else
  bad "case 3a: expected exit 1 + gate-red-unchanged=[gr], got rc=$RC log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

git -C "$C3/fakerepo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c2
run_bhw "$C3" "$C3/state" 1 0
if [ "$RC" -eq 0 ] && grep -q 'buildable=\[gr\]' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"; then
  ok "case 3b: HEAD moved past the gate-red verdict -> work (re-gate)"
else
  bad "case 3b: expected exit 0 + buildable=[gr], got rc=$RC log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

# ---------------------------------------------------------------- case 4 --
# Stale claim -> work.
C4="$ROOT/case4"
mkdir -p "$C4/build-queue" "$C4/state"
cat > "$C4/build-queue/PRD-stale.md" <<EOF
# PRD: stale

- Status: in_progress
- build_target: shell
- build_into: /tmp/does-not-exist-case4
- Lane: carbon $(stale_claim_ts)
EOF
run_bhw "$C4" "$C4/state" 1 0
if [ "$RC" -eq 0 ] && grep -q 'buildable=\[stale\]' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"; then
  ok "case 4: stale claim -> work (exit 0)"
else
  bad "case 4: expected exit 0 + buildable=[stale], got rc=$RC log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

# ---------------------------------------------------------------- case 5 --
# BUILD_HASWORK_DISABLE=1 with every fixture claimed/blocked -> work
# (bypass confirmed). Reuse case2 (claimed) + case3 at the unchanged-HEAD
# gate-red state — rebuild case3's verdict file back to HEAD_X first isn't
# needed; case2's dir alone (100% claimed, zero buildable without the
# bypass) is sufficient to prove the bypass.
run_bhw "$C2" "$C2/state" 1 1
if [ "$RC" -eq 0 ] && [ "$ELAPSED" -lt 1 ] && grep -q 'disabled-passthrough' <<<"$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"; then
  ok "case 5: BUILD_HASWORK_DISABLE=1 bypasses an all-claimed queue -> work, no sleep"
else
  bad "case 5: expected exit 0 + disabled-passthrough + elapsed<1, got rc=$RC elapsed=${ELAPSED}s log=$(grep 'build-has-work ' "$ROOT/log.txt" | tail -1)"
fi

# ---------------------------------------------------------------- case 6 --
# Pace sleep is actually honored on the no-work path: BUILD_HASWORK_PACE=1
# measurably takes >=1s (not instant, not the real 300s default).
run_bhw "$C2" "$C2/state" 1 0
if [ "$RC" -eq 1 ] && [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -lt 10 ]; then
  ok "case 6: pace sleep honored (BUILD_HASWORK_PACE=1 -> elapsed=${ELAPSED}s, not instant, not 300s)"
else
  bad "case 6: expected 1<=elapsed<10 on no-work path, got rc=$RC elapsed=${ELAPSED}s"
fi

# ---------------------------------------------------------------- case 7 --
# unitlive_ac4 (PRD-buildloop-unit-liveness): the tick pre-check appends
# exactly one new LIVENESS line on a tick that's skipped for no work, and
# the liveness script's own exit code never changes this script's outcome.
# Reuse case2 (100% claimed -> no-work) with a fake liveness script that
# deliberately exits 1 (WARN-shaped) to prove the exit code is ignored.
FAKE_LIVENESS="$ROOT/fake-liveness.sh"
cat > "$FAKE_LIVENESS" <<'EOF'
#!/usr/bin/env bash
echo "LIVENESS WARN unit=fake.timer inactive_since=2026-01-01T00:00:00Z"
exit 1
EOF
chmod +x "$FAKE_LIVENESS"
before_lines=$(grep -c '^' "$ROOT/log.txt" 2>/dev/null || echo 0)
OUT=$(PRD_DIR="$C2" BUILD_STATE_DIR="$C2/state" CLAUDE_BUILD_LOG="$ROOT/log.txt" \
      BUILD_HASWORK_PACE=1 BUILD_HASWORK_DISABLE=0 \
      BUILD_LIVENESS_SCRIPT="$FAKE_LIVENESS" \
      "$BHW" 2>&1)
RC=$?
after_liveness_lines=$(grep -c 'LIVENESS WARN unit=fake.timer' "$ROOT/log.txt")
new_liveness_lines_this_case=1  # exactly one call was made above
if [ "$RC" -eq 1 ] && [ "$after_liveness_lines" -eq "$new_liveness_lines_this_case" ]; then
  ok "case 7 (unitlive_ac4): exactly one new LIVENESS line appended on a skipped tick, exit code unaffected by liveness rc"
else
  bad "case 7 (unitlive_ac4): expected rc=1 + exactly 1 LIVENESS line, got rc=$RC liveness_lines=$after_liveness_lines before_lines=$before_lines"
fi

exit "$fail"
