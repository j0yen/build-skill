#!/usr/bin/env bash
# tests/xrepo_ac5_same_repo_no_gate.sh — PRD-build-cross-repo-commit-gate
# AC5: a same-repo land (writer's own build_into equals the repo, or
# --writer-build-into simply omitted — every pre-this-PRD caller) runs no
# cross-repo gate and journals no cross-repo-gate line. Real git only (no
# cargo/autobuilder — the whole point is that this path never reaches
# extend-gate.sh at all), fast.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/../scripts/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq flock; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/xrepo-ac5-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
GIT_ID=(-c user.email=test@xrepo-ac5.local -c user.name=xrepo-ac5-selftest)
trap '[ -n "${XREPO_AC5_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

mk_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m init
}

# A gated-targets manifest that WOULD flag this repo as gated — the point
# of AC5 is that even so, a same-repo (or flag-omitted) land skips the
# check entirely, so this manifest is never even consulted.
REPO="$T/repo"
mk_repo "$REPO"
REPO_RP="$(cd "$REPO" && pwd -P)"
MANIFEST="$T/manifest.json"
jq -n --arg t "$REPO_RP" '{prds: {"owner-one": {build_target: "rust-extend", build_into: $t}}, built_at: "x"}' > "$MANIFEST"
export BUILD_MANIFEST="$MANIFEST" BUILD_STATE_DIR="$T/state" BUILD_JOURNAL_ROOT="$T/journalroot"

echo "=== AC5a: --writer-build-into equal to the repo itself ==="
SLUG_A="ac5a-slug"
WT_A="$("$WORKTREE_EXTEND" add "$REPO" "$SLUG_A" 2>/dev/null)"
printf 'change a\n' >> "$WT_A/README.md"
git -C "$WT_A" "${GIT_ID[@]}" add -A
git -C "$WT_A" "${GIT_ID[@]}" commit -q -m "change a"
JOURNAL_A="$T/journal-a.md"
WORKTREE_EXTEND_JOURNAL="$JOURNAL_A" "$WORKTREE_EXTEND" land "$REPO" "$SLUG_A" --writer-build-into "$REPO_RP" >"$T/out-a" 2>&1
rc_a=$?
expect "AC5a: land exits 0" "[ $rc_a -eq 0 ]"
expect "AC5a: no cross-repo-gate line in worktree-extend journal" "! grep -q cross-repo-gate \"$JOURNAL_A\" 2>/dev/null"

echo "=== AC5b: --writer-build-into omitted entirely (legacy callers) ==="
SLUG_B="ac5b-slug"
WT_B="$("$WORKTREE_EXTEND" add "$REPO" "$SLUG_B" 2>/dev/null)"
printf 'change b\n' >> "$WT_B/README.md"
git -C "$WT_B" "${GIT_ID[@]}" add -A
git -C "$WT_B" "${GIT_ID[@]}" commit -q -m "change b"
JOURNAL_B="$T/journal-b.md"
WORKTREE_EXTEND_JOURNAL="$JOURNAL_B" "$WORKTREE_EXTEND" land "$REPO" "$SLUG_B" >"$T/out-b" 2>&1
rc_b=$?
expect "AC5b: land exits 0" "[ $rc_b -eq 0 ]"
expect "AC5b: no journal file was even created (byte-identical to pre-this-PRD)" "[ ! -f \"$JOURNAL_B\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac5: ALL PASS"
else
  echo "xrepo_ac5: assertion(s) FAILED"
fi
exit "$fail"
