#!/usr/bin/env bash
# tests/mainpin_pin_gate_concurrent_ac9.sh — PRD-build-main-verdict-
# pinned-to-landing AC9 (the piece main-verdict-pin-selftest.sh's own
# header calls out as still missing: "the concurrent-two-slugs-distinct-
# worktrees case").
#
# Two landed slugs S1 (merge sha M1) and S2 (merge sha M2, a LATER commit
# on the same repo) re-verify at the same time — the real-world shape
# this PRD exists for (gate-debt-4f1112d re-checked after agent-wake
# landed behind it, PRD TL;DR). Runs main-verdict-pin-gate.sh S1 and S2
# in the BACKGROUND, concurrently, against the SAME repo checkout, with a
# fake extend-gate.sh that sleeps briefly (widening the race window) and
# records argv + the worktree's actual HEAD at call time.
#
#   AC9-1: both runs exit 0 (fake extend-gate.sh's own exit).
#   AC9-2: each used its OWN worktree path (<repo>-<slug>-verify), never
#     collided or clobbered the other's.
#   AC9-3: each worktree's HEAD at call time was that slug's OWN M, never
#     the other slug's M (the exact failure this PRD fixes, replayed
#     under real concurrency rather than sequential calls).
#   AC9-4: neither worktree exists once both runs finish (cleanup ran for
#     both, independently).
#   AC9-5: git's own worktree registration is left internally consistent
#     — `git worktree list` shows the checkout itself and nothing else
#     once both finish (no orphaned lock/registration from the race).
#
# Everything lives under $TMPDIR; BUILD_STATE_DIR/BUILD_WT_ROOT point at
# this test's own tree, never the running skill's production state/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
PIN_GATE="$HERE/main-verdict-pin-gate.sh"
[ -x "$PIN_GATE" ] || { echo "selftest: $PIN_GATE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-pin-gate-concurrent.XXXXXX")"
trap '[ -n "${MAINPIN_PIN_GATE_CONCURRENT_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c0 (repo root)"

# S1 lands first, at M1.
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c1 (S1's landing, M1)"
M1_SHA="$(git -C "$REPO" rev-parse HEAD)"

# S2 lands behind it, at M2 — the "PRD landed further back on the main
# line than the repo's now-current HEAD" shape this whole PRD is for.
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c2 (S2's landing, M2, HEAD)"
M2_SHA="$(git -C "$REPO" rev-parse HEAD)"

REPO_SLUG="$(basename "$REPO")"
STATE_DIR="$T/state"
WT_ROOT="$T/wtroot"
mkdir -p "$STATE_DIR/landings/$REPO_SLUG" "$WT_ROOT"

S1="mainpin-concurrent-s1"
S2="mainpin-concurrent-s2"
cat > "$STATE_DIR/landings/$REPO_SLUG/$S1.json" <<EOF
{"pr_number": 1, "merge_sha": "$M1_SHA", "armed_at": "2026-09-17T00:00:00Z"}
EOF
cat > "$STATE_DIR/landings/$REPO_SLUG/$S2.json" <<EOF
{"pr_number": 2, "merge_sha": "$M2_SHA", "armed_at": "2026-09-17T00:05:00Z"}
EOF

# Fake extend-gate.sh: records argv + the worktree's HEAD, then sleeps a
# beat so two concurrent invocations genuinely overlap (widens the race
# window instead of trusting them to happen to interleave).
FAKE_EXTEND_GATE="$T/fake-extend-gate.sh"
cat > "$FAKE_EXTEND_GATE" <<'EOF'
#!/usr/bin/env bash
log="${ARGS_LOG_FOR:?}"
{
  echo "argv: $*"
  echo "arg1_dir: $1"
  echo "arg1_head: $(git -C "$1" rev-parse HEAD 2>/dev/null || echo NOGIT)"
} >> "$log"
sleep 0.3
exit 0
EOF
chmod +x "$FAKE_EXTEND_GATE"

LOG1="$T/args-s1.log"; : > "$LOG1"
LOG2="$T/args-s2.log"; : > "$LOG2"

echo "=== AC9: two slugs re-verifying concurrently against the same repo ==="
( env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" \
      MAIN_VERDICT_PIN_GATE_EXTEND_GATE="$FAKE_EXTEND_GATE" ARGS_LOG_FOR="$LOG1" \
      "$PIN_GATE" "$REPO" "$S1" >"$T/out1.log" 2>&1; echo $? > "$T/rc1" ) &
pid1=$!
( env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" \
      MAIN_VERDICT_PIN_GATE_EXTEND_GATE="$FAKE_EXTEND_GATE" ARGS_LOG_FOR="$LOG2" \
      "$PIN_GATE" "$REPO" "$S2" >"$T/out2.log" 2>&1; echo $? > "$T/rc2" ) &
pid2=$!
wait "$pid1" "$pid2"

cat "$T/out1.log"; cat "$T/out2.log"
rc1="$(cat "$T/rc1" 2>/dev/null || echo NA)"
rc2="$(cat "$T/rc2" 2>/dev/null || echo NA)"

expect "AC9-1: S1's run exits 0" "[ \"$rc1\" = 0 ]"
expect "AC9-1: S2's run exits 0" "[ \"$rc2\" = 0 ]"

wt1="$WT_ROOT/${REPO_SLUG}-${S1}-verify"
wt2="$WT_ROOT/${REPO_SLUG}-${S2}-verify"
expect "AC9-2: S1 used its own worktree path ($wt1)" "grep -q \"^arg1_dir: $wt1\$\" \"$LOG1\""
expect "AC9-2: S2 used its own worktree path ($wt2)" "grep -q \"^arg1_dir: $wt2\$\" \"$LOG2\""
expect "AC9-2: the two worktree paths are distinct" "[ \"$wt1\" != \"$wt2\" ]"

expect "AC9-3: S1's worktree HEAD at call time was M1, never M2" "grep -q \"^arg1_head: $M1_SHA\$\" \"$LOG1\""
expect "AC9-3: S1's log never recorded M2 as its HEAD" "! grep -q \"^arg1_head: $M2_SHA\$\" \"$LOG1\""
expect "AC9-3: S2's worktree HEAD at call time was M2, never M1" "grep -q \"^arg1_head: $M2_SHA\$\" \"$LOG2\""
expect "AC9-3: S2's log never recorded M1 as its HEAD" "! grep -q \"^arg1_head: $M1_SHA\$\" \"$LOG2\""

expect "AC9-4: S1's detached worktree is gone after both runs finish" "[ ! -d \"$wt1\" ]"
expect "AC9-4: S2's detached worktree is gone after both runs finish" "[ ! -d \"$wt2\" ]"

remaining_wt="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
expect "AC9-5: git worktree list shows only the checkout itself (no orphaned race registration)" "[ \"$remaining_wt\" = 1 ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_pin_gate_concurrent_ac9: ALL PASS"
  exit 0
else
  echo "mainpin_pin_gate_concurrent_ac9: assertion(s) FAILED"
  exit 1
fi
