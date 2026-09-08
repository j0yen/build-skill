#!/usr/bin/env bash
# worktree_targets_ac1_add_writes_target_config.sh — PRD-build-worktree-targets-off-root AC1.
#
# Given `worktree-extend.sh add <fixture-repo> s1` with `BUILD_TARGET_ROOT=$T/targets`,
# when it returns, then <worktree>/.cargo/config.toml names $T/targets/<repo>-s1,
# that directory exists, and `git -C <worktree> status --porcelain` is empty.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WTE="$HERE/../scripts/worktree-extend.sh"
[ -x "$WTE" ] || { echo "ac1: $WTE not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-targets-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TARGETS="$T/targets"
export BUILD_WT_ROOT="$T/worktrees"
wt="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" add "$REPO" s1)"
rc=$?
expect "add exits 0"           "[ $rc -eq 0 ]"
expect "worktree dir exists"   "[ -d '$wt' ]"

repo_base="$(basename "$REPO")"
want_tdir="$TARGETS/$repo_base-s1"
expect "config.toml exists"    "[ -f '$wt/.cargo/config.toml' ]"
expect "config names target root"  "grep -qF '$want_tdir' '$wt/.cargo/config.toml'"
expect "target dir exists"     "[ -d '$want_tdir' ]"

porcelain="$(git -C "$wt" status --porcelain)"
expect "git status porcelain empty (.cargo/ excluded)" "[ -z '$porcelain' ]"

exit $fail
