#!/usr/bin/env bash
# landres_ac1_pregate_rebase_resolves_generated.sh —
# PRD-build-land-conflict-resolver AC1/R1: gate-then-land.sh now rebases
# the worktree onto main's CURRENT tip before the branch gate, not after
# (the grounding incident: gate-debt-4f1112d gated a tree already behind
# main). Two scenarios, both pre-advancing $repo's main BEFORE
# gate-then-land.sh is ever invoked (a real, not simulated, stale base —
# unlike gate-then-land-selftest.sh's fake-gate side-effect trick, which
# only exercises staleness that happens DURING the run):
#
#   Scenario A — main's pre-advance conflicts with the branch ONLY in a
#     policy-listed generated file: When gate-then-land.sh runs, Then
#     rebase_onto_main()'s land-resolve.sh call regenerates it before the
#     FIRST gate attempt even happens (attempt 1's gate sees the rebased
#     head), and the branch lands — no `land-conflict` anywhere.
#   Scenario B — main's pre-advance conflicts with the branch in a plain
#     source file (no policy): When gate-then-land.sh runs, Then it exits
#     8 with a `rebase-conflict ... pre-gate=true` journal line BEFORE any
#     `attempt 1/3` gate line is ever printed — the fix-before-gate order
#     is the whole point of R1, so this is the one thing worth asserting
#     beyond gate-then-land-selftest.sh's existing coverage of the LOOP.
#
# `extend-gate.sh` is the same fixture stub gate-then-land-selftest.sh
# uses (fast, no real cargo run) — this test is about the pre-gate rebase
# wiring, not re-proving a real gate verdict.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GTL="$HERE/../scripts/gate-then-land.sh"
WORKTREE_EXTEND="$HERE/../scripts/worktree-extend.sh"
[ -x "$GTL" ] || { echo "FAIL: $GTL not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}
# require_git_dir <var-name> <path> — hard-fails (exit 2, not just FAIL) if
# <path> is empty or not a git worktree. Belt-and-braces against `git -C
# "$EMPTY_VAR" commit ...` silently falling back to the CURRENT working
# directory (git treats an empty -C argument as "no -C given" — confirmed
# the hard way: a bug upstream of this file once left WT_A empty, and the
# resulting `git -C "" commit -am ...` committed THIS SCRIPT'S OWN cwd,
# under the fixture's fake git identity, into whatever real repo the test
# happened to be run from). Every REPO_*/WT_* this test creates is checked
# immediately after assignment, before any `git -C` call ever sees it.
require_git_dir() {
  local name="$1" path="$2"
  if [ -z "$path" ] || ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "FAIL: $name is empty or not a git dir ('$path') — refusing to run any git -C against it" >&2
    exit 2
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/landres-pregate-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
export STATE_DIR="$T/state"
export BUILD_STATE_DIR="$T/state"
GIT_ID=(-c user.email=test@landres-selftest.local -c user.name="landres-selftest")
trap '[ -n "${LANDRES_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

cat > "$T/fake-extend-gate.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
wt="$1"; shift
mode="gate"; head_sha=""; scope=""; slug=""; project_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --project-root) project_root="$2"; shift 2 ;;
    --print-verdict-path) mode="path"; shift ;;
    *) shift ;;
  esac
done
root="$wt"; [ -n "$project_root" ] && root="$wt/$project_root"
cache_file="$root/target/autobuilder/last-verdict.json"
if [ "$mode" = path ]; then
  echo "$cache_file"
  exit 0
fi
mkdir -p "$(dirname "$cache_file")"
tree_now="$(git -C "$wt" rev-parse HEAD^{tree})"
jq -n --arg head "$head_sha" --arg tree "$tree_now" --arg scope "$scope" --arg slug "$slug" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: "fake",
   verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
   scope: $scope, slug: $slug}' > "$cache_file"
exit 0
FAKE
chmod +x "$T/fake-extend-gate.sh"

mk_repo_with_gen() {  # $1=name -> prints repo path
  local name="$1"
  local repo="$T/$name"
  mkdir -p "$repo/src"
  git -C "$repo" init -q -b main
  printf '/target\n/.cargo\n' > "$repo/.gitignore"
  printf 'pub fn f() {}\n' > "$repo/src/lib.rs"
  cat > "$repo/regen.sh" <<'EOF'
#!/usr/bin/env bash
echo "generated-canonical-v1" > gen.txt
EOF
  chmod +x "$repo/regen.sh"
  ( cd "$repo" && ./regen.sh )
  cat > "$repo/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
EOF
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m init
  mkdir -p "$STATE_DIR/land-policy"
  cat > "$STATE_DIR/land-policy/$name.json" <<'EOF'
{"generated": [{"path": "gen.txt", "regen": "./regen.sh"}], "append_only": []}
EOF
  echo "$repo"
}

# =========================================================================
# Scenario A — pre-advanced main conflicts only in the generated file
# =========================================================================
echo "=== Scenario A: pre-gate rebase resolves a generated-file conflict, then lands ==="
REPO_A="$(mk_repo_with_gen scenPgA)"
require_git_dir REPO_A "$REPO_A"
WT_A="$("$WORKTREE_EXTEND" add "$REPO_A" scenPgA-slug 2>/dev/null)"
require_git_dir WT_A "$WT_A"
# Branch commit: touches gen.txt (a stale/branch variant, real divergence).
echo "generated-canonical-v1-branch-variant" > "$WT_A/gen.txt"
git -C "$WT_A" "${GIT_ID[@]}" commit -q -am "branch variant of gen.txt"
# Main pre-advances BEFORE gate-then-land.sh is ever invoked — the real
# staleness R1 exists to catch, not a during-the-run simulation.
echo "generated-canonical-v1-main-variant" > "$REPO_A/gen.txt"
git -C "$REPO_A" "${GIT_ID[@]}" commit -q -am "main variant of gen.txt (pre-advance)"
main_before_a="$(git -C "$REPO_A" rev-parse HEAD)"

JOURNAL_A="$T/journal-a.md"
out_a="$T/out-a.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_A" WORKTREE_EXTEND_JOURNAL="$JOURNAL_A" \
    "$GTL" "$REPO_A" scenPgA-slug minor /dev/null >"$out_a" 2>"$out_a.err"
rc_a=$?
cat "$out_a" "$out_a.err" >&2

expect "AC1: gate-then-land exits 0 (pre-gate resolve let it land)" "[ $rc_a -eq 0 ]"
expect "AC1: gate attempt 1/3 was gated AGAINST the pre-advanced main sha" \
  "grep -q \"against main=$main_before_a\" \"$out_a.err\""
expect "AC1: no land-conflict was ever recorded" "! grep -q land-conflict \"$JOURNAL_A\""
expect "AC1: gen.txt landed equal to the regen output (not a stale variant)" \
  "[ \"\$(cat \"$REPO_A/gen.txt\")\" = generated-canonical-v1 ]"

# =========================================================================
# Scenario B — pre-advanced main conflicts in a plain source file (no
# policy entry): must fail BEFORE any gate attempt, not after.
# =========================================================================
echo "=== Scenario B: pre-gate rebase conflict in a source file -> exit 8 before any gate attempt ==="
REPO_B="$(mk_repo_with_gen scenPgB)"
require_git_dir REPO_B "$REPO_B"
WT_B="$("$WORKTREE_EXTEND" add "$REPO_B" scenPgB-slug 2>/dev/null)"
require_git_dir WT_B "$WT_B"
echo "branch change" > "$WT_B/src/lib.rs"
git -C "$WT_B" "${GIT_ID[@]}" commit -q -am "branch changed lib.rs"
echo "main change" > "$REPO_B/src/lib.rs"
git -C "$REPO_B" "${GIT_ID[@]}" commit -q -am "main changed lib.rs (pre-advance, real source conflict)"

JOURNAL_B="$T/journal-b.md"
out_b="$T/out-b.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_B" WORKTREE_EXTEND_JOURNAL="$JOURNAL_B" \
    "$GTL" "$REPO_B" scenPgB-slug minor /dev/null >"$out_b" 2>"$out_b.err"
rc_b=$?
cat "$out_b" "$out_b.err" >&2

expect "AC1: gate-then-land exits 8 (rebase conflict, source file)" "[ $rc_b -eq 8 ]"
expect "AC1: NO gate attempt line was ever printed (fixed before gate, not after)" \
  "! grep -q 'attempt 1/3' \"$out_b.err\""
expect "AC1: journal records the conflict as pre-gate" "grep -q 'pre-gate=true' \"$JOURNAL_B\""
expect "AC1: branch's worktree was restored (rebase aborted, no lingering rebase state)" \
  "[ -z \"\$(git -C \"$WT_B\" status --porcelain 2>/dev/null)\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "landres_ac1_pregate_rebase_resolves_generated: ALL PASS"
  exit 0
else
  echo "landres_ac1_pregate_rebase_resolves_generated: assertion(s) FAILED"
  exit 1
fi
