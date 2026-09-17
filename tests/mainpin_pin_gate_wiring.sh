#!/usr/bin/env bash
# tests/mainpin_pin_gate_wiring.sh — PRD-build-main-verdict-pinned-to-landing
# R2/AC1/AC5/AC7: main-verdict-pin-gate.sh (the new wrapper this step
# adds) is the thing a post-land re-verify calls instead of ever gating
# the checkout's current HEAD. This test fakes extend-gate.sh (same
# convention gate-then-land-selftest.sh already uses — a real gate run is
# 60-90s+ of cargo/autobuilder producers, which is not what THIS script's
# own wiring needs exercised) so it stays fast and isolated, and checks:
#
#   AC-wiring-1: a DETACHED worktree at M (never the checkout itself) is
#     created under $BUILD_WT_ROOT, named <repo>-<slug>-verify, and is
#     gone again after the run (pass or block).
#   AC-wiring-2: extend-gate.sh is invoked against that worktree path,
#     never the checkout, with exactly --head M --scope main --slug S
#     --base <M's first parent> --pinned-landing.
#   AC7: a landing record landing-verdict-resolve.sh cannot resolve M for
#     (no merge_sha, and the landing-check fallback also fails) makes
#     this script exit 4 WITHOUT ever invoking extend-gate.sh — no HEAD
#     gate as a silent fallback.
#
# Everything lives under $TMPDIR; BUILD_STATE_DIR/BUILD_WT_ROOT point at
# this test's own tree, never the running skill's production state/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
PIN_GATE="$HERE/main-verdict-pin-gate.sh"
LANDING_RESOLVE="$HERE/landing-verdict-resolve.sh"
[ -x "$PIN_GATE" ] || { echo "selftest: $PIN_GATE not executable" >&2; exit 2; }
[ -x "$LANDING_RESOLVE" ] || { echo "selftest: $LANDING_RESOLVE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-pin-gate-wiring.XXXXXX")"
trap '[ -n "${MAINPIN_PIN_GATE_WIRING_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c1 (base)"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c2 (the landing, M)"
M_SHA="$(git -C "$REPO" rev-parse HEAD)"
REPO_SLUG="$(basename "$REPO")"

STATE_DIR="$T/state"
WT_ROOT="$T/wtroot"
mkdir -p "$STATE_DIR/landings/$REPO_SLUG" "$WT_ROOT"

SLUG="mainpin-wiring-fixture"
cat > "$STATE_DIR/landings/$REPO_SLUG/$SLUG.json" <<EOF
{"pr_number": 1, "merge_sha": "$M_SHA", "armed_at": "2026-09-17T00:00:00Z"}
EOF

FAKE_EXTEND_GATE="$T/fake-extend-gate.sh"
ARGS_LOG="$T/fake-args.log"
export ARGS_LOG
cat > "$FAKE_EXTEND_GATE" <<'EOF'
#!/usr/bin/env bash
# Records: the worktree path this ran against, its actual HEAD, and every
# arg it was called with — enough for the wiring test to check without
# running a single real producer.
{
  echo "argv: $*"
  echo "arg1_dir: $1"
  echo "arg1_head: $(git -C "$1" rev-parse HEAD 2>/dev/null || echo NOGIT)"
} >> "$ARGS_LOG"
exit 0
EOF
chmod +x "$FAKE_EXTEND_GATE"

echo "=== AC-wiring: main-verdict-pin-gate.sh $REPO $SLUG (fake extend-gate.sh) ==="
env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" \
    MAIN_VERDICT_PIN_GATE_EXTEND_GATE="$FAKE_EXTEND_GATE" \
    "$PIN_GATE" "$REPO" "$SLUG" >"$T/out.log" 2>&1
rc=$?
cat "$T/out.log"
expect "AC-wiring: exits 0 (fake extend-gate.sh's own exit)" "[ $rc -eq 0 ]"

expected_wt="$WT_ROOT/${REPO_SLUG}-${SLUG}-verify"
expect "AC-wiring-1: fake extend-gate.sh was called against the detached worktree path, not \$REPO" \
  "grep -q \"^arg1_dir: $expected_wt\$\" \"$ARGS_LOG\""
expect "AC-wiring-1: the worktree's HEAD at call time was M ($M_SHA), never \$REPO's own state" \
  "grep -q \"^arg1_head: $M_SHA\$\" \"$ARGS_LOG\""
expect "AC-wiring-1: the detached worktree is removed again after the run" \
  "[ ! -d \"$expected_wt\" ]"
expect "AC-wiring-1: \$REPO's own checkout was never touched (still at M, the tip)" \
  "[ \"\$(git -C \"$REPO\" rev-parse HEAD)\" = \"$M_SHA\" ]"

argv_line="$(grep '^argv: ' "$ARGS_LOG" | tail -1)"
expect "AC-wiring-2: extend-gate.sh called with --head M" "printf '%s' \"$argv_line\" | grep -q -- \"--head $M_SHA\""
expect "AC-wiring-2: extend-gate.sh called with --scope main" "printf '%s' \"$argv_line\" | grep -q -- '--scope main'"
expect "AC-wiring-2: extend-gate.sh called with --slug $SLUG" "printf '%s' \"$argv_line\" | grep -q -- \"--slug $SLUG\""
expect "AC-wiring-2: extend-gate.sh called with --base <M's first parent>" "printf '%s' \"$argv_line\" | grep -q -- \"--base $BASE_SHA\""
expect "AC-wiring-2: extend-gate.sh called with --pinned-landing" "printf '%s' \"$argv_line\" | grep -q -- '--pinned-landing'"

echo "=== AC7: an unusable landing record never invokes extend-gate.sh ==="
BAD_SLUG="mainpin-wiring-unusable"
cat > "$STATE_DIR/landings/$REPO_SLUG/$BAD_SLUG.json" <<'EOF'
{"pr_number": 2}
EOF
FAKE_BRANCH_PROTECTION="$T/fake-branch-protection.sh"
cat > "$FAKE_BRANCH_PROTECTION" <<'EOF'
#!/usr/bin/env bash
# Simulates "landing-check" never confirming a merge (pending/red/closed
# all read the same to R7 here) — always a non-zero exit, never merged.
exit 3
EOF
chmod +x "$FAKE_BRANCH_PROTECTION"
before_count="$(wc -l < "$ARGS_LOG")"
env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" \
    MAIN_VERDICT_PIN_GATE_EXTEND_GATE="$FAKE_EXTEND_GATE" \
    LANDING_VERDICT_RESOLVE_BRANCH_PROTECTION="$FAKE_BRANCH_PROTECTION" \
    "$PIN_GATE" "$REPO" "$BAD_SLUG" >"$T/out2.log" 2>&1
rc2=$?
cat "$T/out2.log"
after_count="$(wc -l < "$ARGS_LOG")"
expect "AC7: an unusable landing record exits 4 (landing-verdict-resolve.sh's own exit, propagated)" "[ $rc2 -eq 4 ]"
expect "AC7: extend-gate.sh was never invoked for the unusable record (no new argv line)" "[ \"$before_count\" = \"$after_count\" ]"
expect "AC7: no stray worktree left behind for the failed slug" "[ ! -d \"$WT_ROOT/${REPO_SLUG}-${BAD_SLUG}-verify\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_pin_gate_wiring: ALL PASS"
  exit 0
else
  echo "mainpin_pin_gate_wiring: assertion(s) FAILED"
  exit 1
fi
