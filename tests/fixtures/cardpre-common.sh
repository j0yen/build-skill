#!/usr/bin/env bash
# tests/fixtures/cardpre-common.sh — shared fixture-building for the
# cardpre_ac*.sh test files (PRD-build-intent-card-pregate-refresh). Not a
# standalone test; `source`d by tests/cardpre_ac*.sh.
#
# Reuses bgscope-common.sh's fixture crate / fake toolchain (the same
# disposable rust-extend-shaped crate bgscope_ac*.sh already gates
# against) rather than re-deriving it — this PRD's own change lives
# entirely inside extend-gate.sh's producer sequence, so it needs the
# same kind of real `--scope branch` run bgscope_ac*.sh already pays for,
# just with an intent-card.json seeded to name a DIFFERENT PRD than the
# branch's own claim.
set -uo pipefail

CARDPRE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bgscope-common.sh
source "$CARDPRE_HERE/bgscope-common.sh"

CARDPRE_REPO_ROOT="$BGSCOPE_REPO_ROOT"
CARDPRE_EXTEND_GATE="$BGSCOPE_EXTEND_GATE"
CARDPRE_INTENT_CARD_REFRESH="$CARDPRE_REPO_ROOT/scripts/intent-card-refresh.sh"
CARDPRE_WORKTREE_EXTEND="$BGSCOPE_WORKTREE_EXTEND"
# Real burst-lane.sh probes for a live Hetzner burst-lane session, which
# may genuinely be active on this fleet at test time — irrelevant to
# THIS PRD's own change (extend-gate.sh's pre-gate card refresh) and, on
# a route-check refusal, would stop a fixture run before ever reaching
# it. Same fixture stub extend-gate-phase-timing-selftest.sh already uses
# via extend-gate.sh's own documented $BURST_LANE_SH override.
CARDPRE_BURST_LANE_FAKE="$CARDPRE_HERE/gatephase-fake/burst-lane.sh"

cardpre_fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; cardpre_fail=1; fi
}

# cardpre_write_prd <path> <slug> <title-word> — a minimal, parseable PRD
# (Problem statement paragraph + one numbered P0 Acceptance criteria line)
# so intent-card-refresh.sh's stage-1 parse succeeds and yields a
# distinguishable prd_source/root_motivation per fixture.
cardpre_write_prd() {
  local path="$1" slug="$2" word="$3"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
# PRD-$slug ($word fixture)

- Status: queued
- build_target: shell
- Drafted: 2026-09-16

## Problem statement

This is the $word fixture PRD used by cardpre_ac*.sh
(PRD-build-intent-card-pregate-refresh) to prove the branch-scope gate
refreshes agent/intent-card.json from THIS PRD, not whichever PRD main's
card last named.

## Acceptance criteria

1. P0 — Given the $word fixture, When intent-card-refresh.sh runs, Then
   the card's prd_source names this PRD.
EOF
}

# cardpre_ensure_shared_run <kind: mismatch|missing> -> stdout: shared dir
# path. Builds the fixture crate + a worktree whose intent-card.json is
# seeded to name PRD-A (simulating main's stale card carried onto the
# branch), a manifest.json mapping the branch's own slug to PRD-B (the
# claim this branch is actually building), and runs extend-gate.sh
# --scope branch TWICE against the SAME worktree:
#   run 1 (AC1): card names PRD-A -> refresh commits "intent-card: refresh
#     from PRD-<slug>", card now names PRD-B.
#   run 2 (AC2): card already names PRD-B -> no new commit, journal says
#     "intent-card  current".
# kind=missing skips the manifest entry AND points GATE_PATIENCE_PRD_DIR
# at an empty directory, so PRD-path resolution fails outright (AC3).
# Cached under a fixed path (flock-guarded), same convention as
# bgscope_ensure_shared_run, so cardpre_ac1/ac2 (which read facts off the
# SAME "mismatch" run) don't each pay for their own worktree + gate pass.
cardpre_ensure_shared_run() {
  local kind="$1"
  local dir="${TMPDIR:-/tmp}/cardpre-shared-$kind-$(id -u)"
  local lock="$dir.lock"
  mkdir -p "$(dirname "$dir")"
  (
    exec 8>"$lock"
    flock 8
    if [ -f "$dir/DONE" ] && [ "$(find "$dir/DONE" -mmin -60 2>/dev/null)" ]; then
      exit 0
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    bgscope_write_fixture_crate "$dir/repo"
    bgscope_add_origin "$dir/repo" "$dir/origin.git"
    bgscope_write_fakebin "$dir/fakebin"
    printf 'shared reviewer prompt for cardpre_ac*.sh\n' > "$dir/reviewer-prompt.md"

    local slug="cardpre-shared-$kind"
    mkdir -p "$dir/prds/build-queue"
    cardpre_write_prd "$dir/prds/build-queue/PRD-cardpre-fixture-a.md" cardpre-fixture-a stale
    cardpre_write_prd "$dir/prds/build-queue/PRD-$slug.md" "$slug" claimed

    local wt
    wt="$(BUILD_TARGET_ROOT="$dir/offroot" "$CARDPRE_WORKTREE_EXTEND" add "$dir/repo" "$slug" 2>>"$dir/setup.log")"

    # Seed the card to name PRD-A (main's stale card, carried onto the
    # branch unchanged) -- the exact bug this PRD fixes.
    jq --arg src "$dir/prds/build-queue/PRD-cardpre-fixture-a.md" \
      '.prd_source = $src' "$wt/agent/intent-card.json" > "$wt/agent/intent-card.json.tmp"
    mv "$wt/agent/intent-card.json.tmp" "$wt/agent/intent-card.json"
    git -C "$wt" -c user.name="cardpre-test" -c user.email="selftest@example.com" add agent/intent-card.json
    git -C "$wt" -c user.name="cardpre-test" -c user.email="selftest@example.com" commit -q -m "seed stale card (PRD-A)"

    if [ "$kind" = missing ]; then
      printf '{"prds":{}}\n' > "$dir/manifest.json"
      mkdir -p "$dir/empty-prd-dir/build-queue"
    else
      jq -n --arg slug "$slug" --arg path "$dir/prds/build-queue/PRD-$slug.md" \
        '{prds: {($slug): {path: $path}}}' > "$dir/manifest.json"
    fi

    local prd_dir_for_run="$dir/prds"
    [ "$kind" = missing ] && prd_dir_for_run="$dir/empty-prd-dir"

    local head1; head1="$(git -C "$wt" rev-parse HEAD)"
    env \
      "PATH=$dir/fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
      "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
      "RUSTBUILD_SCRIPTS=$dir/fakebin" \
      "REVIEWER_PROMPT=$dir/reviewer-prompt.md" \
      "CI_CHECKS_BRANCH_WAIT=3" "CI_CHECKS_BRANCH_POLL=1" "BRANCH_GATE_PUSH=1" \
      "BURST_LANE_SH=$CARDPRE_BURST_LANE_FAKE" \
      "EXTEND_GATE_JOURNAL=$dir/journal.md" \
      "INTENT_CARD_REFRESH_MANIFEST=$dir/manifest.json" \
      "GATE_PATIENCE_PRD_DIR=$prd_dir_for_run" \
      timeout -k 5 180 "$CARDPRE_EXTEND_GATE" "$wt" --head "$head1" --scope branch --slug "$slug" --force \
        >"$dir/out1.log" 2>&1
    echo "$?" > "$dir/RC1"
    cp "$wt/agent/intent-card.json" "$dir/card-after-run1.json" 2>/dev/null || true
    git -C "$wt" log --oneline > "$dir/log-after-run1.txt"

    if [ "$kind" != missing ]; then
      local head2; head2="$(git -C "$wt" rev-parse HEAD)"
      env \
        "PATH=$dir/fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
        "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
        "RUSTBUILD_SCRIPTS=$dir/fakebin" \
        "REVIEWER_PROMPT=$dir/reviewer-prompt.md" \
        "CI_CHECKS_BRANCH_WAIT=3" "CI_CHECKS_BRANCH_POLL=1" "BRANCH_GATE_PUSH=1" \
        "BURST_LANE_SH=$CARDPRE_BURST_LANE_FAKE" \
        "EXTEND_GATE_JOURNAL=$dir/journal.md" \
        "INTENT_CARD_REFRESH_MANIFEST=$dir/manifest.json" \
        "GATE_PATIENCE_PRD_DIR=$dir/prds" \
        timeout -k 5 180 "$CARDPRE_EXTEND_GATE" "$wt" --head "$head2" --scope branch --slug "$slug" --force \
          >"$dir/out2.log" 2>&1
      echo "$?" > "$dir/RC2"
      cp "$wt/agent/intent-card.json" "$dir/card-after-run2.json" 2>/dev/null || true
      git -C "$wt" log --oneline > "$dir/log-after-run2.txt"
    fi

    printf '%s\n' "$wt" > "$dir/WORKTREE"
    printf '%s\n' "$slug" > "$dir/SLUG"
    date -u +%FT%TZ > "$dir/DONE"
  )
  printf '%s\n' "$dir"
}
