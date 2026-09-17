#!/usr/bin/env bash
# tests/prpath_ac1_ac2_landing_sequence.sh — PRD-build-main-push-gate-pr-path
# AC1/AC2: given a fixture repo with push_via_branch=true, a branch whose
# gate verdict is pass at head H (carrying a deferred receipt, to prove the
# die-11 re-verify is skipped even when one exists — see AC2's "the
# deferred-receipt main-scope re-verify did NOT run" clause), gate-then-
# land.sh lands H on local main, pushes loop/<slug> via branch-protection.sh
# push, records the landing, journals landing-pending, and exits 0 WITHOUT
# ever invoking extend-gate.sh at --scope main. A second scenario (AC2,
# push_via_branch=false) proves the historical direct-land behaviour is
# byte-for-byte unchanged: no loop/<slug> branch, no gh calls at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"
GTL="$PRPATH_SCRIPTS/gate-then-land.sh"
GIT_ID=(-c user.email=test@prpath-selftest.local -c user.name="prpath-selftest")

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac1ac2.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# fake-extend-gate.sh — same shape as gate-then-land-selftest.sh's own
# fixture stub (a real gate is a real 60-90s+ cargo/autobuilder producer
# sequence; this selftest is about the PUSH-VIA-BRANCH ORCHESTRATION, not
# re-proving the gate itself). Always verdict=pass; when FAKE_GATE_DEFERRED
# is set, the verdict also carries that deferred_receipts list (proving
# AC2's "no die-11 re-verify, even when this land's own verdict deferred
# something" — a push_via_branch repo skips that block unconditionally).
# Every invocation (except --print-verdict-path) appends
# "scope=<scope> head=<head>" to $PRPATH_GATE_CALLS_LOG so the test can
# assert extend-gate.sh was NEVER called at --scope main.
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
root="$wt"
cache_file="$root/target/autobuilder/last-verdict.json"
if [ "$mode" = path ]; then
  echo "$cache_file"
  exit 0
fi
echo "scope=$scope head=$head_sha" >> "${PRPATH_GATE_CALLS_LOG:-/dev/null}"
mkdir -p "$(dirname "$cache_file")"
tree_now="$(git -C "$wt" rev-parse HEAD^{tree})"
deferred_json="[]"
[ -n "${FAKE_GATE_DEFERRED:-}" ] && deferred_json="$(python3 -c "import json,sys; print(json.dumps(sys.argv[1].split(',')))" "$FAKE_GATE_DEFERRED")"
jq -n --arg head "$head_sha" --arg tree "$tree_now" --arg scope "$scope" --arg slug "$slug" \
     --argjson deferred "$deferred_json" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: "fake",
   verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
   deferred_receipts: $deferred, scope: $scope, slug: $slug}' > "$cache_file"
exit 0
FAKE
chmod +x "$ROOT/fake-extend-gate.sh"

mk_repo_and_branch() {  # $1=name -> prints "repo wt" on stdout
  local name="$1"
  local repo="$ROOT/$name" wt
  mkdir -p "$repo/src"
  git -C "$repo" init -q -b main
  printf '/target\n/.cargo\n' > "$repo/.gitignore"
  printf 'pub fn f() {}\n' > "$repo/src/lib.rs"
  cat > "$repo/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
EOF
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m init
  # A real `origin` remote (bare clone) -- unlike gate-then-land-
  # selftest.sh's own fixture repos, this PRD's push_via_branch path
  # actually pushes `loop/<slug>` and (via `branch-protection.sh sync`,
  # a later AC) reads `origin/main`, so the fixture needs a real remote
  # for `git push origin ...` to succeed against.
  git clone -q --bare "$repo" "$ROOT/${name}-origin.git"
  git -C "$repo" remote add origin "$ROOT/${name}-origin.git"
  git -C "$repo" push -q origin main
  wt="$("$PRPATH_SCRIPTS/worktree-extend.sh" add "$repo" "${name}-slug" 2>/dev/null)"
  printf 'pub fn g() {}\n' >> "$wt/src/lib.rs"
  git -C "$wt" "${GIT_ID[@]}" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -q -m "branch work"
  printf '%s %s\n' "$repo" "$wt"
}

# =========================================================================
# Scenario A (AC1/AC2) — push_via_branch=true: land -> push -> PR -> record
# -> landing-pending, and extend-gate.sh is NEVER called at --scope main.
# =========================================================================
echo "=== Scenario A: push_via_branch=true landing sequence ==="
export BUILD_WT_ROOT="$ROOT/build-worktrees-a"
read -r REPO_A WT_A < <(mk_repo_and_branch pvbA)
repo_slug_a="$(basename "$REPO_A")"

export BUILD_STATE_DIR="$ROOT/state-a"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug_a": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

bindir_a="$ROOT/bin-a"
prpath_install_gh_stub "$bindir_a"
gate_calls_a="$ROOT/gate-calls-a.log"
: > "$gate_calls_a"
journal_a="$ROOT/journal-a.md"

out_a="$ROOT/out-a.log"
env PATH="$bindir_a:$PATH" \
    GATE_THEN_LAND_EXTEND_GATE="$ROOT/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$journal_a" WORKTREE_EXTEND_JOURNAL="$journal_a" \
    PRPATH_GATE_CALLS_LOG="$gate_calls_a" FAKE_GATE_DEFERRED="ci-checks" \
    "$GTL" "$REPO_A" pvbA-slug minor /dev/null >"$out_a" 2>"$out_a.err"
rc_a=$?
cat "$out_a" "$out_a.err" >&2

prpath_expect "AC1: gate-then-land exits 0" "[ $rc_a -eq 0 ]"
landed_sha_a="$(cat "$out_a" 2>/dev/null | tr -d '[:space:]')"
prpath_expect "AC1: stdout printed the landed sha (40 hex chars)" "printf '%s' \"$landed_sha_a\" | grep -qE '^[0-9a-f]{40}\$'"
prpath_expect "AC1: local main contains the landed sha" \
  "[ \"\$(git -C \"$REPO_A\" rev-parse HEAD)\" = \"$landed_sha_a\" ]"
prpath_expect "AC1: loop/pvbA-slug was pushed (exists in the fixture 'origin' bare-less clone)" \
  "git -C \"$REPO_A\" show-ref --verify --quiet refs/heads/loop/pvbA-slug"
prpath_expect "AC1: exactly one gh pr create call" "[ \"\$(wc -l < \"$bindir_a/pr-create-calls.log\")\" -eq 1 ]"
prpath_expect "AC1: exactly one gh pr merge --auto --squash call" "[ \"\$(wc -l < \"$bindir_a/pr-merge-calls.log\")\" -eq 1 ]"

record_a="$BUILD_STATE_DIR/landings/$repo_slug_a/pvbA-slug.json"
prpath_expect "AC1: landing record was written" "[ -f \"$record_a\" ]"
prpath_expect "AC1: landing record has pr_number" \
  "[ -n \"\$(python3 -c 'import json;print(json.load(open(\"$record_a\")).get(\"pr_number\",\"\"))' 2>/dev/null)\" ]"
prpath_expect "AC1: landing record head_sha == landed sha" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$record_a\")).get(\"head_sha\",\"\"))')\" = \"$landed_sha_a\" ]"
prpath_expect "AC1: landing record has armed_at" \
  "[ -n \"\$(python3 -c 'import json;print(json.load(open(\"$record_a\")).get(\"armed_at\",\"\"))' 2>/dev/null)\" ]"

prpath_expect "AC1: journal has a landing-pending line" "grep -q landing-pending \"$journal_a\""
prpath_expect "AC2: extend-gate.sh was NEVER called at --scope main" "! grep -q 'scope=main' \"$gate_calls_a\""
prpath_expect "AC2: no post-land-main-gate-block journal line" "! grep -q post-land-main-gate-block \"$journal_a\""
prpath_expect "AC2: no main-scope ci-checks receipt reference in the journal" "! grep -q 'post-land-main-gate-pass' \"$journal_a\""

sidecar_a="$BUILD_STATE_DIR/status/pvbA-slug.json"
prpath_expect "AC1: sidecar last_step=landing-pending" \
  "[ -f \"$sidecar_a\" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"last_step\")==\"landing-pending\" else 1)' \"$sidecar_a\""

# =========================================================================
# Scenario B (AC2) — push_via_branch=false (or unrecorded): behaviour is
# unchanged from before this PRD — no loop/<slug> branch, no gh calls.
# =========================================================================
echo "=== Scenario B: push_via_branch=false (unrecorded) — unchanged behaviour ==="
export BUILD_WT_ROOT="$ROOT/build-worktrees-b"
read -r REPO_B WT_B < <(mk_repo_and_branch pvbB)
export BUILD_STATE_DIR="$ROOT/state-b"
mkdir -p "$BUILD_STATE_DIR"
# no branch-protection.json at all -- push_via_branch_for defaults to false

bindir_b="$ROOT/bin-b"
prpath_install_gh_stub "$bindir_b"
gate_calls_b="$ROOT/gate-calls-b.log"
: > "$gate_calls_b"
journal_b="$ROOT/journal-b.md"

out_b="$ROOT/out-b.log"
env PATH="$bindir_b:$PATH" \
    GATE_THEN_LAND_EXTEND_GATE="$ROOT/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$journal_b" WORKTREE_EXTEND_JOURNAL="$journal_b" \
    PRPATH_GATE_CALLS_LOG="$gate_calls_b" \
    "$GTL" "$REPO_B" pvbB-slug minor /dev/null >"$out_b" 2>"$out_b.err"
rc_b=$?
cat "$out_b" "$out_b.err" >&2

prpath_expect "AC2: gate-then-land exits 0 (unchanged)" "[ $rc_b -eq 0 ]"
prpath_expect "AC2: no loop/<slug> branch was ever created" \
  "! git -C \"$REPO_B\" show-ref --verify --quiet refs/heads/loop/pvbB-slug"
prpath_expect "AC2: no gh calls at all (create log empty)" "[ ! -s \"$bindir_b/pr-create-calls.log\" ]"
prpath_expect "AC2: no gh calls at all (merge log empty)" "[ ! -s \"$bindir_b/pr-merge-calls.log\" ]"
prpath_expect "AC2: no landing record directory was created" "[ ! -d \"$BUILD_STATE_DIR/landings\" ]"
prpath_expect "AC2: journal has an ordinary 'landed' line, not landing-pending" \
  "grep -q ' landed ' \"$journal_b\" && ! grep -q landing-pending \"$journal_b\""

exit "$prpath_fail"
