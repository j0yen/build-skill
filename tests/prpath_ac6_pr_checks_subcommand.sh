#!/usr/bin/env bash
# tests/prpath_ac6_pr_checks_subcommand.sh — PRD-build-main-push-gate-pr-path
# AC6 (requirement 4), the `branch-protection.sh pr-checks` half: given a
# landing record and a stub `gh pr view` returning MERGED with all required
# contexts SUCCESS, `pr-checks` prints one JSON object with merge_sha and
# one context per required name, each with its conclusion; a mixed-result
# rollup reports each context's own conclusion (not collapsed to one
# verdict, unlike `landing-check`) -- this is the data extend-gate.sh's
# main-scope ci-checks producer builds its receipt from, without a second
# `gh` call or a second required-contexts reduction. Exactly one gh call
# per invocation, same as `landing-check`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac6.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR"

work="$(prpath_mk_repo "$ROOT/repo")"
repo_slug="$(basename "$work")"
slug="fixture-slug"

mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"
cat > "$BUILD_STATE_DIR/landings/$repo_slug/$slug.json" <<EOF
{"pr_number": 7, "pr_url": "https://github.com/j0yen/$repo_slug/pull/7", "head_sha": "abc123", "armed_at": "2026-09-16T22:00:00Z"}
EOF
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci", "sandbox"]}}
EOF

bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
export PATH="$bindir:$PATH"

# Both scenarios' `pr-checks` stdout is written to a FILE, not interpolated
# into a shell string -- the JSON itself is full of double quotes, which
# would break prpath_expect's `eval` if spliced straight into a condition
# string (caught live while building this fixture).

# --- all required contexts SUCCESS, MERGED --------------------------------
export PRPATH_GH_PR_JSON='{"state":"MERGED","mergeCommit":{"oid":"deadbeef"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"sandbox","status":"COMPLETED","conclusion":"SUCCESS"}]}'
: > "$bindir/pr-view-calls.log"
"$PRPATH_BP" pr-checks "$work" "$slug" > "$ROOT/out1.json"
rc=$?
calls="$(wc -l < "$bindir/pr-view-calls.log" | tr -d ' ')"
prpath_expect "AC6: pr-checks exits 0" "[ $rc -eq 0 ]"
prpath_expect "AC6: exactly one gh call" "[ \"$calls\" -eq 1 ]"
prpath_expect "AC6: merge_sha == deadbeef" \
  "python3 -c 'import json; d=json.load(open(\"$ROOT/out1.json\")); exit(0 if d[\"merge_sha\"]==\"deadbeef\" else 1)'"
prpath_expect "AC6: two contexts, both SUCCESS" \
  "python3 -c 'import json; d=json.load(open(\"$ROOT/out1.json\")); cs={c[\"name\"]:c[\"conclusion\"] for c in d[\"contexts\"]}; exit(0 if cs=={\"ci\":\"SUCCESS\",\"sandbox\":\"SUCCESS\"} else 1)'"

# --- mixed: one SUCCESS, one still PENDING --------------------------------
export PRPATH_GH_PR_JSON='{"state":"OPEN","mergeCommit":null,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"sandbox","status":"IN_PROGRESS"}]}'
"$PRPATH_BP" pr-checks "$work" "$slug" > "$ROOT/out2.json"
prpath_expect "AC6: mixed state == OPEN" \
  "python3 -c 'import json; d=json.load(open(\"$ROOT/out2.json\")); exit(0 if d[\"state\"]==\"OPEN\" else 1)'"
prpath_expect "AC6: mixed merge_sha empty" \
  "python3 -c 'import json; d=json.load(open(\"$ROOT/out2.json\")); exit(0 if d[\"merge_sha\"]==\"\" else 1)'"
prpath_expect "AC6: mixed contexts: ci=SUCCESS, sandbox=PENDING" \
  "python3 -c 'import json; d=json.load(open(\"$ROOT/out2.json\")); cs={c[\"name\"]:c[\"conclusion\"] for c in d[\"contexts\"]}; exit(0 if cs=={\"ci\":\"SUCCESS\",\"sandbox\":\"PENDING\"} else 1)'"

# --- no landing record -> exit 4 ------------------------------------------
rm -rf "$BUILD_STATE_DIR/landings"
out3="$("$PRPATH_BP" pr-checks "$work" "$slug" 2>"$ROOT/err3.log")"
rc3=$?
prpath_expect "AC6: no landing record -> exit 4" "[ $rc3 -eq 4 ]"

exit "$prpath_fail"
