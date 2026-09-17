#!/usr/bin/env bash
# landres_ac6_resolve_source_conflict_untouched.sh —
# PRD-build-land-conflict-resolver AC6 (resolve slice, negative case):
# given a source-file conflict (no policy entry) mid-rebase, When
# `land-resolve.sh resolve` runs, Then it does NOT continue the rebase,
# reports the file under `source_conflicts=`, exits non-zero, and leaves
# the conflict markers in place — matching today's "abort, not retried"
# contract (the coder-resolve bounded attempt is a separate, later PRD
# step; this script's job at this class is to correctly do nothing).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email a@b.c
git -C "$REPO" config user.name test

printf 'fn main() {}\n' >"$REPO/src.rs"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

git -C "$REPO" checkout -q -b autobuilder/fix1
printf 'fn main() { branch_change(); }\n' >"$REPO/src.rs"
git -C "$REPO" commit -q -am "branch source change"

git -C "$REPO" checkout -q main
printf 'fn main() { main_change(); }\n' >"$REPO/src.rs"
git -C "$REPO" commit -q -am "main source change"

git -C "$REPO" checkout -q autobuilder/fix1

# No policy file at all for this repo -> every path classifies `source`.
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"

git -C "$REPO" rebase main >/dev/null 2>&1 || true

fail=0
out="$("$RESOLVE" resolve "$REPO" fix1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "source_conflicts=src.rs" ]; then
  echo "ok  AC6: resolve reports source_conflicts=src.rs and exits 1"
else
  echo "FAIL: expected rc=1/source_conflicts=src.rs, got rc=$rc out='$out'" >&2
  fail=1
fi

if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo "ok  AC6: rebase left open (working tree still shows the unresolved conflict)"
else
  echo "FAIL: working tree unexpectedly clean — rebase must NOT have been continued" >&2
  fail=1
fi

# Rebase directory must still exist (not continued, not aborted by us).
# Use --absolute-git-dir, not --git-path (which is relative to $REPO, not
# our cwd, and silently "not found" if checked from the wrong directory).
gitdir="$(git -C "$REPO" rev-parse --absolute-git-dir)"
if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
  echo "ok  AC6: rebase state directory still present — resolve did not continue or abort it"
else
  echo "FAIL: rebase state directory is gone — resolve must not touch rebase state on a source conflict" >&2
  fail=1
fi

git -C "$REPO" rebase --abort 2>/dev/null || true
exit $fail
