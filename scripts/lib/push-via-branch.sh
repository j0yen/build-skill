#!/usr/bin/env bash
# lib/push-via-branch.sh — PRD-build-main-push-gate-pr-path shared helper.
#
# `push_via_branch_for <repo_slug>` was originally a private function
# inside branch-protection.sh (PRD-build-main-push-gate AC6/AC7); this
# PRD's landing sequence needs the SAME answer in gate-then-land.sh
# (requirement 1/AC1-AC2: skip the direct-push post-land re-verify for a
# protected repo) and main-push-gate.sh (requirement 5/AC7: accept a
# branch-scope verdict via the PR path) — factored out here so all three
# callers read one state file with one piece of logic, rather than three
# copies drifting apart. `landing_record_path` is the second thing every
# caller of the landing record (branch-protection.sh's own push/landing-
# check/sync, plus gate-then-land.sh and the tick resume path) needs to
# agree on byte-for-byte.
#
# Must be sourced (not executed) with $STATE_DIR already set by the
# caller (every caller in this repo resolves `${BUILD_STATE_DIR:-<skill>/
# state}` before sourcing this file — see branch-protection.sh,
# gate-then-land.sh, main-push-gate.sh).
#
# push_via_branch_for <repo_slug> -> "true"/"false" (default "false" —
# never assume the branch-only path for a repo `enable` never ran
# against).
push_via_branch_for() {
  local repo_slug="$1" state_file="${STATE_DIR:?push_via_branch_for: STATE_DIR not set}/branch-protection.json"
  [ -f "$state_file" ] || { echo false; return; }
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        state = json.load(fh)
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2]) or {}
print('true' if rec.get('push_via_branch') else 'false')
" "$state_file" "$repo_slug"
}

# landing_record_path <repo_slug> <slug> — state/landings/<repo>/<slug>.json,
# one file per in-flight landing (Technical considerations). Written by
# branch-protection.sh's `push` once a PR is opened/reused and auto-merge
# armed; read by `landing-check`/`sync` and by the tick resume path.
landing_record_path() {
  local repo_slug="$1" slug="$2"
  echo "${STATE_DIR:?landing_record_path: STATE_DIR not set}/landings/$repo_slug/$slug.json"
}

# reconcile_main_after_pr_merge <repo> <slug> — DEFECT (observed twice
# 2026-09-18): a push_via_branch=true repo's PR merges via GitHub squash
# (branch-protection.sh cmd_push arms `gh pr merge --auto --squash`), which
# writes a NEW commit object on origin/main whose tree matches local main's
# HEAD (that same content already landed locally, via `worktree-extend.sh
# integrate`, before the push ever happened) but whose sha differs -- local
# main is left carrying the pre-squash commit(s) (a merge commit, in the
# observed cases) forever after, so `git status -sb` reports
# `main...origin/main [ahead N, behind 1]` even though the trees are
# byte-for-byte identical. Left alone, later gates on that repo fail on
# infra (`redeploy-tag` head-untagged against a stale local tip,
# `ci-checks no-landing-record`, `git pull --ff-only` refusing, a later
# branch agent rebasing onto the stale local main and absorbing foreign
# commits) -- see grounding evidence: PR #11, origin 901aeb9 vs local
# 6d8cdb3+8d774b7, operator-repaired by hand 2026-09-18 22:16Z.
#
# Call this ONLY once a PR is confirmed MERGED (branch-protection.sh
# `landing-check` exit 0) -- it never itself checks PR/merge state, it
# only reconciles the local `main` checkout's relationship to whatever
# `origin/main` already is.
#
#   1. `git fetch origin main`.
#   2. Trees identical (`git diff --quiet HEAD origin/main`) AND HEAD is
#      NOT already an ancestor of origin/main (the squash-merge shape --
#      same content, different commit object, neither a superset of the
#      other): back up local HEAD to `backup/main-<slug>-<UTC ts>` (so the
#      pre-squash commit(s) stay reachable, same "never lose a sha, always
#      recoverable from a ref" convention `branch-protection.sh sync`
#      already follows -- see its own header), `git reset --hard
#      origin/main`, journal `land <slug> main-reconciled (...)`.
#   3. Trees identical AND HEAD already an ancestor of origin/main (the
#      trivial already-in-sync case, HEAD == origin/main or a content-free
#      no-op commit chain past it): nothing to do, return 0.
#   4. Trees DIFFER (origin/main carries content local main does not, or
#      vice versa -- a genuinely different landing interleaved, or a
#      not-yet-fetched sibling): do NOT touch main. Journal
#      `land <slug> main-diverged-trees (...)` and leave it for the
#      operator -- this function never resets over real content
#      divergence, only over a squash's cosmetic sha change.
#
# Returns: 0 reconciled (or already in sync) | 1 infra failure (fetch/git
# command failed) | 2 trees diverged, left untouched (not an error -- the
# caller decides how to handle "needs an operator look").
reconcile_main_after_pr_merge() {
  local repo="${1:?reconcile_main_after_pr_merge: missing <repo>}" slug="${2:?reconcile_main_after_pr_merge: missing <slug>}"
  local _rmapm_libdir; _rmapm_libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/journal.sh
  source "$_rmapm_libdir/journal.sh"

  if ! git -C "$repo" fetch origin main >/dev/null 2>&1; then
    echo "reconcile_main_after_pr_merge: git fetch origin main failed for $repo" >&2
    return 1
  fi

  local local_sha origin_sha
  local_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { echo "reconcile_main_after_pr_merge: rev-parse HEAD failed for $repo" >&2; return 1; }
  origin_sha="$(git -C "$repo" rev-parse origin/main 2>/dev/null)" || { echo "reconcile_main_after_pr_merge: rev-parse origin/main failed for $repo" >&2; return 1; }
  local local_short="${local_sha:0:8}" origin_short="${origin_sha:0:8}"

  if ! git -C "$repo" diff --quiet HEAD origin/main -- 2>/dev/null; then
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  land  $slug  main-diverged-trees (local=$local_short origin=$origin_short)"
    echo "reconcile_main_after_pr_merge: $repo trees differ (local=$local_short origin=$origin_short) — leaving main untouched for the operator" >&2
    return 2
  fi

  if git -C "$repo" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    # Trees identical and HEAD already an ancestor (includes local_sha ==
    # origin_sha) -- nothing to reconcile.
    return 0
  fi

  local backup_ref="backup/main-${slug}-$(date -u +%Y%m%dT%H%M%SZ)"
  if ! git -C "$repo" branch -f "$backup_ref" HEAD >/dev/null 2>&1; then
    echo "reconcile_main_after_pr_merge: failed to create $backup_ref for $repo — not resetting" >&2
    return 1
  fi
  if ! git -C "$repo" reset --hard origin/main >/dev/null 2>&1; then
    echo "reconcile_main_after_pr_merge: git reset --hard origin/main failed for $repo (backup kept at $backup_ref)" >&2
    return 1
  fi
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  land  $slug  main-reconciled (local=$local_short origin=$origin_short backup=$backup_ref)"
  echo "reconcile_main_after_pr_merge: $repo main reset $local_short -> $origin_short (backup=$backup_ref)" >&2
  return 0
}
