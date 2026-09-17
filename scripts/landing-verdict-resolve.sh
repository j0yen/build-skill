#!/usr/bin/env bash
# landing-verdict-resolve.sh — PRD-build-main-verdict-pinned-to-landing R1/
# R7: given a repo and a slug that has already landed via the PR path
# (push_via_branch=true), resolve the ONE sha M a main-scope re-verify/
# archive/verified-completed question for that slug must gate — never the
# checkout's current HEAD (that is exactly the bug this PRD closes: a
# re-check for gate-debt-4f1112d ran at HEAD=e70af61, one PRD later than
# gate-debt's own merge at 98eb6f5).
#
# usage: landing-verdict-resolve.sh <repo> <slug>
#   stdout (on success, exit 0): M, the full 40-char merge sha, and
#   nothing else.
#
# Resolution order (Technical considerations: "read merge_sha first, fall
# back to `gh pr view --json mergeCommit` once, then R7"):
#   1. state/landings/<repo>/<slug>.json's own `merge_sha` field, if set
#      (written by `branch-protection.sh landing-check` since this PRD --
#      see landing-check-merge-sha-persist commit -- or already present on
#      a hand-reconstructed record via `reconstructed_from`).
#   2. Otherwise, exactly one `branch-protection.sh landing-check` call
#      (itself exactly one `gh pr view`) -- reusing that command's own
#      merged-verdict persistence rather than re-implementing the GitHub
#      call and the record write here a second time. Only a `merged`
#      result (landing-check exit 0) is accepted; pending/red/closed are
#      NOT a landing this resolver can produce M for, and refuse the same
#      as R7's missing-field case (a slug whose PR merge isn't yet
#      confirmed has nothing to pin a verdict to).
#   3. M must resolve to a real local commit (`git rev-parse --verify
#      M^{commit}`). If it does not, ONE `git fetch origin` is tried, then
#      resolution is retried once. Still-unresolvable -> R7.
#
# R7: any failure path prints nothing on stdout, journals
#   "landing-verdict-resolve  <slug>  landing-record-unusable:<field|sha>"
#   and exits 4. Callers (gate-then-land.sh's post-land re-verify, the
#   archive/verified-completed main-green check) must treat a non-zero
#   exit as "stop, do not gate HEAD as a silent fallback" -- R7's whole
#   point.
#
# Exit: 0 M printed | 2 usage | 4 landing-record-unusable:<field|sha>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
BRANCH_PROTECTION="${LANDING_VERDICT_RESOLVE_BRANCH_PROTECTION:-$HERE/branch-protection.sh}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"
# shellcheck source=lib/repo-slug.sh
source "$HERE/lib/repo-slug.sh"

die_unusable() {
  local slug="$1" field="$2"
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  landing-verdict-resolve  $slug  landing-record-unusable:$field"
  echo "landing-verdict-resolve: landing-record-unusable:$field for $slug" >&2
  exit 4
}

usage() {
  echo "usage: landing-verdict-resolve.sh <repo> <slug>" >&2
  exit 2
}

resolve_repo_dir() {
  local repo_arg="$1"
  if [ -d "$repo_arg/.git" ] || git -C "$repo_arg" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$repo_arg" && pwd); return 0
  fi
  if [ -d "$HOME/wintermute/$repo_arg" ]; then
    echo "$HOME/wintermute/$repo_arg"; return 0
  fi
  return 1
}

[ $# -eq 2 ] || usage
repo_arg="$1" slug="$2"
[ -n "$repo_arg" ] && [ -n "$slug" ] || usage

repo_dir="$(resolve_repo_dir "$repo_arg")" || { echo "landing-verdict-resolve: repo not found locally: $repo_arg" >&2; exit 2; }
repo_slug="$(repo_slug_for_ci "$repo_dir")"
record="$(landing_record_path "$repo_slug" "$slug")"

[ -f "$record" ] || die_unusable "$slug" "record"

merge_sha="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh)
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('merge_sha') or '')
" "$record")"

if [ -z "$merge_sha" ]; then
  # Fall back to exactly one landing-check call (itself exactly one `gh pr
  # view`), which persists merge_sha into the record on a `merged` result
  # -- re-read the record afterward rather than parsing landing-check's
  # stdout a second way.
  [ -x "$BRANCH_PROTECTION" ] || die_unusable "$slug" "merge_sha"
  "$BRANCH_PROTECTION" landing-check "$repo_dir" "$slug" >/dev/null 2>&1
  lc_rc=$?
  if [ "$lc_rc" -ne 0 ]; then
    die_unusable "$slug" "merge_sha"
  fi
  merge_sha="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh)
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('merge_sha') or '')
" "$record")"
  [ -n "$merge_sha" ] || die_unusable "$slug" "merge_sha"
fi

# M must be a real local commit -- one fetch, one retry, then R7.
if ! git -C "$repo_dir" rev-parse --verify "${merge_sha}^{commit}" >/dev/null 2>&1; then
  git -C "$repo_dir" fetch origin >/dev/null 2>&1 || true
  git -C "$repo_dir" rev-parse --verify "${merge_sha}^{commit}" >/dev/null 2>&1 || die_unusable "$slug" "sha"
fi

merge_sha_full="$(git -C "$repo_dir" rev-parse --verify "${merge_sha}^{commit}")"
echo "$merge_sha_full"
exit 0
