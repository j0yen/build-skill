#!/usr/bin/env bash
# mainpush_ac2_matching_card_ok_under_180s.sh — PRD-build-main-push-gate
# AC2: given the same fixture with the card matching extended-gates.toml,
# when the gate runs, then exit 0 and `main-push  ok` with `wall=` under
# 180s on RedBaron.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac2.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

work="$(mainpush_mkfixture "$ROOT")"
gated="$(git -C "$work" rev-parse HEAD)"
matching="$(mainpush_matching_commit "$work")"

t0="$(date -u +%s)"
bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$matching" >/tmp/mainpush-ac2.$$.out 2>&1
rc=$?
t1="$(date -u +%s)"
wall_measured=$(( t1 - t0 ))
rm -f "/tmp/mainpush-ac2.$$.out"

mainpush_expect "AC2: exit 0"                 '[ "$rc" -eq 0 ]'
mainpush_expect "AC2: wall under 180s"        '[ "$wall_measured" -lt 180 ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
line="$(grep 'main-push  ok' "$journal_file" 2>/dev/null | tail -1)"
mainpush_expect "AC2: journal has ok line"        '[ -n "$line" ]'
mainpush_expect "AC2: journal has wall= field"    'printf "%s" "$line" | grep -q "wall="'

exit "$mainpush_fail"
