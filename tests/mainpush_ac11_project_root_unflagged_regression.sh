#!/usr/bin/env bash
# mainpush_ac11_project_root_unflagged_regression.sh — PRD-build-main-push-
# gate-nested-project-root AC3 (P0): given a repo-root-crate repo (the
# common case, e.g. mcphost) with no --project-root passed, main-push-
# gate.sh's behavior (exit codes, messaging) is byte-identical to its
# pre-PRD behavior — the new flag is additive, not a rewrite. Uses the
# SAME repo-root fixture (mainpush_mkfixture) the pre-existing mainpush_ac*
# tests already pin, so this is a regression fixture in the sense the
# PRD's requirement asks for, not a new fixture shape. Kept separate from
# the AC1 (nested-pass) file per requirement 7 — two files, not one test
# asserting both.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac11.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
head_sha="$(git -C "$work" rev-parse HEAD)"

echo "=== no verdict file at all: same not-found path as before this PRD ==="
out1="$ROOT/out1"
bash "$MAINPUSH_GATE" "$work" >"$out1" 2>&1
rc1=$?
mainpush_expect "no-verdict: exit 5 (unchanged)" '[ "$rc1" -eq 5 ]'
mainpush_expect "no-verdict: names the repo-root verdict path (unchanged)" \
  'grep -qF "$work/target/autobuilder/last-verdict.json" "$out1"'

echo "=== repo-root verdict file present: same short-circuit as before this PRD ==="
mkdir -p "$work/target/autobuilder"
jq -n --arg h "$head_sha" '{head: $h, verdict: "delta-pass"}' \
  > "$work/target/autobuilder/last-verdict.json"
out2="$ROOT/out2"
bash "$MAINPUSH_GATE" "$work" >"$out2" 2>&1
rc2=$?
mainpush_expect "repo-root verdict: exit 0 (unchanged)" '[ "$rc2" -eq 0 ]'
mainpush_expect "repo-root verdict: delta=0 short-circuit (unchanged)" 'grep -q "delta=0" "$out2"'
mainpush_expect "repo-root verdict: no project-root line printed (additive-only, no new output on unflagged path)" \
  '! grep -q "project-root:" "$out2"'

exit "$mainpush_fail"
