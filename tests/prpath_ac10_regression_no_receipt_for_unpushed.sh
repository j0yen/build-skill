#!/usr/bin/env bash
# tests/prpath_ac10_regression_no_receipt_for_unpushed.sh —
# PRD-build-main-push-gate-pr-path AC10: replays the shape of the
# 2026-09-16 incident (decision ccaa7224) more faithfully than AC1/AC2's
# single-land fixture — THREE successive lands on the same push_via_
# branch=true repo, each one pushing its OWN `loop/<slug>` branch/PR
# immediately (this PRD's fix), so local `main` ends up several commits
# ahead of `origin/main` while three landings sit pending in parallel —
# the same "main advanced locally, origin/main lagging" shape the
# incident's `58b4d29`/18-commits-ahead state had, just no longer a
# circular precondition. Asserts, across all three lands combined, that
# `extend-gate.sh` was NEVER invoked at `--scope main` (a regression here
# would mean the AC1/AC2 fix only holds for a single land, not a run of
# them) — plus a static check that the specific push_via_branch main-
# scope block in extend-gate.sh itself can never treat an unpushed sha as
# CI-verified (no `git push`, no HEAD-runs `autobuilder ci-checks` call
# inside that block).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"
GTL="$PRPATH_SCRIPTS/gate-then-land.sh"
GIT_ID=(-c user.email=test@prpath-selftest.local -c user.name="prpath-selftest")

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac10.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# Same fake-extend-gate.sh shape as prpath_ac1_ac2's own fixture (always
# verdict=pass; logs "scope=<scope> head=<head>" per call).
cat > "$ROOT/fake-extend-gate.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
wt="$1"; shift
mode="gate"; head_sha=""; scope=""; slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --print-verdict-path) mode="path"; shift ;;
    *) shift ;;
  esac
done
cache_file="$wt/target/autobuilder/last-verdict.json"
if [ "$mode" = path ]; then echo "$cache_file"; exit 0; fi
echo "scope=$scope head=$head_sha" >> "${PRPATH_GATE_CALLS_LOG:-/dev/null}"
mkdir -p "$(dirname "$cache_file")"
tree_now="$(git -C "$wt" rev-parse HEAD^{tree})"
jq -n --arg head "$head_sha" --arg tree "$tree_now" --arg scope "$scope" --arg slug "$slug" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: "fake",
   verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
   deferred_receipts: [], scope: $scope, slug: $slug}' > "$cache_file"
exit 0
FAKE
chmod +x "$ROOT/fake-extend-gate.sh"

REPO="$ROOT/mcphost-fixture"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
printf '/target\n/.cargo\n' > "$REPO/.gitignore"
printf 'pub fn f() {}\n' > "$REPO/src/lib.rs"
cat > "$REPO/Cargo.toml" <<EOF
[package]
name = "mcphost-fixture"
version = "0.1.0"
EOF
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m init
git clone -q --bare "$REPO" "$ROOT/origin.git"
git -C "$REPO" remote add origin "$ROOT/origin.git"
git -C "$REPO" push -q origin main
repo_slug="$(basename "$REPO")"

export BUILD_WT_ROOT="$ROOT/build-worktrees"
export BUILD_STATE_DIR="$ROOT/state"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
gate_calls="$ROOT/gate-calls.log"
: > "$gate_calls"
journal="$ROOT/journal.md"

for n in 1 2 3; do
  slug="land-$n"
  wt="$(env PATH="$bindir:$PATH" "$PRPATH_SCRIPTS/worktree-extend.sh" add "$REPO" "$slug" 2>/dev/null)"
  printf 'pub fn g%s() {}\n' "$n" >> "$wt/src/lib.rs"
  git -C "$wt" "${GIT_ID[@]}" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -q -m "land $n"

  out="$ROOT/out-$n.log"
  env PATH="$bindir:$PATH" \
      GATE_THEN_LAND_EXTEND_GATE="$ROOT/fake-extend-gate.sh" \
      GATE_THEN_LAND_JOURNAL="$journal" WORKTREE_EXTEND_JOURNAL="$journal" \
      PRPATH_GATE_CALLS_LOG="$gate_calls" \
      "$GTL" "$REPO" "$slug" minor /dev/null >"$out" 2>"$out.err"
  rc="$?"
  cat "$out" "$out.err" >&2
  prpath_expect "AC10: land $n exits 0" "[ $rc -eq 0 ]"
done

ahead="$(git -C "$REPO" rev-list --count origin/main..main)"
prpath_expect "AC10: local main is several commits ahead of origin/main (>=3)" "[ \"$ahead\" -ge 3 ]"
prpath_expect "AC10: extend-gate.sh was NEVER called at --scope main across all 3 lands" \
  "! grep -q 'scope=main' \"$gate_calls\""
prpath_expect "AC10: no post-land-main-gate-block for any land" "! grep -q post-land-main-gate-block \"$journal\""
prpath_expect "AC10: 3 distinct PRs were opened (one gh pr create per land)" \
  "[ \"\$(wc -l < \"$bindir/pr-create-calls.log\")\" -eq 3 ]"
prpath_expect "AC10: 3 landing records exist" \
  "[ \"\$(find \"$BUILD_STATE_DIR/landings/$repo_slug\" -maxdepth 1 -name '*.json' | wc -l)\" -eq 3 ]"

# --- static regression guardrail: the push_via_branch main-scope block in
# extend-gate.sh itself (the `else` / --scope main branch of the
# `ci-checks` producer) can never push `main` or fall back to a raw
# HEAD-runs lookup -- extracted between its own `if [ "$(push_via_branch_for`
# guard and the `elif ( cd "$repo" && autobuilder ci-checks` fallback that
# ONLY applies to push_via_branch=false. -----------------------------------
# Written to a FILE, not interpolated into an eval'd condition string --
# this is real shell source, full of double quotes and `$(...)`, which
# would break prpath_expect's `eval` if spliced straight in (same
# gotcha prpath_ac6's own test file already documents for JSON).
EXTEND_GATE_SRC="$PRPATH_HERE/scripts/extend-gate.sh"
block_file="$ROOT/pvb-main-scope-block.txt"
awk '/elif \( cd "\$repo" && autobuilder ci-checks/{exit} /if \[ "\$\(push_via_branch_for/{flag=1} flag{print}' \
  "$EXTEND_GATE_SRC" > "$block_file"
prpath_expect "AC10: extend-gate.sh's push_via_branch main-scope block was found (non-empty)" "[ -s \"$block_file\" ]"
prpath_expect "AC10: that block never runs 'git push'" "! grep -q 'git push' \"$block_file\""
prpath_expect "AC10: that block never calls the raw HEAD-runs 'autobuilder ci-checks'" \
  "! grep -qE 'autobuilder ci-checks --project' \"$block_file\""

exit "$prpath_fail"
