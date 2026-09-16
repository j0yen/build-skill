#!/usr/bin/env bash
# mainpush_ac12_project_root_nested_without_flag_notfound.sh — PRD-build-
# main-push-gate-nested-project-root AC2 (P0): given the same nested-crate
# repo as AC1 (mainpush_ac10), when main-push-gate.sh <repo> runs WITHOUT
# --project-root, then it behaves exactly as it did before this PRD (looks
# at <repo>/target/autobuilder/last-verdict.json, finds nothing there, and
# follows the existing not-found path) — proving the flag is additive, a
# caller who forgets to pass it for a nested repo gets the pre-PRD
# not-found behavior, never a silent wrong-verdict read from the nested
# path it didn't ask for.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac12.XXXXXX")"
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

# Only the NESTED verdict exists (as a real nested-crate gate run would
# leave it) -- no <repo>/target/autobuilder/last-verdict.json at all.
mkdir -p "$REPO/autobuilder/target/autobuilder"
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "delta-pass"}' \
  > "$REPO/autobuilder/target/autobuilder/last-verdict.json"

out="$ROOT/out"
bash "$MAINPUSH_GATE" "$REPO" >"$out" 2>&1
rc=$?

mainpush_expect "AC12 (this PRD AC2): exit 5, same not-found rc as any repo-root miss" '[ "$rc" -eq 5 ]'
mainpush_expect "AC12: names the REPO-ROOT verdict path, not the nested one" \
  'grep -qF "$REPO/target/autobuilder/last-verdict.json" "$out"'
mainpush_expect "AC12: never silently reads the nested verdict it was not told about" \
  '! grep -q "delta-pass" "$out"'

exit "$mainpush_fail"
