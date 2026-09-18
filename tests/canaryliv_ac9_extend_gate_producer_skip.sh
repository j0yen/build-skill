#!/usr/bin/env bash
# tests/canaryliv_ac9_extend_gate_producer_skip.sh — PRD-build-burst-canary-
# live-parity R6/AC9: "Given EXTEND_GATE_SKIP_PRODUCERS=ci-checks,reviewer-
# agent,session-trace and slug canary-branch-1 on the fixture crate, When
# extend-gate.sh runs at --scope branch, Then each named producer has a
# receipt with skip_reason=canary:excluded, the aggregator counts them as
# skipped, no intent-card refresh commit is made, and the ci-checks phase
# finishes in under 10 s."
#
# Reuses bgscope-common.sh's fixture crate + hybrid fake toolchain (real
# autobuilder for rollback-plan; ci-checks/reviewer-agent/session-trace
# never reach it here — that is the whole point) the same way
# cardpre_ac*.sh already does for a different PRD's pre-gate-refresh ACs.
# The card is seeded to name a DIFFERENT PRD than the branch's own claim
# (same trick cardpre_ac1 uses) so a real refresh WOULD commit here if R6's
# canary short-circuit did not suppress it -- proving the "no commit" half
# of AC9 actually exercises the new code path, not just an accident of an
# already-current card.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac9-selftest.XXXXXX")"
SLUG="canary-branch-1"
# wt_path() (worktree-extend.sh) keys the worktree dir by basename($repo)-
# $slug, not by $T -- every run of this fixture writes a repo dir literally
# named "repo", so a prior interrupted run's worktree collides with this
# one's `add` ("fatal: ... already exists") unless the stale dir is removed
# first AND after, win or lose. Removed directly by its known path rather
# than via `worktree-extend.sh cleanup`, since that needs $T/repo to
# already exist as a git repo (true only on the post-run call).
STALE_WT="${BUILD_WT_ROOT:-$HOME/.cache/build-worktrees}/repo-$SLUG"
cleanup() { rm -rf "$STALE_WT" "$T"; }
trap cleanup EXIT
rm -rf "$STALE_WT"

echo "=== AC9: canary-* slug + EXTEND_GATE_SKIP_PRODUCERS excludes the 3 named producers ==="
bgscope_write_fixture_crate "$T/repo" redeploy-tag
git -C "$T/repo" tag v0.1.0
bgscope_add_origin "$T/repo" "$T/origin.git"
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt (canaryliv_ac9)\n' > "$T/reviewer-prompt.md"

# A PRD dir + manifest that WOULD let the pre-gate refresh succeed and
# commit for slug canary-branch-1 -- the card below is seeded to name a
# different (stale) PRD, so if R6's skip did not fire, run would produce a
# real "intent-card: refresh from PRD-canary-branch-1" commit.
mkdir -p "$T/prds/build-queue"
cat > "$T/prds/build-queue/PRD-canaryliv-ac9-stale.md" <<'EOF'
# PRD-canaryliv-ac9-stale (stale fixture)

- Status: queued
- build_target: shell

## Problem statement

Stale fixture PRD, never the branch's own claim.

## Acceptance criteria

1. P0 — Given nothing, When nothing, Then nothing.
EOF
cat > "$T/prds/build-queue/PRD-canary-branch-1.md" <<'EOF'
# PRD-canary-branch-1 (claimed fixture)

- Status: queued
- build_target: shell

## Problem statement

Claimed fixture PRD for canaryliv_ac9_extend_gate_producer_skip.sh.

## Acceptance criteria

1. P0 — Given nothing, When nothing, Then nothing.
EOF
jq -n '{prds: {"canary-branch-1": {path: "'"$T"'/prds/build-queue/PRD-canary-branch-1.md"}}}' > "$T/manifest.json"

SLUG="canary-branch-1"
WT="$(BUILD_TARGET_ROOT="$T/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
expect "setup: worktree created" "[ -d \"$WT\" ]"

# Seed the card to name the stale PRD (main's card carried onto the
# branch unchanged) -- the exact shape cardpre_ac1 uses to prove a real
# refresh+commit would otherwise happen.
jq --arg src "$T/prds/build-queue/PRD-canaryliv-ac9-stale.md" \
  '.prd_source = $src' "$WT/agent/intent-card.json" > "$WT/agent/intent-card.json.tmp"
mv "$WT/agent/intent-card.json.tmp" "$WT/agent/intent-card.json"
git -C "$WT" -c user.name="canaryliv-test" -c user.email="selftest@example.com" add agent/intent-card.json
git -C "$WT" -c user.name="canaryliv-test" -c user.email="selftest@example.com" commit -q -m "seed stale card (AC9 fixture)"

# The throwaway commit a real canary_run_variant_branch would also make.
git -C "$WT" commit -q --allow-empty -m "canary: throwaway commit for --scope branch"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
LOG_BEFORE="$(git -C "$WT" log --oneline)"

JOURNAL="$T/journal.md"
OUT="$T/out.log"
CANARYLIV_BURST_LANE_FAKE="$HERE/fixtures/gatephase-fake/burst-lane.sh"

t0=$(date +%s)
env \
  "PATH=$T/fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
  "RUSTBUILD_SCRIPTS=$T/fakebin" \
  "REVIEWER_PROMPT=$T/reviewer-prompt.md" \
  "BUILD_STATE_DIR=$T/state" \
  "CI_CHECKS_BRANCH_WAIT=3" "CI_CHECKS_BRANCH_POLL=1" "BRANCH_GATE_PUSH=1" \
  "BURST_LANE_SH=$CANARYLIV_BURST_LANE_FAKE" \
  "EXTEND_GATE_JOURNAL=$JOURNAL" \
  "INTENT_CARD_REFRESH_MANIFEST=$T/manifest.json" \
  "GATE_PATIENCE_PRD_DIR=$T/prds" \
  "EXTEND_GATE_SKIP_PRODUCERS=ci-checks,reviewer-agent,session-trace" \
  timeout -k 5 180 "$BGSCOPE_EXTEND_GATE" "$WT" --head "$HEAD_SHA" --scope branch --slug "$SLUG" --force \
    >"$OUT" 2>&1
rc=$?
t1=$(date +%s)
echo "  extend-gate.sh rc=$rc wall=$((t1 - t0))s"
cat "$OUT"

rdir="$WT/target/autobuilder/receipts"
expect "ci-checks.json has skip_reason=canary:excluded" \
  "[ \"\$(jq -r '.skip_reason // empty' '$rdir/ci-checks.json' 2>/dev/null)\" = canary:excluded ]"
expect "ci-checks.json is scope_deferred and verdict=pass (aggregator's skipped bucket)" \
  "[ \"\$(jq -r '.scope_deferred' '$rdir/ci-checks.json' 2>/dev/null)\" = true ] && [ \"\$(jq -r '.verdict' '$rdir/ci-checks.json' 2>/dev/null)\" = pass ]"
expect "reviewer-agent.json has skip_reason=canary:excluded" \
  "[ \"\$(jq -r '.skip_reason // empty' '$rdir/reviewer-agent.json' 2>/dev/null)\" = canary:excluded ]"
expect "reviewer-agent.json is scope_deferred and decision=pass" \
  "[ \"\$(jq -r '.scope_deferred' '$rdir/reviewer-agent.json' 2>/dev/null)\" = true ] && [ \"\$(jq -r '.decision' '$rdir/reviewer-agent.json' 2>/dev/null)\" = pass ]"
expect "session-trace.json has skip_reason=canary:excluded" \
  "[ \"\$(jq -r '.skip_reason // empty' '$rdir/session-trace.json' 2>/dev/null)\" = canary:excluded ]"

expect "no intent-card refresh commit was made" \
  "! git -C '$WT' log --oneline | grep -q 'intent-card: refresh'"
expect "journal shows the pre-gate refresh itself skipped for canary:excluded" \
  "grep -q 'intent-card-refresh  skipped  (slug=canary-branch-1 skip_reason=canary:excluded)' '$JOURNAL'"

phases_line="$(grep -oE 'phases=[^ ]*' "$JOURNAL" 2>/dev/null | head -1 || true)"
echo "  phases field: ${phases_line:-<not found>}"
echo "  gate wall (test-measured): $((t1 - t0))s"
# record_phase() stores the literal "skip" for a skipped phase, never a
# duration (PRD-build-gate-phase-timing) -- so "under 10s" is proven by
# the phase never entering CI_CHECKS_BRANCH_WAIT (recorded as ci-checks:skip,
# not a number) AND the whole gate's measured wall time, not a parsed
# per-phase second count that a skip never produces.
expect "ci-checks phase recorded as skip (never entered CI_CHECKS_BRANCH_WAIT)" \
  "printf '%s' \"\$phases_line\" | grep -q 'ci-checks:skip'"
expect "ci-checks phase finished in under 10s (whole gate wall, since a skip has no phase duration)" \
  "[ $((t1 - t0)) -lt 10 ]"

expect "the variable was NOT refused (this slug is canary-*)" \
  "! grep -q 'skip-producers refused' '$JOURNAL'"

expect "aggregator's own gate tally never names ci-checks/reviewer-agent/session-trace as blocking" \
  "! grep -E 'blocking=' '$OUT' | grep -qE 'ci-checks|reviewer-agent|session-trace'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac9_extend_gate_producer_skip: ALL PASS"
else
  echo "canaryliv_ac9_extend_gate_producer_skip: FAILED" >&2
fi
exit "$fail"
