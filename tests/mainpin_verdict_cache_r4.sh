#!/usr/bin/env bash
# tests/mainpin_verdict_cache_r4.sh — PRD-build-main-verdict-pinned-to-landing
# R4: "the verdict at M is recorded in the verdict cache keyed by M's tree;
# any later question for S reads it and launches no gate (`cached=`
# increments in the tick serialization line)."
#
# Why this needs its OWN test, not just mainpin_pin_gate_wiring.sh: that
# test fakes extend-gate.sh entirely (correct for testing the WORKTREE/ARGV
# wiring, but it never exercises extend-gate.sh's real tree/hash-keyed
# cache-hit logic at all). main-verdict-pin-gate.sh gates a DETACHED
# worktree it removes after every run (own header) — extend-gate.sh's
# ordinary cache_file lives INSIDE that worktree
# (<worktree>/target/autobuilder/last-verdict.json), so without the
# `--verdict-cache-mirror` wiring this step adds, every single pinned
# question for an already-verified slug would silently re-run the full
# 25-producer sequence forever, never hitting a cache that "should be a
# hit forever" (Technical considerations) — the exact regression this test
# guards against.
#
# Technique (same as gate-verdict-tree-cache-selftest.sh, which tests the
# sibling branch/land cache-transfer case): fabricate a valid
# last-verdict.json directly under the mirror path main-verdict-pin-gate.sh
# will look for BEFORE the run, with a REAL extend-gate.sh's own sha256 so
# the real cache-read code's hash check is genuinely exercised — then call
# the REAL main-verdict-pin-gate.sh (never a fake), and assert it exits
# fast, reports (cached), and never ran a single producer.
#
#   AC-R4-1: a pre-seeded mirror cache (tree_sha = M's tree, script_sha256
#     = the real extend-gate.sh's own hash) makes a pinned gate for M a
#     cache hit — no producer output, journal line names `(cached tree=...)`.
#   AC-R4-2: with NO pre-seeded mirror, a pinned gate for a DIFFERENT M'
#     (mismatched tree) is correctly a miss — falls through toward a real
#     run (never falsely reports cached) — proves the seed-in isn't a
#     blanket bypass.
#   AC-R4-3: after a cache-hit run, the mirror file is still present and
#     still carries the same tree_sha — the persist-out path (identical
#     code at the fresh-write site, see extend-gate.sh's own R4 comments)
#     never corrupts or drops the mirror on a replay.
#
# Everything lives under $TMPDIR; BUILD_STATE_DIR/BUILD_WT_ROOT point at
# this test's own tree, never the running skill's production state/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
PIN_GATE="$HERE/main-verdict-pin-gate.sh"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$PIN_GATE" ] || { echo "selftest: $PIN_GATE not executable" >&2; exit 2; }
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
for bin in git jq sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-verdict-cache-r4.XXXXXX")"
trap '[ -n "${MAINPIN_VERDICT_CACHE_R4_KEEP:-}" ] || rm -rf "$T"' EXIT

SELF_HASH="$(sha256sum "$EXTEND_GATE" | awk '{print $1}')"
GIT_ID=(-c user.email=t@mainpin-r4.local -c user.name=mainpin-r4-selftest)

REPO="$T/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "mainpin-r4-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$REPO/src/lib.rs"
printf '/target\n/.cargo\n' > "$REPO/.gitignore"
( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "c1 (base)"
git -C "$REPO" "${GIT_ID[@]}" commit -q --allow-empty -m "c2 (the landing, M)"
M_SHA="$(git -C "$REPO" rev-parse HEAD)"
M_TREE="$(git -C "$REPO" rev-parse "HEAD^{tree}")"
REPO_SLUG="$(basename "$REPO")"

STATE_DIR="$T/state"
WT_ROOT="$T/wtroot"
JOURNAL="$T/journal.md"
mkdir -p "$STATE_DIR/landings/$REPO_SLUG" "$WT_ROOT"
SLUG="mainpin-r4-fixture-slug"
cat > "$STATE_DIR/landings/$REPO_SLUG/$SLUG.json" <<EOF
{"pr_number": 1, "merge_sha": "$M_SHA", "armed_at": "2026-09-17T00:00:00Z"}
EOF

run_pin_gate() {
  env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" EXTEND_GATE_JOURNAL="$JOURNAL" \
      PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
      timeout -k 5 40 "$PIN_GATE" "$REPO" "$SLUG"
}

# =========================================================================
# AC-R4-1/AC-R4-3: a pre-seeded mirror for M is a cache hit, no producers
# =========================================================================
echo "=== AC-R4-1: pre-seeded mirror at M's tree is a cache hit ==="
MIRROR="$STATE_DIR/main-verdict-cache/$REPO_SLUG/$SLUG.json"
mkdir -p "$(dirname "$MIRROR")"
jq -n --arg head "$M_SHA" --arg tree "$M_TREE" --arg hash "$SELF_HASH" \
     --arg scope main --arg slug "$SLUG" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: $hash,
   verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
   cargo_route: {intended: "local", burst: 0, local: 0, passthrough: 0, host: "local"},
   blocks: [], attribution: {in_scope: 0, inherited: 0}, phases: {}, wall_s: 1,
   scope: $scope, slug: $slug, deferred_receipts: []}' > "$MIRROR"
MIRROR_BEFORE_HASH="$(sha256sum "$MIRROR" | awk '{print $1}')"

out="$T/run1.out"
run_pin_gate >"$out" 2>&1
rc=$?
cat "$out"
expect "AC-R4-1: exits 0 (cached pass)" "[ $rc -eq 0 ]"
expect "AC-R4-1: stdout reports (cached)" "grep -q '(cached)' \"$out\""
expect "AC-R4-1: NO producer output (proof of no real run)" \
  "! grep -qE 'autobuilder (intake|loop|vti-plan|rollback-plan|reviewer-agent|ci-checks)' \"$out\""
expect "AC-R4-1: journal names a cache-hit line with M's tree" \
  "grep -q \"(cached tree=$M_TREE from=main slug=$SLUG)\" \"$JOURNAL\""
expect "AC-R4-1: the detached worktree is gone again" \
  "[ ! -d \"$WT_ROOT/${REPO_SLUG}-${SLUG}-verify\" ]"

echo "=== AC-R4-3: mirror survives the cache-hit replay unchanged ==="
expect "AC-R4-3: mirror file still exists" "[ -f \"$MIRROR\" ]"
expect "AC-R4-3: mirror still carries M's tree_sha" \
  "[ \"\$(jq -r .tree_sha \"$MIRROR\")\" = \"$M_TREE\" ]"
expect "AC-R4-3: mirror content unchanged by the replay (byte-identical verdict)" \
  "[ \"\$(sha256sum \"$MIRROR\" | awk '{print \$1}')\" = \"$MIRROR_BEFORE_HASH\" ]"

# =========================================================================
# AC-R4-2: no mirror (or a mismatched one) is correctly a miss, not a
# false hit — falls through toward a real run instead of trusting a stale
# entry. Uses a SECOND, freshly-landed slug at a DIFFERENT M' so this
# case can't accidentally reuse AC-R4-1's now-populated mirror/worktree.
# =========================================================================
echo "=== AC-R4-2: a mismatched-tree mirror is never a false cache hit ==="
# A real file change, not --allow-empty — an empty commit's tree is
# byte-identical to its parent's, which would make M2's tree equal M's
# tree and defeat this case's whole point (a genuinely DIFFERENT tree).
printf 'pub fn sub(a: i32, b: i32) -> i32 { a - b }\n' >> "$REPO/src/lib.rs"
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "c3 (a second landing, M-prime)"
M2_SHA="$(git -C "$REPO" rev-parse HEAD)"
SLUG2="mainpin-r4-fixture-slug-2"
cat > "$STATE_DIR/landings/$REPO_SLUG/$SLUG2.json" <<EOF
{"pr_number": 2, "merge_sha": "$M2_SHA", "armed_at": "2026-09-17T00:00:00Z"}
EOF
MIRROR2="$STATE_DIR/main-verdict-cache/$REPO_SLUG/$SLUG2.json"
mkdir -p "$(dirname "$MIRROR2")"
# Deliberately seeded with the FIRST landing's tree (M, not M-prime) — a
# stale/mismatched entry that must never be trusted for SLUG2's own M'.
jq -n --arg head "$M_SHA" --arg tree "$M_TREE" --arg hash "$SELF_HASH" \
     --arg scope main --arg slug "$SLUG2" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: $hash,
   verdict: "pass", exit_code: 0, scope: $scope, slug: $slug, deferred_receipts: []}' > "$MIRROR2"

out2="$T/run2.out"
env BUILD_STATE_DIR="$STATE_DIR" BUILD_WT_ROOT="$WT_ROOT" EXTEND_GATE_JOURNAL="$JOURNAL" \
    PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
    timeout -k 5 15 "$PIN_GATE" "$REPO" "$SLUG2" >"$out2" 2>&1
rc2=$?
cat "$out2"
# A real run's cache decision happens near-immediately (right after the
# integration lock, well before any of the 25 producers start). This
# minimal fixture repo then falls through to a genuine (fast) block —
# no agent/intent-card.json, no GitHub remote — rather than a slow real
# gate (a real fleet repo's own gate can take up to 1659s, the whole
# reason this PRD exists); `timeout` is a safety bound only, not expected
# to fire. What matters either way: it never printed (cached) — a
# mismatched-tree mirror must never be reported a hit.
expect "AC-R4-2: a tree-mismatched mirror never prints (cached)" "! grep -q '(cached)' \"$out2\""
expect "AC-R4-2: no false cache-hit journal line for SLUG2 at the stale tree" \
  "! grep -q \"(cached tree=$M_TREE from=main slug=$SLUG2)\" \"$JOURNAL\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_verdict_cache_r4: ALL PASS"
  exit 0
else
  echo "mainpin_verdict_cache_r4: assertion(s) FAILED"
  exit 1
fi
