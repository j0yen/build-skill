#!/usr/bin/env bash
# mainpush_ac9_timeout_is_unknown_not_refused.sh — PRD-build-main-push-gate
# AC9: given the check command exceeds the timeout, when the gate runs,
# then exit 5 with rc=124 and the branch is deferred, not pushed. Uses
# MAIN_PUSH_GATE_TIMEOUT=1 to keep this test fast rather than waiting out
# the real 15-minute ceiling — the ceiling itself is a one-line env read
# in main-push-gate.sh, not re-derived here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac9.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
sed -i 's#"cargo test --test intent_card"#"sleep 3 \&\& cargo test --test intent_card"#' "$work/.buildloop/ci-equivalent.toml"
git -C "$work" -c user.name="Fixture Bot" -c user.email="fixture@example.invalid" commit -aqm "slow delta mapping baseline"
gated="$(git -C "$work" rev-parse HEAD)"
matching="$(mainpush_matching_commit "$work")"
remote_before="$(git -C "$work" ls-remote origin main | awk '{print $1}')"

out="$(MAIN_PUSH_GATE_TIMEOUT=1 bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$matching" 2>&1)"
rc=$?

mainpush_expect "AC9: exit 5"                  '[ "$rc" -eq 5 ]'
mainpush_expect "AC9: no push occurred"        '[ "$(git -C "$work" ls-remote origin main | awk "{print \$1}")" = "$remote_before" ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
line="$(grep 'main-push  unknown' "$journal_file" 2>/dev/null | tail -1)"
mainpush_expect "AC9: journal has unknown line" '[ -n "$line" ]'
mainpush_expect "AC9: journal shows rc=124"     'printf "%s" "$line" | grep -q "rc=124"'

exit "$mainpush_fail"
