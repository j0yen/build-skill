#!/usr/bin/env bash
# landres_ac10_worktree_extend_land_resolves.sh —
# PRD-build-land-conflict-resolver AC10/R8 (P1): a shell/python worktree
# land (`worktree-extend.sh land`, cmd_land) gets the same policy-
# classified conflict resolution gate-then-land.sh's rebase_onto_main
# already has for rust-extend — land_resolve_attempt() tries
# land-resolve.sh before any of cmd_land's die-4/die-5 conflict exits.
#
# Three scenarios:
#   A — the pre-ff-merge rebase site (default advanced while the
#       worktree still exists — the common "sibling landed first" case,
#       same shape landres_ac1's Scenario A already covers for
#       gate-then-land.sh/rust-extend): a policy-listed generated file
#       conflicts; land_resolve_attempt resolves it via a real rebase
#       continue, `land` exits 0 and lands rather than die 5.
#   B — the direct-merge site (no worktree present at land time — e.g. a
#       cleaned-up worktree whose branch ref survives — so `cmd_land`
#       skips straight to `git merge --no-ff` against $repo itself): the
#       same generated-file conflict, now a MERGE conflict rather than a
#       rebase conflict, resolves via land-resolve.sh's
#       git_conflict_continue committing the merge (not
#       `rebase --continue` — the two need different finishing commands).
#       `land` exits 0, never die 4.
#   C — regression: a source-file conflict (no policy, no coder
#       configured) at the Scenario A call site still dies exactly as
#       before this PRD (exit 5, branch kept, main untouched).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE_EXTEND="$HERE/../scripts/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "FAIL: $WORKTREE_EXTEND not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

fail=0
GIT_ID=(-c user.email=test@landres-ac10.local -c user.name="landres-ac10")

# require_git_dir <var-name> <path> — hard-fails (exit 2, not just FAIL) if
# <path> is empty or not a git worktree. Belt-and-braces against `git -C
# "$EMPTY_VAR" commit ...` silently falling back to the CURRENT working
# directory (git treats an empty -C argument as "no -C given") — the exact
# landmine landres_ac1_pregate_rebase_resolves_generated.sh's own comment
# warns about, and the one that actually fired once while drafting this
# file (a since-fixed `local name=... repo=...` bug left $repo unset,
# `git -C "" commit` then committed this repo's OWN cwd under the
# fixture's identity). Every REPO_*/WT_* this test creates is checked
# immediately after assignment, before any `git -C` call ever sees it.
require_git_dir() {
  local name="$1" path="$2"
  if [ -z "$path" ] || ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "FAIL: $name is empty or not a git dir ('$path') — refusing to run any git -C against it" >&2
    exit 2
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/landres-ac10-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
export STATE_DIR="$T/state"
export BUILD_STATE_DIR="$T/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"
trap '[ -n "${LANDRES_AC10_KEEP:-}" ] || rm -rf "$T"' EXIT

mk_repo_with_gen() {  # $1=name -> prints repo path
  local name="$1"
  local repo="$T/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  cat >"$repo/regen.sh" <<'EOF'
#!/usr/bin/env bash
echo "generated-canonical-v1" > gen.txt
EOF
  chmod +x "$repo/regen.sh"
  ( cd "$repo" && ./regen.sh )
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m base
  cat >"$BUILD_STATE_DIR/land-policy/$name.json" <<'EOF'
{"generated": [{"path": "gen.txt", "regen": "./regen.sh"}], "append_only": []}
EOF
  echo "$repo"
}

# === Scenario A: pre-ff-merge rebase site, generated-file conflict ===
REPO_A="$(mk_repo_with_gen repoA)"
require_git_dir REPO_A "$REPO_A"
WT_A="$("$WORKTREE_EXTEND" add "$REPO_A" ac10a-slug 2>/dev/null)"
require_git_dir WT_A "$WT_A"
echo "generated-canonical-v1-branch-variant" > "$WT_A/gen.txt"
git -C "$WT_A" "${GIT_ID[@]}" commit -q -am "branch variant of gen.txt"
echo "generated-canonical-v1-main-variant" > "$REPO_A/gen.txt"
git -C "$REPO_A" "${GIT_ID[@]}" commit -q -am "main variant of gen.txt"

out_a="$T/out-a.log"
"$WORKTREE_EXTEND" land "$REPO_A" ac10a-slug >"$out_a" 2>"$out_a.err"
rc_a=$?
cat "$out_a.err" >&2

if [ "$rc_a" -eq 0 ]; then
  echo "ok  AC10 (A): land exits 0 (pre-ff-merge rebase conflict resolved, not died)"
else
  echo "FAIL (A): expected land to exit 0, got rc=$rc_a" >&2
  fail=1
fi
if grep -q 'land-resolve resolved the pre-ff-merge rebase conflict' "$out_a.err"; then
  echo "ok  AC10 (A): stderr names the resolved rebase conflict"
else
  echo "FAIL (A): no 'land-resolve resolved the pre-ff-merge rebase conflict' line" >&2
  fail=1
fi
[ "$(cat "$REPO_A/gen.txt" 2>/dev/null)" = "generated-canonical-v1" ] \
  && echo "ok  AC10 (A): landed gen.txt equals the regen output" \
  || { echo "FAIL (A): gen.txt != regen output" >&2; fail=1; }

# === Scenario B: direct-merge site (no worktree present) ===
REPO_B="$(mk_repo_with_gen repoB)"
require_git_dir REPO_B "$REPO_B"
WT_B="$("$WORKTREE_EXTEND" add "$REPO_B" ac10b-slug 2>/dev/null)"
require_git_dir WT_B "$WT_B"
echo "generated-canonical-v1-branch-variant" > "$WT_B/gen.txt"
git -C "$WT_B" "${GIT_ID[@]}" commit -q -am "branch variant of gen.txt"
git -C "$REPO_B" worktree remove "$WT_B" --force 2>/dev/null
echo "generated-canonical-v1-main-variant" > "$REPO_B/gen.txt"
git -C "$REPO_B" "${GIT_ID[@]}" commit -q -am "main variant of gen.txt"

out_b="$T/out-b.log"
"$WORKTREE_EXTEND" land "$REPO_B" ac10b-slug >"$out_b" 2>"$out_b.err"
rc_b=$?
cat "$out_b.err" >&2

if [ "$rc_b" -eq 0 ]; then
  echo "ok  AC10 (B): land exits 0 (direct-merge conflict resolved, not died)"
else
  echo "FAIL (B): expected land to exit 0, got rc=$rc_b" >&2
  fail=1
fi
if grep -q 'land-resolve resolved the merge conflict landing' "$out_b.err"; then
  echo "ok  AC10 (B): stderr names the resolved merge conflict (git commit, not rebase --continue)"
else
  echo "FAIL (B): no 'land-resolve resolved the merge conflict landing' line" >&2
  fail=1
fi
[ "$(cat "$REPO_B/gen.txt" 2>/dev/null)" = "generated-canonical-v1" ] \
  && echo "ok  AC10 (B): landed gen.txt equals the regen output" \
  || { echo "FAIL (B): gen.txt != regen output" >&2; fail=1; }

# === Scenario C: regression — source conflict, no policy, still dies ===
REPO_C="$T/repoC"
mkdir -p "$REPO_C/src"
git -C "$REPO_C" init -q -b main
require_git_dir REPO_C "$REPO_C"
printf 'fn main() {}\n' >"$REPO_C/src/lib.rs"
git -C "$REPO_C" "${GIT_ID[@]}" add -A
git -C "$REPO_C" "${GIT_ID[@]}" commit -q -m base

WT_C="$("$WORKTREE_EXTEND" add "$REPO_C" ac10c-slug 2>/dev/null)"
require_git_dir WT_C "$WT_C"
printf 'fn main() { branch(); }\n' >"$WT_C/src/lib.rs"
git -C "$WT_C" "${GIT_ID[@]}" commit -q -am "branch source change"
printf 'fn main() { mainc(); }\n' >"$REPO_C/src/lib.rs"
git -C "$REPO_C" "${GIT_ID[@]}" commit -q -am "main source change"
# No state/land-policy/repoC.json -> every path classifies source; no
# $LAND_RESOLVE_CODER configured -> R4 never attempted either.

out_c="$T/out-c.log"
"$WORKTREE_EXTEND" land "$REPO_C" ac10c-slug >"$out_c" 2>"$out_c.err"
rc_c=$?
cat "$out_c.err" >&2

if [ "$rc_c" -eq 5 ]; then
  echo "ok  AC10 (C, regression): land still exits 5 on an unresolvable source conflict (no policy, no coder)"
else
  echo "FAIL (C): expected rc=5, got rc=$rc_c" >&2
  fail=1
fi
if [ -z "$(git -C "$REPO_C" status --porcelain)" ]; then
  echo "ok  AC10 (C, regression): main left clean"
else
  echo "FAIL (C): $REPO_C not clean after the refused land" >&2
  fail=1
fi

exit $fail
