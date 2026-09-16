#!/usr/bin/env bash
# mainpush_ac13_project_root_missing_cargo_toml_fails_loud.sh — PRD-build-
# main-push-gate-nested-project-root AC4 (P1): given --project-root <rel>
# where <repo>/<rel>/Cargo.toml does not exist, main-push-gate.sh fails
# loud with a clear error naming the missing path, never silently falling
# back to repo root (same validation style as extend-gate.sh's own
# --project-root, PRD's Technical considerations).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac13.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

REPO="$ROOT/plain-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'seed\n' > "$REPO/f.txt"
git -C "$REPO" -c user.name=t -c user.email=t@e.com add -A
git -C "$REPO" -c user.name=t -c user.email=t@e.com commit -q -m init

out="$ROOT/out"
bash "$MAINPUSH_GATE" "$REPO" --project-root does-not-exist >"$out" 2>&1
rc=$?

mainpush_expect "AC13 (this PRD AC4): does not exit 0 (never silently proceeds)" '[ "$rc" -ne 0 ]'
mainpush_expect "AC13: error names the missing Cargo.toml path" \
  'grep -qF "$REPO/does-not-exist/Cargo.toml" "$out" || grep -qF "no Cargo.toml at --project-root does-not-exist" "$out"'
mainpush_expect "AC13: never falls back to a repo-root read (no ok/refused verdict emitted)" \
  '! grep -Eq "main-push-gate: ok|refused —" "$out"'

exit "$mainpush_fail"
