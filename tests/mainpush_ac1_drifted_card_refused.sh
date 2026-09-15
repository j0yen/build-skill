#!/usr/bin/env bash
# mainpush_ac1_drifted_card_refused.sh — PRD-build-main-push-gate AC1:
# given a fixture mcphost worktree at a green gated head and a refresh
# commit that rewrites intent-card.json with the 3c11214 drift (prd_path
# mismatch), when main-push-gate.sh runs, then exit 4, no push occurs, and
# the journal line reads `main-push  refused … delta=1
# check="cargo test --test intent_card" rc=101`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac1.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
gated="$(git -C "$work" rev-parse HEAD)"
remote_before="$(git -C "$work" ls-remote origin main | awk '{print $1}')"
drift="$(mainpush_drift_commit "$work")"

out="$(bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$drift" 2>&1)"
rc=$?

mainpush_expect "AC1: exit 4"                 '[ "$rc" -eq 4 ]'
mainpush_expect "AC1: no push occurred"       '[ "$(git -C "$work" ls-remote origin main | awk "{print \$1}")" = "$remote_before" ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
line="$(grep 'main-push  refused' "$journal_file" 2>/dev/null | tail -1)"
mainpush_expect "AC1: journal has refused line"          '[ -n "$line" ]'
mainpush_expect "AC1: journal shows delta=1"             'printf "%s" "$line" | grep -q "delta=1"'
mainpush_expect "AC1: journal shows the mapped check"    'printf "%s" "$line" | grep -qF "check=\"cargo test --test intent_card\""'
mainpush_expect "AC1: journal shows rc=101"              'printf "%s" "$line" | grep -q "rc=101"'

exit "$mainpush_fail"
