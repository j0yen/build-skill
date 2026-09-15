#!/usr/bin/env bash
# mainpush_ac4_prepush_hook_refuses_and_bypass.sh — PRD-build-main-push-gate
# AC4: given the pre-push hook installed and a local main ahead of remote
# by a red refresh commit, when `git push origin main` runs, then the push
# is refused by the hook with the gate's journal line and
# `git rev-parse origin/main` is unchanged; given
# MAIN_PUSH_GATE_BYPASS=1, then the push proceeds and the journal records
# `bypassed`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac4.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
# Point core.hooksPath at THIS repo's own scripts/repo-hooks (test
# isolation -- install-repo-hooks.sh's own default prefers the real
# ~/.claude/skills/build install; a fixture always overrides explicitly so
# the test exercises the real hook script without touching production
# wiring).
git -C "$work" config core.hooksPath "$MAINPUSH_SCRIPTS/repo-hooks"

remote_before="$(git -C "$work" ls-remote origin main | awk '{print $1}')"
mainpush_drift_commit "$work" >/dev/null

pushd "$work" >/dev/null
git push origin HEAD:main >/tmp/mainpush-ac4.$$.out 2>&1
push_rc=$?
push_out="$(cat "/tmp/mainpush-ac4.$$.out")"
rm -f "/tmp/mainpush-ac4.$$.out"
popd >/dev/null

mainpush_expect "AC4: hook refuses the push (nonzero)" '[ "$push_rc" -ne 0 ]'
mainpush_expect "AC4: remote main unchanged" '[ "$(git -C "$work" ls-remote origin main | awk "{print \$1}")" = "$remote_before" ]'
mainpush_expect "AC4: hook output names main-push-gate" 'printf "%s" "$push_out" | grep -q "main-push-gate"'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
mainpush_expect "AC4: journal has refused line" 'grep -q "main-push  refused" "$journal_file"'

# --- bypass ---
pushd "$work" >/dev/null
MAIN_PUSH_GATE_BYPASS=1 git push origin HEAD:main >/tmp/mainpush-ac4b.$$.out 2>&1
bypass_rc=$?
rm -f "/tmp/mainpush-ac4b.$$.out"
popd >/dev/null

mainpush_expect "AC4: bypass push succeeds" '[ "$bypass_rc" -eq 0 ]'
mainpush_expect "AC4: remote main advanced after bypass" '[ "$(git -C "$work" ls-remote origin main | awk "{print \$1}")" != "$remote_before" ]'
mainpush_expect "AC4: journal records bypassed" 'grep -q "main-push  bypassed" "$journal_file"'

exit "$mainpush_fail"
