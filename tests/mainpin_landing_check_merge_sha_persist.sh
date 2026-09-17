#!/usr/bin/env bash
# tests/mainpin_landing_check_merge_sha_persist.sh —
# PRD-build-main-verdict-pinned-to-landing, foundation piece of R1/AC1/
# AC2/AC4: "resolve S's merge sha M from state/landings/<repo>/<slug>.json
# (merge_sha; reconstructed_from allowed)" only works going forward if
# `branch-protection.sh landing-check` actually WRITES merge_sha into the
# record once GitHub reports the PR merged — before this PRD, `push`
# writes only pr_url/pr_number/head_sha(pre-squash)/armed_at, and
# `landing-check` computed merge_sha from `gh pr view` but only ever
# printed it to stdout, never persisted it (verified against the real
# record at state/landings/mcphost/mcphost-gate-debt-4f1112d.json, which
# has no top-level `merge_sha` field, only one embedded in prose inside
# `reconstructed_from`).
#
# This fixture: a landing record with no merge_sha field, a stub `gh pr
# view` reporting MERGED with mergeCommit.oid=M and all required contexts
# SUCCESS. `landing-check` must (a) still print "merged M" and exit 0
# (unchanged historical behavior) and (b) leave the record on disk with
# "merge_sha": "M" set. A second `landing-check` call (M unchanged) must
# be idempotent — same field, same value, no error. A `pending` verdict
# must NOT write any merge_sha field (never persist a value that isn't
# actually a merge).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
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

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-mergesha.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# --- tiny real git repo (landing-check/sync only need one commit) --------
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
repo_slug="$(basename "$work")"
slug="fixture-slug"

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"
record="$BUILD_STATE_DIR/landings/$repo_slug/$slug.json"
cat > "$record" <<EOF
{"pr_number": 42, "pr_url": "https://github.com/j0yen/$repo_slug/pull/42", "head_sha": "abc123", "armed_at": "2026-09-16T22:00:00Z"}
EOF
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

# --- stub gh: `auth status` ok; `pr view` returns $MAINPIN_GH_PR_JSON ----
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
: > "$bindir/pr-view-calls.log"
export PATH="$bindir:$PATH"

# --- case 1: merged, all required SUCCESS -> merge_sha persisted --------
export MAINPIN_GH_PR_JSON='{"state":"MERGED","mergeCommit":{"oid":"98eb6f521b2a18f03d1c80995bd5585ae5bd77a8"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
out="$("$BP" landing-check "$work" "$slug")"
rc=$?
expect "merged prints 'merged <sha>'" '[ "$out" = "merged 98eb6f521b2a18f03d1c80995bd5585ae5bd77a8" ]'
expect "merged exits 0" '[ "$rc" -eq 0 ]'
persisted="$(python3 -c "import json; print(json.load(open('$record')).get('merge_sha',''))")"
expect "merge_sha persisted into the landing record" '[ "$persisted" = "98eb6f521b2a18f03d1c80995bd5585ae5bd77a8" ]'
kept_head_sha="$(python3 -c "import json; print(json.load(open('$record')).get('head_sha',''))")"
expect "existing head_sha field untouched" '[ "$kept_head_sha" = "abc123" ]'

# --- case 2: re-run (idempotent) -----------------------------------------
out2="$("$BP" landing-check "$work" "$slug")"
rc2=$?
persisted2="$(python3 -c "import json; print(json.load(open('$record')).get('merge_sha',''))")"
expect "second landing-check call is idempotent" '[ "$rc2" -eq 0 ] && [ "$out2" = "$out" ] && [ "$persisted2" = "$persisted" ]'

# --- case 3: a second slug, still pending -> no merge_sha written --------
slug2="fixture-slug-pending"
mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"
record2="$BUILD_STATE_DIR/landings/$repo_slug/$slug2.json"
cat > "$record2" <<EOF
{"pr_number": 43, "pr_url": "https://github.com/j0yen/$repo_slug/pull/43", "head_sha": "def456", "armed_at": "2026-09-16T22:05:00Z"}
EOF
export MAINPIN_GH_PR_JSON='{"state":"OPEN","mergeCommit":null,"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}]}'
out3="$("$BP" landing-check "$work" "$slug2")"
rc3=$?
expect "pending prints 'pending'" '[ "$out3" = "pending" ]'
expect "pending exits 3" '[ "$rc3" -eq 3 ]'
has_merge_sha3="$(python3 -c "import json; print('merge_sha' in json.load(open('$record2')))")"
expect "pending verdict never writes merge_sha" '[ "$has_merge_sha3" = "False" ]'

exit "$fail"
