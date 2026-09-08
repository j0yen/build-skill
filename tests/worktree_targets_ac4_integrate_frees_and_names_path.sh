#!/usr/bin/env bash
# worktree_targets_ac4_integrate_frees_and_names_path.sh — PRD-build-worktree-targets-off-root AC4.
#
# Given `worktree-extend.sh integrate` on a fixture branch, when it succeeds,
# then the worktree and target are gone and the output contains the freed
# path. ("output" = combined stdout+stderr — integrate's stdout stays the
# bare new version for existing `newver=$(...)` callers; the freed path is
# named on stderr, same convention as this script's other operational lines.)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WTE="$HERE/../scripts/worktree-extend.sh"
[ -x "$WTE" ] || { echo "ac4: $WTE not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-targets-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"
EOF
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main
git -C "$REPO" add Cargo.toml
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TARGETS="$T/targets"
export BUILD_WT_ROOT="$T/worktrees"
# Isolate the streak/sidecar state this integrate touches on a clean landing
# (loom-serial-fallback.sh streak-reset) away from the real build-skill state.
export BUILD_STATE_DIR="$T/state"
export STATE_DIR="$T/state"
mkdir -p "$BUILD_STATE_DIR"

repo_base="$(basename "$REPO")"
wt="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" add "$REPO" s1)"
tdir="$TARGETS/$repo_base-s1"

echo "change" > "$wt/change.txt"
git -C "$wt" add change.txt
git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m "s1 change"

out="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" integrate "$REPO" s1 patch "" 2>&1)"; rc=$?
expect "integrate exits 0"                 "[ $rc -eq 0 ]"
expect "worktree gone after integrate"     "[ ! -d '$wt' ]"
expect "target dir gone after integrate"   "[ ! -d '$tdir' ]"
expect "output names the freed path"       "[[ '$out' == *'$tdir'* ]]"
expect "branch kept (not dropped)"         "git -C '$REPO' show-ref --verify --quiet refs/heads/autobuilder/s1"
expect "version bumped (merge landed)"     "grep -q 'version = \"0.1.1\"' '$REPO/Cargo.toml'"

exit $fail
