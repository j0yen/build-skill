#!/usr/bin/env bash
# mainpush_ac8_missing_ci_equivalent_unknown.sh — PRD-build-main-push-gate
# AC8: given a repo with no .buildloop/ci-equivalent.toml, when the gate
# runs, then exit 5 and the journal names the missing file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac8.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
gated="$(git -C "$work" rev-parse HEAD)"
rm -f "$work/.buildloop/ci-equivalent.toml"
git -C "$work" -c user.name="Fixture Bot" -c user.email="fixture@example.invalid" commit -aqm "remove ci-equivalent.toml"
head_sha="$(git -C "$work" rev-parse HEAD)"

out="$(bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$head_sha" 2>&1)"
rc=$?

mainpush_expect "AC8: exit 5"                         '[ "$rc" -eq 5 ]'
mainpush_expect "AC8: names the missing file"         'printf "%s" "$out" | grep -qF ".buildloop/ci-equivalent.toml"'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
mainpush_expect "AC8: journal has unknown line" 'grep -q "main-push  unknown" "$journal_file"'

exit "$mainpush_fail"
