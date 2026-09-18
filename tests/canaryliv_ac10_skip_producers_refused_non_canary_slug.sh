#!/usr/bin/env bash
# tests/canaryliv_ac10_skip_producers_refused_non_canary_slug.sh —
# PRD-build-burst-canary-live-parity R6/AC10: "Given the same variable
# [EXTEND_GATE_SKIP_PRODUCERS=ci-checks,reviewer-agent,session-trace] and
# slug mcphost-foo, When extend-gate.sh runs, Then the variable is
# ignored, all producers run, and the journal has
# 'skip-producers refused (slug=mcphost-foo)'."
#
# "All producers run" is proven by absence: none of the 3 named
# producers' receipts carry skip_reason=canary:excluded, i.e. every one of
# them went through its ordinary code path (ci-checks' real branch-scope
# push+poll, reviewer-agent's real `claude -p` stub, session-trace simply
# never gets an override written for it at all -- identical to what this
# same fixture produces with EXTEND_GATE_SKIP_PRODUCERS unset entirely).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac10-selftest.XXXXXX")"
# wt_path() (worktree-extend.sh) keys the worktree dir by basename($repo)-
# $slug, not by $T -- every run of this fixture writes a repo dir literally
# named "repo", so a prior interrupted run's worktree collides with this
# one's `add` ("fatal: ... already exists") unless the stale dir is removed
# first AND after, win or lose.
STALE_WT="${BUILD_WT_ROOT:-$HOME/.cache/build-worktrees}/repo-mcphost-foo"
cleanup() { rm -rf "$STALE_WT" "$T"; }
trap cleanup EXIT
rm -rf "$STALE_WT"

echo "=== AC10: non-canary slug + EXTEND_GATE_SKIP_PRODUCERS is refused, journaled, all producers run ==="
bgscope_write_fixture_crate "$T/repo" redeploy-tag
git -C "$T/repo" tag v0.1.0
bgscope_add_origin "$T/repo" "$T/origin.git"
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt (canaryliv_ac10)\n' > "$T/reviewer-prompt.md"

# PRD dir + manifest so the pre-gate refresh has a real claim to resolve
# for this slug (never blocked on prd-not-found, which would otherwise
# make reviewer-agent skip for an UNRELATED reason and confuse "all
# producers run").
mkdir -p "$T/prds/build-queue"
cat > "$T/prds/build-queue/PRD-mcphost-foo.md" <<'EOF'
# PRD-mcphost-foo (claimed fixture)

- Status: queued
- build_target: shell

## Problem statement

Claimed fixture PRD for canaryliv_ac10_skip_producers_refused_non_canary_slug.sh.

## Acceptance criteria

1. P0 — Given nothing, When nothing, Then nothing.
EOF
jq -n '{prds: {"mcphost-foo": {path: "'"$T"'/prds/build-queue/PRD-mcphost-foo.md"}}}' > "$T/manifest.json"

SLUG="mcphost-foo"
WT="$(BUILD_TARGET_ROOT="$T/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
expect "setup: worktree created" "[ -d \"$WT\" ]"
echo "docs: harmless change (AC10 fixture)" >> "$WT/README.md"
git -C "$WT" -c user.name="canaryliv-test" -c user.email="selftest@example.com" add README.md
git -C "$WT" -c user.name="canaryliv-test" -c user.email="selftest@example.com" commit -q -m "docs: harmless change (AC10 fixture)"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

JOURNAL="$T/journal.md"
OUT="$T/out.log"
CANARYLIV_BURST_LANE_FAKE="$HERE/fixtures/gatephase-fake/burst-lane.sh"

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
echo "  extend-gate.sh rc=$rc"
cat "$OUT"

expect "journal has skip-producers refused (slug=mcphost-foo)" \
  "grep -q 'skip-producers refused (slug=mcphost-foo)' '$JOURNAL'"

rdir="$WT/target/autobuilder/receipts"
expect "ci-checks.json exists (producer ran) and is NOT canary:excluded" \
  "[ -s '$rdir/ci-checks.json' ] && [ \"\$(jq -r '.skip_reason // empty' '$rdir/ci-checks.json' 2>/dev/null)\" != canary:excluded ]"
expect "reviewer-agent.json exists (producer ran) and is NOT canary:excluded" \
  "[ -s '$rdir/reviewer-agent.json' ] && [ \"\$(jq -r '.skip_reason // empty' '$rdir/reviewer-agent.json' 2>/dev/null)\" != canary:excluded ]"
expect "reviewer-agent.json carries a real reviewer run (not our synthetic skip receipt)" \
  "[ \"\$(jq -r '.scope_deferred // false' '$rdir/reviewer-agent.json' 2>/dev/null)\" != true ] && [ \"\$(jq -r '.intent_card_sha' '$rdir/reviewer-agent.json' 2>/dev/null)\" != '' ]"
expect "session-trace.json was never written by our canary override (same as the variable being unset)" \
  "[ ! -e '$rdir/session-trace.json' ]"

expect "intent-card-refresh did not take the canary skip path" \
  "! grep -qE 'intent-card-refresh  skipped  \(slug=mcphost-foo skip_reason=canary:excluded\)' '$JOURNAL'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac10_skip_producers_refused_non_canary_slug: ALL PASS"
else
  echo "canaryliv_ac10_skip_producers_refused_non_canary_slug: FAILED" >&2
fi
exit "$fail"
