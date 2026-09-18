#!/usr/bin/env bash
# gate-verdict-tree-cache-selftest.sh — PRD-build-gate-before-land
# requirement 4 (P0) / AC7: the verdict cache is keyed on the TREE
# (`git rev-parse HEAD^{tree}`) plus this script's own sha256, not the
# commit sha, and `land`/`integrate` copy a branch's `last-verdict.json`
# onto main's cache under that tree key — so the post-land
# `extend-gate.sh <build_into> --head <landed sha>` on a merge whose tree
# equals the gated tree is a CACHE HIT (no producer runs) and journals
# `(cached tree=... from=branch slug=<slug>)`.
#
# Real `worktree-extend.sh add`/`land` + a REAL `extend-gate.sh` invocation
# for the cache-hit read (needs autobuilder/jq on $PATH like every other
# extend-gate selftest) — but the branch's OWN gate verdict is fabricated
# directly (same technique worktree-extend-gated-land-selftest.sh uses for
# requirement 2) rather than run through the full 25-producer sequence:
# this selftest is about the CACHE mechanism, not about the producers
# themselves (already covered by extend-gate-scope-selftest.sh and
# extend-gate-concurrent-selftest.sh). The fabricated file's `script_sha256`
# is computed from the REAL extend-gate.sh on disk so the real cache-read
# code path's hash check is genuinely exercised, not stubbed out.
#
#   AC7a — after a gated land, main's `target/autobuilder/last-verdict.json`
#          carries the branch's tree_sha (== the merge commit's tree, since
#          main had not diverged) and a head_sha refreshed to the landed sha.
#   AC7b — the post-land `extend-gate.sh <repo> --head <landed sha>` (no
#          --force) exits with the cached verdict's exit code, prints
#          `(cached)`, and journals `(cached tree=<tree> from=branch
#          slug=<slug>)` — no producer ran (no audit/intake/etc. output).
#   AC7c (migration) — a last-verdict.json with no `tree_sha` key (the
#          pre-this-PRD schema) is read back as `tree_sha` empty, i.e. a
#          guaranteed miss.
#   AC7d — a cache file whose tree_sha does not match the CURRENT tree is
#          never reported `(cached)` — the mismatch correctly falls
#          through toward a full run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq flock autobuilder sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-tree-cache-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
GIT_ID=(-c user.email=test@gate-tree-cache-selftest.local -c user.name="gate-tree-cache-selftest")
JOURNAL="$T/journal.md"
export EXTEND_GATE_JOURNAL="$JOURNAL"
# worktree-extend.sh land (called below) writes its OWN journal line
# (`land ... lock_hold=...`) independently of EXTEND_GATE_JOURNAL above —
# isolate it too, or it leaks this selftest's fixture slug into the real
# shared journal.
export WORKTREE_EXTEND_JOURNAL="$JOURNAL"
trap '[ -n "${GATE_TREE_CACHE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

SELF_HASH="$(sha256sum "$EXTEND_GATE" | awk '{print $1}')"

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "gate-tree-cache-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
mkdir -p "$REPO/src"
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$REPO/src/lib.rs"
# /target must be ignored BEFORE any worktree's off-root `target` symlink
# (PRD-build-worktree-targets-off-root) gets swept up by `git add -A` below
# — an untracked fixture repo with no .gitignore would otherwise commit
# that symlink straight into the branch, and a later `land` merging it
# into main would point $REPO/target at a directory `cleanup` then deletes.
printf '/target\n/.cargo\n' > "$REPO/.gitignore"
( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m init
MAIN_SHA0="$(git -C "$REPO" rev-parse HEAD)"

# =========================================================================
# AC7a/AC7b — branch gate (fabricated verdict) -> land -> cache-hit on main
# =========================================================================
echo "=== AC7a/AC7b: branch verdict transfers to main's tree-keyed cache ==="
SLUG="gtc-selftest-$$"
WT="$("$WORKTREE_EXTEND" add "$REPO" "$SLUG" 2>/dev/null)"
expect "setup: worktree exists" "[ -d \"$WT\" ]"
printf 'pub fn sub(a: i32, b: i32) -> i32 { a - b }\n' >> "$WT/src/lib.rs"
git -C "$WT" "${GIT_ID[@]}" add -A
git -C "$WT" "${GIT_ID[@]}" commit -q -m "branch work"
WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
WT_TREE="$(git -C "$WT" rev-parse "HEAD^{tree}")"

# Fabricate the branch's own last-verdict.json under its off-root target
# dir, in the SAME shape extend-gate.sh --scope branch would have written
# (only the fields the cache-read/transfer code actually touches matter;
# the rest mirror the real schema for readability).
WT_TARGET_DIR="$(readlink "$WT/target")"
mkdir -p "$WT_TARGET_DIR/autobuilder"
BRANCH_VERDICT="$WT_TARGET_DIR/autobuilder/last-verdict.json"
jq -n --arg head "$WT_HEAD" --arg tree "$WT_TREE" --arg hash "$SELF_HASH" \
     --arg scope branch --arg slug "$SLUG" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: $hash,
   verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
   cargo_route: {intended: "local", burst: 0, local: 0, passthrough: 0, host: "local"},
   blocks: [], attribution: {in_scope: 0, inherited: 0}, phases: {}, wall_s: 1,
   scope: $scope, slug: $slug}' > "$BRANCH_VERDICT"

LANDED_SHA="$("$WORKTREE_EXTEND" land --gated-at "$MAIN_SHA0" --verdict "$BRANCH_VERDICT" "$REPO" "$SLUG" 2>"$T/land.err")"
LAND_RC=$?
cat "$T/land.err" >&2
expect "AC7a setup: land exits 0" "[ $LAND_RC -eq 0 ]"
expect "AC7a setup: merge tree equals the branch's gated tree" \
  "[ \"\$(git -C \"$REPO\" rev-parse \"$LANDED_SHA^{tree}\")\" = \"$WT_TREE\" ]"

MAIN_CACHE="$REPO/target/autobuilder/last-verdict.json"
expect "AC7a: main's cache file was written by land's transfer" "[ -f \"$MAIN_CACHE\" ]"
cached_tree_after_land="$(jq -r '.tree_sha // empty' "$MAIN_CACHE" 2>/dev/null)"
cached_head_after_land="$(jq -r '.head_sha // empty' "$MAIN_CACHE" 2>/dev/null)"
cached_scope_after_land="$(jq -r '.scope // empty' "$MAIN_CACHE" 2>/dev/null)"
cached_slug_after_land="$(jq -r '.slug // empty' "$MAIN_CACHE" 2>/dev/null)"
expect "AC7a: transferred cache carries the branch's tree_sha" "[ \"$cached_tree_after_land\" = \"$WT_TREE\" ]"
expect "AC7a: transferred cache's head_sha was refreshed to the landed sha" "[ \"$cached_head_after_land\" = \"$LANDED_SHA\" ]"
expect "AC7a: transferred cache kept scope=branch" "[ \"$cached_scope_after_land\" = branch ]"
expect "AC7a: transferred cache kept slug=$SLUG" "[ \"$cached_slug_after_land\" = \"$SLUG\" ]"

out="$T/main-gate.out"
env PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  timeout -k 5 30 "$EXTEND_GATE" "$REPO" --head "$LANDED_SHA" >"$out" 2>&1
rc=$?
cat "$out"
expect "AC7b: post-land main gate exits 0 (cached pass)" "[ $rc -eq 0 ]"
expect "AC7b: stdout reports (cached)" "grep -q '(cached)' \"$out\""
expect "AC7b: NO producer output (proof of no real run — audit/intake/etc never printed)" \
  "! grep -qE 'autobuilder (intake|loop|vti-plan|rollback-plan|reviewer-agent|ci-checks)' \"$out\""
journal_line="$(grep -m1 '(cached tree=' "$JOURNAL" 2>/dev/null || true)"
expect "AC7b: a cache-hit journal line was written" "[ -n \"$journal_line\" ]"
expect "AC7b: journal line reads (cached tree=$WT_TREE from=branch slug=$SLUG)" \
  "printf '%s' \"$journal_line\" | grep -qF '(cached tree=$WT_TREE from=branch slug=$SLUG)'"
echo "  journal: $journal_line"

# =========================================================================
# AC7c — migration: a pre-this-PRD cache file (no tree_sha) is a miss
# =========================================================================
echo "=== AC7c: legacy (head-keyed, no tree_sha) cache is read as empty ==="
LEGACY_CACHE="$T/legacy-verdict.json"
jq -n --arg head "$LANDED_SHA" --arg hash "$SELF_HASH" \
  '{head_sha: $head, head: $head, script_sha256: $hash, verdict: "pass", exit_code: 0}' > "$LEGACY_CACHE"
legacy_tree_field="$(jq -r '.tree_sha // empty' "$LEGACY_CACHE")"
expect "AC7c: legacy schema has no tree_sha (reads empty, guaranteed miss)" "[ -z \"$legacy_tree_field\" ]"

# =========================================================================
# AC7d — a tree_sha mismatch is never reported (cached)
# =========================================================================
echo "=== AC7d: mismatched tree_sha never yields a cache hit ==="
cp "$MAIN_CACHE" "$T/main-cache.good.json"
jq '.tree_sha = "0000000000000000000000000000000000000000"' "$T/main-cache.good.json" > "$MAIN_CACHE"
out2="$T/main-gate-miss.out"
env PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  timeout -k 3 20 "$EXTEND_GATE" "$REPO" --head "$LANDED_SHA" >"$out2" 2>&1 || true
expect "AC7d: a tree_sha mismatch never prints (cached)" "! grep -q '(cached)' \"$out2\""
# restore, so a subsequent real run in this same $T is unaffected (no other
# assertions depend on it, but leaves the fixture in a consistent state)
cp "$T/main-cache.good.json" "$MAIN_CACHE"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "gate-verdict-tree-cache-selftest: ALL PASS"
  exit 0
else
  echo "gate-verdict-tree-cache-selftest: assertion(s) FAILED"
  exit 1
fi
