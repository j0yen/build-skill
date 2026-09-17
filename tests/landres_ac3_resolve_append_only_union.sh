#!/usr/bin/env bash
# landres_ac3_resolve_append_only_union.sh —
# PRD-build-land-conflict-resolver AC3 (resolve slice): given a fixture
# repo where main and a branch each appended a different line to a
# policy-listed append-only file (real rebase conflict), When
# `land-resolve.sh resolve` runs mid-rebase, Then it union-merges the two
# additions, stages the result, continues the rebase, and the landed file
# contains both lines.
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

printf '# Changelog\n- v1: initial\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

git -C "$REPO" checkout -q -b autobuilder/fix1
printf '# Changelog\n- v1: initial\n- v2: branch entry\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" commit -q -am "branch appended v2 entry"

git -C "$REPO" checkout -q main
printf '# Changelog\n- v1: initial\n- v2: main entry\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" commit -q -am "main appended v2 entry"

git -C "$REPO" checkout -q autobuilder/fix1

export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"
cat >"$BUILD_STATE_DIR/land-policy/repo.json" <<'EOF'
{"generated": [], "append_only": ["CHANGELOG.md"]}
EOF

git -C "$REPO" rebase main >/dev/null 2>&1 || true
conflicted_before="$(git -C "$REPO" diff --name-only --diff-filter=U)"

fail=0
if [ "$conflicted_before" = "CHANGELOG.md" ]; then
  echo "ok  AC3: fixture produced a real rebase conflict in CHANGELOG.md"
else
  echo "FAIL: expected a conflict in CHANGELOG.md, got '$conflicted_before'" >&2
  fail=1
fi

out="$("$RESOLVE" resolve "$REPO" fix1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "resolved=all" ]; then
  echo "ok  AC3: land-resolve resolve reports resolved=all"
else
  echo "FAIL: expected rc=0/resolved=all, got rc=$rc out='$out'" >&2
  fail=1
fi

if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  echo "ok  AC3: rebase completed, working tree clean"
else
  echo "FAIL: working tree not clean after resolve" >&2
  fail=1
fi

content="$(cat "$REPO/CHANGELOG.md")"
if grep -qF 'main entry' <<<"$content" && grep -qF 'branch entry' <<<"$content"; then
  echo "ok  AC3: landed CHANGELOG.md contains BOTH the main and branch entries"
else
  echo "FAIL: landed CHANGELOG.md missing one or both entries:" >&2
  echo "$content" >&2
  fail=1
fi

exit $fail
