#!/usr/bin/env bash
# worktree_targets_ac3_prune_landed.sh — PRD-build-worktree-targets-off-root AC3.
#
# Given a worktree whose branch is merged into the fixture's origin/main,
# when `worktree-extend.sh prune-landed <fixture-repo>` runs, then that
# worktree and its target are removed and an unmerged sibling worktree is
# untouched.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WTE="$HERE/../scripts/worktree-extend.sh"
[ -x "$WTE" ] || { echo "ac3: $WTE not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-targets-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ORIGIN="$T/origin.git"
git init -q --bare "$ORIGIN"

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TARGETS="$T/targets"
export BUILD_WT_ROOT="$T/worktrees"
repo_base="$(basename "$REPO")"

# s1: will be merged into main and pushed to origin — "landed".
wt1="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" add "$REPO" s1)"
echo landed > "$wt1/landed.txt"
git -C "$wt1" add landed.txt
git -C "$wt1" -c user.name=t -c user.email=t@t commit -q -m "s1 change"
git -C "$REPO" checkout -q main
git -C "$REPO" -c user.name=t -c user.email=t@t merge -q --no-ff --no-edit autobuilder/s1
git -C "$REPO" push -q origin main

# s2: left unmerged — sibling that must be untouched.
wt2="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" add "$REPO" s2)"
echo unmerged > "$wt2/unmerged.txt"
git -C "$wt2" add unmerged.txt
git -C "$wt2" -c user.name=t -c user.email=t@t commit -q -m "s2 change"

tdir1="$TARGETS/$repo_base-s1"
tdir2="$TARGETS/$repo_base-s2"
expect "s1 target dir exists before prune" "[ -d '$tdir1' ]"
expect "s2 target dir exists before prune" "[ -d '$tdir2' ]"

out="$("$WTE" prune-landed "$REPO" 2>&1)"; rc=$?
expect "prune-landed exits 0"        "[ $rc -eq 0 ]"
expect "s1 worktree removed"         "[ ! -d '$wt1' ]"
expect "s1 target dir removed"       "[ ! -d '$tdir1' ]"
expect "s2 worktree untouched"       "[ -d '$wt2' ]"
expect "s2 target dir untouched"     "[ -d '$tdir2' ]"
expect "s2 unmerged file still present" "[ -f '$wt2/unmerged.txt' ]"
expect "prune-landed output names s1" "[[ '$out' == *'s1'* ]]"

exit $fail
