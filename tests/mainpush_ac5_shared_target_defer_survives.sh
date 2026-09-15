#!/usr/bin/env bash
# mainpush_ac5_shared_target_defer_survives.sh — PRD-build-main-push-gate
# AC5: given SKILL.md step 5 wired, when the shared-target selftest
# replays a landing whose refresh goes red, then the PRD stays
# in_progress with last_error=main-push-refused, the branch survives
# (`git branch --list` shows it), and no `wm-push` call is recorded.
#
# Exercises the REAL worktree-extend.sh add/cleanup mechanics (the same
# ones SKILL.md's "Worktree isolation" step 5 names) around
# main-push-gate.sh, rather than re-deriving the coordinator's own
# manifest bookkeeping — this test's job is to prove the branch and
# refresh commit are not lost and no push happens on a refusal, which is
# the part a script can prove; the manifest-field assertions
# (`status: in_progress`, `last_error: main-push-refused`) are the
# coordinator's own Phase 7 write, documented in SKILL.md's step 5 text
# and covered by that prose contract, not re-tested here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac5.XXXXXX")"
trap 'rm -rf "$ROOT" "$WT_ROOT_OVERRIDE"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"
WT_ROOT_OVERRIDE="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac5-wtroot.XXXXXX")"
export BUILD_WT_ROOT="$WT_ROOT_OVERRIDE"

work="$(mainpush_mkfixture "$ROOT")"
main_gated="$(git -C "$work" rev-parse HEAD)"
slug="mainpush-ac5-fixture"
branch="autobuilder/$slug"

worktree_extend="$MAINPUSH_SCRIPTS/worktree-extend.sh"
branch_wt="$(bash "$worktree_extend" add "$work" "$slug" 2>/dev/null | tail -1)"
mainpush_expect "AC5: worktree created" '[ -d "$branch_wt" ]'

# Simulate the refresh commit going red on the branch (the shared-target
# integrate+refresh already happened conceptually; here the branch's
# refresh commit is the drift).
mainpush_drift_commit "$branch_wt" >/dev/null
branch_head="$(git -C "$branch_wt" rev-parse HEAD)"

# main-push-gate.sh's check runs against <repo>'s CHECKED-OUT files, so it
# is pointed at the branch's own worktree (which is actually at
# $branch_head) -- exactly how SKILL.md's real sequence uses it too: by
# the time main-push-gate.sh runs against the main checkout in production,
# `worktree-extend.sh integrate` has already merged the branch INTO that
# checkout, so its working directory already reflects the head under test.
# --gated/--head both resolve fine against $branch_wt since a git worktree
# shares its parent repo's object store and refs.
out="$(bash "$MAINPUSH_GATE" "$branch_wt" --gated "$main_gated" --head "$branch_head" 2>&1)"
rc=$?
mainpush_expect "AC5: main-push-gate refuses (exit 4)" '[ "$rc" -eq 4 ]'

# SKILL.md step 5 contract: on exit 4/5, cleanup WITHOUT --drop-branch, and
# no wm-push (i.e. no push of $branch_head onto $work's main).
bash "$worktree_extend" cleanup "$work" "$slug" >/dev/null 2>&1

mainpush_expect "AC5: branch survives (git branch --list)" \
  '[ -n "$(git -C "$work" branch --list "$branch")" ]'
mainpush_expect "AC5: refresh commit still reachable from the surviving branch" \
  'git -C "$work" merge-base --is-ancestor "$branch_head" "$branch" 2>/dev/null'
mainpush_expect "AC5: work checkout did not advance (no push recorded)" \
  '[ "$(git -C "$work" rev-parse HEAD)" = "$main_gated" ]'

exit "$mainpush_fail"
