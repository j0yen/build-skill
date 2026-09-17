#!/usr/bin/env bash
# tests/mainpin_landing_verdict_resolve_r7.sh —
# PRD-build-main-verdict-pinned-to-landing R1 (resolution order) + R7
# (missing/unusable landing record -> named error, no HEAD fallback).
#
# Four cases against scripts/landing-verdict-resolve.sh:
#   1. Record already has merge_sha -> prints it, makes NO gh call.
#   2. Record has no merge_sha but a pr_number, stub `gh pr view` reports
#      MERGED -> prints the merge sha AND persists it into the record
#      (via the shared landing-check path), exactly one gh call.
#   3. No landing record file at all -> exit 4,
#      "landing-record-unusable:record" in the journal, nothing on stdout.
#   4. Record has a merge_sha that resolves on neither the local repo nor
#      `origin` (a fetch does not produce it) -> exit 4,
#      "landing-record-unusable:sha" in the journal, nothing on stdout.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
LVR="$SKILL_DIR/scripts/landing-verdict-resolve.sh"
BP="$SKILL_DIR/scripts/branch-protection.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label ($cond)" >&2
    fail=1
  fi
}

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-lvr.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

origin="$ROOT/origin.git" work="$ROOT/work"
git init --bare -q -b main "$origin"
git clone -q "$origin" "$work"
(
  cd "$work"
  git config user.name "Fixture Bot"
  git config user.email "fixture@example.invalid"
  echo one > file.txt
  git add file.txt
  git commit -qm initial
  git push -q origin main
)
real_sha="$(git -C "$work" rev-parse HEAD)"
repo_slug="$(basename "$work")"

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
export LANDING_VERDICT_RESOLVE_BRANCH_PROTECTION="$BP"
mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"

bindir="$ROOT/bin"
mkdir -p "$bindir"
cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "auth status") exit 0 ;;
esac
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "call" >> "$(dirname "$0")/pr-view-calls.log"
  body="${MAINPIN_GH_PR_JSON:-{\}}"
  printf '%s' "$body"
  exit 0
fi
echo "gh-stub: unexpected invocation: $*" >&2
exit 1
STUB
chmod +x "$bindir/gh"
export PATH="$bindir:$PATH"

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"

# --- case 1: merge_sha already on the record -> no gh call --------------
slug1="slug-has-merge-sha"
record1="$BUILD_STATE_DIR/landings/$repo_slug/$slug1.json"
cat > "$record1" <<EOF
{"pr_number": 1, "pr_url": "https://github.com/j0yen/$repo_slug/pull/1", "head_sha": "abc", "armed_at": "2026-09-16T22:00:00Z", "merge_sha": "$real_sha"}
EOF
: > "$bindir/pr-view-calls.log"
out1="$("$LVR" "$work" "$slug1")"
rc1=$?
calls1="$(wc -l < "$bindir/pr-view-calls.log" | tr -d ' ')"
expect "case1: prints the record's merge_sha" '[ "$out1" = "$real_sha" ]'
expect "case1: exits 0" '[ "$rc1" -eq 0 ]'
expect "case1: no gh call made" '[ "$calls1" -eq 0 ]'

# --- case 2: no merge_sha, falls back to one landing-check call ---------
slug2="slug-fallback-merged"
record2="$BUILD_STATE_DIR/landings/$repo_slug/$slug2.json"
cat > "$record2" <<EOF
{"pr_number": 2, "pr_url": "https://github.com/j0yen/$repo_slug/pull/2", "head_sha": "def", "armed_at": "2026-09-16T22:05:00Z"}
EOF
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF
: > "$bindir/pr-view-calls.log"
export MAINPIN_GH_PR_JSON="{\"state\":\"MERGED\",\"mergeCommit\":{\"oid\":\"$real_sha\"},\"statusCheckRollup\":[{\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}"
out2="$("$LVR" "$work" "$slug2")"
rc2=$?
calls2="$(wc -l < "$bindir/pr-view-calls.log" | tr -d ' ')"
persisted2="$(python3 -c "import json; print(json.load(open('$record2')).get('merge_sha',''))")"
expect "case2: prints the resolved merge sha" '[ "$out2" = "$real_sha" ]'
expect "case2: exits 0" '[ "$rc2" -eq 0 ]'
expect "case2: exactly one gh call" '[ "$calls2" -eq 1 ]'
expect "case2: persists merge_sha into the record" '[ "$persisted2" = "$real_sha" ]'

# --- case 3: no landing record at all ------------------------------------
slug3="slug-missing-record"
out3="$("$LVR" "$work" "$slug3" 2>/dev/null)"; rc3=$?
expect "case3: stdout empty" '[ -z "$out3" ]'
expect "case3: exits 4" '[ "$rc3" -eq 4 ]'
expect "case3: journal names landing-record-unusable:record" \
  'grep -q "landing-record-unusable:record" "$journal_file" 2>/dev/null'

# --- case 4: merge_sha set but unresolvable even after a fetch ----------
slug4="slug-bad-sha"
record4="$BUILD_STATE_DIR/landings/$repo_slug/$slug4.json"
bogus_sha="0000000000000000000000000000000000dead"
cat > "$record4" <<EOF
{"pr_number": 4, "pr_url": "https://github.com/j0yen/$repo_slug/pull/4", "head_sha": "ghi", "armed_at": "2026-09-16T22:10:00Z", "merge_sha": "$bogus_sha"}
EOF
out4="$("$LVR" "$work" "$slug4" 2>/dev/null)"; rc4=$?
expect "case4: stdout empty" '[ -z "$out4" ]'
expect "case4: exits 4" '[ "$rc4" -eq 4 ]'
expect "case4: journal names landing-record-unusable:sha" \
  'grep -q "landing-record-unusable:sha" "$journal_file" 2>/dev/null'

exit "$fail"
