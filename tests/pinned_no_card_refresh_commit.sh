#!/usr/bin/env bash
# tests/pinned_no_card_refresh_commit.sh — decision 42f14605 extended
# 2026-09-17 19:35 EDT: regression test for the defect
# tests/pinned_slug_common_dir.sh's own root cause traced to — under
# --pinned-landing, extend-gate.sh's pre-gate intent-card-refresh phase
# used to COMMIT a new card into the detached verify worktree whenever
# one changed, moving HEAD off M (main-verdict-pin-gate.sh's own
# contract: "M's tree is immutable"). Live evidence: mcphost-agent-wake's
# verify worktree drifted e70af61 -> ea72956 ("intent-card: refresh from
# PRD-mcphost-agent-wake"), which is what made rollback-plan's M^..HEAD
# range span an extra commit and ci-checks' landing lookup miss.
#
# Uses the same real-extend-gate.sh + fake-toolchain harness
# tests/gateinfra_ac13_head_after_intent_card_refresh.sh uses
# (tests/fixtures/rvrcpt-common.sh) rather than trying to extract the
# inline phase as a standalone function -- it reads $repo/$slug/$scope/
# $journal/$head_now/record_phase/note_block/journal_line, all local to
# one giant script; a real (fixture) end-to-end run through the fake
# toolchain is what actually proves "extend-gate.sh, invoked with
# --pinned-landing, never commits" without re-implementing the phase.
#
# Two scenarios against fixture repos that each start with a
# DELIBERATELY STALE card already committed at HEAD (M):
#   pinned_landing=true   (--scope main --pinned-landing --head M --base M^)
#     -> the stub refresh is never invoked, HEAD stays at M, the stale
#        card is untouched, and the journal carries the new skip line.
#   pinned_landing=false  (--scope branch, same stub, same stale card)
#     -> unchanged existing behavior: the stub IS invoked and commits,
#        HEAD moves off M, journal carries 'intent-card  refreshed'.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/rvrcpt-common.sh
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/pinned-no-card-refresh.XXXXXX")"
cleanup() { [ -n "${PINNEDCARD_KEEP:-}" ] || rm -rf "$T"; }
trap cleanup EXIT

SLUG="pinned-card-probe"

mkdir -p "$T/prds/build-queue"
cat > "$T/prds/build-queue/PRD-$SLUG.md" <<EOF
# PRD — $SLUG (fixture)

- Status: queued
- build_target: rust-extend

## Acceptance criteria

1. P0 — Given a fixture, When it runs, Then it passes.
EOF

# Stub refresh: same shape as gateinfra_ac13's own stub (writes a fresh
# card + commits it) but also drops an invocation marker so this test can
# assert it was never even called under --pinned-landing, not just that
# no commit resulted.
mk_stub() {
  local marker="$1" stub="$2"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
set -uo pipefail
: >> "$marker"
repo="\$1"
mkdir -p "\$repo/agent"
printf '{"schema":"autobuilder.intent_card.v1","fixture":"fresh-%s"}\n' "\$(date -u +%s%N)" > "\$repo/agent/intent-card.json"
git -C "\$repo" add -A -- agent/intent-card.json >/dev/null 2>&1
git -C "\$repo" -c user.email=f@x -c user.name=f commit -q -m "intent-card: refresh (fixture)" -- agent/intent-card.json >/dev/null 2>&1
echo "fixture refresh committed"
exit 0
EOF
  chmod +x "$stub"
}

# build_repo_at_M <dir> — a fixture crate whose HEAD (M) already carries a
# deliberately STALE card (mimicking S's own pre-land refresh, done once,
# long before this gate run), plus one more commit on top of init so M has
# a real parent (M^) to pass as --base.
build_repo_at_m() {
  local repo="$1"
  rvrcpt_write_fixture_crate "$repo"
  mkdir -p "$repo/agent"
  printf '{"schema":"autobuilder.intent_card.v1","fixture":"stale-committed-in-M"}\n' > "$repo/agent/intent-card.json"
  git -C "$repo" add -A -- agent/intent-card.json >/dev/null 2>&1
  git -C "$repo" -c user.email=f@x -c user.name=f commit -q -m "loop: $SLUG (fixture merge, M)" >/dev/null 2>&1
}

echo "=== pinned_landing=true: refresh phase must be skipped, HEAD stays at M ==="
REPO_A="$T/repo-pinned"
build_repo_at_m "$REPO_A"
JOURNAL_A="$T/journal-pinned.md"
: > "$JOURNAL_A"
MARKER_A="$T/stub-invoked-pinned"
STUB_A="$T/stub-pinned.sh"
mk_stub "$MARKER_A" "$STUB_A"

m_sha="$(git -C "$REPO_A" rev-parse HEAD)"
m_base="$(git -C "$REPO_A" rev-parse HEAD^)"
card_before="$(cat "$REPO_A/agent/intent-card.json")"

export FAKE_GH_AUTH_RC=0
out_a="$(INTENT_CARD_REFRESH_BIN="$STUB_A" \
         GATE_PATIENCE_PRD_DIR="$T/prds" \
         rvrcpt_run_gate "$REPO_A" "$JOURNAL_A" \
           --scope main --slug "$SLUG" --pinned-landing --head "$m_sha" --base "$m_base" 2>&1)"
printf '%s\n' "$out_a" > "$T/out-pinned.log"

head_after_a="$(git -C "$REPO_A" rev-parse HEAD)"
card_after_a="$(cat "$REPO_A/agent/intent-card.json")"

expect "stub was never invoked under --pinned-landing" "[ ! -f '$MARKER_A' ]"
expect "HEAD unchanged (still M)" "[ '$head_after_a' = '$m_sha' ]"
expect "the stale card committed in M was never rewritten" "[ \"\$card_after_a\" = \"\$card_before\" ]"
expect "journal carries the new skip line" \
  "grep -q 'intent-card-refresh  skipped  (pinned-landing: gating M as landed, head=' '$JOURNAL_A'"
expect "journal skip line names M itself" \
  "grep -q \"head=$m_sha\" '$JOURNAL_A'"
expect "no head-advanced line for this run" \
  "! grep -q 'head-advanced  (cause=intent-card-refresh' '$JOURNAL_A'"

echo "=== pinned_landing=false (--scope branch): existing refresh-commit behavior unchanged ==="
REPO_B="$T/repo-branch"
build_repo_at_m "$REPO_B"
JOURNAL_B="$T/journal-branch.md"
: > "$JOURNAL_B"
MARKER_B="$T/stub-invoked-branch"
STUB_B="$T/stub-branch.sh"
mk_stub "$MARKER_B" "$STUB_B"

head_before_b="$(git -C "$REPO_B" rev-parse HEAD)"

out_b="$(INTENT_CARD_REFRESH_BIN="$STUB_B" \
         GATE_PATIENCE_PRD_DIR="$T/prds" \
         rvrcpt_run_gate "$REPO_B" "$JOURNAL_B" --scope branch --slug "$SLUG" 2>&1)"
unset FAKE_GH_AUTH_RC
printf '%s\n' "$out_b" > "$T/out-branch.log"

head_after_b="$(git -C "$REPO_B" rev-parse HEAD)"

expect "stub WAS invoked for a non-pinned branch-scope gate" "[ -f '$MARKER_B' ]"
expect "HEAD moved off the pre-run head (a refresh commit happened)" \
  "[ '$head_after_b' != '$head_before_b' ]"
# The stub self-commits (same shape gateinfra_ac13's own stub uses), so by
# the time extend-gate.sh's own post-refresh `git status` check runs the
# tree is already clean -- it journals `intent-card  current`, not
# `refreshed` (that second-commit path is real-INTENT_CARD_REFRESH_BIN-
# specific, not a self-committing stub's). The property this scenario
# exists to prove -- unchanged existing behavior, a mid-gate commit still
# happens for branch scope -- is exactly what `head-advanced` records.
expect "journal carries the existing 'head-advanced' line (mid-gate commit, unchanged for branch scope)" \
  "grep -q 'head-advanced  (cause=intent-card-refresh' '$JOURNAL_B'"

if [ "$fail" -ne 0 ]; then
  echo "--- pinned run output (tail) ---" >&2
  tail -40 "$T/out-pinned.log" >&2
  echo "--- pinned journal ---" >&2
  cat "$JOURNAL_A" >&2
  echo "--- branch run output (tail) ---" >&2
  tail -40 "$T/out-branch.log" >&2
  echo "--- branch journal ---" >&2
  cat "$JOURNAL_B" >&2
  echo "pinned_no_card_refresh_commit: FAIL" >&2
  exit 1
fi
echo "pinned_no_card_refresh_commit: PASS"
