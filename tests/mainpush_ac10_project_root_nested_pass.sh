#!/usr/bin/env bash
# mainpush_ac10_project_root_nested_pass.sh — PRD-build-main-push-gate-
# nested-project-root AC1 (P0): given a repo whose Cargo crate is nested at
# <repo>/autobuilder/, when main-push-gate.sh <repo> --project-root
# autobuilder runs against a HEAD whose NESTED
# autobuilder/target/autobuilder/last-verdict.json reports delta-pass at
# that HEAD, then the script exits 0 and does not refuse the push — proof
# the --project-root flag makes the nested verdict visible (before this
# PRD, the script only ever looked at <repo>/target/autobuilder/
# last-verdict.json, which never exists for a nested crate). Kept
# separate from the AC3 (unflagged, repo-root-crate) regression file per
# requirement 7 — two files, not one test asserting both.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac10.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

REPO="$ROOT/nested-repo"
mkdir -p "$REPO/autobuilder"
git -C "$REPO" init -q -b main
printf 'nested crate root\n' > "$REPO/autobuilder/Cargo.toml"
printf 'seed\n' > "$REPO/README.md"
git -C "$REPO" -c user.name=t -c user.email=t@e.com add -A
git -C "$REPO" -c user.name=t -c user.email=t@e.com commit -q -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# The verdict this PRD needs visible: written under the NESTED crate's own
# target/, exactly where a nested crate's real gate run leaves it (never at
# <repo>/target/autobuilder/, which is what the pre-PRD script only knew
# how to read).
mkdir -p "$REPO/autobuilder/target/autobuilder"
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "delta-pass", new_blocks: []}' \
  > "$REPO/autobuilder/target/autobuilder/last-verdict.json"

out="$ROOT/out"
bash "$MAINPUSH_GATE" "$REPO" --project-root autobuilder >"$out" 2>&1
rc=$?

mainpush_expect "AC10 (this PRD AC1): exit 0" '[ "$rc" -eq 0 ]'
mainpush_expect "AC10: does not refuse the push" '! grep -qi refused "$out"'
mainpush_expect "AC10: reports the resolved project-root" 'grep -q "project-root: autobuilder" "$out"'

exit "$mainpush_fail"
