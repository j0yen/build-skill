#!/usr/bin/env bash
# mainpush_ac3_equal_shas_short_circuit.sh — PRD-build-main-push-gate AC3:
# given gated and head shas equal, when the gate runs, then exit 0,
# delta=0, and no check command is executed (stub command file untouched).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac3.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
head_sha="$(git -C "$work" rev-parse HEAD)"

# stub command file: the mapped check "touches" this if it ever actually
# runs (rewrite the delta command to append to it) -- AC3's proof that no
# command runs on the identical-sha path, not just that the exit code is 0.
stub="$ROOT/stub-touched"
sed -i "s#\"cargo test --test intent_card\"#\"touch $stub \&\& cargo test --test intent_card\"#" "$work/.buildloop/ci-equivalent.toml"

bash "$MAINPUSH_GATE" "$work" --gated "$head_sha" --head "$head_sha" >/tmp/mainpush-ac3.$$.out 2>&1
rc=$?
rm -f "/tmp/mainpush-ac3.$$.out"

mainpush_expect "AC3: exit 0"                    '[ "$rc" -eq 0 ]'
mainpush_expect "AC3: stub command file untouched" '[ ! -e "$stub" ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
line="$(grep 'main-push  ok' "$journal_file" 2>/dev/null | tail -1)"
mainpush_expect "AC3: journal has ok line"       '[ -n "$line" ]'
mainpush_expect "AC3: journal shows delta=0"     'printf "%s" "$line" | grep -q "delta=0"'

exit "$mainpush_fail"
